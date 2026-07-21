# User-facing data models: Headers and Response.
#
# Headers is a case-insensitive view over response headers. Response wraps a parsed HTTP response and
# provides the requests-like API (status_code, text, content, headers, ok, json(), raise_for_status()).

from .exceptions import HTTPError
from ._http import _bytes_to_string
from ._json import parse_json
from ._streaming import StreamingConn
from std.memory import OwnedPointer


struct Headers(Movable):
    """Case-insensitive, read-only view over HTTP headers.

    Keys are stored lowercased; lookups are case-insensitive. ``get`` returns a default if absent.
    """

    var _data: Dict[String, String]

    def __init__(out self):
        self._data = {}

    def __init__(out self, data: Dict[String, String]):
        self._data = {}
        for entry in data.items():
            self._data[_to_lower(entry.key)] = entry.value

    def __getitem__(self, key: String) raises -> String:
        return self._data[_to_lower(key)]

    def get(self, key: String, default: String) -> String:
        return self._data.get(_to_lower(key), default)

    def contains(self, key: String) raises -> Bool:
        var lowered = _to_lower(key)
        for k in self._data:
            if k == lowered:
                return True
        return False

    def items(self) -> _ItemsRef:
        return _ItemsRef(self._data)

    def write_to(self, mut writer: Some[Writer]):
        writer.write("Headers({")
        var first = True
        for entry in self._data.items():
            if not first:
                writer.write(", ")
            writer.write(entry.key, ": ", entry.value)
            first = False
        writer.write("})")


struct _ItemsRef:
    """Helper exposing iteration over header entries (workaround for returning iterables).
    """

    var _data: Dict[String, String]

    def __init__(out self, data: Dict[String, String]):
        self._data = data


struct Response(Movable, Writable):
    """An HTTP response — the return type of every request function.

    Fields: ``status_code``, ``headers``, ``content``, ``url``. Computed: ``text``, ``ok``, ``json()``.
    When created with ``stream=True``, carries a live connection for incremental body reads.
    """

    var status_code: Int
    var reason: String
    var headers: Headers
    var content: List[UInt8]
    var url: String
    var encoding: String
    var _stream_conn: Optional[OwnedPointer[StreamingConn]]

    def __init__(out self):
        self.status_code = 0
        self.reason = ""
        self.headers = Headers()
        self.content = List[UInt8]()
        self.url = ""
        self.encoding = "utf-8"
        self._stream_conn = None

    def __init__(
        out self,
        status_code: Int,
        reason: String,
        var headers: Headers,
        var content: List[UInt8],
        url: String,
    ):
        self.status_code = status_code
        self.reason = reason
        self.headers = headers^
        self.content = content^
        self.url = url
        self.encoding = "utf-8"
        self._stream_conn = None

    def __init__(
        out self,
        status_code: Int,
        reason: String,
        var headers: Headers,
        var content: List[UInt8],
        url: String,
        var stream_conn: OwnedPointer[StreamingConn],
    ):
        self.status_code = status_code
        self.reason = reason
        self.headers = headers^
        self.content = content^
        self.url = url
        self.encoding = "utf-8"
        self._stream_conn = stream_conn^

    def ok(self) -> Bool:
        """True if status_code < 400."""
        return self.status_code < 400

    def is_streaming(self) -> Bool:
        """True if this Response was created with stream=True (body not yet read).
        """
        return self._stream_conn != None

    def iter_content(
        mut self, chunk_size: Int = 512
    ) raises -> List[List[UInt8]]:
        """Iterate body chunks. Only valid for streaming responses (stream=True).

        Returns a List of byte chunks. Drains the stream; calling twice returns an empty list.
        For non-streaming responses, returns the full content as a single chunk.
        """
        if self._stream_conn == None:
            var single: List[List[UInt8]] = []
            var copy = List[UInt8]()
            for b in self.content:
                copy.append(b)
            single.append(copy^)
            return single^
        var chunks: List[List[UInt8]] = []
        while True:
            var chunk_opt = self._stream_conn.value()[].read_chunk(chunk_size)
            if chunk_opt == None:
                break
            # Copy bytes out of the borrowed Optional value (can't move out of .value() directly).
            var chunk_copy = List[UInt8]()
            for b in chunk_opt.value():
                chunk_copy.append(b)
            chunks.append(chunk_copy^)
        # Stream drained; drop the connection.
        self._stream_conn = None
        return chunks^

    def iter_lines(mut self) raises -> List[String]:
        """Split the body into lines (newline-delimited), like requests' iter_lines.

        Drains the stream if streaming. Line terminators (``\\r``/``\\n``) are stripped.
        A trailing empty line (body ending in a newline) is omitted.
        """
        var body = self.text()
        var lines: List[String] = []
        var cur = String()
        for cp in body.codepoints():
            var i = Int(cp)
            if i == 10:  # \n — end of line
                lines.append(cur)
                cur = String()
            elif i == 13:  # \r — skip (part of \r\n framing)
                continue
            else:
                cur += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
        if cur.byte_length() > 0:
            lines.append(cur)
        return lines^

    def is_redirect(self) raises -> Bool:
        """True if the response is a redirect that carries a ``Location`` header.
        """
        if not self.headers.contains("location"):
            return False
        var s = self.status_code
        return s == 301 or s == 302 or s == 303 or s == 307 or s == 308

    def is_permanent_redirect(self) raises -> Bool:
        """True if the response is a permanent redirect (301 or 308) with a
        ``Location`` header."""
        if not self.headers.contains("location"):
            return False
        return self.status_code == 301 or self.status_code == 308

    def links(self) raises -> Dict[String, String]:
        """Parse the ``Link`` header into a ``rel -> url`` map (like ``r.links``).

        Example ``Link`` value::

            <https://api/next>; rel="next", <https://api/last>; rel="last"

        Returns an empty Dict when no ``Link`` header is present.
        """
        var result: Dict[String, String] = {}
        var raw = self.headers.get("link", "")
        if raw.byte_length() == 0:
            return result^
        # Split on commas that separate link entries.
        for entry in raw.split(","):
            var url = String()
            var rel = String()
            for part in entry.split(";"):
                var seg = String(part.strip())
                if seg.startswith("<") and seg.endswith(">"):
                    url = String(seg[byte = 1 : seg.byte_length() - 1])
                elif seg.startswith("rel="):
                    var val = String(seg[byte = 4 : seg.byte_length()])
                    if val.startswith('"') and val.endswith('"'):
                        val = String(val[byte = 1 : val.byte_length() - 1])
                    rel = val
            if rel.byte_length() > 0 and url.byte_length() > 0:
                result[rel] = url
        return result^

    def close(mut self):
        """Release the underlying connection for a streaming response (no-op otherwise).
        """
        self._stream_conn = None

    def _drain_stream(mut self) raises:
        """Read the entire streaming body into self.content (used by text()/content access).
        """
        if self._stream_conn == None:
            return
        while True:
            var chunk = self._stream_conn.value()[].read_chunk(8192)
            if chunk == None:
                break
            for b in chunk.value():
                self.content.append(b)
        self._stream_conn = None

    def text(mut self) raises -> String:
        """Decode the body to a String using ``encoding`` (lossy UTF-8). Drains stream if streaming.
        """
        if self._stream_conn != None:
            self._drain_stream()
        return _bytes_to_string(self.content)

    def json(mut self) raises -> JSONValue:
        """Parse the body as JSON. Raises RequestException on malformed JSON."""
        return parse_json(self.text())

    def raise_for_status(self) raises HTTPError:
        """Raise HTTPError for 4xx/5xx responses; no-op otherwise."""
        if self.status_code >= 400:
            var msg = self.reason
            if msg.byte_length() == 0:
                msg = "HTTP error"
            raise HTTPError(msg, status_code=self.status_code)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "<Response [",
            self.status_code,
            " ",
            self.reason,
            "]>",
        )


# --- helpers (ASCII lowercase, duplicated locally to avoid import cycles) ---


def _to_lower(s: String) -> String:
    var out = String()
    for cp in s.codepoints():
        var i = Int(cp)
        if i >= 65 and i <= 90:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i + 32)))
        else:
            out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(i)))
    return out


# JSONValue is defined in _json; re-exposed here so `from .models import JSONValue` works.
from ._json import JSONValue
