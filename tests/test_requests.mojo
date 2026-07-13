# Test suite for the pure-Mojo requests library.
#
# Covers: URL parsing, percent-encoding, request building, response parsing (Content-Length + chunked),
# headers (case-insensitivity), JSON parsing, and error handling.
#
# Run with: pixi run mojo tests/test_requests.mojo

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from requests._url import parse_url, url_encode, build_query_string, _find
from requests._http import build_request, parse_response
from requests._json import parse_json


def _contains(haystack: String, needle: String) -> Bool:
    return _find(haystack, needle) >= 0


# --- helpers ---


def _to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[i])
    return out^


# --- URL parsing ---


def test_parse_full_url() raises:
    var u = parse_url("http://example.com:8080/path/to?x=1&y=2#frag")
    assert_equal(u.scheme, "http")
    assert_equal(u.host, "example.com")
    assert_equal(u.port, 8080)
    assert_equal(u.path, "/path/to")
    assert_equal(u.query, "x=1&y=2")
    assert_equal(u.fragment, "frag")
    assert_equal(u.request_target(), "/path/to?x=1&y=2")
    assert_equal(u.origin(), "http://example.com:8080")
    assert_equal(u.host_header(), "example.com:8080")


def test_parse_default_port() raises:
    var u = parse_url("http://localhost/index.html")
    assert_equal(u.host, "localhost")
    assert_equal(u.port, 80)
    assert_equal(u.path, "/index.html")
    assert_equal(u.host_header(), "localhost")


def test_parse_rejects_https() raises:
    var raised = False
    try:
        _ = parse_url("https://example.com")
    except _:
        raised = True
    assert_true(raised, "https scheme should be rejected")


def test_parse_missing_scheme() raises:
    var raised = False
    try:
        _ = parse_url("example.com/path")
    except _:
        raised = True
    assert_true(raised, "missing scheme should be rejected")


# --- URL encoding ---


def test_url_encode_spaces_and_special() raises:
    assert_equal(url_encode("hello world"), "hello+world")
    assert_equal(url_encode("a&b=c"), "a%26b%3Dc")
    assert_equal(url_encode("plain123"), "plain123")


def test_build_query_string() raises:
    var params: Dict[String, String] = {"a": "1", "b": "two words"}
    var qs = build_query_string(params)
    assert_true(_contains(qs, "a=1"), "query should contain a=1")
    assert_true(_contains(qs, "b=two+words"), "query should encode b")


# --- Request building ---


def test_build_get_request() raises:
    var u = parse_url("http://example.com:9090/a?x=1")
    var headers: Dict[String, String] = {"User-Agent": "test/1.0"}
    var req = build_request("GET", u, headers, "")
    assert_true(_contains(req, "GET /a?x=1 HTTP/1.1"), "request line")
    assert_true(_contains(req, "Host: example.com:9090"), "host header")
    assert_true(_contains(req, "User-Agent: test/1.0"), "user-agent header")
    assert_true(_contains(req, "Connection: close"), "connection header")


def test_build_post_request_sets_content_length() raises:
    var u = parse_url("http://example.com/submit")
    var headers: Dict[String, String] = {}
    var req = build_request("POST", u, headers, "name=mojo")
    assert_true(_contains(req, "POST /submit HTTP/1.1"), "post request line")
    assert_true(_contains(req, "Content-Length: 9"), "content-length for body")


# --- Response parsing ---


def test_parse_response_content_length() raises:
    var raw = _to_bytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello")
    var pr = parse_response(raw)
    assert_equal(pr.status_code, 200)
    assert_equal(pr.reason, "OK")
    assert_equal(pr.headers["content-type"], "text/plain")
    assert_equal(Int(len(pr.body[])), 5)


def test_parse_response_chunked() raises:
    var raw = _to_bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n")
    var pr = parse_response(raw)
    assert_equal(pr.status_code, 200)
    assert_equal(Int(len(pr.body[])), 11)


def test_parse_response_404() raises:
    var raw = _to_bytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    var pr = parse_response(raw)
    assert_equal(pr.status_code, 404)
    assert_equal(pr.reason, "Not Found")


# --- JSON parsing ---


def test_json_object() raises:
    var j = parse_json("{\"name\":\"mojo\",\"ver\":1}")
    assert_equal(j["name"].as_string(), "mojo")
    assert_equal(j["ver"].as_int(), 1)


def test_json_array() raises:
    var j = parse_json("[1, 2, 3]")
    assert_equal(j.len(), 3)
    assert_equal(j[0].as_int(), 1)
    assert_equal(j[2].as_int(), 3)


def test_json_types() raises:
    assert_true(parse_json("true").as_bool())
    assert_false(parse_json("false").as_bool())
    assert_true(parse_json("null").is_null())


def test_json_nested() raises:
    var j = parse_json("{\"a\":[{\"b\":2}]}")
    assert_equal(j["a"][0]["b"].as_int(), 2)


# --- runner (auto-discovers all test_* functions in this module) ---


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
