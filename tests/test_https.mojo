# HTTPS-specific tests for the pure-Mojo requests library.
#
# Covers: https URL parsing (scheme/port/origin), SSLError exception kind, and TLS layer availability.
# Live TLS round-trip tests are covered by examples/demo.mojo (they require network access).
#
# Run with: pixi run mojo -I . tests/test_https.mojo

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from requests._url import parse_url
from requests.exceptions import ssl_error, exception_kind


# --- https URL parsing ---


def test_https_default_port() raises:
    var u = parse_url("https://example.com/path")
    assert_equal(u.scheme, "https")
    assert_equal(u.port, 443)


def test_https_custom_port() raises:
    var u = parse_url("https://example.com:8443/path")
    assert_equal(u.port, 8443)
    assert_equal(u.host_header(), "example.com:8443")


def test_https_origin_omits_default_port() raises:
    var u = parse_url("https://example.com/x")
    assert_equal(u.origin(), "https://example.com")


def test_https_request_target() raises:
    var u = parse_url("https://api.example.com/v1/data?q=test")
    assert_equal(u.request_target(), "/v1/data?q=test")


def test_http_still_defaults_to_80() raises:
    var u = parse_url("http://example.com/x")
    assert_equal(u.port, 80)
    assert_equal(u.host_header(), "example.com")


# --- SSLError exception kind ---


def test_ssl_error_kind() raises:
    var err = ssl_error("handshake failed")
    assert_equal(exception_kind(err), "SSLError")


def test_ssl_error_message() raises:
    var err = ssl_error("cert invalid")
    var s = String(err)
    assert_true(
        s == "SSLError: cert invalid", "ssl_error message should be prefixed"
    )


# --- TLS layer importable (compile-time check that _tls.mojo is well-formed) ---


def test_tls_connection_importable() raises:
    # If _tls.mojo compiled and TLSConnection is constructible, TLS support is wired up.
    # We don't perform a live handshake here (that needs network); this is a smoke test.
    from requests._tls import TLSConnection

    _ = TLSConnection()
    assert_true(True, "TLSConnection constructed")


# --- runner ---


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
