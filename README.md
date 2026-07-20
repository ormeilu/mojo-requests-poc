# mojo-requests

A pure-Mojo HTTP client library, modeled after Python's [`requests`](https://docs.python-requests.org/).

**No Python. No libcurl.** TCP sockets are provided via libc FFI (`external_call`) against the system's
libc (`socket`, `connect`, `send`, `recv`, `close`). HTTPS/TLS is provided via OpenSSL (auto-discovered
and `dlopen`'d at runtime). Everything else — URL parsing, HTTP/1.1 framing, chunked transfer decoding,
percent-encoding, and a JSON parser — is written in Mojo.

> **Mojo version:** built and tested against Mojo 1.0.0b3 (nightly). Mojo is evolving rapidly; older or
> newer builds may require small adjustments.

## Quick start

```bash
# Clone, then enter the environment
pixi shell

# Run the test suite (30 tests: 16 HTTP + 8 HTTPS + 6 streaming)
pixi run test                # core HTTP / URL / JSON tests
pixi run test-https          # HTTPS-specific tests
pixi run test-streaming      # stream=True + iter_content (live network)
# …or run them all:
pixi run test-all

# Run the demo (starts a local HTTP server for you to hit)
pixi run demo

# Benchmark against python requests + httpx (uses hyperfine)
pixi run bench
```

## Usage

```mojo
import requests

# Simple GET
var r = requests.get("http://example.com/")
print(r.status_code)        # 200
print(r.text())             # the body as a String
print(r.headers["Server"])  # case-insensitive header access

# GET with query params (auto percent-encoded)
var params: Dict[String, String] = {"q": "hello world", "page": "2"}
var r2 = requests.get("http://example.com/search", params=params^)
print(r2.url)               # http://example.com/search?q=hello+world&page=2

# POST with a JSON body
var r3 = requests.post("http://example.com/api", json="{\"name\":\"mojo\"}")
var parsed = r3.json()      # JSONValue
print(parsed["name"].as_string())

# Sessions: reuse default headers across requests
var s = requests.Session()
s.headers["Authorization"] = "Bearer xyz"
var r4 = s.get("http://example.com/protected")

# HTTPS (TLS via OpenSSL — certificate verification enabled by default)
var r5 = requests.get("https://example.com/", timeout=15.0)
print(r5.status_code)       # 200

# Streaming: keep the connection open, read the body in chunks (no full buffering)
var r6 = requests.get("https://example.com/large.bin", stream=True)
print(r6.is_streaming())    # True
var total = 0
for chunk in r6.iter_content(8192):
    total += len(chunk)
print("downloaded bytes:", total)
# text() also works — it auto-drains the stream first.

# Error handling
var err = s.get("http://example.com/missing")
err.raise_for_status()      # raises HTTPError on 4xx/5xx
```

## API reference

### Module-level functions

All mirror Python's `requests`:

| Function  | Signature |
|-----------|-----------|
| `get`     | `(url, params?, headers?, timeout?)` |
| `post`    | `(url, data?, json?, headers?, timeout?)` |
| `put`     | `(url, data?, json?, headers?, timeout?)` |
| `patch`   | `(url, data?, json?, headers?, timeout?)` |
| `delete`  | `(url, headers?, timeout?)` |
| `head`    | `(url, headers?, timeout?)` |
| `options` | `(url, headers?, timeout?)` |
| `request` | `(method, url, params?, headers?, data?, json?, timeout?)` |

Arguments are keyword-friendly with `Optional[...] = None` defaults. Collection args (`params`, `headers`)
are consumed (transferred with `^`) since Mojo's `Dict` is not implicitly copyable.

### `Session`

```mojo
var s = requests.Session()
s.headers["key"] = "value"   # default headers applied to every request
s.get(url, ...)
s.post(url, json=..., ...)
```

### `Response`

| Member / method      | Description |
|----------------------|-------------|
| `status_code`        | HTTP status code (`Int`) |
| `reason`             | Status reason phrase (`String`) |
| `headers`            | Case-insensitive `Headers` (e.g. `headers["Content-Type"]`, `headers.get(key, default)`) |
| `content`            | Raw body bytes (`List[UInt8]`) |
| `url`                | Final URL (`String`) |
| `text()`             | Body decoded to `String` (lossy UTF-8). Drains the stream if `stream=True`. |
| `json()`             | Body parsed as `JSONValue`. Drains the stream if `stream=True`. |
| `ok()`               | `True` if `status_code < 400` |
| `raise_for_status()` | raises `HTTPError` on 4xx/5xx |
| `is_streaming()`     | `True` if this Response was created with `stream=True` and the body hasn't been read yet |
| `iter_content(n)`    | For `stream=True`: returns `List[List[UInt8]]` of up-to-`n`-byte chunks (drains the stream) |

### `JSONValue`

```mojo
var j = r.json()
j.kind                 # "object" | "array" | "string" | "int" | "float" | "bool" | "null"
j["key"]               # subscript into objects/arrays (returns a copy)
j.as_string()          # typed accessor (raises if wrong kind)
j.as_int()
j.as_float()
j.as_bool()
j.len()                # object key count or array length
j.is_null()
```

### Exceptions

Mojo's `Error` is a builtin struct (not a conformance trait), so exceptions are **constructor functions**
that return a categorized `Error`. Classify a caught error with `exception_kind()`:

```mojo
from requests.exceptions import connection_error, http_error, timeout_error, ssl_error, exception_kind

try:
    var r = requests.get(url, timeout=5.0)
    r.raise_for_status()
except e:
    var kind = exception_kind(e)   # "ConnectionError" | "Timeout" | "HTTPError" | "SSLError" | ...
    print("failed:", kind, e)
```

## How it works

The library is layered (each file is independently testable):

```
requests/
├── __init__.mojo    # public re-exports
├── api.mojo         # module-level get/post/... (delegates to Session)
├── session.mojo     # request orchestration: URL → DNS → headers → wire format → socket/TLS → parse
├── models.mojo      # Response, Headers (case-insensitive)
├── _http.mojo       # HTTP/1.1 request building + response framing (Content-Length + chunked)
├── _url.mojo        # URL parser + percent-encoding
├── _dns.mojo        # DNS resolution (inet_pton → getaddrinfo) via libc
├── _net.mojo        # TCPSocket: socket/connect/send/recv/close/timeout via libc FFI
├── _tls.mojo        # TLSConnection: OpenSSL TLS layer (dlopen'd, SNI + cert verification)
├── _json.mojo       # minimal recursive-descent JSON parser (std.json doesn't exist in Mojo 1.0)
└── exceptions.mojo  # error constructors + classifier
```

**Networking:** Mojo 1.0 has no `std.net` / `std.socket`. This library calls libc syscalls directly via
`std.ffi.external_call["socket"|"connect"|"send"|"recv"|"close"|"setsockopt", ...]`. DNS resolution uses
`inet_pton` for dotted-decimal IPs and `getaddrinfo` (thread-safe) for hostnames.

**TLS/HTTPS:** OpenSSL is auto-discovered (Homebrew `/opt/homebrew/lib`, `/usr/local/lib`, Linux
`/usr/lib`, etc.) and loaded at runtime via `OwnedDLHandle` (dlopen). The `TLSConnection` wraps the
already-connected raw socket: `SSL_CTX_new` → `SSL_new` → `SSL_set_fd` → `SSL_set_tlsext_host_name` (SNI)
→ `SSL_connect`. Certificate verification is enabled by default (`SSL_VERIFY_PEER` + system CA store).

## Benchmark

`pixi run bench` starts a local HTTP server and benchmarks sequential GET requests using
[hyperfine](https://github.com/sharkdp/hyperfine) — comparing Python `requests`, Python `httpx`,
and `mojo-requests` (both `mojo run` with compile, and a pre-built binary without).

### Methodology

- Each run issues **200 sequential GET requests** to a local `python3 -m http.server` (no network
  variance).
- All implementations use a **session/client** (keep-alive connection reuse where supported).
- hyperfine: **3 warmup runs + 10 measured runs** per implementation.

### System

| | |
|---|---|
| **OS** | macOS 26.4.1 (build 25E253) |
| **CPU** | Apple M1 — 8 cores (8 logical) |
| **RAM** | 16 GB |
| **Mojo** | 1.0.0b3.dev2026071306 |
| **Python** | 3.14.6 |
| **requests** | 2.34.2 |
| **httpx** | 0.28.1 |
| **hyperfine** | 1.20.0 |

### Results (200 sequential GETs)

| Command | Mean ± σ | Min | Max | Relative |
|:---|---:|---:|---:|---:|
| `mojo (pre-built)` | **76.6 ms ± 13.4 ms** | 63.4 ms | 109.9 ms | **1.00** |
| `python httpx` | 280.8 ms ± 88.9 ms | 212.7 ms | 507.8 ms | 3.67× |
| `python requests` | 282.3 ms ± 54.1 ms | 245.9 ms | 427.7 ms | 3.69× |
| `mojo run (incl. compile)` | 1036.0 ms ± 20.0 ms | 1006.0 ms | 1064.0 ms | 13.52× |

> mojo-requests (pre-built) is **~3.7× faster** than Python `requests` and `httpx`.
> The `mojo run` row includes ~960 ms of compile time per invocation — use `mojo build` for
> production (the pre-built binary is the fair comparison).

Full results are exported to `benchmark/results.md` on each run.

## Limitations & roadmap

- **IPv4 only** (the `sockaddr_in` path). IPv6 support would add a `sockaddr_in6` path.
- **No connection pooling / keep-alive.** Each request opens a fresh TCP+TLS connection (the
  server is asked to close after responding). Reuse across requests is future work.
- **No proxy support** (`proxies` parameter).
- **Streaming + redirects don't combine.** When `stream=True`, redirects are not followed
  (matches Python requests' caveat). Streaming a chunked-encoded body reads until close;
  incremental dechunking is future work.
- **TLS requires OpenSSL** to be installed (the library auto-discovers it; raises `SSLError` if
  not found). A pure-Mojo TLS implementation is explicitly out of scope — see `TODO.md`.

### Implemented

- [x] HTTP/1.1 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS over TCP (libc FFI, no Python, no libcurl)
- [x] HTTPS/TLS via OpenSSL (auto-discovered, `dlopen`'d at runtime, cert verification on)
- [x] URL parsing + percent-encoding + query-string building
- [x] Response framing: `Content-Length` and `Transfer-Encoding: chunked`
- [x] JSON request bodies + JSON response parsing (pure-Mojo parser)
- [x] Redirect following (`allow_redirects`, 3xx, supports absolute/protocol-relative/root-relative/relative)
- [x] Cookie jar persistence across requests in a `Session`
- [x] Streaming responses (`stream=True` + `iter_content(chunk_size)`)

## License

MIT.
