# STRUGGLES

A field log of everything that fought back while building `mojo-requests` against
**Mojo 1.0.0b3** (`dev2026071921`, nightly). Mojo is a moving target in a raw, pre-stable
state — most of these are language/stdlib gaps, compiler bugs, or behaviors that contradict
both the docs and pretrained knowledge.

Each entry has: **Symptom** (what you see), **Cause** (why), **Fix** (what we do), and a
**Where** pointer into the codebase. This exists so nobody re-discovers these the hard way.

> Companion docs: [`AGENTS.md`](AGENTS.md) (contributor orientation + gotchas) and
> [`TODO.md`](TODO.md) (roadmap). This file is the long-form, narrative version of the pain.

---

## 1. Strings × FFI × `unsafe_ptr()` — the worst class of bug

Three distinct-but-related failures, all in the String→C boundary. These were the hardest to
diagnose because the bytes were *correct at call time* but the C library saw garbage.

### 1.1 `String.unsafe_ptr()` is not stable across an FFI call boundary

**Symptom:** `SSL_CTX_load_verify_locations(ctx, path, NULL)` returned `rc=0` with OpenSSL's
error queue reporting `system library::No such file or directory` / `BIO routines::no such
file` — even though the path bytes were correct when printed.

**Cause:** A Mojo `String`'s backing buffer can be **clobbered between the moment the FFI
shim materializes the C-ABI argument and the moment the C library actually dereferences it**.
The window opens whenever other heap activity happens in between (e.g. `build_request`
doing Dict + String concat work, which runs before OpenSSL gets to open the file). The shim
hands OpenSSL a pointer into String storage that gets relocated/overwritten.

**Fix:** Copy the string into an explicitly `alloc`'d, NUL-terminated buffer that we own and
pass *that* pointer. Applied for both the CA bundle path and the SNI hostname.

**Where:** [`requests/_tls.mojo`](requests/_tls.mojo) — `connect()` CA-bundle block
(~L124-136) and SNI block (~L182-190). When debugging OpenSSL failures, drain the error
queue with `ERR_get_error` + `ERR_error_string_n` (helper: `_drain_openssl_errors`).

### 1.2 Strings built char-by-char from FFI bytes carry a rejected internal representation

**Symptom:** A `String` assembled by `out += String(Codepoint(...))` (e.g. from `_getenv`)
was rejected by OpenSSL when its `.unsafe_ptr()` was passed in.

**Cause:** The incremental build leaves an internal representation whose `.unsafe_ptr()`
points at something C libraries reject — the layout isn't the canonical contiguous form.

**Fix:** Round-trip through `String() + x` to normalize the layout before handing the pointer
to OpenSSL:

```mojo
resolved_path = String() + ca_bundle.value()   # normalize, then it's safe to unsafe_ptr()
```

**Where:** [`requests/_tls.mojo`](requests/_tls.mojo) — `connect()` trust-store resolution
(~L100-117). Comment calls it out as a "Mojo String-build artifact observed in 1.0 beta".

### 1.3 `external_call` JIT-crashes (does NOT raise) on a missing symbol

**Symptom:** Needed to read `errno` portably. Tried `external_call["__error", ...]` (macOS)
with a `try/except` fallback to `external_call["__errno_location", ...]` (Linux). The
`except` branch never fired.

**Cause:** `external_call` resolves the symbol at JIT time. If the symbol is missing, it
does **not** raise a Mojo `Error` — it hard-crashes the JIT with `Failed to materialize
symbols`. So you cannot probe for platform-specific libc symbols at runtime.

**Fix:** Use a POSIX API that exists on **every** platform instead. For timeout detection
we switched to `getsockopt(SO_ERROR)` (standard POSIX, resolves on both macOS and Linux)
instead of the `__error`/`__errno_location` errno accessors.

**Where:** [`requests/_net.mojo`](requests/_net.mojo) — `_is_timeout()` (~L162-185) and its
docstring.

---

## 2. String slicing — interior-reference lifetime bugs

### 2.1 Cannot slice a `String` and reassign to itself

**Symptom:** Compiler error `use of invalidated interior reference` on patterns like
`size_str = String(size_str[byte=0:semi])`.

**Cause:** The RHS slice (`size_str[byte=...]`) holds an *interior reference* into `size_str`'s
buffer. The LHS reassignment of `size_str` invalidates that origin before the slice is
materialized — classic dangling-origin.

**Fix:** Slice into a fresh local first, then assign:

```mojo
var sliced = String(size_str[byte=0:semi])   # fresh local
size_str = sliced
```

**Where:** [`requests/_http.mojo`](requests/_http.mojo) `_dechunk` (~L220) and
[`requests/_url.mojo`](requests/_url.mojo) `parse_url` (fragment/query slicing ~L84-92).
This one surfaced specifically when CI ran a newer nightly (`dev2026072006`) — the older
build had tolerated it.

---

## 3. Ownership, move semantics, and `Movable`

### 3.1 `OwnedPointer[T]` requires `T` to be `Movable` (+ hand-written `__moveinit__`)

**Symptom:** `OwnedPointer[Foo](foo^)` refused to compile for a `Foo` with a `__del__`.

**Cause:** Mojo's `OwnedPointer` needs to move its payload, but a struct with a destructor
doesn't get an auto-synthesized move constructor.

**Fix:** Declare `struct Foo(Movable):` and hand-write `__moveinit__` — copy every field,
then neuter the source's destructor side effects (set its `closed = True`, `fd = -1`, etc.).

**Where:** [`requests/_streaming.mojo`](requests/_streaming.mojo) `StreamingConn.__moveinit__`
(~L57-70) — the canonical worked example.

### 3.2 `Optional[OwnedPointer[T]]` is not implicitly copyable — steal with `^`

**Symptom:** Couldn't move a libssl handle out of an `Optional[OwnedPointer[OwnedDLHandle]]`.

**Cause:** The `Optional[OwnedPointer[...]]` nesting makes the type non-`ImplicitlyCopyable`,
and `.value()` returns a borrow, not an owned value.

**Fix:** Steal the inner value and reset the source:

```mojo
var h = self._opt^
self._opt = None
return h^
```

**Where:** [`requests/_tls.mojo`](requests/_tls.mojo) `_steal_ssl` / `_steal_libssl` (~L274-288).

### 3.3 `^` transfers ownership for every non-`ImplicitlyCopyable` type

`Dict`, `Response`, `Optional[OwnedPointer]`, `CookieJar`, `List` — all require `^` at the
use site when transferring. Call sites everywhere; documented in [`AGENTS.md`](AGENTS.md) and
[`README.md`](README.md).

### 3.4 Can't move a `Dict` field out of a struct while other fields are read

**Symptom:** Wanted to move `parsed.headers` (a `Dict`) out and keep reading other fields of
`parsed`. Compiler refused.

**Cause:** `Dict` is non-copyable. Partial move of one field invalidates the struct, so you
can't borrow siblings after moving one.

**Fix:** Take the whole owning struct by value (`var parsed: ParsedResponse`) and move the
whole thing; rebuild the `Dict` into a fresh one for the fields you still need.

**Where:** [`requests/_http.mojo`](requests/_http.mojo) `_build_parsed` (~L160-167) and
[`requests/session.mojo`](requests/session.mojo) `_build_response` (~L540-552). The docstrings
spell this out as "avoids partial-move errors".

### 3.5 `UnsafePointer` is non-nullable — null C-ABI args need `c_int(0)`

For FFI null pointers (e.g. the `CApath` parameter of `SSL_CTX_load_verify_locations`), pass
`c_int(0)` — the FFI shim widens it to a null pointer. **Where:** [`requests/_tls.mojo`](requests/_tls.mojo) (~L121, L159, L164).

---

## 4. The error / exception model — a design goal that's partially impossible

The whole exception refactor (the last open roadmap item) ran head-first into four language
limits. The intended design — *distinct typed structs per category AND runtime typed
dispatch* — is **mutually exclusive** in this build. Full write-up in [`TODO.md`](TODO.md)
"Implementation notes"; the short version:

### 4.1 No multi-type `raises` union

`raises A | B`, `raises A, B`, and `raises [A, B]` all fail to parse. A function that raises
two categories (e.g. `parse_url` raises both `InvalidURL` and `UnsupportedScheme`) must stay
bare `raises`.

### 4.2 Strict typed propagation — `raises A` cannot call `raises B`

Hard compiler error: `cannot call function that may raise 'B' in context that supports an
error type of 'A'`. The Session orchestration layer (`_do_request` → `request` → `get`/`post`)
fans out to 5+ disjoint error types, so it all stays bare `raises`.

### 4.3 Same-`try`-block type unification

A `try` block infers its exception type from its typed raisers and forbids coexistence with
wider types. A typed `raises SSLError` call and a bare `raises` call **cannot share one try
block**. Worked around by splitting the session's connect/send/recv try blocks per scheme
(`is_https` branches each get their own try/except).

**Where:** [`requests/session.mojo`](requests/session.mojo) (~L222-280) — there's a NOTE
comment explaining the split.

### 4.4 No runtime type recovery on a caught `Error`

`__get_original_error_value_as[T]()` does not exist. A caught `Error` exposes no fields;
`repr(e)` shows `Error('ConnectionError(msg=...)')` — the struct is stringified away.
Concrete fields are accessible only within the same typed-`raises` context. Across a
bare-`raises` boundary, only the rendered `write_to` string survives.

### 4.5 Consequence — `exception_kind()` must stay string-prefix-based

Because of 4.4, runtime dispatch is done by parsing the message prefix (`"SSLError: ..."`,
`"HTTPError 404: ...`). Each exception struct's `write_to` emits a prefix pinned by a
`comptime *_PREFIX` constant so the classifier and the structs can't drift.

**Where:** [`requests/exceptions.mojo`](requests/exceptions.mojo) — module docstring (~L13-26)
and `exception_kind()` docstring (~L164-173).

### 4.6 Bonus: `Error` is a builtin struct, not a user trait

You don't conform to `Error`; you `raise MyStruct(...)` and Mojo wraps it. A caught value is
always the builtin `Error`. This is why 4.4 holds.

### 4.7 Re-raise with `raise e^` to preserve the concrete type

`Error` is not `ImplicitlyCopyable`, so `raise e` fails (`cannot be implicitly copied`). Use
`raise e^` to transfer ownership — this preserves the concrete struct type through the `Error`
wrapper (verified: the `write_to` renders the original struct). Applied as a behavior fix
during the exception refactor: an SSL handshake failure during `s.get(...)` now surfaces as
`SSLError: ...` instead of being flattened into `RequestException: SSLError: ...`.

---

## 5. DNS / networking — lazy init, heap-state-dependent flakiness

### 5.1 `getaddrinfo` lazy-inits and fails on the very first resolve in a process

**Symptom:** The first real DNS lookup in a fresh Mojo process intermittently fails.

**Cause:** The libc resolver initializes lazily; the very first call can return failure on
some systems. Combined with heap-state-dependent behavior in Mojo 1.0 beta.

**Fix:** `Session.__init__` warms the resolver with a throwaway `_dns_resolve("localhost")`.
Keep that priming call.

**Where:** [`requests/session.mojo`](requests/session.mojo) (~L42-48).

### 5.2 First contact with a real hostname can still hiccup → retry with backoff

Even after warmup, the first lookup of an external hostname can fail transiently.
`_getaddrinfo` retries up to **5 times** with exponential backoff (50/100/200/400ms via
`std.time.sleep`, which replaced a hand-rolled `nanosleep` FFI + `struct timespec` — `std.time`
is the idiomatic Mojo way and dropped the libc `Timespec` mirror entirely). This was bumped
from 3→5 after the macOS CI runner failed with the shorter retry.

**Where:** [`requests/_dns.mojo`](requests/_dns.mojo) `_getaddrinfo` retry loop.

### 5.3 Resolve DNS before header Dict allocations (ordering workaround)

The session resolves DNS *before* building the header `Dict` and request string — because
those allocations perturb the heap state in a way that can make `getaddrinfo` fail. The IP is
resolved up front and passed directly to `connect`.

**Where:** [`requests/session.mojo`](requests/session.mojo) `_do_request` (~L175-176).

### 5.4 `gethostbyname` is unsafe (static buffer) → switched to `getaddrinfo`

`gethostbyname` returns a pointer to a static buffer — not thread-safe. `getaddrinfo` is
thread-safe and heap-allocated. This switch also fixed a heap-state-dependent DNS failure in
the session flow.

### 5.5 CI must not depend on external DNS/TLS — local server mandate

GitHub-hosted macOS/Linux runners intermittently failed to resolve `example.com`. The test
suite now runs a local HTTP+HTTPS server (`tests/server.py`, started by
[`pixi run server`](pixi.toml)) and feeds `BASE_URL`/`HTTPS_BASE_URL`/`SSL_CERT_FILE` into the
tests via env. **Do not introduce tests that require real outbound DNS/TLS.**

**Where:** [`tests/server.py`](tests/server.py), [`.github/workflows/ci.yml`](.github/workflows/ci.yml),
[`AGENTS.md`](AGENTS.md) CI section.

### 5.6 `AF_INET6` is NOT portable (30 on macOS/BSD, 10 on Linux) — never hard-code it

**Symptom:** `inet_pton(AF_INET6, "::1", &dst)` returned `-1` (`EAFNOSUPPORT`) on macOS when
`AF_INET6` was declared as `comptime AF_INET6: c_int = 10` (the Linux value). Resolving any
IPv6 literal failed immediately.

**Cause:** The address-family constants aren't fixed by POSIX the way `AF_INET` (2) is.
`AF_INET6` is **30 on macOS/BSD** and **10 on Linux** — verified empirically with a C probe
(`#include <sys/socket.h>`; `printf("AF_INET6=%d\n", AF_INET6)`). The original plan assumed
they were identical; they are not.

**Fix:** Don't hard-code `AF_INET6` anywhere. **Discover it at runtime** with `_af_inet6()`:
call `inet_pton(candidate, "::1", &dst)` against each known family value (`10` Linux, `30`
macOS/BSD) and keep whichever returns `1`. For `socket()` / `sin6_family`, carry that value
through in `ResolvedAddress.pf` and pass *that* (not a comptime constant). Family detection in
the addrinfo walk compares against the portable `AF_INET` (2) and treats anything else as IPv6
— with our `AF_UNSPEC` + `SOCK_STREAM` hints, `getaddrinfo` only ever returns AF_INET or
AF_INET6, so this is safe.

**Correction (2026-07):** an earlier version of this Fix said to route IPv6 literals through
`getaddrinfo(host, AI_NUMERICHOST)` "because it reports the correct per-platform `ai_family`".
That was **wrong in practice** — `getaddrinfo` consults the kernel's configured address families
and **FAILS for `::1` / `2001:db8::1` on hosts with no IPv6 networking** (GitHub ubuntu runners),
even though the text is valid. It broke `test_resolve_ipv6_*` on ubuntu-latest CI (see commit
`3d42d01`). `inet_pton` is a pure userspace text→binary parser with no kernel dependency, so it
works everywhere — which is why literal parsing now uses `_af_inet6()` + `inet_pton`, and
`getaddrinfo` is reserved for the *hostname* path only. The `AI_NUMERICHOST` comptime const was
deleted (dead code).

**Where:** [`requests/_dns.mojo`](requests/_dns.mojo) — `_af_inet6()` probe + `resolve()` IPv6
branch (no `AF_INET6` comptime const exists; family carried via `ResolvedAddress.pf`),
[`requests/_net.mojo`](requests/_net.mojo) `_do_connect`.

### 5.7 Sliced-String host handed to `getaddrinfo` gets clobbered (same class as §1.1)

**Symptom:** `resolve("::1")` worked in isolation, but `resolve(parse_url("http://[::1]:8080/").host)`
failed with `ConnectionError: DNS resolution failed for host: ::1` — same bytes (3, `::1`), same
call, different outcome.

**Cause:** This is the §1.1 `String.unsafe_ptr()`-not-stable-across-FFI bug, surfacing in DNS
rather than TLS. `parse_url` extracts the host via `String(authority[byte=1:close])`; by the
time `_getaddrinfo` passes `host.unsafe_ptr()` to `getaddrinfo`, intervening allocations
(`alloc[AddrInfo]`, the result ptr) have clobbered the buffer the FFI shim materialized. The
sliced host's backing storage is especially fragile.

**Failed attempt at the fix:** `String() + x` normalization (the §1.2 recipe for char-by-char
strings) made it *worse* — the concatenation produces a buffer getaddrinfo rejects even more
reliably. (§1.2's "normalize with `String() + x`" is not a universal cure; it helps some
String-build artifacts and hurts others. Diagnose, don't cargo-cult.)

**Fix:** Copy the host into an explicitly `alloc`'d, NUL-terminated buffer that we own and pass
*that* pointer — the same pattern `_tls.mojo` uses for the CA-bundle path and SNI hostname
(`_cstr` helper). Applied to both `inet_pton` and `getaddrinfo` calls in `_dns.mojo`.

**Where:** [`requests/_dns.mojo`](requests/_dns.mojo) `_cstr` helper + its call sites in
`resolve` / `_getaddrinfo`.

---

## 6. Missing stdlib

### 6.1 No `std.json` → hand-written recursive-descent parser

Mojo 1.0 has no `std.json`. We ship a minimal parser in [`requests/_json.mojo`](requests/_json.mojo).
Because `JSONValue` is recursive (objects/arrays contain `JSONValue`s), the collection fields
are heap-allocated behind `OwnedPointer` so the struct has a fixed, deletable layout.

### 6.2 No `std.net` / `std.socket` → raw libc FFI

Every socket operation is `external_call["socket"|"connect"|"send"|"recv"|"close"|"setsockopt", ...]`.
No higher-level networking abstraction exists. See [`requests/_net.mojo`](requests/_net.mojo),
[`requests/_dns.mojo`](requests/_dns.mojo).

### 6.3 No mutable globals → each TLSConnection owns its own `dlopen` handle

Mojo has no mutable module-level state. So we can't cache the libssl handle globally — each
`TLSConnection` opens (and closes) its own `OwnedDLHandle`. There's a small cost but it's the
only correct option.

**Symptom (exact):** a top-level `var x: c_int = ...` fails to *compile* with
`global variables are not supported; move this into a function body or use 'comptime' to declare
a constant`. This is a hard parse error, not a runtime issue — the module won't build at all.
`comptime X = ...` works for *immutable* constants, but there is no mutable equivalent.

**Consequence for caching:** you cannot memoize an expensive probe in a module-level cache. The
`_af_inet6()` DNS probe (§5.6) originally tried `var _af_inet6_cache: c_int = -1` and hit exactly
this error (commit `3d42d01`); the fix was to drop the cache and just re-probe (cheap). Any
"compute once, stash globally" pattern must instead thread the value through a struct field or
recompute.

**Where:** [`requests/_tls.mojo`](requests/_tls.mojo) `_load_libssl` (~L306-333),
[`requests/_dns.mojo`](requests/_dns.mojo) `_af_inet6()`.

### 6.4 Async exists (`std.runtime.asyncrt`); threading primitives do not

**Correction of this entry's old claim.** The original text said "no `std.async`, no `Coroutine`,
no `async`/`await`." That is **wrong for this build**. Native async is present:

- **`std.runtime.asyncrt`** imports cleanly and exposes `Task[type, origins]`,
  `RaisingTask[type, origins]`, `TaskGroup`, `TaskGroupContext`, and the free functions
  `create_task(handle, out task)`, `create_raising_task[...](handle, out task)`, and
  `parallelism_level() -> Int` (returns host CPU core count; there is also a GPU-flavoured
  overload taking `Optional[DeviceContext]`).
- **`async def`/`await` syntax works.** `async def foo() -> T` produces a `Coroutine[T, {}]`;
  `async def foo() raises -> T` produces a `RaisingCoroutine[T, {}]`. `await` is a real operator
  dispatching on `__await__`. `Coroutine`/`RaisingCoroutine` live in `std.builtin.coroutine`
  (not `std.coroutine`).
- A native runtime backs it: `libAsyncRTMojoBindings.dylib` + `libAsyncRTRuntimeGlobals.dylib`
  ship with the toolchain. No explicit start/stop API — `parallelism_level()` works with no
  setup.

**What is still absent in this build** (the threading half of the original claim stands):
`std.thread`, `std.socket`, `std.ssl`, `std.net`, `std.json`, `std.unsafe`, `std.ptr` are all
missing. So raw libc FFI for sockets/networking (§6.2) and the hand-written JSON parser (§6.1)
remain necessary — but a concurrency layer now exists on top of them.

**Ergonomic gaps in this build** (honest caveats — the API is real but rough for an HTTP client
that wants parallel requests):
- `TaskGroup` exposes only `__init__` / `__del__` / `wait` — **no public `.add()` / `.spawn()`**.
  Tasks are associated with a group via the `TaskGroupContext` callback + `create_task`'s
  `out` parameter, not a direct submit.
- `TaskGroupContext`'s constructor takes an **unsafe `Pointer[TaskGroup, MutUntrackedOrigin]`**,
  which has no clean construction path in this build (no `std.unsafe`/`std.ptr`).
- The context's callback must be **`thin` (non-raising)** — a `def cb(mut g: TaskGroup) raises`
  is rejected. Raising work has to propagate via `RaisingTask.wait`'s `out result` instead.
- `DeviceContext` (the GPU context re-exported into asyncrt) fails to construct on a host
  without a GPU, so the `parallelism_level(ctx)` overload is effectively GPU-only here.

**So:** a future `AsyncSession.gather()` should target `std.runtime.asyncrt`, not the
hand-rolled `poll()` loop this file used to recommend. The `poll()` approach is now a fallback
if the asyncrt surface stays this rough. See [`TODO.md`](TODO.md) "Async support" for the
reframed plan.

### 6.5 Pure-Mojo TLS is explicitly out of scope

Re-implementing TLS 1.3 (state machine, AEAD, X.509 path validation, constant-time crypto) in
Mojo would dwarf the rest of the library. OpenSSL via FFI is battle-tested and
auto-discovered. Struck through in [`TODO.md`](TODO.md).

---

## 7. Collections / iterators / deprecated syntax

### 7.1 No clean way to return an iterable → `_ItemsRef` shim

`Headers.items()` needs to hand back something iterable. There's no direct way to return an
iterator over `Dict` entries, so we wrap it in a `_ItemsRef` helper struct.

**Where:** [`requests/models.mojo`](requests/models.mojo) (~L56-58).

### 7.2 `read` is deprecated → use `imm` for buffer access

`build_request` originally used `read url: URL`. In current nightlies `read` is deprecated in
this position; `imm` is the replacement.

**Where:** [`requests/_http.mojo`](requests/_http.mojo) `build_request` signature (~L18-23).

### 7.3 Can't move out of `Optional.value()` directly — copy bytes

In `iter_content`, copying bytes out of a borrowed `Optional.value()` can't be done by moving
— you copy element-by-element into a fresh `List`.

**Where:** [`requests/models.mojo`](requests/models.mojo) (~L152).

---

## 8. Build / toolchain / CI

### 8.1 Targeting a moving nightly

Pinned to `>=1.0.0b3.dev2026071921,<2` in [`pixi.toml`](pixi.toml). A newer nightly
(`dev2026072006`) surfaced the interior-reference bugs in §2.1. Older/newer builds may need
small tweaks.

### 8.2 `mojo format` is canonical and CI-enforced

CI's `fmt-check` task runs `mojo format --quiet` then `git diff --exit-code` — it fails if any
source diverges from canonical formatting. Always run `pixi run mojo format requests/ tests/ examples/`
before committing.

### 8.3 Per-invocation compile cost (~960 ms) dominates `mojo run`

`mojo run` recompiles every time. For the benchmark, the fair comparison is a pre-built binary
(`mojo build`); the `mojo run` row is shown for reference only and is ~13× slower purely from
compile time. See [`README.md`](README.md) Benchmark section.

### 8.4 Local `requests/` dir shadows pip's `requests` for Python benchmarks

The Python benchmark scripts must run from `/tmp` (or be copied there) — otherwise the local
Mojo `requests/` package dir shadows pip's `requests`.

**Where:** [`benchmark/run.sh`](benchmark/run.sh) (~L58, L70).

### 8.5 Platform detection — three spellings, one works in this build

**Symptom:** Needed OS-conditional code (originally for portable `AF_INET6` naming and the errno
accessor in §1.3).

**Cause — the names moved around; this entry chased them twice.** The original text tested the
GPU-skill spellings `is_apple` / `is_linux` / `is_macos` and the C-isms `target_os` /
`__is_macosx` / `OS.macOS` — all wrong. Verified now, there are **three** legitimate spellings
in `std.sys.info`, and they are *not* equivalent in the pinned build (`>=1.0.0b3.dev2026071921,<2`):

| Spelling | Status in pinned build | Notes |
|---|---|---|
| `os_is_linux()` / `os_is_macos()` — free functions in `std.sys.info` | **DO NOT resolve** — `module 'info' does not contain 'os_is_linux'` | Pin-drift. These exist in current mojolang.org docs but not in our build. |
| `CompilationTarget.is_linux()` / `.is_macos()` — static methods on the `CompilationTarget` struct | **WORK** — verified at runtime (returns `macos` on this host) | **This is the one to use.** Requires `from std.sys.info import CompilationTarget`. |
| `is_gpu()` / `has_accelerator()` / `is_little_endian()` / `is_big_endian()` — free functions in `std.sys.info` | WORK | Unrelated to OS detection but commonly confused with it. |

Per the [CompilationTarget docs](https://mojolang.org/docs/std/sys/info/CompilationTarget/), the
struct also exposes a large CPU-feature family (`is_x86`, `is_apple_silicon`, `is_apple_m1`..`m5`,
`has_avx*`, `has_neon*`, …). **Note: there is no `is_windows` in any spelling** — Mojo does not
target Windows, so don't write a `CompilationTarget.is_windows()` branch (it won't compile).

**The working pattern:**

```mojo
from std.sys.info import CompilationTarget

comptime if CompilationTarget.is_macos():
    EAGAIN = 35
comptime if CompilationTarget.is_linux():
    EAGAIN = 11
```

(The docs' own example omits the required `std.` prefix — `from sys.info import ...` does not
parse; the working form is `from std.sys.info import ...`.)

**Why this entry still matters despite the fix.** The `CompilationTarget.is_*()` predicates are
**compile-time** (they select code at build time, not runtime). For portable runtime values that
the *library* needs to pass to libc — like `AF_INET6` (macOS 30, Linux 10) — you either
(a) branch with `comptime if CompilationTarget.is_*()` to pick the constant at build time, or
(b) sidestep the constant entirely. Option (b) is what this repo uses:

- §1.3's errno detection uses `getsockopt(SO_ERROR)` — a POSIX API that exists on every platform
  — so no OS branch is needed at all.
- The IPv6 work uses two runtime tricks instead of an OS branch: the *hostname* path reads
  `ai_family` back from `getaddrinfo(AF_UNSPEC)`, and the *literal* path discovers `AF_INET6`
  with `_af_inet6()` — an `inet_pton` probe over the known candidate values (§5.6). Both source
  the platform value at runtime, so the socket layer never hard-codes `AF_INET6` or `comptime
  if`-branches on OS.

There appears to be no `compiles(...)` intrinsic in this build for guarding speculative calls, so
you cannot `comptime if compiles(...)` your way past a missing symbol — pick an API that exists,
or branch on `CompilationTarget.is_*()`.

**Where:** [`requests/_net.mojo`](requests/_net.mojo) `_is_timeout()` (~L162-185) — the POSIX
`SO_ERROR` workaround. Planned: [`requests/_dns.mojo`](requests/_dns.mojo) /
[`requests/_net.mojo`](requests/_net.mojo) for the `AF_UNSPEC` + runtime-`ai_family` IPv6 path.

---

## 9. OpenSSL-via-FFI ergonomics (Mojo-shaped friction)

Not pure Mojo bugs, but friction worth recording:

- **`SSL_set_tlsext_host_name` is a macro** → must call `SSL_ctrl(ssl, 55, 0, hostname)`
  directly. Many servers refuse TLS without SNI. ([`_tls.mojo`](requests/_tls.mojo) ~L181)
- **OpenSSL constants must be `comptime c_int`** to pass cleanly through `OwnedDLHandle.call`.
  Same pattern in `_net.mojo`, `_dns.mojo`, `_streaming.mojo`.
- **Calls go through `self._libssl.value()[].call["SYMBOL", RetType](args...)`** and the handle
  must be stored as `OwnedPointer[OwnedDLHandle]` on the `TLSConnection` so it outlives the ctx.
- **`_drain_openssl_errors` exists** because `external_call` failures are otherwise opaque —
  a bare `rc=0` tells you nothing. The helper reads `ERR_get_error` + `ERR_error_string_n`.

---

## 10. Deliberate simplifications (not bugs, but limitations shaped by Mojo's state)

These are called out so they don't get reported as bugs:

- **Set-Cookie attributes are not parsed** — minimal v1 reads `name=value`, ignores
  Path/Domain/Expires/Secure/HttpOnly. ([`_cookies.mojo`](requests/_cookies.mojo),
  [`TODO.md`](TODO.md))
- **Streaming + redirects don't combine** — when `stream=True`, redirects are not followed
  (matches Python's caveat). ([`session.mojo`](requests/session.mojo) ~L107)
- **Incremental chunked dechunking is not implemented** — streaming a chunked body reads until
  close instead. ([`_streaming.mojo`](requests/_streaming.mojo) ~L80)

---

## How to debug when something goes wrong

1. **OpenSSL failure with `rc=0` / weird error** → it's probably §1.1 (unsafe_ptr clobber).
   Drain the error queue (`_drain_openssl_errors`) and check whether you passed a raw
   `String.unsafe_ptr()` where you should've passed an `alloc`'d buffer.
2. **`use of invalidated interior reference`** → §2.1. Slice into a fresh local first.
3. **`cannot be implicitly copied`** → §3.2/§3.3. Add `^` at the use site.
4. **`cannot call function that may raise 'X' in context that supports 'Y'`** → §4.2/§4.3.
   Either keep the caller bare `raises`, or split the try block.
5. **First-request DNS failure** → §5.1/§5.2. The warmup + retry should handle it; if not,
   you're probably hitting a real resolver issue.
6. **JIT crash on an `external_call`** → §1.3. The symbol doesn't exist on this platform;
   switch to a universally-available POSIX API.

---

## Contributing to this file

Found a new Mojo struggle? Add it. Format: **Symptom / Cause / Fix / Where**. Be specific
about the Mojo build (the behavior may be fixed in a future nightly). If you worked around it
in code, point at the file:line so the workaround and the rationale stay linked.
