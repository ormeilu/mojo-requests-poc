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
- [ ] **Proxy support** — `proxies` parameter (HTTP/HTTPS proxy tunneling).
- [ ] **Pure-Mojo TLS** — replace OpenSSL FFI with a Mojo-native TLS 1.3 implementation.
