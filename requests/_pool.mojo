# Connection pooling / keep-alive — a reusable live TCP/TLS connection.
#
# A `KeptAliveConn` owns a connected socket fd (and, for HTTPS, a libssl handle + SSL*), tagged
# with the endpoint it belongs to (scheme/host/port). Unlike the one-shot request path in
# `session._do_request` (which sends `Connection: close` and reads the body to EOF), a pooled
# connection sends `Connection: keep-alive` and reads *exactly* one framed response
# (Content-Length or chunked) so the socket stays usable for the next request to the same
# endpoint. This amortizes the TCP handshake and — for HTTPS — the far more expensive TLS
# handshake across requests in a `Session`.
#
# Ownership model mirrors `_streaming.StreamingConn`: Movable with a hand-written `__moveinit__`
# that neuters the source, plus `_disown()` / `close()` (see STRUGGLES.md §3.1). The live parts
# are stolen from a freshly-connected `TCPSocket` + `TLSConnection` via their existing
# `fd_value()` / `_steal_ssl()` / `_steal_libssl()` / `_disown()` helpers.

from std.ffi import external_call, OwnedDLHandle, c_int
from std.memory import OwnedPointer, alloc
from .exceptions import ConnectionError, SSLError

comptime CHUNK_SIZE = 8192


struct KeptAliveConn(Movable):
    """A live, reusable connection to one endpoint.

    - ``scheme`` / ``host`` / ``port``: the endpoint identity used to match a pooled connection
      to an outgoing request.
    - ``fd``: the raw socket file descriptor (owned; closed on close/__del__).
    - ``is_https``: True when the connection is wrapped in TLS.
    - ``libssl`` / ``ssl``: the libssl handle + SSL* (present iff HTTPS).
    - ``closed``: whether the connection has been torn down.
    """

    var scheme: String
    var host: String
    var port: Int
    var fd: c_int
    var is_https: Bool
    var libssl: Optional[OwnedPointer[OwnedDLHandle]]
    var ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]
    var closed: Bool

    def __init__(out self):
        """Default: an empty, already-closed placeholder (owns nothing)."""
        self.scheme = String()
        self.host = String()
        self.port = 0
        self.fd = c_int(-1)
        self.is_https = False
        self.libssl = None
        self.ssl = None
        self.closed = True

    def __init__(
        out self,
        scheme: String,
        host: String,
        port: Int,
        fd: c_int,
        is_https: Bool,
        var libssl: Optional[OwnedPointer[OwnedDLHandle]],
        var ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]],
    ):
        self.scheme = scheme
        self.host = host
        self.port = port
        self.fd = fd
        self.is_https = is_https
        self.libssl = libssl^
        self.ssl = ssl^
        self.closed = False

    def __moveinit__(out self, mut existing: Self):
        """Transfer ownership; neuter the source so its destructor doesn't double-close.
        """
        self.scheme = existing.scheme^
        self.host = existing.host^
        self.port = existing.port
        self.fd = existing.fd
        self.is_https = existing.is_https
        self.libssl = existing.libssl^
        self.ssl = existing.ssl^
        self.closed = existing.closed
        existing.closed = True
        existing.fd = c_int(-1)

    def __del__(deinit self):
        self.close()

    def matches(self, scheme: String, host: String, port: Int) -> Bool:
        """True if this idle connection serves the given endpoint."""
        return (
            not self.closed
            and self.scheme == scheme
            and self.host == host
            and self.port == port
        )

    def send_all(mut self, data: String) raises:
        """Send the full request over the connection (raw send for HTTP, SSL_write for HTTPS).
        """
        var ptr = data.unsafe_ptr()
        var remaining = data.byte_length()
        var offset = 0
        while remaining > 0:
            var sent: c_int
            if self.is_https:
                sent = self.libssl.value()[].call["SSL_write", c_int](
                    self.ssl.value(), ptr + offset, c_int(remaining)
                )
            else:
                sent = external_call["send", c_int](
                    self.fd, ptr + offset, c_int(remaining), c_int(0)
                )
            if sent <= c_int(0):
                raise ConnectionError("send failed on pooled connection")
            offset += Int(sent)
            remaining -= Int(sent)

    def _recv_once(
        mut self, buf: UnsafePointer[UInt8, MutUntrackedOrigin], max_bytes: Int
    ) raises -> c_int:
        """One recv()/SSL_read() call. Returns byte count, or <=0 on close/error.
        """
        if self.is_https:
            return self.libssl.value()[].call["SSL_read", c_int](
                self.ssl.value(), buf, c_int(max_bytes)
            )
        return external_call["recv", c_int](
            self.fd, buf, c_int(max_bytes), c_int(0)
        )

    def recv_framed(
        mut self, method: String, mut reusable: Bool
    ) raises -> List[UInt8]:
        """Read exactly one HTTP response and return the raw bytes (headers + framed body).

        Reads until the header terminator, parses the framing (Content-Length / chunked /
        Connection: close / status), then reads exactly the delimited body — so the socket is
        left positioned at the start of the next response and can be reused.

        Sets ``reusable`` to True iff the response is self-delimiting (Content-Length, chunked,
        or bodiless) AND the server did not send ``Connection: close``. When neither framing is
        present, falls back to read-to-EOF and marks the connection not reusable.

        Raises ``ConnectionError`` if the peer closes before any headers arrive (a stale pooled
        connection) so the caller can retry on a fresh socket.
        """
        reusable = False
        var raw = List[UInt8]()
        var buf = alloc[UInt8](CHUNK_SIZE)

        # Phase 1: read until the \r\n\r\n header terminator.
        var hdr_end = -1
        while hdr_end < 0:
            var n = self._recv_once(buf, CHUNK_SIZE)
            if n <= c_int(0):
                buf.free()
                if len(raw) == 0:
                    raise ConnectionError(
                        "pooled connection closed before response"
                    )
                # Partial headers then EOF — malformed; let the caller's parser reject it.
                return raw^
            for i in range(Int(n)):
                raw.append(buf[i])
            hdr_end = _find_crlf_crlf(raw)

        # Parse framing from the header block.
        var head = _bytes_to_str(raw, 0, hdr_end - 4)
        var status = _parse_status(head)
        var cl = _header_content_length(head)
        var chunked = _header_is_chunked(head)
        var conn_close = _header_conn_close(head)
        var bodiless = (
            method == "HEAD"
            or status == 204
            or status == 304
            or (status >= 100 and status < 200)
        )

        var body_have = len(raw) - hdr_end

        if bodiless:
            reusable = not conn_close
        elif cl >= 0:
            # Content-Length: read until we have exactly cl body bytes.
            while body_have < cl:
                var n = self._recv_once(buf, CHUNK_SIZE)
                if n <= c_int(0):
                    break
                for i in range(Int(n)):
                    raw.append(buf[i])
                body_have += Int(n)
            reusable = (not conn_close) and body_have >= cl
        elif chunked:
            # Chunked: read until the terminating 0-size chunk (…\r\n0\r\n\r\n).
            while not _has_chunk_terminator(raw, hdr_end):
                var n = self._recv_once(buf, CHUNK_SIZE)
                if n <= c_int(0):
                    break
                for i in range(Int(n)):
                    raw.append(buf[i])
            reusable = (not conn_close) and _has_chunk_terminator(raw, hdr_end)
        else:
            # No framing → body delimited by connection close. Read to EOF; not reusable.
            while True:
                var n = self._recv_once(buf, CHUNK_SIZE)
                if n <= c_int(0):
                    break
                for i in range(Int(n)):
                    raw.append(buf[i])
            reusable = False

        buf.free()
        return raw^

    def _disown(mut self):
        """Mark as not owning its fd/ssl (so __del__/close won't touch them)."""
        self.closed = True
        self.fd = c_int(-1)
        self.ssl = None

    def close(mut self):
        if self.closed:
            return
        self.closed = True
        if self.is_https and self.libssl != None and self.ssl != None:
            _ = self.libssl.value()[].call["SSL_shutdown", c_int](
                self.ssl.value()
            )
            _ = self.libssl.value()[].call["SSL_free", c_int](self.ssl.value())
            self.ssl = None
        if self.fd >= c_int(0):
            _ = external_call["close", c_int](self.fd)
            self.fd = c_int(-1)


# --- byte / header scanning helpers ---------------------------------------------------------


def _find_crlf_crlf(raw: List[UInt8]) -> Int:
    """Index of the first byte AFTER a ``\\r\\n\\r\\n`` terminator in ``raw``, or -1.
    """
    var n = len(raw)
    if n < 4:
        return -1
    for i in range(n - 3):
        if (
            raw[i] == 0x0D
            and raw[i + 1] == 0x0A
            and raw[i + 2] == 0x0D
            and raw[i + 3] == 0x0A
        ):
            return i + 4
    return -1


def _has_chunk_terminator(raw: List[UInt8], body_start: Int) -> Bool:
    """True if the chunked body (from ``body_start``) contains the terminating ``0\\r\\n\\r\\n``.

    Accepts both ``\\r\\n0\\r\\n\\r\\n`` (a normal final chunk) and a body that opens directly
    with ``0\\r\\n\\r\\n`` (empty chunked body).
    """
    var n = len(raw)
    # Need at least "0\r\n\r\n" (5 bytes) in the body region.
    var start = body_start
    if start < 0:
        start = 0
    for i in range(start, n - 4):
        if (
            raw[i] == 0x30
            and raw[i + 1] == 0x0D
            and raw[i + 2] == 0x0A
            and raw[i + 3] == 0x0D
            and raw[i + 4] == 0x0A
        ):
            # Ensure this "0" starts a chunk-size line: it's at body_start, or preceded by \r\n.
            if i == start or (raw[i - 1] == 0x0A and raw[i - 2] == 0x0D):
                return True
    return False


def _bytes_to_str(raw: List[UInt8], start: Int, end: Int) -> String:
    """Lossy-UTF8 decode ``raw[start:end]`` into a String."""
    var slice = List[UInt8]()
    var lo = start
    if lo < 0:
        lo = 0
    var hi = end
    if hi > len(raw):
        hi = len(raw)
    for i in range(lo, hi):
        slice.append(raw[i])
    var span = Span[UInt8](ptr=slice.unsafe_ptr(), length=len(slice))
    return String(from_utf8_lossy=span)


def _to_lower(s: String) -> String:
    var out = String()
    for cp in s.codepoints():
        var i = Int(cp)
        if i >= 65 and i <= 90:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i + 32)))
        else:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
    return out


def _parse_status(head: String) -> Int:
    """Extract the numeric status code from the status line ("HTTP/1.1 200 OK" -> 200).
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


def _header_value(head: String, name_lower: String) -> Optional[String]:
    """Return the value of header ``name_lower`` (case-insensitive), or None."""
    var lines = head.split("\r\n")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = _find(line, ":")
        if colon <= 0:
            continue
        var key = _to_lower(_strip(String(line[byte=0:colon])))
        if key == name_lower:
            return _strip(String(line[byte = colon + 1 : line.byte_length()]))
    return None


def _header_content_length(head: String) -> Int:
    """Content-Length as Int, or -1 if absent/malformed."""
    var v = _header_value(head, "content-length")
    if v == None:
        return -1
    var s = v.value()
    var sp = s.unsafe_ptr()
    var val = 0
    var seen = False
    for i in range(s.byte_length()):
        var b = sp[i]
        if b < 0x30 or b > 0x39:
            return -1 if not seen else val
        val = val * 10 + Int(b - 0x30)
        seen = True
    return val if seen else -1


def _header_is_chunked(head: String) -> Bool:
    var v = _header_value(head, "transfer-encoding")
    if v == None:
        return False
    return _find(_to_lower(v.value()), "chunked") >= 0


def _header_conn_close(head: String) -> Bool:
    var v = _header_value(head, "connection")
    if v == None:
        return False
    return _find(_to_lower(v.value()), "close") >= 0


def _strip(s: String) -> String:
    """Trim leading/trailing ASCII spaces and tabs."""
    var n = s.byte_length()
    var sp = s.unsafe_ptr()
    var lo = 0
    while lo < n and (sp[lo] == 0x20 or sp[lo] == 0x09):
        lo += 1
    var hi = n
    while hi > lo and (sp[hi - 1] == 0x20 or sp[hi - 1] == 0x09):
        hi -= 1
    return String(s[byte=lo:hi])


def _find(haystack: String, needle: String) -> Int:
    """Byte index of the first occurrence of ``needle``, or -1."""
    var hl = haystack.byte_length()
    var nl = needle.byte_length()
    if nl == 0 or hl < nl:
        return -1
    var hp = haystack.unsafe_ptr()
    var np = needle.unsafe_ptr()
    for i in range(hl - nl + 1):
        var matched = True
        for j in range(nl):
            if hp[i + j] != np[j]:
                matched = False
                break
        if matched:
            return i
    return -1
