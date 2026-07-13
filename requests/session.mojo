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

    def __init__(out self):
        self.headers = {}
        self.headers["User-Agent"] = "mojo-requests/0.1"
        self.headers["Accept"] = "*/*"
        # Warm up the DNS resolver: the first getaddrinfo call in a process can fail on some
        # systems (lazy resolver init). Doing a throwaway resolve here primes it for real use.
        try:
            _ = _dns_resolve("localhost")
        except _:
            pass

    def request(
        self,
        method: String,
        url: String,
        params: Optional[Dict[String, String]] = None,
        headers: Optional[Dict[String, String]] = None,
        data: Optional[String] = None,
        json: Optional[String] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        """Issue an HTTP request and return a Response.

        - ``params``: query-string parameters (merged with any in the URL).
        - ``headers``: per-call headers (merged with the session defaults; per-call wins).
        - ``data``: raw request body (form-encoded string, etc.).
        - ``json``: JSON body string (also sets Content-Type: application/json).
        - ``timeout``: per-call connect/send/recv timeout in seconds.
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

        return _build_response(parsed^, final_url)

    # --- Convenience method shortcuts ---

    def get(
        self, url: String, params: Optional[Dict[String, String]] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("GET", url, params=params, headers=headers, timeout=timeout)

    def post(
        self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("POST", url, headers=headers, data=data, json=json, timeout=timeout)

    def put(
        self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("PUT", url, headers=headers, data=data, json=json, timeout=timeout)

    def patch(
        self, url: String, data: Optional[String] = None, json: Optional[String] = None,
        headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("PATCH", url, headers=headers, data=data, json=json, timeout=timeout)

    def delete(
        self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("DELETE", url, headers=headers, timeout=timeout)

    def head(
        self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("HEAD", url, headers=headers, timeout=timeout)

    def options(
        self, url: String, headers: Optional[Dict[String, String]] = None,
        timeout: Optional[Float64] = None,
    ) raises -> Response:
        return self.request("OPTIONS", url, headers=headers, timeout=timeout)


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
