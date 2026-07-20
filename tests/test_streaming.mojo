# Test suite for streaming responses (stream=True + iter_content).
#
# Covers: StreamingConn construction + read_chunk behavior on a synthetic buffer,
# the iter_content() API on a non-streaming Response, and live streaming against
# a real HTTP server.
#
# Live tests read BASE_URL / HTTPS_BASE_URL from the environment (set by the
# local test server tests/server.py and the CI workflow). When unset, they fall
# back to example.com so manual ``pixi run test-streaming`` still works without
# a local server.
#
# Run with: pixi run mojo -I . tests/test_streaming.mojo

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.memory import OwnedPointer
from std.ffi import c_int, OwnedDLHandle, external_call
from requests.session import Session
from requests.models import Response, Headers
from requests._streaming import StreamingConn


# --- helpers ---


def _bytes_from_string(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] (ASCII bytes)."""
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[i])
    return out^


def _byte(c: String) -> UInt8:
    """First byte of a 1-char ASCII string as UInt8."""
    return UInt8(c.unsafe_ptr()[0])


def _getenv(name: String) -> String:
    """Read an environment variable via libc getenv (returns "" if unset)."""
    var ptr = external_call["getenv", UnsafePointer[UInt8, MutUntrackedOrigin]](
        name.unsafe_ptr()
    )
    if Int(ptr) == 0:
        return ""
    var out = String()
    var i = 0
    while ptr[i] != 0:
        out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(ptr[i])))
        i += 1
    return out


def _http_base() -> String:
    var v = _getenv("BASE_URL")
    if v.byte_length() > 0:
        return v
    return "http://example.com"


def _https_base() -> String:
    var v = _getenv("HTTPS_BASE_URL")
    if v.byte_length() > 0:
        return v
    return "https://example.com"


def _contains(haystack: String, needle: String) -> Bool:
    if needle.byte_length() == 0:
        return True
    if haystack.byte_length() < needle.byte_length():
        return False
    var h = haystack.unsafe_ptr()
    var n = needle.unsafe_ptr()
    var hl = haystack.byte_length()
    var nl = needle.byte_length()
    for i in range(hl - nl + 1):
        var matched = True
        for j in range(nl):
            if h[i + j] != n[j]:
                matched = False
                break
        if matched:
            return True
    return False


# --- unit: StreamingConn drains a pre-buffered body, respecting Content-Length ---


def test_streaming_conn_drains_buffer() raises:
    # Pre-buffer 10 body bytes (no socket needed if Content-Length == buffer size).
    var buf = _bytes_from_string("hello12345")
    var no_libssl: Optional[OwnedPointer[OwnedDLHandle]] = None
    var no_ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    var conn = StreamingConn(c_int(-1), no_libssl^, no_ssl^, buf^, 10, False)
    var conn_ptr = OwnedPointer[StreamingConn](conn^)

    # First chunk: ask for 4 bytes -> get 4 ("hell").
    var c1 = conn_ptr[].read_chunk(4)
    assert_true(c1 != None)
    assert_equal(len(c1.value()), 4)
    assert_equal(c1.value()[0], _byte("h"))
    assert_equal(c1.value()[3], _byte("l"))

    # Second chunk: ask for 4 bytes -> get 4 ("o123").
    var c2 = conn_ptr[].read_chunk(4)
    assert_true(c2 != None)
    assert_equal(len(c2.value()), 4)
    assert_equal(c2.value()[0], _byte("o"))

    # Third chunk: ask for 4 bytes -> get only 2 left ("45").
    var c3 = conn_ptr[].read_chunk(4)
    assert_true(c3 != None)
    assert_equal(len(c3.value()), 2)
    assert_equal(c3.value()[0], _byte("4"))
    assert_equal(c3.value()[1], _byte("5"))

    # Fourth chunk: body complete -> None.
    var c4 = conn_ptr[].read_chunk(4)
    assert_true(c4 == None)


# --- unit: iter_content on a non-streaming Response returns content as one chunk ---


def test_iter_content_non_streaming() raises:
    var h = Headers()
    var body = _bytes_from_string("abc")
    var r = Response(200, "OK", h^, body^, "http://x/")
    assert_false(r.is_streaming())
    var chunks = r.iter_content(8)
    assert_equal(len(chunks), 1)
    assert_equal(len(chunks[0]), 3)
    assert_equal(chunks[0][0], _byte("a"))
    assert_equal(chunks[0][1], _byte("b"))
    assert_equal(chunks[0][2], _byte("c"))


# --- unit: a Response created with a StreamingConn reports is_streaming ---


def test_response_is_streaming_flag() raises:
    var buf = List[UInt8]()
    var no_libssl: Optional[OwnedPointer[OwnedDLHandle]] = None
    var no_ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    var conn = StreamingConn(c_int(-1), no_libssl^, no_ssl^, buf^, 0, False)
    var conn_ptr = OwnedPointer[StreamingConn](conn^)

    var h = Headers()
    var empty = List[UInt8]()
    var r = Response(200, "OK", h^, empty^, "http://x/", conn_ptr^)
    assert_true(r.is_streaming())


# --- live: stream a real HTTP response, verify chunked byte count + content ---


def test_live_stream_http() raises:
    var s = Session()
    var r = s.get(_http_base() + "/large.bin", stream=True)
    assert_equal(r.status_code, 200)
    assert_true(r.is_streaming())
    var total = 0
    var chunks_seen = 0
    for chunk in r.iter_content(64):
        chunks_seen += 1
        total += len(chunk)
    assert_true(total > 0, "streamed body should not be empty")
    assert_true(chunks_seen > 1, "should have received more than one chunk")


# --- live: stream a real HTTPS response ---


def test_live_stream_https() raises:
    var s = Session()
    var r = s.get(_https_base() + "/", stream=True)
    assert_equal(r.status_code, 200)
    assert_true(r.is_streaming())
    var total = 0
    for chunk in r.iter_content(128):
        total += len(chunk)
    assert_true(total > 0, "HTTPS streamed body should not be empty")


# --- live: text() drains a streaming response automatically ---


def test_live_stream_text_drains() raises:
    var s = Session()
    var r = s.get(_http_base() + "/large.bin", stream=True)
    assert_true(r.is_streaming())
    var txt = r.text()
    # After text() drains, the stream is consumed.
    assert_false(r.is_streaming())
    assert_true(txt.byte_length() > 0)


# --- runner ---


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
