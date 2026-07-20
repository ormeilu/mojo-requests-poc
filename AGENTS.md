# AGENTS.md

Guidance for ZCode agents working in `mojo-requests`.

## What this is

A pure-Mojo HTTP client modeled after Python's `requests`. **No Python, no libcurl** — TCP sockets are libc FFI (`std.ffi.external_call` against `socket`/`connect`/`send`/`recv`/`close`/`getaddrinfo`). HTTPS is OpenSSL loaded at runtime via `dlopen` (`OwnedDLHandle`). URL parsing, HTTP/1.1 framing, percent-encoding, and a JSON parser are hand-written in Mojo.

Targeting **Mojo 1.0.0b3** (nightly). The language is moving fast — older/newer builds may need small tweaks.

## Layout

```
requests/        the library (import path is `requests`, sources compiled with `mojo -I .`)
  __init__.mojo  public re-exports
  api.mojo       module-level get/post/... (delegates to a default Session)
  session.mojo   request engine: URL → DNS → headers → wire → socket/TLS → parse. The only orchestration entry point.
  models.mojo    Response, Headers (case-insensitive)
  _http.mojo     HTTP/1.1 request building + response framing (Content-Length + chunked)
  _url.mojo      URL parser + percent-encoding
  _dns.mojo      DNS (inet_pton → getaddrinfo) via libc
  _net.mojo      TCPSocket: socket/connect/send/recv/timeout via libc FFI
  _tls.mojo      TLSConnection: OpenSSL TLS layer (dlopen'd, SNI + cert verification)
  _streaming.mojo StreamingConn — owns the live socket/TLS for `stream=True`
  _json.mojo     minimal recursive-descent JSON parser (no std.json in Mojo 1.0)
  _cookies.mojo  CookieJar (Session-scoped)
  exceptions.mojo error constructors + exception_kind() classifier
tests/           test_requests / test_https / test_streaming Mojo tests + server.py (local HTTP+HTTPS)
examples/        demo.mojo
benchmark/       hyperfine comparison vs python requests / httpx
.github/workflows/ci.yml  lint + matrix test (macos-latest, ubuntu-latest)
```

Layer rule: `session.mojo` orchestrates. Everything else is independently testable and should not reach back up into `Session`/`api`.

## Commands (run via pixi)

```bash
pixi shell                 # enter env
pixi run test              # core HTTP / URL / JSON tests
pixi run test-https        # HTTPS tests
pixi run test-streaming    # stream=True + iter_content (reads BASE_URL / HTTPS_BASE_URL / SSL_CERT_FILE from env)
pixi run test-all          # all three suites
pixi run demo              # examples/demo.mojo
pixi run bench             # benchmark/run.sh (hyperfine)
pixi run fmt-check         # mojo format check — FAILS if any source diverges. Run before committing.
pixi run server            # local HTTP+HTTPS test server (prints BASE_URL / HTTPS_BASE_URL / ROOT)
```

Run a single test file directly: `pixi run mojo -I . tests/test_<name>.mojo`.

Tests read live targets from env (`BASE_URL`, `HTTPS_BASE_URL`, `SSL_CERT_FILE`) and **fall back to example.com** when unset. To run HTTPS/streaming live tests locally, start `pixi run server` in another shell and `export` the values it prints (plus `SSL_CERT_FILE=$ROOT/cert.pem`) before invoking mojo.

`mojo format requests/ tests/ examples/` is canonical formatting — CI's `fmt-check` task fails if `git diff` shows drift. Always re-run it after edits.

## Mojo gotchas (these have all bitten us)

- **`UnsafePointer` is non-nullable.** For null C-ABI args to FFI (e.g. the `CApath` parameter of `SSL_CTX_load_verify_locations`), pass `c_int(0)` — the FFI shim widens it to a null pointer.
- **`OwnedPointer[T]` requires `T` to be `Movable`.** If `T` has `__del__`, you must also declare `struct Foo(Movable):` and implement `__moveinit__`. Without it, `OwnedPointer[Foo](x^)` won't compile.
- **`Optional[OwnedPointer[T]]` is not implicitly copyable** (it's non-`ImplicitlyCopyable`). Steal the inner value with `var h = self._opt^; self._opt = None; return h^`.
- **`^` sigil transfers ownership** of any non-`ImplicitlyCopyable` type (`Dict`, `Response`, `Optional[OwnedPointer]`, `CookieJar`). Match the surrounding call sites.
- **Cannot slice a `String` and reassign to itself**: `x = String(x[byte=...])` invalidates the interior reference. Slice into a fresh local first: `var s = String(x[byte=...]); x = s`. (Bite hit in `_http.mojo` and `_url.mojo`.)
- **Strings built char-by-char from FFI bytes can carry an internal representation** whose `.unsafe_ptr()` C libraries reject. Round-trip through `String() + x` to normalize the layout before handing the pointer to OpenSSL. (Bite hit in `_tls.mojo`.)
- **Mojo `Error` is a builtin struct, not a user trait.** Exceptions are constructor functions in `exceptions.mojo` that return `Error` with a recognizable prefix (`"ConnectionError: ..."`, `"SSLError: ..."`). Recover the category with `exception_kind(err)`. Add a new category by adding a `*_PREFIX` comptime const + constructor + a branch in `exception_kind`.
- **`build_request` uses `imm` (not `read`)** for buffer access — `read` is deprecated in current nightlies.
- **DNS lazy-inits on first call** and may fail on the very first resolve in a process. `Session.__init__` warms the resolver with a throwaway `_dns_resolve("localhost")`. Keep that priming call.

## TLS / OpenSSL conventions

- Discover libssl at runtime via `_load_libssl()` in `_tls.mojo` (searches Homebrew paths, `/usr/local/lib`, `/usr/lib`, ...). Never link OpenSSL — always `dlopen`.
- Call OpenSSL through the handle: `self._libssl.value()[].call["SYMBOL", RetType](args...)`. The handle is stored as `OwnedPointer[OwnedDLHandle]` on the `TLSConnection` so it outlives the ctx.
- **Cert verification is ON by default.** Trust-store resolution priority, in `connect()`:
  1. explicit `ca_bundle` parameter
  2. `$REQUESTS_CA_BUNDLE` (matches python `requests`)
  3. `$SSL_CERT_FILE` (OpenSSL's native convention)
  4. `SSL_CTX_set_default_verify_paths` (system defaults)
- `verify=False` disables peer verification entirely (`SSL_VERIFY_NONE`). Thread `verify: Optional[Bool]` and `ca_bundle: Optional[String]` through `Session.request()` → `_do_request()` → `TLSConnection.connect()`. Per-call overrides Session defaults.

## CI

`.github/workflows/ci.yml`: `lint` (`mojo format` check) + `test` matrix (`macos-latest`, `ubuntu-latest`). Linux installs `libssl-dev`. The test job starts `tests/server.py` in the background, waits up to 20s for `HTTPS_BASE_URL=` to appear, then feeds `BASE_URL`/`HTTPS_BASE_URL`/`SSL_CERT_FILE` into `$GITHUB_ENV` so the live tests hit `localhost` (no external network). **Do not introduce tests that require real outbound DNS/TLS** — keep everything pointed at the local server.

Remote: `git@github.com:ormeilu/mojo-requests-poc.git`. Default branch `master`.

## Before committing

1. `pixi run fmt-check` (or `mojo format requests/ tests/ examples/` then re-check).
2. `pixi run test-all` (and start `pixi run server` + export env vars for the HTTPS/streaming live tests).
3. GPG signing is disabled in this repo's commits — commit with `git -c commit.gpgsign=false commit ...` only if signing would otherwise fail.

## Roadmap pointers

See `TODO.md`. Current open items: IPv6 (`sockaddr_in6`), connection pooling/keep-alive, proxy support, honoring `REQUESTS_CA_BUNDLE`. **Pure-Mojo TLS is explicitly out of scope** (struck through in TODO.md) — OpenSSL via FFI is the steady-state answer.
