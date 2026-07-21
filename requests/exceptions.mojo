# Typed exceptions for the pure-Mojo requests library.
#
# Each exception category is a `@Movable, Writable` struct that can be raised directly
# (`raise ConnectionError("refused", host=...)`) and renders a stable, prefixed message via
# `write_to`. The categories mirror Python's `requests.exceptions`.
#
# ## Leaf functions are typed; orchestration is bare `raises`
#
# Leaf functions that raise a single category carry a typed `raises` clause — e.g.
# `_dns.resolve` is `raises ConnectionError`, `TLSConnection.connect` is `raises SSLError`,
# `Response.raise_for_status` is `raises HTTPError`. Callers in the same typed context can
# pattern-match on the concrete struct.
#
# The Session orchestration layer (`_do_request`, `request`, `get`/`post`/...) fans out to
# several disjoint error types, and Mojo 1.0 has no multi-type `raises` union
# (`raises A | B` / `raises A, B` / `raises [A, B]` all fail to parse). Those functions stay
# bare `raises` and propagate the concrete struct value up via `raise e^` — the struct's type
# is preserved through the `Error` wrapper and renders via `write_to`, but its fields cannot
# be recovered by the catcher (a caught `Error` exposes no runtime type-recovery API).
#
# ## Classification stays string-prefix-based
#
# Because a caught `Error` cannot be introspected back to its concrete struct, runtime
# dispatch is done by parsing the rendered message prefix via `exception_kind()`. The prefix
# each `write_to` emits is pinned by the `comptime *_PREFIX` constants below so the classifier
# and the structs never drift.


# Prefix each struct's write_to emits. Keep in sync with the write_to implementations.
comptime REQUEST_PREFIX = "RequestException"
comptime CONNECTION_PREFIX = "ConnectionError"
comptime TIMEOUT_PREFIX = "Timeout"
comptime INVALID_URL_PREFIX = "InvalidURL"
comptime UNSUPPORTED_SCHEME_PREFIX = "UnsupportedScheme"
comptime HTTP_ERROR_PREFIX = "HTTPError"
comptime SSL_PREFIX = "SSLError"
comptime CONNECT_TIMEOUT_PREFIX = "ConnectTimeout"
comptime READ_TIMEOUT_PREFIX = "ReadTimeout"
comptime JSON_DECODE_PREFIX = "JSONDecodeError"
comptime TOO_MANY_REDIRECTS_PREFIX = "TooManyRedirects"
comptime URL_REQUIRED_PREFIX = "URLRequired"
comptime PROXY_PREFIX = "ProxyError"


# --- Structs --------------------------------------------------------------


struct RequestException(Movable, Writable):
    """Base / generic requests error (no more specific category applies)."""

    var msg: String

    def __init__(out self, msg: String):
        self.msg = msg

    def write_to(self, mut writer: Some[Writer]):
        writer.write(REQUEST_PREFIX, ": ", self.msg)


struct ConnectionError(Movable, Writable):
    """A connection-level error (refused, reset, DNS failure, etc.).

    ``host`` is optional context (the peer hostname being contacted); it is folded into the
    rendered message only when set, so the prefix stays stable for classification.
    """

    var msg: String
    var host: String

    def __init__(out self, msg: String, *, host: String = ""):
        self.msg = msg
        self.host = host

    def write_to(self, mut writer: Some[Writer]):
        if self.host.byte_length() > 0:
            writer.write(
                CONNECTION_PREFIX, ": ", self.msg, " (host=", self.host, ")"
            )
        else:
            writer.write(CONNECTION_PREFIX, ": ", self.msg)


struct Timeout(Movable, Writable):
    """The request timed out (SO_RCVTIMEO/SO_SNDTIMEO expired on a socket with a timeout set).
    """

    var msg: String
    var host: String

    def __init__(out self, msg: String, *, host: String = ""):
        self.msg = msg
        self.host = host

    def write_to(self, mut writer: Some[Writer]):
        if self.host.byte_length() > 0:
            writer.write(
                TIMEOUT_PREFIX, ": ", self.msg, " (host=", self.host, ")"
            )
        else:
            writer.write(TIMEOUT_PREFIX, ": ", self.msg)


struct InvalidURL(Movable, Writable):
    """The URL was malformed (missing scheme, missing host, bad port)."""

    var msg: String

    def __init__(out self, msg: String):
        self.msg = msg

    def write_to(self, mut writer: Some[Writer]):
        writer.write(INVALID_URL_PREFIX, ": ", self.msg)


struct UnsupportedScheme(Movable, Writable):
    """The URL scheme is not supported (only ``http`` and ``https`` are)."""

    var msg: String
    var scheme: String

    def __init__(out self, msg: String, *, scheme: String = ""):
        self.msg = msg
        self.scheme = scheme

    def write_to(self, mut writer: Some[Writer]):
        writer.write(UNSUPPORTED_SCHEME_PREFIX, ": ", self.msg)


struct HTTPError(Movable, Writable):
    """An HTTP error response (e.g. 4xx/5xx from ``raise_for_status``).

    ``status_code`` renders into the prefix line (``HTTPError 404: ...``) so it is recoverable
    by string-scanning for callers that catch the bare ``Error`` from ``raise_for_status``.
    """

    var msg: String
    var status_code: Int

    def __init__(out self, msg: String, *, status_code: Int = 0):
        self.msg = msg
        self.status_code = status_code

    def write_to(self, mut writer: Some[Writer]):
        writer.write(HTTP_ERROR_PREFIX, " ", self.status_code, ": ", self.msg)


struct SSLError(Movable, Writable):
    """A TLS/SSL error (handshake failure, certificate validation, missing libssl, etc.).
    """

    var msg: String
    var hostname: String

    def __init__(out self, msg: String, *, hostname: String = ""):
        self.msg = msg
        self.hostname = hostname

    def write_to(self, mut writer: Some[Writer]):
        if self.hostname.byte_length() > 0:
            writer.write(
                SSL_PREFIX, ": ", self.msg, " (hostname=", self.hostname, ")"
            )
        else:
            writer.write(SSL_PREFIX, ": ", self.msg)


struct ConnectTimeout(Movable, Writable):
    """The request timed out while establishing the connection (connect phase).

    Mirrors Python's ``requests.ConnectTimeout`` (a ConnectionError + Timeout).
    """

    var msg: String
    var host: String

    def __init__(out self, msg: String, *, host: String = ""):
        self.msg = msg
        self.host = host

    def write_to(self, mut writer: Some[Writer]):
        if self.host.byte_length() > 0:
            writer.write(
                CONNECT_TIMEOUT_PREFIX,
                ": ",
                self.msg,
                " (host=",
                self.host,
                ")",
            )
        else:
            writer.write(CONNECT_TIMEOUT_PREFIX, ": ", self.msg)


struct ReadTimeout(Movable, Writable):
    """The server did not send any data in the allotted time (read phase).

    Mirrors Python's ``requests.ReadTimeout``.
    """

    var msg: String
    var host: String

    def __init__(out self, msg: String, *, host: String = ""):
        self.msg = msg
        self.host = host

    def write_to(self, mut writer: Some[Writer]):
        if self.host.byte_length() > 0:
            writer.write(
                READ_TIMEOUT_PREFIX, ": ", self.msg, " (host=", self.host, ")"
            )
        else:
            writer.write(READ_TIMEOUT_PREFIX, ": ", self.msg)


struct JSONDecodeError(Movable, Writable):
    """The response body could not be parsed as JSON.

    Mirrors Python's ``requests.JSONDecodeError`` (raised by ``Response.json()``).
    """

    var msg: String

    def __init__(out self, msg: String):
        self.msg = msg

    def write_to(self, mut writer: Some[Writer]):
        writer.write(JSON_DECODE_PREFIX, ": ", self.msg)


struct TooManyRedirects(Movable, Writable):
    """The configured redirect limit was exceeded.

    Mirrors Python's ``requests.TooManyRedirects``.
    """

    var msg: String

    def __init__(out self, msg: String):
        self.msg = msg

    def write_to(self, mut writer: Some[Writer]):
        writer.write(TOO_MANY_REDIRECTS_PREFIX, ": ", self.msg)


struct URLRequired(Movable, Writable):
    """A valid URL is required to make a request (none was supplied).

    Mirrors Python's ``requests.URLRequired``.
    """

    var msg: String

    def __init__(out self, msg: String):
        self.msg = msg

    def write_to(self, mut writer: Some[Writer]):
        writer.write(URL_REQUIRED_PREFIX, ": ", self.msg)


struct ProxyError(Movable, Writable):
    """A proxy-level error (bad proxy URL, CONNECT tunnel refused, unsupported proxy scheme).

    Mirrors Python's ``requests.exceptions.ProxyError``. ``host`` is the *target* host being
    tunneled to (optional context), folded into the message only when set so the prefix stays
    stable for classification.
    """

    var msg: String
    var host: String

    def __init__(out self, msg: String, *, host: String = ""):
        self.msg = msg
        self.host = host

    def write_to(self, mut writer: Some[Writer]):
        if self.host.byte_length() > 0:
            writer.write(
                PROXY_PREFIX, ": ", self.msg, " (host=", self.host, ")"
            )
        else:
            writer.write(PROXY_PREFIX, ": ", self.msg)


# --- Classification --------------------------------------------------------


def exception_kind(err: Error) -> String:
    """Classify a caught ``Error`` by the prefix one of the exception structs renders.

    Returns one of the category strings above (e.g. ``"ConnectionError"``).
    Falls back to ``"RequestException"`` for unrecognized messages.

    This is string-prefix-based because a caught ``Error`` in Mojo 1.0 cannot be introspected
    back to the concrete struct that was raised — ``write_to`` is the only signal that survives
    a bare-``raises`` propagation boundary. See the module docstring for details.
    """
    var s = String(err)
    # Check the more specific compound prefixes before their broader relatives
    # (e.g. ConnectTimeout before ConnectionError/Timeout).
    if _starts_with(s, CONNECT_TIMEOUT_PREFIX):
        return CONNECT_TIMEOUT_PREFIX
    if _starts_with(s, READ_TIMEOUT_PREFIX):
        return READ_TIMEOUT_PREFIX
    if _starts_with(s, JSON_DECODE_PREFIX):
        return JSON_DECODE_PREFIX
    if _starts_with(s, TOO_MANY_REDIRECTS_PREFIX):
        return TOO_MANY_REDIRECTS_PREFIX
    if _starts_with(s, URL_REQUIRED_PREFIX):
        return URL_REQUIRED_PREFIX
    if _starts_with(s, PROXY_PREFIX):
        return PROXY_PREFIX
    if _starts_with(s, CONNECTION_PREFIX):
        return CONNECTION_PREFIX
    if _starts_with(s, TIMEOUT_PREFIX):
        return TIMEOUT_PREFIX
    if _starts_with(s, INVALID_URL_PREFIX):
        return INVALID_URL_PREFIX
    if _starts_with(s, UNSUPPORTED_SCHEME_PREFIX):
        return UNSUPPORTED_SCHEME_PREFIX
    if _starts_with(s, HTTP_ERROR_PREFIX):
        return HTTP_ERROR_PREFIX
    if _starts_with(s, SSL_PREFIX):
        return SSL_PREFIX
    return REQUEST_PREFIX


def _starts_with(s: String, prefix: String) -> Bool:
    """True if ``s`` begins with ``prefix`` (compared byte-by-byte)."""
    if s.byte_length() < prefix.byte_length():
        return False
    var pl = prefix.byte_length()
    var p = prefix.unsafe_ptr()
    var sp = s.unsafe_ptr()
    for i in range(pl):
        if sp[i] != p[i]:
            return False
    return True
