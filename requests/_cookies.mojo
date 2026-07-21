# Cookie jar — parse Set-Cookie headers and store cookies for subsequent requests.
#
# Minimal implementation: parses "name=value" from Set-Cookie headers (ignores attributes like
# Path, Domain, Expires, Secure, HttpOnly for now). Stores cookies per-host and sends them
# back as a "Cookie: name=value; ..." request header.

from ._url import parse_url, _find


struct CookieJar(Movable):
    """A simple cookie store: maps cookie name → value.

    Cookies are stored globally (not per-host) for simplicity. For a v1 client this matches
    Python requests' default Session cookie behavior closely enough for most use cases.
    """

    var _cookies: Dict[String, String]

    def __init__(out self):
        self._cookies = {}

    def extract_from_headers(mut self, headers: Headers, host: String) raises:
        """Parse Set-Cookie headers from a response and store the cookies."""
        # Headers may contain multiple Set-Cookie values separated by newlines in our parser,
        # or a single combined header. We try both the lowercase "set-cookie" key.
        if not headers.contains("set-cookie"):
            return
        var raw = headers["set-cookie"]
        # A single Set-Cookie header may contain multiple cookies (uncommon but possible).
        # Each cookie is "name=value; attributes...". Split on ';' to get the name=value part.
        var parts = raw.split(";")
        for part in parts:
            var p = String(part)
            var eq = _find(p, "=")
            if eq < 0:
                continue
            var name = String(p[byte=0:eq])
            var value = String(p[byte = eq + 1 :])
            name = _strip(name)
            value = _strip(value)
            if name.byte_length() > 0:
                self._cookies[name] = value

    def cookie_header(self) -> String:
        """Build a 'name=value; name2=value2' string for the Cookie request header.
        """
        if len(self._cookies) == 0:
            return String()
        var parts: List[String] = []
        for entry in self._cookies.items():
            parts.append(entry.key + "=" + entry.value)
        return "; ".join(parts)

    def clear(mut self):
        self._cookies = {}


def _strip(s: String) -> String:
    """Strip leading/trailing ASCII whitespace."""
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var start = 0
    var end = n
    while start < n and _is_ws(sp[start]):
        start += 1
    while end > start and _is_ws(sp[end - 1]):
        end -= 1
    return String(s[byte=start:end])


def _is_ws(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0D or b == 0x0A


# Forward declaration: Headers is in models.mojo
from .models import Headers
