# Test suite for connection pooling / keep-alive.
#
# Two kinds of tests:
#   1. Unit tests on the response-framing helpers in requests._pool — fully deterministic,
#      no network, always run.
#   2. Live tests that reuse a Session across requests and assert the connection pool behaves
#      (a self-delimiting response is pooled; the next request to the same endpoint reuses it,
#      so the pool count stays stable rather than growing).
#
# Live tests read BASE_URL / HTTPS_BASE_URL from the environment (set by tests/server.py and
# the CI workflow — the server runs HTTP/1.1 so keep-alive is available). When unset they fall
# back to example.com so a manual run still works.
#
# Run with: pixi run mojo -I . tests/test_keepalive.mojo

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.ffi import external_call
from requests.session import Session
from requests._pool import (
    KeptAliveConn,
    _find_crlf_crlf,
    _has_chunk_terminator,
    _header_content_length,
    _header_is_chunked,
    _header_conn_close,
    _parse_status,
)


# --- helpers ---


def _b(s: String) -> List[UInt8]:
    var o = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        o.append(p[i])
    return o^


def _getenv(name: String) -> String:
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
    return v if v.byte_length() > 0 else "http://example.com"


def _https_base() -> String:
    var v = _getenv("HTTPS_BASE_URL")
    return v if v.byte_length() > 0 else "https://example.com"


# --- unit tests: framing helpers ------------------------------------------------------------


def test_find_crlf_crlf() raises:
    assert_equal(
        _find_crlf_crlf(_b("A\r\n\r\nB")), 5
    )  # index just past terminator
    assert_equal(_find_crlf_crlf(_b("no terminator here")), -1)
    assert_equal(_find_crlf_crlf(_b("HTTP/1.1 200 OK\r\nX: y\r\n\r\nBODY")), 25)


def test_parse_status() raises:
    assert_equal(_parse_status("HTTP/1.1 200 OK\r\n\r\n"), 200)
    assert_equal(_parse_status("HTTP/1.1 204 No Content\r\n\r\n"), 204)
    assert_equal(_parse_status("HTTP/1.1 404 Not Found\r\n\r\n"), 404)
    assert_equal(_parse_status("garbage"), 0)


def test_header_content_length() raises:
    assert_equal(
        _header_content_length("HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n"),
        42,
    )
    # Case-insensitive header name.
    assert_equal(
        _header_content_length("HTTP/1.1 200 OK\r\ncontent-length: 7\r\n\r\n"),
        7,
    )
    # Absent → -1.
    assert_equal(_header_content_length("HTTP/1.1 200 OK\r\nX: y\r\n\r\n"), -1)


def test_header_is_chunked() raises:
    assert_true(
        _header_is_chunked(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        )
    )
    assert_false(
        _header_is_chunked("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n")
    )


def test_header_conn_close() raises:
    assert_true(
        _header_conn_close("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
    )
    assert_true(
        _header_conn_close("HTTP/1.1 200 OK\r\nConnection: Keep-Alive\r\n\r\n")
        == False
    )


def test_has_chunk_terminator() raises:
    # Complete chunked body ends with 0\r\n\r\n.
    assert_true(_has_chunk_terminator(_b("5\r\nhello\r\n0\r\n\r\n"), 0))
    # Empty chunked body.
    assert_true(_has_chunk_terminator(_b("0\r\n\r\n"), 0))
    # Incomplete — no terminating chunk yet.
    assert_false(_has_chunk_terminator(_b("5\r\nhello\r\n"), 0))
    # A literal '0' inside chunk data must not be mistaken for the terminator.
    assert_false(_has_chunk_terminator(_b("3\r\n0ab\r\n"), 0))


def test_kept_alive_conn_matches() raises:
    # Default conn is closed → never matches.
    var closed = KeptAliveConn()
    assert_false(closed.matches("http", "localhost", 80))
    # A live (fd only) conn matches its own endpoint, not others.
    var live = KeptAliveConn("http", "localhost", 80, -1, False, None, None)
    assert_true(live.matches("http", "localhost", 80))
    assert_false(live.matches("https", "localhost", 80))
    assert_false(live.matches("http", "localhost", 8080))
    assert_false(live.matches("http", "other", 80))
    live._disown()  # don't try to close fd -1 on drop


# --- live tests: real connection reuse ------------------------------------------------------


def test_http_keep_alive_reuses_connection() raises:
    var base = _http_base()
    with Session() as s:
        var r1 = s.get(base + "/hello.txt")
        assert_equal(r1.status_code, 200)
        var after1 = len(s._pool)
        # A keep-alive server leaves exactly one idle connection pooled.
        assert_true(after1 <= 1)

        var r2 = s.get(base + "/hello.txt")
        assert_equal(r2.status_code, 200)
        # Reuse must not grow the pool: same endpoint → same single connection.
        assert_equal(len(s._pool), after1)


def test_http_body_intact_over_keep_alive() raises:
    var base = _http_base()
    with Session() as s:
        # Two sequential reads of a known fixture — framed reads must return the exact body
        # each time (no bleed between responses on the reused socket).
        var r1 = s.get(base + "/hello.txt")
        var r2 = s.get(base + "/hello.txt")
        assert_equal(r1.text(), r2.text())


def test_session_close_drains_pool() raises:
    var base = _http_base()
    var s = Session()
    _ = s.get(base + "/hello.txt")
    s.close()
    assert_equal(len(s._pool), 0)
    # Idempotent.
    s.close()
    assert_equal(len(s._pool), 0)


def test_https_keep_alive_reuses_connection() raises:
    var base = _https_base()
    with Session() as s:
        var r1 = s.get(base + "/hello.txt")
        assert_equal(r1.status_code, 200)
        var after1 = len(s._pool)
        assert_true(after1 <= 1)
        var r2 = s.get(base + "/index.html")
        assert_equal(r2.status_code, 200)
        assert_equal(len(s._pool), after1)


def test_https_large_body_framed_read() raises:
    # large.bin is 65536 bytes with a Content-Length — exercises the framed read looping over
    # many recv()/SSL_read() calls and stopping exactly at the body end (so the socket stays
    # reusable rather than reading into the next response or blocking on EOF).
    var base = _https_base()
    with Session() as s:
        var r = s.get(base + "/large.bin")
        assert_equal(r.status_code, 200)
        assert_equal(r.text().byte_length(), 65536)
        assert_true(len(s._pool) <= 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
