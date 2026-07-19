# Session — the request engine.
#
# Session.request() is the single entry point: it parses the URL, merges default + per-call headers, builds the
# request wire format, opens a TCP connection, sends/receives, and parses the response into a Response object.
# The module-level API in api.mojo delegates to a default Session.

from ._url import parse_url, build_query_string, url_encode
from ._http import build_request, parse_response, ParsedResponse
from ._net import TCPSocket
from ._dns import resolve as _dns_resolve
from ._tls import TLSConnection
from ._cookies import CookieJar
from .models import Response, Headers
from .exceptions import request_exception


struct Session:
    """A request session holding default headers applied to every request.

    Usage:
        var s = Session()
        s.headers["User-Agent"] = "myapp/1.0"
        var r = s.get("http://example.com")
    """
    var headers: Dict[String, String]
    var cookies: CookieJar

    def __init__(out self):
        self.headers = {}
        self.headers["User-Agent"] = "mojo-requests/0.1"
        self.headers["Accept"] = "*/*"
        self.cookies = CookieJar()
        # Warm up the DNS resolver: the first getaddrinfo call in a process can fail on some
        # systems (lazy resolver init). Doing a throwaway resolve here primes it for real use.
        try:
            _ = _dns_resolve("localhost")
        except _:
            pass

    def request(
        mut self,
        method: String,
        url: String,
        var params: Optional[Dict[String, String]] = None,
        headers: Optional[Dict[String, String]] = None,
        data: Optional[String] = None,
        json: Optional[String] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        """Issue an HTTP request and return a Response.

        - ``params``: query-string parameters (merged with any in the URL).
        - ``headers``: per-call headers (merged with the session defaults; per-call wins).
        - ``data``: raw request body (form-encoded string, etc.).
        - ``json``: JSON body string (also sets Content-Type: application/json).
        - ``timeout``: per-call connect/send/recv timeout in seconds.
        - ``allow_redirects``: follow 3xx redirects (default True). Up to MAX_REDIRECTS hops.
        """
        var current_url = url
        var redirect_method = method
        var current_data = data
        var current_json = json

        # First request: consumes params (owned). Subsequent redirects pass None for params.
        var resp = self._do_request(redirect_method, current_url, params^, headers, current_data, current_json, timeout)

        comptime MAX_REDIRECTS = 30
        if not allow_redirects:
            return resp^

        for _ in range(MAX_REDIRECTS):
            # Not a redirect? Return.
            if resp.status_code < 300 or resp.status_code >= 400:
                return resp^

            # No Location header? Return as-is.
            if not resp.headers.contains("location"):
                return resp^

            var location = resp.headers["location"]
            if location.byte_length() == 0:
                return resp^

            # Resolve relative redirects against the current URL.
            current_url = _resolve_redirect(current_url, location)

            # 303 / 301/302 after POST → GET (matches Python requests behavior).
            if resp.status_code == 303 or (
                (resp.status_code == 301 or resp.status_code == 302) and redirect_method == "POST"
            ):
                redirect_method = "GET"
                current_data = None
                current_json = None

            # Issue the next request (no params on redirects).
            var none_params: Optional[Dict[String, String]] = None
            resp = self._do_request(redirect_method, current_url, none_params^, headers, current_data, current_json, timeout)

        raise request_exception("too many redirects (max 30)")

    def _do_request(mut self,
        method: String,
        url: String,
        params: Optional[Dict[String, String]],
        headers: Optional[Dict[String, String]],
        data: Optional[String],
        json: Optional[String],
        timeout: Optional[Float64],
    ) raises -> Response:
        """Perform a single HTTP request (no redirect following)."""
        # Resolve URL + query params.
        var u = parse_url(url)

        # Resolve DNS NOW (before header Dict allocations) to avoid a heap-state-dependent
        # getaddrinfo failure observed in Mojo 1.0 beta. The IP is passed directly to connect.
        var host = u.host
        var scheme = u.scheme
        var port = u.port
        var ip = _dns_resolve(host)

        if params != None:
            var extra = build_query_string(params.value())
            if u.query.byte_length() > 0:
                u.query = u.query + "&" + extra
            else:
                u.query = extra

        # Merge headers: session defaults <- per-call (per-call wins).
        var merged: Dict[String, String] = {}
        for entry in self.headers.items():
            merged[entry.key] = entry.value
        if headers != None:
            for entry in headers.value().items():
                merged[_to_lower(entry.key)] = entry.value

        # Inject cookies from the session jar (if any), unless the caller set a Cookie header.
        var cookie_str = self.cookies.cookie_header()
        if cookie_str.byte_length() > 0 and not _has_key_ci(merged, "Cookie"):
            merged["Cookie"] = cookie_str

        # Body.
        var body = String()
        if json != None:
            body = json.value()
            if not _has_key_ci(merged, "Content-Type"):
                merged["Content-Type"] = "application/json"
        elif data != None:
            body = data.value()
            if not _has_key_ci(merged, "Content-Type"):
                merged["Content-Type"] = "application/x-www-form-urlencoded"

        # Build the wire request.
        var req_str = build_request(method, u, merged, body)

        # Connect, send, receive. Branch on scheme: https wraps the TCP socket in TLS.
        # DNS was already resolved above (before header allocations) to avoid a heap-state bug.
        var sock = TCPSocket()
        var raw = List[UInt8]()
        var had_error = False
        var err_msg = String()

        if scheme == "https":
            # HTTPS: TCP connect, then TLS handshake, then send/recv over the encrypted channel.
            var tls = TLSConnection()
            try:
                sock.connect_ip(ip, port, timeout)
                tls.connect(sock.fd_value(), host)
                tls.send_all(req_str)
                raw = tls.recv_all()
                tls.close()
                sock.close()
            except e:
                tls.close()
                sock.close()
                had_error = True
                err_msg = String(e)
        else:
            # HTTP: raw TCP send/recv.
            try:
                sock.connect_ip(ip, port, timeout)
                sock.send_all(req_str)
                raw = sock.recv_all()
                sock.close()
            except e:
                sock.close()
                had_error = True
                err_msg = String(e)

        if had_error:
            raise request_exception(err_msg)

        if len(raw) == 0:
            raise request_exception("empty response from server")

        var parsed = parse_response(raw)

        # Compute the final URL before building the response.
        var final_url = u.origin() + u.path
        if u.query.byte_length() > 0:
            final_url = final_url + "?" + u.query

        var resp = _build_response(parsed^, final_url)

        # Extract Set-Cookie headers into the session jar.
        self.cookies.extract_from_headers(resp.headers, host)

        return resp^

    # --- Convenience method shortcuts ---

    def get(
        mut self, url: String, var params: Optional[Dict[String, String]] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("GET", url, params=params^, headers=headers, timeout=timeout, allow_redirects=allow_redirects)

    def post(
        mut self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("POST", url, headers=headers, data=data, json=json, timeout=timeout, allow_redirects=allow_redirects)

    def put(
        mut self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("PUT", url, headers=headers, data=data, json=json, timeout=timeout, allow_redirects=allow_redirects)

    def patch(
        mut self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("PATCH", url, headers=headers, data=data, json=json, timeout=timeout, allow_redirects=allow_redirects)

    def delete(
        mut self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("DELETE", url, headers=headers, timeout=timeout, allow_redirects=allow_redirects)

    def head(
        mut self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("HEAD", url, headers=headers, timeout=timeout, allow_redirects=allow_redirects)

    def options(
        mut self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
    ) raises -> Response:
        return self.request("OPTIONS", url, headers=headers, timeout=timeout, allow_redirects=allow_redirects)


# --- helpers ---


def _to_lower(s: String) -> String:
    var out = String()
    for cp in s.codepoints():
        var i = Int(cp)
        if i >= 65 and i <= 90:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i + 32)))
        else:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
    return out


def _has_key_ci(d: Dict[String, String], key: String) -> Bool:
    var lowered = _to_lower(key)
    for k in d:
        if _to_lower(k) == lowered:
            return True
    return False


def _build_response(var parsed: ParsedResponse, url: String) -> Response:
    """Convert an owned ParsedResponse into a Response.

    Takes ownership of the whole struct so fields can be moved out cleanly (avoids partial-move errors).
    """
    var hdrs = Headers()
    for entry in parsed.headers.items():
        hdrs._data[entry.key] = entry.value
    # Copy body bytes out of the heap-allocated list into a fresh List for the Response.
    var body_copy = List[UInt8]()
    for b in parsed.body[]:
        body_copy.append(b)
    return Response(parsed.status_code, parsed.reason, hdrs^, body_copy^, url)


def _resolve_redirect(base_url: String, location: String) raises -> String:
    """Resolve a (possibly relative) Location header against the base URL.

    Handles:
    - Absolute:        "http://host/path"  → use as-is
    - Protocol-rel:    "//host/path"       → "scheme://host/path"
    - Root-relative:   "/path"             → "scheme://host/path"
    - Relative:        "path"              → "scheme://host/current_dir/path"
    """
    # Absolute URL (has "://")
    if _find(location, "://") >= 0:
        return location

    # Parse the base URL to get scheme + host.
    var base = parse_url(base_url)
    var origin = base.origin()

    # Protocol-relative: "//host/path"
    var loc_ptr = location.unsafe_ptr()
    if location.byte_length() >= 2 and loc_ptr[0] == 0x2F and loc_ptr[1] == 0x2F:
        return base.scheme + ":" + location

    # Root-relative: "/path"
    if location.byte_length() >= 1 and loc_ptr[0] == 0x2F:
        return origin + location

    # Relative: resolve against the current path's directory.
    # Strip the filename from the base path, append the relative location.
    var last_slash = _find_reverse(base.path, "/")
    if last_slash >= 0:
        var dir = String(base.path[byte=0 : last_slash + 1])
        return origin + dir + location
    return origin + "/" + location


def _find_reverse(haystack: String, needle: String) -> Int:
    """Return the byte index of the LAST occurrence of ``needle``, or -1."""
    var hl = haystack.byte_length()
    var nl = needle.byte_length()
    if nl == 0 or hl < nl:
        return -1
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    var i = hl - nl
    while i >= 0:
        var matched = True
        for j in range(nl):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return i
        i -= 1
    return -1


def _find(haystack: String, needle: String) -> Int:
    """Return the byte index of the first occurrence of ``needle``, or -1."""
    var hl = haystack.byte_length()
    var nl = needle.byte_length()
    if nl == 0 or hl < nl:
        return -1
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    var last = hl - nl
    for i in range(last + 1):
        var matched = True
        for j in range(nl):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return i
    return -1
