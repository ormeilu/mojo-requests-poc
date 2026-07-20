# TODO — mojo-requests roadmap

## Async support

Mojo 1.0 has **no built-in async/threading** primitives — no `std.async`, no `Coroutine`, no `Thread`,
no `async`/`await` syntax. Adding async to mojo-requests requires building the concurrency layer
from scratch via libc FFI.

**Viable approach (verified): non-blocking sockets + `poll()` event loop**

- Set sockets to non-blocking via `fcntl(fd, F_SETFL, O_NONBLOCK)` — `fcntl` is FFI-able via `external_call`.
- Use `poll(struct pollfd*, nfds, timeout)` to multiplex multiple in-flight sockets — **verified working** via `external_call["poll", ...]`.
- Implement a single-threaded event loop (like Node.js / Python asyncio): issue N concurrent requests, poll for readiness, read/respond as sockets become ready.
- API: `requests.AsyncSession` with `async_get` / `gather()` semantics.

**Alternative approaches (rejected for now):**
- `pthread_create` via FFI — needs C-ABI function pointers, which Mojo doesn't cleanly expose yet.
- `fork()` via FFI — process-level concurrency, heavy and awkward for sharing state.

**Benchmark impact:** Once async lands, add `benchmark/bench_mojo_requests_async.mojo` (concurrent requests) and `benchmark/bench_python_httpx_async.py` (`httpx.AsyncClient`) to the hyperfine comparison.

## Other roadmap items

- [ ] **IPv6 support** — add a `sockaddr_in6` path alongside `sockaddr_in`.
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
- [ ] **Rewrite exceptions as typed `Error` structs** — replace the current string-prefix-based error model (functions in `exceptions.mojo` that build `Error(t"ConnectionError: ...")` + an `exception_kind()` classifier that matches on the message prefix) with proper Mojo typed errors, following this pattern:

  ```mojo
  @fieldwise_init
  @register_passable("trivial")
  struct InvalidColumnIndexError(Movable, Writable):
      comptime msg = "InvalidColumnIndex: Index provided is greater than the number of columns."

      fn write_to[W: Writer, //](self, mut writer: W):
          writer.write_string(Self.msg)
  ```

  Each exception category (`ConnectionError`, `Timeout`, `HTTPError`, `SSLError`, `InvalidURL`, `UnsupportedScheme`, `RequestException`) becomes a `@register_passable("trivial")` struct conforming to `Movable` + `Writable`, carrying a comptime `msg` plus any runtime fields (e.g. status code for `HTTPError`, hostname for connection errors). Raise sites become `raises SpecificError` instead of `raises Error`, and `try/except` blocks can pattern-match on the concrete type rather than string-parsing the message. `raise_for_status()` and the convenience methods should be updated to raise the new typed errors. This is a cross-cutting refactor touching every file that raises or catches — do it as one focused PR.
- ~~**Pure-Mojo TLS** — replace OpenSSL FFI with a Mojo-native TLS 1.3 implementation.~~ **Won't do:** too massive and risky an undertaking (full TLS 1.3 state machine, AEAD, X.509 path validation, constant-time crypto). OpenSSL via FFI is battle-tested, auto-discovered at runtime, and good enough — re-implementing it in Mojo would dwarf the rest of the library for no real-world gain.
