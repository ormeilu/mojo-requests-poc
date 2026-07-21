# Test suite for proxy support (HTTP forwarding + HTTPS CONNECT tunneling).
#
# Two kinds of tests:
#   1. Unit tests — deterministic, no network: proxy selection, absolute-form request building,
#      CONNECT-response parsing helpers, and ProxyError classification. Always run.
#   2. Live tests — route real requests through the forward proxy started by tests/server.py.
#      Gated on PROXY_URL (set by the server + CI). When unset the live tests are skipped so a
#      bare `mojo -I . tests/test_proxy.mojo` still passes on the unit tests alone.
#
# Run with: pixi run mojo -I . tests/test_proxy.mojo
#   (for the live tests: start `pixi run server` and export BASE_URL / HTTPS_BASE_URL / PROXY_URL)

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.ffi import external_call
from requests.session import Session
from requests._url import parse_url
from requests._http import build_request
from requests._proxy import (
    select_proxy,
    _ends_crlf_crlf,
    _parse_status,
)
from requests.exceptions import exception_kind, PROXY_PREFIX


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


def _proxies(scheme: String, url: String) -> Dict[String, String]:
    var d: Dict[String, String] = {}
    d[scheme] = url
    return d^


# --- unit tests: proxy selection ------------------------------------------------------------


def test_select_proxy_exact_scheme() raises:
    var p = _proxies("http", "http://127.0.0.1:8888")
    var sel = select_proxy(p, "http")
    assert_true(sel != None)
    assert_equal(sel.value().host, "127.0.0.1")
    assert_equal(sel.value().port, 8888)


def test_select_proxy_none_when_unmatched() raises:
    var p = _proxies("http", "http://127.0.0.1:8888")
    assert_true(select_proxy(p, "https") == None)
    var empty: Dict[String, String] = {}
    assert_true(select_proxy(empty, "http") == None)


def test_select_proxy_all_catchall() raises:
    var p = _proxies("all", "http://prox:3128")
    var sel = select_proxy(p, "https")
    assert_true(sel != None)
    assert_equal(sel.value().port, 3128)


def test_select_proxy_exact_beats_all() raises:
    var d: Dict[String, String] = {}
    d["all"] = "http://catchall:1"
    d["http"] = "http://specific:2"
    var sel = select_proxy(d, "http")
    assert_equal(sel.value().host, "specific")


def test_select_proxy_empty_value_is_none() raises:
    var p = _proxies("http", "")
    assert_true(select_proxy(p, "http") == None)


def test_select_proxy_rejects_non_http_scheme() raises:
    var p = _proxies("https", "https://tls-proxy:8443")
    var raised = False
    try:
        _ = select_proxy(p, "https")
    except e:
        raised = True
        assert_equal(exception_kind(e), PROXY_PREFIX)
    assert_true(raised)


# --- unit tests: absolute-form request building ---------------------------------------------


def test_build_request_absolute_target() raises:
    var u = parse_url("http://example.com/path?x=1")
    var h: Dict[String, String] = {}
    var req = build_request("GET", u, h, "", absolute_target=True)
    var line = String(req.split("\r\n")[0])
    assert_equal(line, "GET http://example.com/path?x=1 HTTP/1.1")


def test_build_request_origin_form_default() raises:
    var u = parse_url("http://example.com/path?x=1")
    var h: Dict[String, String] = {}
    var req = build_request("GET", u, h, "")
    var line = String(req.split("\r\n")[0])
    assert_equal(line, "GET /path?x=1 HTTP/1.1")


# --- unit tests: CONNECT-response parsing helpers -------------------------------------------


def test_ends_crlf_crlf() raises:
    assert_true(_ends_crlf_crlf(_b("HTTP/1.1 200 OK\r\n\r\n")))
    assert_false(_ends_crlf_crlf(_b("HTTP/1.1 200 OK\r\n")))
    assert_false(_ends_crlf_crlf(_b("ab")))


def test_connect_status_parse() raises:
    assert_equal(
        _parse_status("HTTP/1.1 200 Connection established\r\n\r\n"), 200
    )
    assert_equal(_parse_status("HTTP/1.1 407 Proxy Auth Required\r\n\r\n"), 407)
    assert_equal(_parse_status("HTTP/1.1 502 Bad Gateway\r\n\r\n"), 502)


# --- live tests: through the forward proxy --------------------------------------------------


def test_http_through_proxy() raises:
    var proxy = _getenv("PROXY_URL")
    var base = _getenv("BASE_URL")
    if proxy.byte_length() == 0 or base.byte_length() == 0:
        return  # skip: no live proxy/server
    with Session() as s:
        var r = s.get(base + "/hello.txt", proxies=_proxies("http", proxy))
        assert_equal(r.status_code, 200)
        assert_equal(r.text(), "hello world\n")
        # Proxied requests are not pooled.
        assert_equal(len(s._pool), 0)


def test_https_through_proxy_connect_tunnel() raises:
    var proxy = _getenv("PROXY_URL")
    var base = _getenv("HTTPS_BASE_URL")
    if proxy.byte_length() == 0 or base.byte_length() == 0:
        return  # skip
    with Session() as s:
        # verify=False: this test asserts the CONNECT tunnel + end-to-end TLS handshake work,
        # independent of the self-signed cert's trust chain.
        var r = s.get(
            base + "/hello.txt",
            proxies=_proxies("https", proxy),
            verify=False,
        )
        assert_equal(r.status_code, 200)
        assert_equal(r.text(), "hello world\n")
        assert_equal(len(s._pool), 0)


def test_session_level_proxies() raises:
    var proxy = _getenv("PROXY_URL")
    var base = _getenv("BASE_URL")
    if proxy.byte_length() == 0 or base.byte_length() == 0:
        return  # skip
    with Session() as s:
        s.proxies["http"] = proxy
        var r = s.get(
            base + "/index.html"
        )  # no per-call proxies → uses Session default
        assert_equal(r.status_code, 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
