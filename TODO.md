# TODO — mojo-requests roadmap

## Async support

> **Correction (2026-07):** This section previously claimed "Mojo 1.0 has no built-in
> async/threading primitives." That is wrong about async — native async exists. The reframed
> plan below reflects it. See [`STRUGGLES.md`](STRUGGLES.md) §6.4 for the full API probe.

**What's already there.** Mojo 1.0 ships a native async runtime:
- `std.runtime.asyncrt` — `Task`, `RaisingTask`, `TaskGroup`, `TaskGroupContext`,
  `create_task`, `create_raising_task`, `parallelism_level()` (returns host CPU cores).
- `async def foo() -> T` produces a `Coroutine[T, {}]`; `async def foo() raises -> T` produces
  a `RaisingCoroutine[T, {}]`. `await` is a real operator. `Coroutine`/`RaisingCoroutine` live
  in `std.builtin.coroutine`.
- A native runtime backs it (`libAsyncRT*.dylib`), so no manual event loop is needed.

**Preferred approach: build `AsyncSession` on `std.runtime.asyncrt`.**

- Wrap the existing blocking `_do_request` coroutine so an `async def _async_request(...)`
  returns a `RaisingCoroutine[Response, ...]`.
- `AsyncSession.gather(urls)` runs N of them concurrently inside a `TaskGroup`, collects via
  `RaisingTask.wait`, returns `List[Response]`.
- API: `requests.AsyncSession` with `async_get` / `gather()` semantics — mirrors
  `httpx.AsyncClient` / `requests`-style ergonomics.

**Real blockers in the pinned build (`1.0.0b3.dev2026071921`) — these are why this isn't done
yet:**

- `TaskGroup` exposes only `__init__` / `__del__` / `wait` — **no public `.add()` / `.spawn()`**.
  Tasks attach to a group via the `TaskGroupContext` callback + `create_task`'s `out` parameter.
- `TaskGroupContext`'s constructor needs an **unsafe `Pointer[TaskGroup, MutUntrackedOrigin]`**
  with no clean construction path in this build (no `std.unsafe` / `std.ptr`).
- The context callback must be **`thin` (non-raising)** — raising work has to propagate via
  `RaisingTask.wait`'s `out result`.
- It's unverified whether two `create_task` coroutines actually run on separate OS threads in
  this build (the runtime reports CPU-core parallelism, but the submission API is too rough to
  exercise from the REPL without more probing).

So `AsyncSession` is feasible but needs the asyncrt surface either probed deeper or the pin
bumped to a newer nightly where the ergonomics may have settled.

**Fallback (only if asyncrt stays unusable): non-blocking sockets + `poll()` event loop**

- Set sockets non-blocking via `fcntl(fd, F_SETFL, O_NONBLOCK)` — `fcntl` is FFI-able.
- Multiplex with `poll(struct pollfd*, nfds, timeout)` — verified working via
  `external_call["poll", ...]`.
- Single-threaded event loop (Node.js / Python asyncio style): issue N concurrent requests,
  poll for readiness, read/respond as sockets become ready.
- Demoted from "verified viable" to "fallback" — it duplicates work the native runtime already
  does.

**Alternative approaches (rejected):**
- `pthread_create` via FFI — needs C-ABI function pointers Mojo doesn't cleanly expose yet.
- `fork()` via FFI — process-level concurrency, heavy and awkward for sharing state.

**Benchmark impact:** Once async lands, add `benchmark/bench_mojo_requests_async.mojo`
(concurrent requests) and `benchmark/benchmark_python_httpx_async.py` (`httpx.AsyncClient`) to
the hyperfine comparison.

## Other roadmap items

- [x] **IPv6 support** — `sockaddr_in6` connect path alongside `sockaddr_in`. `getaddrinfo(AF_UNSPEC)` returns both A and AAAA records; we **prefer IPv4** (first `AF_INET` result) for backward compatibility with IPv4-only targets (the local test server in particular) and fall back to the first `AF_INET6`. Bracketed IPv6 literal URLs (`http://[::1]:8080/`, `https://[2001:db8::1]/x`) parse per RFC 3986 — host stored without brackets, re-bracketed in `Host`/`origin()` per RFC 7230 §5.5. Works over HTTP and HTTPS (TLS is family-agnostic — it runs over the already-connected fd). **Deferred:** happy-eyeballs (RFC 8305 — racing v6+v4) and a dual-stack local test server (`tests/server.py` binds IPv4-only, so live IPv6 is exercised via the `::1` literal unit test + the connection-refused path, not a real fetch). Portability note: `AF_INET6` is 30 on macOS/BSD and 10 on Linux, so it is never hard-coded — `ResolvedAddress.pf` carries the platform-correct value, sourced from `getaddrinfo`'s `ai_family` on the hostname path and from the `_af_inet6()` `inet_pton` probe on the literal path. IPv6 **literals** are parsed with `inet_pton` (a pure userspace text→binary parser) rather than `getaddrinfo(AI_NUMERICHOST)`, because `getaddrinfo` consults the kernel and fails for `::1` on hosts with no IPv6 networking (GitHub ubuntu runners).
- [x] **Redirects** — `allow_redirects` parameter; follow `Location` headers (3xx). Supports absolute, protocol-relative (`//host`), root-relative (`/path`), and relative redirects. 301/302/303 after POST → GET.
- [x] **Cookie jar persistence** — `Session` persists `Set-Cookie` across requests and sends them back as a `Cookie` header. Minimal v1 (parses name=value; ignores Path/Domain/Expires attributes).
- [x] **Streaming responses** — `stream=True` keeps the connection open; `iter_content(chunk_size)` pulls body bytes on demand. Supports HTTP and HTTPS (TLS handle transfers into a `StreamingConn`). `text()`/`iter_content()` auto-drain. Redirects skipped when streaming (matches Python's stream+allow_redirects caveat). Chunked transfer-encoding streams until close (incremental dechunking is future work).
- [ ] **Connection pooling / keep-alive** — reuse TCP connections across requests in a Session.
- [ ] **TLS performance tuning** — OpenSSL is CPU-bound; most of the cost is the handshake. Three levers, in order of payoff:
  - **TLS session resumption** (highest payoff). After keep-alive lands, enable `SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_CLIENT)` + ticket support so repeat handshakes to the same host skip the asymmetric key exchange. Needs a per-Session (host → `SSL_SESSION*`) cache and `SSL_set_session()` on the client side.
  - **Cipher/protocol curation.** Force TLS 1.3 (`SSL_CTX_set_min_proto_version(TLS1_3_VERSION)`) when available and prefer ECDSA/X25519 + AES-GCM/ChaCha20-Poly1305 via `SSL_CTX_set_ciphersuites()`. Saves 1-RTT (TLS 1.3 vs 1.2) and dramatically speeds up the handshake.
  - **Hardware acceleration** — mostly *not* our job: mojo-requests `dlopen`s whatever system OpenSSL it finds, so AES-NI/NEON/QAT availability depends on how *that* build was compiled. Could add a diagnostic that logs `OPENSSL_INFO_AVAILABLE_ENGINES` / checks for the `aesni` engine at startup, but the real lever is the system OpenSSL build, not our code.
- [ ] **Proxy support** — `proxies` parameter (HTTP/HTTPS proxy tunneling).
- [x] **`REQUESTS_CA_BUNDLE` env var** — honor it as the CA cert path (matches python `requests` semantics: `export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`). Useful on CI / minimal Linux images where the system trust store path differs from OpenSSL's defaults. Implemented in `_tls.mojo`: trust-store resolution order is `ca_bundle` param > `$REQUESTS_CA_BUNDLE` > `$SSL_CERT_FILE` > OpenSSL system defaults.
- [x] **Rewrite exceptions as typed `Error` structs** — replace the current string-prefix-based error model (functions in `exceptions.mojo` that build `Error(t"ConnectionError: ...")` + an `exception_kind()` classifier that matches on the message prefix) with proper Mojo typed errors, following this pattern:

  ```mojo
  struct ConnectionError(Movable, Writable):
      var msg: String
      var host: String
      def __init__(out self, msg: String, *, host: String = ""):
          self.msg = msg
          self.host = host
      def write_to(self, mut writer: Some[Writer]):
          writer.write("ConnectionError: ", self.msg)
  ```

  Each exception category (`ConnectionError`, `Timeout`, `HTTPError`, `SSLError`, `InvalidURL`, `UnsupportedScheme`, `RequestException`) is a struct conforming to `Movable` + `Writable`, carrying a `msg` plus any runtime fields (status code for `HTTPError`, host for connection errors, hostname for SSL errors, scheme for `UnsupportedScheme`). Raise sites at single-category leaf functions carry typed `raises` clauses: `_dns.resolve` is `raises ConnectionError`, `TLSConnection.connect`/`send_all` are `raises SSLError`, `Response.raise_for_status` is `raises HTTPError`. `raise_for_status()` and the convenience methods raise the new typed errors.

  ### Implementation notes (Mojo 1.0.0b3 constraints discovered during the refactor)

  The original vision — "distinct structs per category AND runtime typed dispatch via `try/except` pattern-matching" — is **partially unachievable** in this Mojo build. Verified empirically:

  - **No multi-type `raises` union.** `raises A | B`, `raises A, B`, and `raises [A, B]` all fail to parse. A function that raises two categories (e.g. `parse_url` raises both `InvalidURL` and `UnsupportedScheme`) must stay bare `raises`.
  - **Strict typed propagation.** `raises A` cannot call `raises B` (hard compiler error: "cannot call function that may raise 'B' in context that supports an error type of 'A'"). The Session orchestration layer fans out to 5+ disjoint error types, so `_do_request` / `request` / `get` / `post` / ... stay bare `raises`.
  - **Same-`try`-block type unification.** A `try` block infers its exception type from its typed raisers and forbids coexistence with wider types — a typed `raises SSLError` call and a bare `raises` call cannot share one try block. The session's connect/send/recv try blocks are split per scheme (`is_https` branches each get their own try/except) to work around this.
  - **No runtime type recovery on a caught `Error`.** `__get_original_error_value_as[T]` does not exist; a caught `Error` exposes no fields. Concrete struct fields are accessible only within the same typed-`raises` context. Across a bare-`raises` boundary, only the rendered `write_to` string survives.

  **Consequence:** `exception_kind(err: Error) -> String` is kept and remains **string-prefix-based** — it is the *only* runtime dispatch mechanism available after a bare-`raises` propagation boundary. Each struct's `write_to` emits a stable prefix (`"SSLError: ..."`, `"HTTPError 404: ..."`, etc.) pinned by `comptime *_PREFIX` constants so the classifier and the structs never drift. The session's connect/send/recv `except` blocks re-raise the original typed error with `raise e^` (preserving its concrete type through the `Error` wrapper) instead of flattening it into a `RequestException` — so an SSL handshake failure during `s.get("https://...")` now surfaces as `SSLError: ...`, matching Python `requests` semantics.

  **Timeout wired up:** `_net.mojo` detects `SO_RCVTIMEO`/`SO_SNDTIMEO` expiry via `getsockopt(SO_ERROR)` (portable — unlike the `__error`/`__errno_location` errno accessors, which require platform-specific symbol resolution and `external_call` does not raise on a missing symbol, it JIT-crashes) and raises `Timeout` instead of `ConnectionError` when the socket had a timeout set and the pending error is `EAGAIN`/`EWOULDBLOCK` (EAGAIN and EWOULDBLOCK are equal on every supported platform: macOS 35, Linux 11).
- ~~**Pure-Mojo TLS** — replace OpenSSL FFI with a Mojo-native TLS 1.3 implementation.~~ **Won't do:** too massive and risky an undertaking (full TLS 1.3 state machine, AEAD, X.509 path validation, constant-time crypto). OpenSSL via FFI is battle-tested, auto-discovered at runtime, and good enough — re-implementing it in Mojo would dwarf the rest of the library for no real-world gain.
