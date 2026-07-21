# Test suite for the pure-Mojo requests library.
#
# Covers: URL parsing, percent-encoding, request building, response parsing (Content-Length + chunked),
# headers (case-insensitivity), JSON parsing, and error handling.
#
# Run with: pixi run mojo tests/test_requests.mojo

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from requests._url import parse_url, url_encode, build_query_string, _find
from requests._dns import resolve
from requests._http import build_request, parse_response
from requests._json import parse_json
from requests.exceptions import exception_kind
from requests.models import Response, Headers


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


def test_parse_accepts_https() raises:
    var u = parse_url("https://example.com/path")
    assert_equal(u.scheme, "https")
    assert_equal(u.port, 443)
    assert_equal(u.host_header(), "example.com")
    assert_equal(u.origin(), "https://example.com")


def test_parse_rejects_ftp_scheme() raises:
    var raised = False
    try:
        _ = parse_url("ftp://example.com")
    except _:
        raised = True
    assert_true(raised, "ftp scheme should be rejected")


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


# --- IPv6 literal URL parsing ---
#
# RFC 3986: an IPv6 literal in a URL authority is wrapped in brackets — http://[::1]:8080/ —
# because IPv6 literals contain ':' which would otherwise collide with the port separator. We
# store the host WITHOUT brackets (bare "::1", used directly for DNS/connect), and host_header()
# / origin() re-add the brackets per RFC 7230 §5.5.


def test_parse_ipv6_literal_with_port() raises:
    var u = parse_url("http://[::1]:8080/path")
    assert_equal(u.host, "::1")
    assert_equal(u.port, 8080)
    assert_equal(u.path, "/path")
    assert_true(u.is_ipv6_literal(), "::1 should be an IPv6 literal")
    assert_equal(u.host_header(), "[::1]:8080")
    assert_equal(u.origin(), "http://[::1]:8080")


def test_parse_ipv6_literal_default_port() raises:
    var u = parse_url("http://[::1]/")
    assert_equal(u.host, "::1")
    assert_equal(u.port, 80)
    assert_equal(u.host_header(), "[::1]")
    assert_equal(u.origin(), "http://[::1]")


def test_parse_ipv6_literal_https() raises:
    var u = parse_url("https://[2001:db8::1]/x")
    assert_equal(u.host, "2001:db8::1")
    assert_equal(u.port, 443)
    assert_equal(u.host_header(), "[2001:db8::1]")
    assert_equal(u.origin(), "https://[2001:db8::1]")


def test_parse_ipv6_literal_unterminated_rejected() raises:
    var raised = False
    try:
        _ = parse_url("http://[::1/path")
    except _:
        raised = True
    assert_true(raised, "unterminated '[' should be rejected")


def test_parse_ipv6_literal_garbage_after_bracket_rejected() raises:
    var raised = False
    try:
        _ = parse_url("http://[::1]x/path")
    except _:
        raised = True
    assert_true(raised, "garbage after ']' should be rejected")


def test_parse_ipv4_literal_not_treated_as_ipv6() raises:
    # Regression guard: IPv4 literals / hostnames don't trigger the IPv6 bracket path.
    var u = parse_url("http://127.0.0.1:9090/p")
    assert_equal(u.host, "127.0.0.1")
    assert_false(u.is_ipv6_literal(), "127.0.0.1 is not an IPv6 literal")
    assert_equal(u.host_header(), "127.0.0.1:9090")


def test_build_get_request_ipv6_host_brackets_host_header() raises:
    var u = parse_url("http://[::1]:9090/a?x=1")
    var headers: Dict[String, String] = {"User-Agent": "test/1.0"}
    var req = build_request("GET", u, headers, "")
    assert_true(_contains(req, "GET /a?x=1 HTTP/1.1"), "request line")
    assert_true(
        _contains(req, "Host: [::1]:9090"), "bracketed IPv6 host header"
    )


# --- DNS resolver: IPv4 / IPv6 literal detection (no network) ---
#
# `resolve("::1")` is a literal probe (AI_NUMERICHOST) — no DNS round-trip, no network needed,
# so it's safe to exercise unconditionally in CI. `resolve("127.0.0.1")` goes through the
# inet_pton(AF_INET) fast path. Both assert the family their callers will dispatch on.


def test_resolve_ipv4_literal() raises:
    var a = resolve("127.0.0.1")
    assert_true(a.is_ipv4(), "127.0.0.1 should resolve as IPv4")
    assert_false(a.is_ipv6(), "127.0.0.1 should not be IPv6")


def test_resolve_ipv6_loopback_literal() raises:
    var a = resolve("::1")
    assert_true(a.is_ipv6(), "'::1' should resolve as IPv6")
    assert_false(a.is_ipv4(), "'::1' should not be IPv4")


def test_resolve_ipv6_full_literal() raises:
    var a = resolve("2001:db8::1")
    assert_true(a.is_ipv6(), "'2001:db8::1' should resolve as IPv6")


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
    var raw = _to_bytes(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length:"
        " 5\r\n\r\nhello"
    )
    var pr = parse_response(raw)
    assert_equal(pr.status_code, 200)
    assert_equal(pr.reason, "OK")
    assert_equal(pr.headers["content-type"], "text/plain")
    assert_equal(Int(len(pr.body[])), 5)


def test_parse_response_chunked() raises:
    var raw = _to_bytes(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding:"
        " chunked\r\n\r\n5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"
    )
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
    var j = parse_json('{"name":"mojo","ver":1}')
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
    var j = parse_json('{"a":[{"b":2}]}')
    assert_equal(j["a"][0]["b"].as_int(), 2)


# --- typed-exception classification ---
#
# These exercise the new typed-Error-struct model at the leaf functions: each typed leaf
# raises a concrete struct (InvalidURL / UnsupportedScheme / HTTPError / RequestException)
# that propagates through bare-`raises` callers and is recoverable only via exception_kind()
# on the caught Error's rendered message (Mojo 1.0 has no runtime type recovery on caught
# Error — see requests/exceptions.mojo docstring).


def _classify_parse_error(url: String) raises -> String:
    """Run parse_url (which raises InvalidURL / UnsupportedScheme) and classify the caught error.
    """
    try:
        _ = parse_url(url)
        return ""  # unreachable — url is malformed
    except e:
        return exception_kind(e)


def _classify_json_error(doc: String) raises -> String:
    try:
        _ = parse_json(doc)
        return ""  # unreachable — doc is malformed
    except e:
        return exception_kind(e)


def _classify_raise_for_status(status_code: Int) raises -> String:
    # Build a minimal Response with the given status code and call raise_for_status.
    var r = Response(status_code, "Bad", Headers(), List[UInt8](), "http://x/")
    try:
        r.raise_for_status()
        return "none"
    except e:
        return exception_kind(e)


def test_parse_ftp_scheme_classifies_unsupported() raises:
    # UnsupportedScheme is a typed leaf in parse_url.
    assert_equal(
        _classify_parse_error("ftp://example.com"), "UnsupportedScheme"
    )


def test_parse_missing_scheme_classifies_invalid_url() raises:
    # InvalidURL is a typed leaf in parse_url (separate category from UnsupportedScheme;
    # parse_url raises both, so it stays bare `raises`).
    assert_equal(_classify_parse_error("example.com/path"), "InvalidURL")


def test_parse_bad_port_classifies_invalid_url() raises:
    assert_equal(
        _classify_parse_error("http://example.com:notaport/"), "InvalidURL"
    )


def test_malformed_json_classifies_request_exception() raises:
    # RequestException is raised by the JSON parser on malformed input.
    assert_equal(_classify_json_error("{not valid"), "RequestException")


def test_raise_for_status_classifies_http_error() raises:
    # HTTPError is a typed leaf on Response.raise_for_status (carries status_code).
    assert_equal(_classify_raise_for_status(404), "HTTPError")
    assert_equal(_classify_raise_for_status(500), "HTTPError")


def test_raise_for_status_noop_under_400() raises:
    # raise_for_status is a no-op for 2xx/3xx.
    assert_equal(_classify_raise_for_status(200), "none")
    assert_equal(_classify_raise_for_status(301), "none")


# --- runner (auto-discovers all test_* functions in this module) ---


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
