# URL parser — pure Mojo.
#
# Parses absolute HTTP URLs into scheme/host/port/path/query/fragment.
# Implements percent-encoding for query strings and form bodies.

from .exceptions import InvalidURL, UnsupportedScheme


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
        """The request target for the HTTP request line (path [+ '?' + query]).
        """
        if self.query.byte_length() > 0:
            return self.path + "?" + self.query
        return self.path

    def is_ipv6_literal(self) -> Bool:
        """True if ``host`` is an IPv6 literal (contains a ``:``).

        Stored WITHOUT brackets (RFC 3986 authority form is ``[::1]``, but we store the bare
        ``::1`` for handing to DNS/connect); ``host_header``/``origin`` re-add the brackets per
        RFC 7230 §5.5.
        """
        return _find(self.host, ":") >= 0

    def _display_host(self) -> String:
        """The host as it should appear in a Host header / origin URL — bracketed for IPv6
        literals (``::1`` → ``[::1]``), unchanged otherwise."""
        if self.is_ipv6_literal():
            return "[" + self.host + "]"
        return self.host

    def origin(self) -> String:
        """``scheme://host[:port]`` (omits default ports 80/443)."""
        if (self.scheme == "http" and self.port == 80) or (
            self.scheme == "https" and self.port == 443
        ):
            return self.scheme + "://" + self._display_host()
        return (
            self.scheme + "://" + self._display_host() + ":" + String(self.port)
        )

    def host_header(self) -> String:
        """Host header value (host[:port] if non-default for the scheme)."""
        if (self.scheme == "http" and self.port == 80) or (
            self.scheme == "https" and self.port == 443
        ):
            return self._display_host()
        return self._display_host() + ":" + String(self.port)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.origin(), self.path)


def parse_url(raw: String) raises -> URL:
    """Parse an absolute ``http://host[:port][/path][?query][#fragment]`` URL.

    Raises ``InvalidURL`` on malformed input and ``UnsupportedScheme`` for non-http schemes.
    """
    var s = raw
    var u = URL()

    # scheme://
    var sep = _find(s, "://")
    if sep < 0:
        raise InvalidURL(String(t"URL missing scheme (use http://): {raw}"))
    u.scheme = _to_lower(String(s[byte=0:sep]))

    if u.scheme != "http" and u.scheme != "https":
        raise UnsupportedScheme(
            String(t"scheme '{u.scheme}' not supported (only http/https)"),
            scheme=u.scheme,
        )

    var rest_start = sep + 3  # skip "://"
    var rest = String(s[byte=rest_start:])

    # fragment
    var frag_pos = _find(rest, "#")
    if frag_pos >= 0:
        u.fragment = String(rest[byte = frag_pos + 1 :])
        var sliced = String(rest[byte=0:frag_pos])
        rest = sliced

    # query
    var q_pos = _find(rest, "?")
    if q_pos >= 0:
        u.query = String(rest[byte = q_pos + 1 :])
        var sliced = String(rest[byte=0:q_pos])
        rest = sliced

    # path
    var p_pos = _find(rest, "/")
    var authority: String
    if p_pos >= 0:
        authority = String(rest[byte=0:p_pos])
        u.path = String(rest[byte=p_pos:])
    else:
        authority = rest
        u.path = "/"

    # authority = host[:port], where host may be a bracketed IPv6 literal: [::1] or [::1]:8080
    # (RFC 3986). We store the host WITHOUT brackets (bare "::1"), used directly for DNS/connect.
    if authority.byte_length() == 0:
        raise InvalidURL(String(t"URL missing host: {raw}"))

    var auth_ptr = authority.unsafe_ptr()
    if (
        authority.byte_length() >= 1 and auth_ptr[0] == 0x5B
    ):  # '[' → IPv6 literal
        var close = _find(authority, "]")
        if close < 0:
            raise InvalidURL(String(t"URL has unterminated '[' in host: {raw}"))
        u.host = String(authority[byte=1:close])  # without brackets
        var after = authority.byte_length() - (close + 1)
        if after == 0:
            # No port. Default port: 443 for https, 80 for http.
            if u.scheme == "https":
                u.port = 443
            else:
                u.port = 80
        else:
            # Must be ":port" immediately after the ']'.
            var rest_after_bracket = String(authority[byte = close + 1 :])
            var rap = rest_after_bracket.unsafe_ptr()
            if rest_after_bracket.byte_length() < 1 or rap[0] != 0x3A:  # ':'
                raise InvalidURL(
                    String(t"URL has garbage after IPv6 host: {raw}")
                )
            var port_str = String(rest_after_bracket[byte=1:])
            var parsed_port = _parse_int(port_str)
            if (
                parsed_port == None
                or parsed_port.value() < 1
                or parsed_port.value() > 65535
            ):
                raise InvalidURL(String(t"URL has invalid port: {port_str}"))
            u.port = parsed_port.value()
    else:
        # Plain hostname or IPv4 literal: split on the FIRST ':' (IPv4 literals have none).
        var colon = _find(authority, ":")
        if colon >= 0:
            u.host = String(authority[byte=0:colon])
            var port_str = String(authority[byte = colon + 1 :])
            var parsed_port = _parse_int(port_str)
            if (
                parsed_port == None
                or parsed_port.value() < 1
                or parsed_port.value() > 65535
            ):
                raise InvalidURL(String(t"URL has invalid port: {port_str}"))
            u.port = parsed_port.value()
        else:
            u.host = authority
            # Default port: 443 for https, 80 for http.
            if u.scheme == "https":
                u.port = 443
            else:
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
            out += String(
                Codepoint(
                    unsafe_unchecked_codepoint=UInt32(hp[(b >> 4) & 0x0F])
                )
            )
            out += String(
                Codepoint(unsafe_unchecked_codepoint=UInt32(hp[b & 0x0F]))
            )
    return out


def build_query_string(params: Dict[String, String]) -> String:
    """Build a ``key=value&key=value`` query string from a dict, percent-encoding both sides.
    """
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
    """Return the byte index of the first occurrence of ``needle`` in ``haystack``, or -1.
    """
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
    """Lowercase an ASCII string (non-ASCII codepoints pass through unchanged).
    """
    var out = String()
    for cp in s.codepoints():
        var i = Int(cp)
        if i >= 65 and i <= 90:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i + 32)))
        else:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
    return out
