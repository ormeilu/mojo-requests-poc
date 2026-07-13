# mojo-requests

A pure-Mojo HTTP client library, modeled after Python's [`requests`](https://docs.python-requests.org/).

**No Python. No libcurl. No external C dependencies.** TCP sockets are provided via libc FFI
(`external_call`) against the system's libc (`socket`, `connect`, `send`, `recv`, `close`). Everything
else — URL parsing, HTTP/1.1 framing, chunked transfer decoding, percent-encoding, and a JSON parser —
is written in Mojo.

> **Mojo version:** built and tested against Mojo 1.0.0b3 (nightly). Mojo is evolving rapidly; older or
> newer builds may require small adjustments.

## Quick start

```bash
# Clone, then enter the environment
pixi shell

# Run the test suite (15 tests)
pixi run test

# Run the demo (starts a local HTTP server for you to hit)
pixi run demo
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
| `text()`             | Body decoded to `String` (lossy UTF-8) |
| `json()`             | Body parsed as `JSONValue` |
| `ok()`               | `True` if `status_code < 400` |
| `raise_for_status()` | raises `HTTPError` on 4xx/5xx |

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
from requests.exceptions import connection_error, http_error, timeout_error, exception_kind

try:
    var r = requests.get(url, timeout=5.0)
    r.raise_for_status()
except e:
    var kind = exception_kind(e)   # "ConnectionError" | "Timeout" | "HTTPError" | ...
    print("failed:", kind, e)
```

## How it works

The library is layered (each file is independently testable):

```
requests/
├── __init__.mojo    # public re-exports
├── api.mojo         # module-level get/post/... (delegates to Session)
├── session.mojo     # request orchestration: URL → headers → wire format → socket → parse
├── models.mojo      # Response, Headers (case-insensitive)
├── _http.mojo       # HTTP/1.1 request building + response framing (Content-Length + chunked)
├── _url.mojo        # URL parser + percent-encoding
├── _dns.mojo        # DNS resolution (inet_pton → gethostbyname fallback) via libc
├── _net.mojo        # TCPSocket: socket/connect/send/recv/close/timeout via libc FFI
├── _json.mojo       # minimal recursive-descent JSON parser (std.json doesn't exist in Mojo 1.0)
└── exceptions.mojo  # error constructors + classifier
```

**Networking:** Mojo 1.0 has no `std.net` / `std.socket`. This library calls libc syscalls directly via
`std.ffi.external_call["socket"|"connect"|"send"|"recv"|"close"|"setsockopt", ...]`. DNS resolution uses
`inet_pton` for dotted-decimal IPs and `gethostbyname` for hostnames.

## Limitations & roadmap

- **HTTP only (no HTTPS/TLS).** TLS is a large, separate effort. v1 is plain HTTP. See roadmap below.
- **IPv4 only** (the `sockaddr_in` path). IPv6 support would add a `sockaddr_in6` path.
- **No redirects.** `allow_redirects` is not yet implemented (responses are returned as-is).
- **No cookie jar persistence.** Sessions carry default headers but don't persist `Set-Cookie`.
- **No streaming.** The full response is read into memory (`recv` until close).

### HTTPS roadmap

Adding HTTPS requires a TLS implementation. Possible approaches, in order of "purity":

1. **Pure-Mojo TLS** — implement TLS 1.2/1.3 (record layer, handshake, AES-GCM/ChaCha20-Poly1305,
   X.509 validation). The most work, but keeps the "pure Mojo" guarantee. A Mojo `BoringSSL`-style
   package would be a strong community contribution.
2. **FFI to libssl/BoringSSL** — call `SSL_read`/`SSL_write` via `external_call`. Practical and fast, but
   the TLS layer is C, not Mojo. A pluggable `TLSContext` hook is already architecturally feasible since
   `_net.mojo` is the single socket boundary.

## License

MIT.
