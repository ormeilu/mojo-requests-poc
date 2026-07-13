# Exception helpers for the pure-Mojo requests library.
#
# Mojo's `Error` is a builtin struct, not a trait user types can conform to. So we model
# exceptions as constructor functions that build an `Error` value carrying a recognizable, prefixed message.
# This mirrors the categories Python's `requests.exceptions` exposes (ConnectionError, Timeout, HTTPError, ...)
# while staying within Mojo's error model.
#
# Classify a caught `Error` with `exception_kind()` to recover the category.

from std.io import print


# Exception category tags. Values are matched against the message prefix produced by
# the constructors below. Keep these in sync with the constructors.
comptime CONNECTION_PREFIX = "ConnectionError"
comptime TIMEOUT_PREFIX = "Timeout"
comptime INVALID_URL_PREFIX = "InvalidURL"
comptime UNSUPPORTED_SCHEME_PREFIX = "UnsupportedScheme"
comptime HTTP_ERROR_PREFIX = "HTTPError"
comptime REQUEST_PREFIX = "RequestException"


# --- Constructors ---------------------------------------------------------
# Each returns a ready-to-raise `Error`. The prefix encodes the category.


def request_exception(msg: String) -> Error:
    """Generic requests error (base category)."""
    return Error(t"RequestException: {msg}")


def connection_error(msg: String) -> Error:
    """A connection-level error (refused, reset, DNS failure, etc.)."""
    return Error(t"ConnectionError: {msg}")


def timeout_error(msg: String) -> Error:
    """The request timed out."""
    return Error(t"Timeout: {msg}")


def invalid_url_error(msg: String) -> Error:
    """The URL was malformed or unsupported."""
    return Error(t"InvalidURL: {msg}")


def unsupported_scheme_error(msg: String) -> Error:
    """The URL scheme is not supported (only `http` is supported in v1)."""
    return Error(t"UnsupportedScheme: {msg}")


def http_error(msg: String, status_code: Int) -> Error:
    """An HTTP error response (e.g. 4xx/5xx from raise_for_status)."""
    return Error(t"HTTPError {status_code}: {msg}")


# --- Classification --------------------------------------------------------


def exception_kind(err: Error) -> String:
    """Classify a caught Error by the prefix one of the constructors wrote.

    Returns one of the category strings above (e.g. ``"ConnectionError"``).
    Falls back to ``"RequestException"`` for unrecognized messages.
    """
    var s = String(err)
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
    return REQUEST_PREFIX


def _starts_with(s: String, prefix: String) -> Bool:
    """True if `s` begins with `prefix` (compared byte-by-byte)."""
    if s.byte_length() < prefix.byte_length():
        return False
    var pl = prefix.byte_length()
    var p = prefix.unsafe_ptr()
    var sp = s.unsafe_ptr()
    for i in range(pl):
        if sp[i] != p[i]:
            return False
    return True
