# Session — the request engine.
#
# Session.request() is the single entry point: it parses the URL, merges default + per-call headers, builds the
# request wire format, opens a TCP connection, sends/receives, and parses the response into a Response object.
# The module-level API in api.mojo delegates to a default Session.

from ._url import parse_url, build_query_string, url_encode
from ._http import build_request, parse_response, parse_headers, ParsedResponse
from ._net import TCPSocket
from ._dns import resolve as _dns_resolve
from ._tls import TLSConnection
from ._cookies import CookieJar
from ._streaming import StreamingConn
from ._pool import KeptAliveConn
from ._net import ResolvedAddress
from .models import Response, Headers
from .exceptions import RequestException, URLRequired, TooManyRedirects
from std.memory import OwnedPointer
from std.ffi import c_int, OwnedDLHandle


struct Session(Movable):
    """A request session holding default headers applied to every request.

    Keep-alive: non-streaming requests reuse TCP/TLS connections to the same endpoint
    (scheme/host/port). After a self-delimiting response (Content-Length or chunked, and no
    ``Connection: close``), the live connection is returned to an internal pool and picked up by
    the next request to that endpoint — amortizing the TCP and (for HTTPS) TLS handshake. A
    pooled connection found stale on reuse is transparently retried on a fresh socket.

    Usage:
        var s = Session()
        s.headers["User-Agent"] = "myapp/1.0"
        var r = s.get("http://example.com")

    Context-manager form (auto-closes pooled connections on exit):
        with Session() as s:
            var r1 = s.get("https://example.com")
            var r2 = s.get("https://example.com")   # reuses r1's connection
    """

    var headers: Dict[String, String]
    var cookies: CookieJar
    var verify: Bool
    var ca_bundle: Optional[String]
    var _pool: List[KeptAliveConn]

    def __init__(out self):
        self.headers = {}
        self.headers["User-Agent"] = "mojo-requests/0.1"
        self.headers["Accept"] = "*/*"
        self.cookies = CookieJar()
        # TLS defaults: verify peers against the system trust store (overridable per-call
        # and per-Session via the verify/ca_bundle parameters).
        self.verify = True
        self.ca_bundle = None
        self._pool = []
        # Warm up the DNS resolver: the first getaddrinfo call in a process can fail on some
        # systems (lazy resolver init). Doing a throwaway resolve here primes it for real use.
        try:
            _ = _dns_resolve("localhost")
        except _:
            pass

    def __moveinit__(out self, mut existing: Self):
        """Move the session; the pool transfers so the source's destructor closes nothing.

        Hand-written because the added ``__del__`` (draining the connection pool) suppresses the
        synthesized move constructor (STRUGGLES.md §3.1)."""
        self.headers = existing.headers^
        self.cookies = existing.cookies^
        self.verify = existing.verify
        self.ca_bundle = existing.ca_bundle^
        self._pool = existing._pool^

    def __del__(deinit self):
        """Close every pooled connection when the Session is dropped (no fd/SSL leaks).
        """
        self.close()

    def __enter__(var self) -> Self:
        """Enter a ``with`` block. The Session is moved into the block and its ``__del__`` closes
        every pooled connection when the block exits (normally or via an exception) — so no
        separate ``__exit__`` is needed (and Mojo forbids pairing a consuming ``__enter__`` with
        one)."""
        return self^

    def close(mut self):
        """Close and discard every idle pooled connection. Idempotent."""
        while len(self._pool) > 0:
            var c = self._pool.pop()
            c.close()

    def _pool_find(self, scheme: String, host: String, port: Int) -> Int:
        """Index of an idle pooled connection matching the endpoint, or -1."""
        for i in range(len(self._pool)):
            if self._pool[i].matches(scheme, host, port):
                return i
        return -1

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
        stream: Bool = False,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        """Issue an HTTP request and return a Response.

        - ``params``: query-string parameters (merged with any in the URL).
        - ``headers``: per-call headers (merged with the session defaults; per-call wins).
        - ``data``: raw request body (form-encoded string, etc.).
        - ``json``: JSON body string (also sets Content-Type: application/json).
        - ``timeout``: per-call connect/send/recv timeout in seconds.
        - ``allow_redirects``: follow 3xx redirects (default True). Ignored when ``stream=True``.
        - ``stream``: if True, return a Response whose body is read lazily via iter_content().
          The connection stays open until the Response is dropped.
        - ``verify``: override the Session-level TLS verification setting for this call.
          None (default) uses self.verify; True verifies peers; False disables verification.
        - ``ca_bundle``: override the Session-level CA bundle path for this call. When None
          (default), the trust store is resolved from $REQUESTS_CA_BUNDLE / $SSL_CERT_FILE /
          system defaults — see TLSConnection.connect.
        """
        if url.byte_length() == 0:
            raise URLRequired("no URL supplied for request")

        var current_url = url
        var redirect_method = method
        var current_data = data
        var current_json = json

        # Resolve effective verify/ca_bundle: per-call override > Session-level default.
        var eff_verify = self.verify
        if verify != None:
            eff_verify = verify.value()
        var eff_ca_bundle = ca_bundle
        if eff_ca_bundle == None:
            eff_ca_bundle = self.ca_bundle

        # First request: consumes params (owned). Subsequent redirects pass None for params.
        var resp = self._do_request(
            redirect_method,
            current_url,
            params^,
            headers,
            current_data,
            current_json,
            timeout,
            stream,
            eff_verify,
            eff_ca_bundle,
        )

        comptime MAX_REDIRECTS = 30
        # Streaming responses are returned as-is (no redirect following; connection stays open).
        if stream or not allow_redirects:
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
                (resp.status_code == 301 or resp.status_code == 302)
                and redirect_method == "POST"
            ):
                redirect_method = "GET"
                current_data = None
                current_json = None

            # Issue the next request (no params on redirects; redirects never stream).
            var none_params: Optional[Dict[String, String]] = None
            resp = self._do_request(
                redirect_method,
                current_url,
                none_params^,
                headers,
                current_data,
                current_json,
                timeout,
                False,
                eff_verify,
                eff_ca_bundle,
            )

        raise TooManyRedirects("exceeded 30 redirects")

    def _do_request(
        mut self,
        method: String,
        url: String,
        params: Optional[Dict[String, String]],
        headers: Optional[Dict[String, String]],
        data: Optional[String],
        json: Optional[String],
        timeout: Optional[Float64],
        stream: Bool,
        verify: Bool,
        ca_bundle: Optional[String],
    ) raises -> Response:
        """Perform a single HTTP request (no redirect following).

        When ``stream`` is True, the connection stays open and the Response carries a live
        StreamingConn for lazy body reads via iter_content().
        """
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

        # Build the wire request. Streaming reads the body to EOF (Connection: close); the
        # pooled non-streaming path reads a framed body and reuses the socket (Connection:
        # keep-alive).
        var is_https = scheme == "https"
        var req_str = build_request(
            method, u, merged, body, keep_alive=not stream
        )

        # Compute the final URL.
        var final_url = u.origin() + u.path
        if u.query.byte_length() > 0:
            final_url = final_url + "?" + u.query

        if stream:
            # Streaming: fresh connection (never pooled), read headers incrementally, keep it
            # alive inside the Response. NOTE: the connect/send try blocks are split per scheme
            # because Mojo 1.0 unifies exception types within a single try block — a typed
            # `raises SSLError` call (tls.*) cannot coexist with a bare `raises` call (sock.*).
            var sock = TCPSocket()
            var tls = TLSConnection()
            if is_https:
                try:
                    sock.connect_ip(ip, port, timeout)
                    tls.connect(sock.fd_value(), host, verify, ca_bundle)
                    tls.send_all(req_str)
                except e:
                    tls.close()
                    sock.close()
                    raise e^
            else:
                try:
                    sock.connect_ip(ip, port, timeout)
                    sock.send_all(req_str)
                except e:
                    sock.close()
                    raise e^
            return self._stream_response(sock^, tls^, is_https, host, final_url)

        # Non-streaming: exchange over a pooled (or fresh) keep-alive connection.
        var raw = self._exchange(
            method,
            req_str,
            scheme,
            host,
            port,
            ip,
            timeout,
            verify,
            ca_bundle,
            is_https,
        )
        if len(raw) == 0:
            raise RequestException("empty response from server")

        var parsed = parse_response(raw)
        var resp = _build_response(parsed^, final_url)
        # Extract Set-Cookie headers into the session jar.
        self.cookies.extract_from_headers(resp.headers, host)
        return resp^

    def _exchange(
        mut self,
        method: String,
        req_str: String,
        scheme: String,
        host: String,
        port: Int,
        ip: ResolvedAddress,
        timeout: Optional[Float64],
        verify: Bool,
        ca_bundle: Optional[String],
        is_https: Bool,
    ) raises -> List[UInt8]:
        """Send ``req_str`` and read one framed response, reusing a pooled connection when possible.

        Tries an idle pooled connection for this endpoint first; if its send/recv fails (a stale
        keep-alive socket the server already dropped), it is closed and the request is retried
        once on a fresh connection. A connection that yields a self-delimiting, non-``close``
        response is returned to the pool; otherwise it is closed.
        """
        var reusable = False
        var raw = List[UInt8]()

        # Attempt reuse.
        var idx = self._pool_find(scheme, host, port)
        if idx >= 0:
            var pooled = self._pool.pop(idx)
            var ok = True
            try:
                pooled.send_all(req_str)
                raw = pooled.recv_framed(method, reusable)
            except e:
                pooled.close()
                ok = False
            if ok:
                if reusable:
                    self._pool.append(pooled^)
                else:
                    pooled.close()
                return raw^
            # else: stale — fall through to a fresh connection.

        # Fresh connection.
        var fresh = self._connect_new(
            scheme, host, port, ip, timeout, verify, ca_bundle, is_https
        )
        fresh.send_all(req_str)
        raw = fresh.recv_framed(method, reusable)
        if reusable:
            self._pool.append(fresh^)
        else:
            fresh.close()
        return raw^

    def _connect_new(
        mut self,
        scheme: String,
        host: String,
        port: Int,
        ip: ResolvedAddress,
        timeout: Optional[Float64],
        verify: Bool,
        ca_bundle: Optional[String],
        is_https: Bool,
    ) raises -> KeptAliveConn:
        """Open a fresh TCP (and, for HTTPS, TLS) connection and hand back a KeptAliveConn that
        owns the live fd + SSL* + libssl handle (stolen from the throwaway socket/TLS wrappers,
        the same way streaming does). NOTE: split per scheme for the same typed-`raises` reason
        as the streaming path."""
        var sock = TCPSocket()
        var tls = TLSConnection()
        if is_https:
            try:
                sock.connect_ip(ip, port, timeout)
                tls.connect(sock.fd_value(), host, verify, ca_bundle)
            except e:
                tls.close()
                sock.close()
                raise e^
            var fd = sock.fd_value()
            var ssl_ptr = tls._steal_ssl()
            var handle = tls._steal_libssl()
            sock._disown()
            tls._disown()
            return KeptAliveConn(
                scheme, host, port, fd, True, handle^, ssl_ptr^
            )
        else:
            try:
                sock.connect_ip(ip, port, timeout)
            except e:
                sock.close()
                raise e^
            var fd = sock.fd_value()
            sock._disown()
            var no_handle: Optional[OwnedPointer[OwnedDLHandle]] = None
            var no_ssl: Optional[
                UnsafePointer[UInt8, MutUntrackedOrigin]
            ] = None
            return KeptAliveConn(
                scheme, host, port, fd, False, no_handle^, no_ssl^
            )

    def _stream_response(
        mut self,
        var sock: TCPSocket,
        var tls: TLSConnection,
        is_https: Bool,
        host: String,
        final_url: String,
    ) raises -> Response:
        """Read response headers incrementally, then return a streaming Response.

        The socket+TLS connection ownership transfers into the StreamingConn (closed when the
        Response is dropped).
        """
        # Read bytes until we find the \r\n\r\n header terminator, plus any leftover body bytes.
        var header_buf = List[UInt8]()
        var term_found = False
        var tmp = alloc[UInt8](8192)
        while not term_found:
            var n = tls._ssl_read_raw(
                tmp, 8192
            ) if is_https else sock._recv_raw(tmp, 8192)
            if n > c_int(0):
                var count = Int(n)
                for i in range(count):
                    header_buf.append(tmp[i])
                # Check for \r\n\r\n in the buffer.
                if _contains_term(header_buf):
                    term_found = True
            else:
                break
        tmp.free()

        if not term_found:
            tls.close()
            sock.close()
            raise RequestException("streaming: incomplete response headers")

        # Split header bytes from leftover body bytes at the terminator.
        var sep = _find_in_list(header_buf, _crlf_crlf())
        var head_str = _list_slice_to_string(header_buf, 0, sep)
        var body_start = sep + 4
        var leftover = List[UInt8]()
        for i in range(body_start, len(header_buf)):
            leftover.append(header_buf[i])

        var ph = parse_headers(head_str)
        var status_code = ph.status_code
        var reason = ph.reason
        # Read framing values, then copy headers (Dict can't be moved out of a struct field).
        var te = ph.headers.get("transfer-encoding", String(""))
        var cl_str = ph.headers.get("content-length", String(""))
        var chunked = _to_lower(te) == "chunked"
        var cl = _parse_content_length(cl_str)
        var hdrs = Headers()
        for entry in ph.headers.items():
            hdrs._data[entry.key] = entry.value

        # Extract Set-Cookie from the headers we already have.
        self.cookies.extract_from_headers(hdrs, host)

        # Build the StreamingConn. It takes ownership of the socket fd + TLS handle.
        var fd = sock.fd_value()
        var ssl_ptr = (
            tls._steal_ssl()
        )  # transfer SSL* out of TLSConnection (prevents its close)
        var libssl_handle = tls._steal_libssl()  # transfer the libssl handle
        # Mark sock/tls as no longer owning the connection so their destructors don't double-close.
        sock._disown()
        tls._disown()

        var content_length = -1
        if cl != None:
            content_length = cl.value()
        var conn = StreamingConn(
            fd, libssl_handle^, ssl_ptr^, leftover^, content_length, chunked
        )
        var conn_ptr = OwnedPointer[StreamingConn](conn^)

        return Response(
            status_code, reason, hdrs^, List[UInt8](), final_url, conn_ptr^
        )

    # --- Convenience method shortcuts ---

    def get(
        mut self,
        url: String,
        var params: Optional[Dict[String, String]] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        stream: Bool = False,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "GET",
            url,
            params=params^,
            headers=headers,
            timeout=timeout,
            allow_redirects=allow_redirects,
            stream=stream,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def post(
        mut self,
        url: String,
        data: Optional[String] = None,
        json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "POST",
            url,
            headers=headers,
            data=data,
            json=json,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def put(
        mut self,
        url: String,
        data: Optional[String] = None,
        json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "PUT",
            url,
            headers=headers,
            data=data,
            json=json,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def patch(
        mut self,
        url: String,
        data: Optional[String] = None,
        json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "PATCH",
            url,
            headers=headers,
            data=data,
            json=json,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def delete(
        mut self,
        url: String,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "DELETE",
            url,
            headers=headers,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def head(
        mut self,
        url: String,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "HEAD",
            url,
            headers=headers,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )

    def options(
        mut self,
        url: String,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
        allow_redirects: Bool = True,
        verify: Optional[Bool] = None,
        ca_bundle: Optional[String] = None,
    ) raises -> Response:
        return self.request(
            "OPTIONS",
            url,
            headers=headers,
            timeout=timeout,
            allow_redirects=allow_redirects,
            verify=verify,
            ca_bundle=ca_bundle,
        )


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
    if (
        location.byte_length() >= 2
        and loc_ptr[0] == 0x2F
        and loc_ptr[1] == 0x2F
    ):
        return base.scheme + ":" + location

    # Root-relative: "/path"
    if location.byte_length() >= 1 and loc_ptr[0] == 0x2F:
        return origin + location

    # Relative: resolve against the current path's directory.
    # Strip the filename from the base path, append the relative location.
    var last_slash = _find_reverse(base.path, "/")
    if last_slash >= 0:
        var dir = String(base.path[byte = 0 : last_slash + 1])
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


# --- streaming helpers ---


def _contains_term(buf: List[UInt8]) -> Bool:
    """True if the buffer contains the \\r\\n\\r\\n header terminator."""
    return _find_in_list(buf, _crlf_crlf()) >= 0


def _crlf_crlf() -> List[UInt8]:
    """The byte sequence \\r\\n\\r\\n (HTTP header terminator)."""
    var n: List[UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    return n^


def _find_in_list(buf: List[UInt8], needle: List[UInt8]) -> Int:
    """Return the byte index of the first occurrence of ``needle`` in ``buf``, or -1.
    """
    var bl = len(buf)
    var nl = len(needle)
    if nl == 0 or bl < nl:
        return -1
    var last = bl - nl
    for i in range(last + 1):
        var matched = True
        for j in range(nl):
            if buf[i + j] != needle[j]:
                matched = False
                break
        if matched:
            return i
    return -1


def _list_slice_to_string(buf: List[UInt8], start: Int, end: Int) -> String:
    """Convert a slice of a byte list to a String (lossy UTF-8)."""
    var slice = List[UInt8]()
    for i in range(start, end):
        slice.append(buf[i])
    var span = Span[UInt8](ptr=slice.unsafe_ptr(), length=len(slice))
    return String(from_utf8_lossy=span)


def _parse_content_length(s: String) -> Optional[Int]:
    """Parse a Content-Length value (digits) to Int, or None."""
    if s.byte_length() == 0:
        return None
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var v = 0
    for i in range(n):
        var b = sp[i]
        if b < 0x30 or b > 0x39:
            return None
        v = v * 10 + Int(b - 0x30)
    return v
