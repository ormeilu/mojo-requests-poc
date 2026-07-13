# User-facing data models: Headers and Response.
#
# Headers is a case-insensitive view over response headers. Response wraps a parsed HTTP response and
# provides the requests-like API (status_code, text, content, headers, ok, json(), raise_for_status()).

from .exceptions import http_error
from ._http import _bytes_to_string
from ._json import parse_json


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

    def contains(self, key: String) -> Bool:
        return self._data.contains(_to_lower(key))

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
    """Helper exposing iteration over header entries (workaround for returning iterables)."""
    var _data: Dict[String, String]
    def __init__(out self, data: Dict[String, String]):
        self._data = data


struct Response(Movable, Writable):
    """An HTTP response — the return type of every request function.

    Fields: ``status_code``, ``headers``, ``content``, ``url``. Computed: ``text``, ``ok``, ``json()``.
    """
    var status_code: Int
    var reason: String
    var headers: Headers
    var content: List[UInt8]
    var url: String
    var encoding: String

    def __init__(out self):
        self.status_code = 0
        self.reason = ""
        self.headers = Headers()
        self.content = List[UInt8]()
        self.url = ""
        self.encoding = "utf-8"

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

    def ok(self) -> Bool:
        """True if status_code < 400."""
        return self.status_code < 400

    def text(self) -> String:
        """Decode the body to a String using ``encoding`` (lossy UTF-8)."""
        return _bytes_to_string(self.content)

    def json(self) raises -> JSONValue:
        """Parse the body as JSON. Raises request_exception on malformed JSON."""
        return parse_json(self.text())

    def raise_for_status(self) raises:
        """Raise http_error for 4xx/5xx responses; no-op otherwise."""
        if self.status_code >= 400:
            var msg = self.reason
            if msg.byte_length() == 0:
                msg = "HTTP error"
            raise http_error(msg, self.status_code)

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
