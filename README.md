# mojo-requests

A pure-Mojo HTTP client library, modeled after Python's [`requests`](https://docs.python-requests.org/).

**No Python. No libcurl.** TCP sockets are provided via libc FFI (`external_call`) against the system's
libc (`socket`, `connect`, `send`, `recv`, `close`). HTTPS/TLS is provided via OpenSSL (auto-discovered
and `dlopen`'d at runtime). Everything else — URL parsing, HTTP/1.1 framing, chunked transfer decoding,
percent-encoding, and a JSON parser — is written in Mojo.

> **Mojo version:** built and tested against Mojo 1.0.0b3 (nightly). Mojo is evolving rapidly; older or
> newer builds may require small adjustments.

> **Building this fought back.** Mojo 1.0 is pre-stable — FFI pointer-lifetime clobbers, interior-reference
> slicing bugs, a partially-impossible typed-exception model, lazy-init DNS flakiness, and missing stdlib
> (`std.json`, `std.net`, mutable globals, platform detection) all had to be worked around. Every one is
> documented — symptom, cause, fix, and a file:line pointer — in [`STRUGGLES.md`](STRUGGLES.md), the
> long-form field log. See also [`AGENTS.md`](AGENTS.md) (contributor orientation) and [`TODO.md`](TODO.md)
> (roadmap).

## Quick start

```bash
# Clone, then enter the environment
pixi shell

# Run the test suite (61 tests: 32 HTTP + 11 HTTPS + 6 streaming + 12 keep-alive)
pixi run test                # core HTTP / URL / JSON tests
pixi run test-https          # HTTPS-specific tests
pixi run test-streaming      # stream=True + iter_content (live network)
pixi run test-keepalive      # connection pooling / keep-alive
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

# Keep-alive: a Session reuses the underlying TCP/TLS connection across requests to the
# same endpoint automatically (amortizing the TCP + TLS handshake). Use it as a context
# manager so idle pooled connections are closed on block exit.
with requests.Session() as session:
    var a = session.get("https://example.com/")
    var b = session.get("https://example.com/about")   # reuses a's connection
    print(a.status_code, b.status_code)
# `session.close()` closes the pool explicitly if you don't use `with`.

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
| `get`     | `(url, params?, headers?, timeout?, verify?, ca_bundle?)` |
| `post`    | `(url, data?, json?, headers?, timeout?, verify?, ca_bundle?)` |
| `put`     | `(url, data?, json?, headers?, timeout?, verify?, ca_bundle?)` |
| `patch`   | `(url, data?, json?, headers?, timeout?, verify?, ca_bundle?)` |
| `delete`  | `(url, headers?, timeout?, verify?, ca_bundle?)` |
| `head`    | `(url, headers?, timeout?, verify?, ca_bundle?)` |
| `options` | `(url, headers?, timeout?, verify?, ca_bundle?)` |
| `request` | `(method, url, params?, headers?, data?, json?, timeout?, verify?, ca_bundle?)` |

Arguments are keyword-friendly with `Optional[...] = None` defaults. Collection args (`params`, `headers`)
are consumed (transferred with `^`) since Mojo's `Dict` is not implicitly copyable.

The `verify` / `ca_bundle` parameters (and the matching `Session` fields) control TLS certificate
verification — see [TLS verification](#tls-verification) below.

### `Session`

```mojo
var s = requests.Session()
s.headers["key"] = "value"   # default headers applied to every request
s.get(url, ...)
s.post(url, json=..., ...)
s.close()                    # close all pooled keep-alive connections
```

A `Session` also persists cookies and TLS defaults (`verify` / `ca_bundle`) across requests, and
**pools connections** for keep-alive: after a self-delimiting response (Content-Length or chunked,
without `Connection: close`) the live TCP/TLS connection is kept and reused by the next request to
the same scheme/host/port — skipping the TCP and (for HTTPS) TLS handshake. A pooled connection the
server has since dropped is transparently retried once on a fresh socket.

Use it as a **context manager** so pooled connections are closed on block exit (via `__del__`, so it
also fires on an exception):

```mojo
with requests.Session() as s:
    var r1 = s.get("https://example.com/")
    var r2 = s.get("https://example.com/next")   # reuses r1's connection
# pool closed here
```

Streaming responses (`stream=True`) are never pooled — the live connection is owned by the
`Response` until it is dropped. Connection reuse is per-`Session`; the module-level functions
(`requests.get`, …) create a throwaway Session and so do not pool across calls.

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

Each error category is a typed struct conforming to `Movable` + `Writable`, carrying a `msg` plus
any category-specific fields:

| Struct              | Extra fields   | Raised when |
|---------------------|----------------|-------------|
| `ConnectionError`   | `host`         | DNS / socket / connect failure |
| `Timeout`           | `host`         | connect/send/recv exceeded the `timeout` |
| `SSLError`          | `hostname`     | TLS handshake / certificate verification failure |
| `HTTPError`         | `status_code`  | `raise_for_status()` on a 4xx/5xx |
| `InvalidURL`        | —              | malformed URL |
| `UnsupportedScheme` | `scheme`       | non-`http(s)` scheme |
| `RequestException`  | —              | generic / fallback |

You raise them directly (`raise ConnectionError("...", host=h)`); Mojo wraps the struct in its
builtin `Error`. Leaf functions that raise exactly one category carry a **typed** `raises` clause
(e.g. `_dns.resolve` is `raises ConnectionError`, `TLSConnection.connect` is `raises SSLError`,
`Response.raise_for_status` is `raises HTTPError`).

Because Mojo's `Error` is a builtin wrapper with **no runtime field/type recovery** across a bare
`raises` boundary (and no multi-type `raises` union), the orchestration layer stays bare `raises`
and you classify a caught error by its rendered category prefix via `exception_kind()`:

```mojo
from requests.exceptions import exception_kind

try:
    var r = requests.get(url, timeout=5.0)
    r.raise_for_status()
except e:
    var kind = exception_kind(e)   # "ConnectionError" | "Timeout" | "HTTPError" | "SSLError" | ...
    print("failed:", kind, e)      # `e` renders as e.g. "SSLError: certificate verify failed"
```

`exception_kind()` matches the stable prefix each struct's `write_to` emits (pinned by
`comptime *_PREFIX` constants so the classifier and the structs can't drift). The `Session`
connect/send/recv paths re-raise the original typed error with `raise e^`, so an SSL handshake
failure during `s.get("https://…")` surfaces as `SSLError: …` rather than being flattened into
`RequestException`. See [`STRUGGLES.md`](STRUGGLES.md) §4 for why typed dispatch is only partially
achievable in this Mojo build.

## TLS verification

HTTPS certificate verification is **on by default** (peer certs are checked against the system trust
store via OpenSSL). Two parameters — available on every request function, every `Session` method, and
as fields on `Session` itself — let you customize this:

| Parameter    | Type                | Default | Meaning |
|--------------|---------------------|---------|---------|
| `verify`     | `Optional[Bool]`    | `None`  | `None` uses the Session default; `True` verifies peers; `False` disables verification entirely (insecure). |
| `ca_bundle`  | `Optional[String]`  | `None`  | Path to a PEM file of trusted CA certificates. Overrides the system trust store. |

When `verify=True` and no explicit `ca_bundle` is given, the trust store is resolved in this priority
order (mirrors Python `requests` semantics):

1. the `ca_bundle` argument (highest priority)
2. `$REQUESTS_CA_BUNDLE` environment variable
3. `$SSL_CERT_FILE` environment variable (OpenSSL's native convention)
4. OpenSSL's compiled-in system default paths

```mojo
# Per-call: trust a specific self-signed cert (e.g. a local test server).
var r = requests.get("https://localhost:8443/", ca_bundle="/path/to/cert.pem")

# Per-call: skip verification entirely (insecure — testing only).
var r2 = requests.get("https://self-signed.example/", verify=False)

# Session-wide default, overridable per-call.
var s = requests.Session()
s.verify = False            # default for every request on this Session
var r3 = s.get("https://internal.corp/", verify=True)   # re-enable for this one
```

On CI / minimal Linux images where the system trust store path differs from OpenSSL's defaults, the
cleanest fix is usually the env var — no code changes required:

```bash
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# or:
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
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
- [x] TLS verification controls: `verify=False`, `ca_bundle` param, `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` env vars

## License

Apache License 2.0. See [LICENSE](LICENSE).
