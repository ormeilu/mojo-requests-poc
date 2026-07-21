# Proxy support — HTTP proxying + HTTPS CONNECT tunneling (pure Mojo).
#
# Two mechanisms, matching Python `requests`:
#   - HTTP target through an HTTP proxy: the request is sent to the proxy with an *absolute-form*
#     request target (`GET http://host/path HTTP/1.1`); the proxy forwards it. See
#     `build_request(..., absolute_target=True)` in `_http.mojo`.
#   - HTTPS target through an HTTP proxy: a `CONNECT host:port` tunnel is established on the raw
#     socket (`tunnel_connect`); after a 2xx from the proxy the socket is a transparent pipe to
#     the target, and the normal TLS handshake runs over it (SNI/cert verification against the
#     *target* host, not the proxy).
#
# v1 limits (deferred): proxy authentication / userinfo in the proxy URL, and HTTPS proxies
# (TLS to the proxy itself). Proxied connections are never pooled (a fresh connection per
# request) — pooling by proxy endpoint is future work.

from std.ffi import c_int
from std.memory import alloc
from ._url import URL, parse_url
from ._net import TCPSocket
from .exceptions import ProxyError


def select_proxy(
    proxies: Dict[String, String], scheme: String
) raises -> Optional[URL]:
    """Pick and parse the proxy URL for a target ``scheme`` (``http``/``https``).

    Lookup order: an exact ``scheme`` key, then an ``all`` catch-all key. Returns None when no
    proxy applies (empty dict, no matching key, or an empty value). Raises ``InvalidURL`` if the
    proxy URL is malformed and ``ProxyError`` if it names an unsupported (non-http) proxy scheme.
    """
    var val: String
    if scheme in proxies:
        val = proxies[scheme]
    elif "all" in proxies:
        val = proxies["all"]
    else:
        return None
    if val.byte_length() == 0:
        return None
    var pu = parse_url(val)
    if pu.scheme != "http":
        raise ProxyError(
            String(
                t"unsupported proxy scheme '{pu.scheme}' (only http proxies are"
                t" supported)"
            )
        )
    return pu^


def tunnel_connect(
    mut sock: TCPSocket,
    target_host: String,
    target_port: Int,
    is_ipv6_literal: Bool,
) raises:
    """Establish a CONNECT tunnel through an already-connected proxy socket.

    Sends ``CONNECT host:port HTTP/1.1`` + ``Host`` header, reads the proxy's response headers,
    and raises ``ProxyError`` unless the status is 2xx. On success the socket is a transparent
    byte pipe to ``target_host:target_port`` and the caller runs the TLS handshake over it.

    IPv6 literal targets are bracketed (``[::1]:443``) per RFC 7230. The response is read one
    byte at a time up to the ``\\r\\n\\r\\n`` terminator so no bytes past the proxy's reply are
    consumed (the client speaks first in TLS, so the target sends nothing until then).
    """
    var authority: String
    if is_ipv6_literal:
        authority = "[" + target_host + "]:" + String(target_port)
    else:
        authority = target_host + ":" + String(target_port)
    var req = (
        "CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n\r\n"
    )
    sock.send_all(req)

    var buf = alloc[UInt8](1)
    var data = List[UInt8]()
    while True:
        var n = sock._recv_raw(buf, 1)
        if n <= c_int(0):
            buf.free()
            raise ProxyError(
                "proxy closed connection during CONNECT", host=target_host
            )
        data.append(buf[0])
        if _ends_crlf_crlf(data):
            break
    buf.free()

    var head = _bytes_to_string(data)
    var status = _parse_status(head)
    if status < 200 or status >= 300:
        raise ProxyError(
            String(t"proxy CONNECT to {authority} failed with status {status}"),
            host=target_host,
        )


# --- helpers --------------------------------------------------------------


def _ends_crlf_crlf(data: List[UInt8]) -> Bool:
    """True if ``data`` ends with the ``\\r\\n\\r\\n`` header terminator."""
    var n = len(data)
    if n < 4:
        return False
    return (
        data[n - 4] == 0x0D
        and data[n - 3] == 0x0A
        and data[n - 2] == 0x0D
        and data[n - 1] == 0x0A
    )


def _bytes_to_string(bs: List[UInt8]) -> String:
    """Decode bytes to a String (lossy UTF-8)."""
    var span = Span[UInt8](ptr=bs.unsafe_ptr(), length=len(bs))
    return String(from_utf8_lossy=span)


def _parse_status(head: String) -> Int:
    """Extract the numeric status code from a status line (``HTTP/1.1 200 ...`` -> 200).
    """
    var lines = head.split("\r\n")
    if len(lines) == 0:
        return 0
    var parts = String(lines[0]).split(" ")
    if len(parts) < 2:
        return 0
    var code = String(parts[1])
    var sp = code.unsafe_ptr()
    var v = 0
    var seen = False
    for i in range(code.byte_length()):
        var b = sp[i]
        if b < 0x30 or b > 0x39:
            break
        v = v * 10 + Int(b - 0x30)
        seen = True
    return v if seen else 0
