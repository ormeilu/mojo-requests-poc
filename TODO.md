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
- [ ] **Redirects** — `allow_redirects` parameter; follow `Location` headers (3xx).
- [ ] **Cookie jar persistence** — `Session` should persist `Set-Cookie` across requests.
- [ ] **Streaming responses** — read body incrementally instead of buffering all into memory.
- [ ] **Connection pooling / keep-alive** — reuse TCP connections across requests in a Session.
- [ ] **Proxy support** — `proxies` parameter (HTTP/HTTPS proxy tunneling).
- [ ] **Pure-Mojo TLS** — replace OpenSSL FFI with a Mojo-native TLS 1.3 implementation.
