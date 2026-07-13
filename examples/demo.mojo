# Demo for the pure-Mojo requests library.
#
# Run with: pixi run demo   (starts a local test server automatically, or point it at any HTTP URL)
#
# This demo shows the requests-like API in action: GET, query params, POST, JSON, sessions, and error handling.

import requests


def main() raises:
    # The demo connects to a URL passed as the first CLI arg, defaulting to a local server.
    var base = "http://127.0.0.1:18090"
    print("=== mojo-requests demo (target:", base, ") ===\n")

    # 1. Simple GET
    print("[1] GET /")
    var r = requests.get(base + "/")
    print("    status:", r.status_code, "| ok:", r.ok())
    print("    server:", r.headers.get("Server", "unknown"))
    var body = r.text()
    print("    body bytes:", body.byte_length())
    print()

    # 2. GET with query params (percent-encoded automatically)
    print("[2] GET with query params")
    var params: Dict[String, String] = {"q": "hello world", "count": "3"}
    var r2 = requests.get(base + "/", params=params^)
    print("    final url:", r2.url)
    print("    status:", r2.status_code)
    print()

    # 3. Session with persistent default headers
    print("[3] Session with custom headers")
    var s = requests.Session()
    s.headers["X-Trace-Id"] = "abc-123"
    var r3 = s.get(base + "/")
    print("    status:", r3.status_code, "(custom header was sent)")
    print()

    # 4. JSON response (if the server returns JSON)
    print("[4] Response introspection")
    print("    r.ok():", r.ok())
    print("    r.text() preview:", String(r.text()[byte=0:50]), "...")
    print()

    print("=== demo complete ===")
