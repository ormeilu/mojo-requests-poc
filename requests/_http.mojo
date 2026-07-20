# HTTP/1.1 request building + response framing — pure Mojo.
#
# Builds the on-the-wire request string and parses the raw response bytes into status line / headers / body.
# Supports Content-Length framing and Transfer-Encoding: chunked dechunking.

from ._url import URL, build_query_string, url_encode, _to_lower, _find
from .exceptions import request_exception
from std.memory import OwnedPointer


comptime CRLF = "\r\n"
comptime HEADER_TERMINATOR = "\r\n\r\n"


# --- Request building --------------------------------------------------------


def build_request(
    method: String,
    imm url: URL,
    imm headers: Dict[String, String],
    body: String,
) -> String:
    """Assemble the HTTP/1.1 request wire format.

    - Inserts a default ``Host`` header if absent.
    - Inserts ``Content-Length`` when a body is present.
    - Inserts ``Connection: close`` so the server closes after responding (simplest reliable read-to-EOF).
    """
    var h = headers.copy()
    if not _has_key_ci(h, "Host"):
        h["Host"] = url.host_header()
    if body.byte_length() > 0 and not _has_key_ci(h, "Content-Length"):
        h["Content-Length"] = String(body.byte_length())
    if not _has_key_ci(h, "Connection"):
        h["Connection"] = "close"

    var lines: List[String] = []
    lines.append(method + " " + url.request_target() + " HTTP/1.1")
    for entry in h.items():
        lines.append(entry.key + ": " + entry.value)
    var head = CRLF.join(lines) + HEADER_TERMINATOR
    return head + body


def _has_key_ci(d: Dict[String, String], key: String) -> Bool:
    """Case-insensitive header presence check."""
    var lowered = _to_lower(key)
    for k in d:
        if _to_lower(k) == lowered:
            return True
    return False


# --- Response parsing ------------------------------------------------------


@fieldwise_init
struct ParsedHeaders:
    """Just the status line + headers (no body). Returned by parse_headers()."""

    var status_code: Int
    var reason: String
    var headers: Dict[String, String]


def parse_headers(head: String) raises -> ParsedHeaders:
    """Parse the header block (status line + headers, no body) into a ParsedHeaders.

    ``head`` is the bytes up to (but not including) the terminating ``\\r\\n\\r\\n``.
    """
    var lines = head.split(CRLF)
    if len(lines) == 0:
        raise request_exception("malformed response: empty header block")

    # Status line: "HTTP/1.1 200 OK"
    var status_line = String(lines[0])
    var status_parts = status_line.split(" ")
    if len(status_parts) < 2:
        raise request_exception(String(t"malformed status line: {status_line}"))
    var code = _parse_int_local(String(status_parts[1]))
    if code == None:
        raise request_exception(
            String(t"malformed status code: {status_parts[1]}")
        )

    var reason = String()
    var sp_pos = _find(status_line, " ")
    if sp_pos >= 0:
        var after_ver = String(status_line[byte = sp_pos + 1 :])
        var sp2 = _find(after_ver, " ")
        if sp2 >= 0:
            reason = String(after_ver[byte = sp2 + 1 :])

    var headers: Dict[String, String] = {}
    var i = 1
    while i < len(lines):
        var line = String(lines[i])
        if line.byte_length() == 0:
            i += 1
            continue
        var colon = _find(line, ":")
        if colon < 0:
            i += 1
            continue
        var name = _to_lower(String(line[byte=0:colon]))
        var value = String(line[byte = colon + 1 :])
        value = _strip(value)
        headers[name] = value
        i += 1

    return ParsedHeaders(code.value(), reason, headers^)


@fieldwise_init
struct ParsedResponse:
    """The parsed pieces of an HTTP response, before being wrapped in a Response object.

    body is heap-allocated so the whole struct can be cheaply moved without partial-move restrictions.
    """

    var status_code: Int
    var reason: String
    var headers: Dict[String, String]
    var body: OwnedPointer[List[UInt8]]

    def __init__(
        out self,
        status_code: Int,
        reason: String,
        var headers: Dict[String, String],
        var body: List[UInt8],
    ):
        self.status_code = status_code
        self.reason = reason
        self.headers = headers^
        self.body = OwnedPointer[List[UInt8]](body^)


def parse_response(raw: List[UInt8]) raises -> ParsedResponse:
    """Parse raw response bytes (headers + body) into a ParsedResponse.

    Handles Content-Length and chunked Transfer-Encoding. The raw bytes must contain the full response
    (the socket layer reads until the peer closes, which our ``Connection: close`` header requests).
    """
    var raw_str = _bytes_to_string(raw)

    # Split headers from body at the first \r\n\r\n.
    var sep = _find(raw_str, HEADER_TERMINATOR)
    if sep < 0:
        raise request_exception("malformed response: no header/body separator")

    var head = String(raw_str[byte=0:sep])
    var body_start = sep + 4  # len("\r\n\r\n")

    var ph = parse_headers(head)
    return _build_parsed(ph^, raw, body_start)


def _build_parsed(
    var ph: ParsedHeaders, raw: List[UInt8], body_start: Int
) raises -> ParsedResponse:
    """Build a ParsedResponse from owned headers.

    Copies header entries into a fresh Dict (Dict is non-copyable and can't be moved out of a struct
    field while other fields are read, so we rebuild it).
    """
    var status_code = ph.status_code
    var reason = ph.reason
    # Read framing info as values, then copy headers into a fresh dict.
    var te = ph.headers.get("transfer-encoding", String(""))
    var cl_str = ph.headers.get("content-length", String(""))
    var chunked = _to_lower(te) == "chunked"
    var cl = _parse_int_local(cl_str)
    var headers_copy: Dict[String, String] = {}
    for entry in ph.headers.items():
        headers_copy[entry.key] = entry.value
    var body = _extract_body(raw, body_start, chunked, cl)
    return ParsedResponse(status_code, reason, headers_copy^, body^)


def _extract_body(
    raw: List[UInt8],
    body_start: Int,
    chunked: Bool,
    content_length: Optional[Int],
) raises -> List[UInt8]:
    """Extract the response body. ``chunked`` and ``content_length`` are pre-parsed framing values.
    """
    if chunked:
        return _dechunk(raw, body_start)

    var body = List[UInt8]()
    var total = len(raw)
    if body_start >= total:
        return body^

    if content_length != None:
        var take = content_length.value()
        if body_start + take > total:
            take = total - body_start  # don't overrun
        for k in range(take):
            body.append(raw[body_start + k])
    else:
        for k in range(body_start, total):
            body.append(raw[k])
    return body^


def _dechunk(raw: List[UInt8], body_start: Int) raises -> List[UInt8]:
    """Decode HTTP chunked transfer-encoding into a contiguous body."""
    var out = List[UInt8]()
    var pos = body_start
    var total = len(raw)
    while pos < total:
        # Read a chunk size line (hex) up to \r\n.
        var size_line = _read_line(raw, pos)
        var size_str = _bytes_to_string(size_line.line)
        # Strip any chunk extensions (";...")
        var semi = _find(size_str, ";")
        if semi >= 0:
            size_str = String(size_str[byte=0:semi])
        size_str = _strip(size_str)
        var size = _parse_hex(size_str)
        if size == None:
            raise request_exception(String(t"malformed chunk size: {size_str}"))
        pos = size_line.next_pos  # past "\r\n"
        if size.value() == 0:
            break
        for _ in range(size.value()):
            if pos < total:
                out.append(raw[pos])
                pos += 1
        # Skip trailing "\r\n" after chunk data.
        pos = _skip_crlf(raw, pos)
    return out^


@fieldwise_init
struct _LineRead:
    var line: List[UInt8]
    var next_pos: Int


def _read_line(raw: List[UInt8], start: Int) -> _LineRead:
    """Read bytes until \n, not including the trailing \r\n. Returns the line and the position after \n.
    """
    var line = List[UInt8]()
    var pos = start
    var total = len(raw)
    while pos < total:
        var b = raw[pos]
        if b == 0x0A:  # '\n'
            pos += 1
            break
        line.append(b)
        pos += 1
    # strip trailing '\r' if present
    if len(line) > 0 and line[len(line) - 1] == 0x0D:
        _ = line.pop()
    return _LineRead(line^, pos)


def _skip_crlf(raw: List[UInt8], pos: Int) -> Int:
    """Skip a trailing \\r\\n after chunk data, if present."""
    var p = pos
    var total = len(raw)
    if p < total and raw[p] == 0x0D:
        p += 1
    if p < total and raw[p] == 0x0A:
        p += 1
    return p


def _parse_hex(s: String) -> Optional[Int]:
    """Parse a hexadecimal string to Int, or None."""
    if s.byte_length() == 0:
        return None
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var v = 0
    for i in range(n):
        var b = sp[i]
        var d = _hex_digit(b)
        if d < 0:
            return None
        v = v * 16 + d
    return v


def _hex_digit(b: UInt8) -> Int:
    if b >= 0x30 and b <= 0x39:
        return Int(b - 0x30)
    if b >= 0x41 and b <= 0x46:
        return Int(b - 0x41 + 10)
    if b >= 0x61 and b <= 0x66:
        return Int(b - 0x61 + 10)
    return -1


def _bytes_to_string(bs: List[UInt8]) -> String:
    """Decode bytes to a String (lossy UTF-8)."""
    var span = Span[UInt8](ptr=bs.unsafe_ptr(), length=len(bs))
    return String(from_utf8_lossy=span)


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


def _parse_int_local(s: String) -> Optional[Int]:
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
