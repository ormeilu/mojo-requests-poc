# URL parser — pure Mojo.
#
# Parses absolute HTTP URLs into scheme/host/port/path/query/fragment.
# Implements percent-encoding for query strings and form bodies.

from .exceptions import invalid_url_error, unsupported_scheme_error


struct URL(Movable, Writable):
    """A parsed absolute HTTP URL.

    Fields are all owned Strings. ``port`` defaults to 80 for http if absent.
    """
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var query: String
    var fragment: String

    def __init__(out self):
        self.scheme = "http"
        self.host = ""
        self.port = 80
        self.path = "/"
        self.query = ""
        self.fragment = ""

    def request_target(self) -> String:
        """The request target for the HTTP request line (path [+ '?' + query])."""
        if self.query.byte_length() > 0:
            return self.path + "?" + self.query
        return self.path

    def origin(self) -> String:
        """``scheme://host[:port]`` (omits default port 80)."""
        if self.port == 80:
            return self.scheme + "://" + self.host
        return self.scheme + "://" + self.host + ":" + String(self.port)

    def host_header(self) -> String:
        """Host header value (host[:port] if non-default)."""
        if self.port == 80:
            return self.host
        return self.host + ":" + String(self.port)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.origin(), self.path)


def parse_url(raw: String) raises -> URL:
    """Parse an absolute ``http://host[:port][/path][?query][#fragment]`` URL.

    Raises ``invalid_url_error`` on malformed input and ``unsupported_scheme_error`` for non-http schemes.
    """
    var s = raw
    var u = URL()

    # scheme://
    var sep = _find(s, "://")
    if sep < 0:
        raise invalid_url_error(String(t"URL missing scheme (use http://): {raw}"))
    u.scheme = _to_lower(String(s[byte=0:sep]))

    if u.scheme != "http":
        raise unsupported_scheme_error(String(t"scheme '{u.scheme}' not supported (http only in v1)"))

    var rest_start = sep + 3  # skip "://"
    var rest = String(s[byte=rest_start:])

    # fragment
    var frag_pos = _find(rest, "#")
    if frag_pos >= 0:
        u.fragment = String(rest[byte=frag_pos + 1 :])
        rest = String(rest[byte=0:frag_pos])

    # query
    var q_pos = _find(rest, "?")
    if q_pos >= 0:
        u.query = String(rest[byte=q_pos + 1 :])
        rest = String(rest[byte=0:q_pos])

    # path
    var p_pos = _find(rest, "/")
    var authority: String
    if p_pos >= 0:
        authority = String(rest[byte=0:p_pos])
        u.path = String(rest[byte=p_pos:])
    else:
        authority = rest
        u.path = "/"

    # authority = host[:port]
    if authority.byte_length() == 0:
        raise invalid_url_error(String(t"URL missing host: {raw}"))

    var colon = _find(authority, ":")
    if colon >= 0:
        u.host = String(authority[byte=0:colon])
        var port_str = String(authority[byte=colon + 1 :])
        var parsed_port = _parse_int(port_str)
        if parsed_port == None or parsed_port.value() < 1 or parsed_port.value() > 65535:
            raise invalid_url_error(String(t"URL has invalid port: {port_str}"))
        u.port = parsed_port.value()
    else:
        u.host = authority
        u.port = 80

    return u^


# --- Query string + form encoding -----------------------------------------


def url_encode(s: String) -> String:
    """Percent-encode a string for use in query strings / form bodies.

    Unreserved characters (A-Z a-z 0-9 - _ . ~) pass through; everything else is %XX-encoded. Space -> +.
    """
    var out = String()
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var hex = "0123456789ABCDEF"
    var hp = hex.unsafe_ptr()
    for i in range(n):
        var b = sp[i]
        if _is_unreserved(b):
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(b)))
        elif b == 0x20:  # space -> '+'
            out += "+"
        else:
            out += "%"
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(hp[(b >> 4) & 0x0F])))
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(hp[b & 0x0F])))
    return out


def build_query_string(params: Dict[String, String]) -> String:
    """Build a ``key=value&key=value`` query string from a dict, percent-encoding both sides."""
    var parts: List[String] = []
    for entry in params.items():
        parts.append(url_encode(entry.key) + "=" + url_encode(entry.value))
    return "&".join(parts)


# --- Helpers --------------------------------------------------------------


def _is_unreserved(b: UInt8) -> Bool:
    # A-Z a-z 0-9 - _ . ~
    if b >= 0x41 and b <= 0x5A:
        return True
    if b >= 0x61 and b <= 0x7A:
        return True
    if b >= 0x30 and b <= 0x39:
        return True
    if b == 0x2D or b == 0x5F or b == 0x2E or b == 0x7E:
        return True
    return False


def _find(haystack: String, needle: String) -> Int:
    """Return the byte index of the first occurrence of ``needle`` in ``haystack``, or -1."""
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


def _parse_int(s: String) -> Optional[Int]:
    """Parse a non-empty ASCII digit string to Int, or None."""
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


def _to_lower(s: String) -> String:
    """Lowercase an ASCII string (non-ASCII codepoints pass through unchanged)."""
    var out = String()
    for cp in s.codepoints():
        var i = Int(cp)
        if i >= 65 and i <= 90:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i + 32)))
        else:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
    return out
