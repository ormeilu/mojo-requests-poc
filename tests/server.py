#!/usr/bin/env python3
"""Local HTTP + HTTPS test server for the mojo-requests test suite.

Serves a fixed set of fixtures from a directory on both a plain HTTP port and a
TLS-wrapped HTTPS port (self-signed cert generated on the fly). Used by CI to
avoid flaky external-network tests; also usable locally via ``pixi run server``.

Prints the two base URLs on stdout as:

    HTTP_PORT=18090
    HTTPS_PORT=18091
    BASE_URL=http://127.0.0.1:18090
    HTTPS_BASE_URL=https://127.0.0.1:18091

so the calling shell / CI step can export them for the test runner.

Stops cleanly on SIGINT/SIGTERM.
"""

from __future__ import annotations

import argparse
import os
import signal
import ssl
import sys
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def _write_fixtures(root: Path) -> Path:
    """Populate the served directory with the fixtures the test suite expects."""
    root.mkdir(parents=True, exist_ok=True)

    (root / "index.html").write_text(
        "<!doctype html><html><body>Example Domain</body></html>\n"
    )
    (root / "hello.txt").write_text("hello world\n")
    (root / "large.bin").write_bytes(b"x" * 65536)
    return root


def _make_self_signed_cert(directory: Path) -> tuple[Path, Path]:
    """Generate a self-signed cert + key in *directory*. Uses cryptography if
    available, otherwise falls back to invoking openssl via subprocess."""
    cert_path = directory / "cert.pem"
    key_path = directory / "key.pem"
    if cert_path.exists() and key_path.exists():
        return cert_path, key_path

    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        import datetime

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = issuer = x509.Name(
            [x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")]
        )
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.datetime.utcnow())
            .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=365))
            .add_extension(
                x509.SubjectAlternativeName(
                    [
                        x509.DNSName("localhost"),
                        x509.IPAddress(__import__("ipaddress").ip_address("127.0.0.1")),
                    ]
                ),
                critical=False,
            )
            .sign(key, hashes.SHA256())
        )
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
        return cert_path, key_path
    except ImportError:
        pass

    # Fallback: openssl CLI (available on GitHub runners and macOS default).
    import subprocess

    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            str(key_path),
            "-out",
            str(cert_path),
            "-days",
            "365",
            "-nodes",
            "-subj",
            "/CN=127.0.0.1",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
        capture_output=True,
    )
    return cert_path, key_path


def _make_https_handler(certfile: str) -> type:
    """A request handler that sets HSTS-less headers + serves the same tree."""

    class Handler(SimpleHTTPRequestHandler):
        # HTTP/1.1 enables persistent connections (keep-alive) so the client's connection
        # pool can be exercised. SimpleHTTPRequestHandler emits Content-Length for file GETs,
        # so responses are self-delimiting and the socket stays reusable.
        protocol_version = "HTTP/1.1"

        # Don't spam stderr with per-request logs.
        def log_message(self, fmt, *args):  # noqa: A003 - signature from base
            pass

    return Handler


def _make_proxy_handler() -> type:
    """A minimal forward proxy: absolute-form GET forwarding + CONNECT tunneling.

    Exercises the client's proxy support (tests/test_proxy.mojo):
      - ``GET http://host/path`` → the proxy fetches the origin and relays the response.
      - ``CONNECT host:port`` → the proxy opens a raw tunnel and pumps bytes both ways, so the
        client runs its TLS handshake end-to-end with the target.
    """
    import http.client
    import select
    import socket as _socket
    from http.server import BaseHTTPRequestHandler
    from urllib.parse import urlsplit

    class ProxyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # noqa: A003
            pass

        def do_GET(self):  # noqa: N802
            parts = urlsplit(self.path)
            if not parts.hostname:
                self.send_error(400, "proxy requires absolute-form target")
                return
            selector = parts.path or "/"
            if parts.query:
                selector += "?" + parts.query
            try:
                conn = http.client.HTTPConnection(
                    parts.hostname, parts.port or 80, timeout=10
                )
                conn.request("GET", selector)
                resp = conn.getresponse()
                body = resp.read()
            except OSError as exc:
                self.send_error(502, f"proxy upstream error: {exc}")
                return
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() in ("transfer-encoding", "connection", "content-length"):
                    continue
                self.send_header(key, val)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_CONNECT(self):  # noqa: N802
            host, _, port_s = self.path.partition(":")
            try:
                upstream = _socket.create_connection(
                    (host, int(port_s or 443)), timeout=10
                )
            except OSError as exc:
                self.send_error(502, f"CONNECT failed: {exc}")
                return
            self.send_response(200, "Connection established")
            self.end_headers()
            client = self.connection
            client.setblocking(False)
            upstream.setblocking(False)
            socks = [client, upstream]
            try:
                while True:
                    readable, _, errored = select.select(socks, [], socks, 30)
                    if errored:
                        break
                    for s in readable:
                        other = upstream if s is client else client
                        data = s.recv(65536)
                        if not data:
                            return
                        other.sendall(data)
            except OSError:
                pass
            finally:
                upstream.close()

    return ProxyHandler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http-port", type=int, default=18090)
    parser.add_argument("--https-port", type=int, default=18091)
    parser.add_argument("--proxy-port", type=int, default=18092)
    parser.add_argument(
        "--root", type=str, default=None, help="directory to serve (default: temp)"
    )
    args = parser.parse_args()

    root = Path(args.root) if args.root else Path(tempfile.mkdtemp(prefix="mojo-test-"))
    _write_fixtures(root)
    os.chdir(root)

    # HTTP server.
    http_handler = _make_https_handler("")
    httpd = ThreadingHTTPServer(("127.0.0.1", args.http_port), http_handler)

    # HTTPS server (self-signed).
    cert_path, key_path = _make_self_signed_cert(root)
    https_handler = _make_https_handler(str(cert_path))
    httpsd = ThreadingHTTPServer(("127.0.0.1", args.https_port), https_handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    httpsd.socket = ctx.wrap_socket(httpsd.socket, server_side=True)

    # Forward proxy (absolute-form GET forwarding + CONNECT tunneling).
    proxy_handler = _make_proxy_handler()
    proxyd = ThreadingHTTPServer(("127.0.0.1", args.proxy_port), proxy_handler)

    threads = [
        threading.Thread(target=httpd.serve_forever, daemon=True),
        threading.Thread(target=httpsd.serve_forever, daemon=True),
        threading.Thread(target=proxyd.serve_forever, daemon=True),
    ]
    for t in threads:
        t.start()

    # Announce.
    print(f"HTTP_PORT={args.http_port}")
    print(f"HTTPS_PORT={args.https_port}")
    print(f"PROXY_PORT={args.proxy_port}")
    print(f"BASE_URL=http://127.0.0.1:{args.http_port}")
    print(f"HTTPS_BASE_URL=https://127.0.0.1:{args.https_port}")
    print(f"PROXY_URL=http://127.0.0.1:{args.proxy_port}")
    print(f"ROOT={root}")
    sys.stdout.flush()

    # Stop on SIGINT / SIGTERM.
    stop = threading.Event()

    def _handle(signum, frame):
        stop.set()

    signal.signal(signal.SIGINT, _handle)
    signal.signal(signal.SIGTERM, _handle)
    stop.wait()
    httpd.shutdown()
    httpsd.shutdown()
    proxyd.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
