# TLS layer — OpenSSL via dlopen (OwnedDLHandle).
#
# TLSConnection wraps an already-connected raw socket (the fd from _net.TCPSocket) with an OpenSSL SSL
# object. After connect(), send_all/recv_all go through SSL_write/SSL_read (encrypted) instead of raw
# socket syscalls.
#
# libssl is auto-discovered at runtime (no hard-coded paths) and dlopen'd via OwnedDLHandle. The TLS
# layer is C (OpenSSL); the rest of the library remains pure Mojo.

from std.ffi import OwnedDLHandle, c_int
from std.memory import alloc, OwnedPointer
from .exceptions import ssl_error


# OpenSSL constants (comptime c_int so they pass cleanly to OwnedDLHandle.call).
comptime SSL_VERIFY_PEER: c_int = 1
comptime SSL_CTRL_SET_TLSEXT_HOSTNAME: c_int = 55
comptime TLSEXT_NAMETYPE_host_name: c_int = 0
comptime SSL_ERROR_SSL: c_int = 1
comptime SSL_ERROR_SYSCALL: c_int = 5


struct TLSConnection:
    """A TLS connection over an existing TCP socket.

    Usage:
        var sock = TCPSocket()
        sock.connect(host, port)
        var tls = TLSConnection()
        tls.connect(sock.fd_value(), host)   # performs TLS handshake
        tls.send_all(request)
        var response_bytes = tls.recv_all()
        tls.close()
    """

    var _libssl: Optional[OwnedPointer[OwnedDLHandle]]
    var _ctx: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]  # SSL_CTX*
    var _ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]  # SSL*
    var _closed: Bool

    def __init__(out self):
        self._libssl = None
        self._ctx = None
        self._ssl = None
        self._closed = True

    def __del__(deinit self):
        self.close()

    def connect(mut self, sock_fd: c_int, hostname: String) raises:
        """Perform the TLS handshake over an already-connected socket.

        - ``sock_fd``: the connected raw socket fd (from TCPSocket.fd_value()).
        - ``hostname``: used for SNI and certificate verification.
        Raises ``ssl_error`` on any failure (missing libssl, handshake failure, cert rejection).
        """
        var libssl = _load_libssl()
        # Store the handle on the heap so it lives as long as this TLSConnection.
        self._libssl = OwnedPointer[OwnedDLHandle](libssl^)

        # Initialize OpenSSL (idempotent in OpenSSL 1.1+).
        var init_rc = self._libssl.value()[].call["OPENSSL_init_ssl", c_int](
            c_int(0), c_int(0)
        )
        if init_rc != c_int(1):
            raise ssl_error("OPENSSL_init_ssl failed")

        # Build a TLS context with certificate verification enabled.
        var method = self._libssl.value()[].call[
            "TLS_method", UnsafePointer[UInt8, MutUntrackedOrigin]
        ]()
        var ctx = self._libssl.value()[].call[
            "SSL_CTX_new", UnsafePointer[UInt8, MutUntrackedOrigin]
        ](method)
        if Int(ctx) == 0:
            raise ssl_error("SSL_CTX_new returned NULL")
        self._ctx = ctx

        # Use the system default CA paths for verification.
        _ = self._libssl.value()[].call[
            "SSL_CTX_set_default_verify_paths", c_int
        ](ctx)
        # Enable peer (certificate) verification.
        _ = self._libssl.value()[].call["SSL_CTX_set_verify", c_int](
            ctx, SSL_VERIFY_PEER, c_int(0)
        )

        var ssl = self._libssl.value()[].call[
            "SSL_new", UnsafePointer[UInt8, MutUntrackedOrigin]
        ](ctx)
        if Int(ssl) == 0:
            raise ssl_error("SSL_new returned NULL")
        self._ssl = ssl

        # Bind the SSL object to the existing socket fd.
        var setfd_rc = self._libssl.value()[].call["SSL_set_fd", c_int](
            ssl, sock_fd
        )
        if setfd_rc != c_int(1):
            raise ssl_error("SSL_set_fd failed")

        # SNI: SSL_set_tlsext_host_name is a macro -> SSL_ctrl(ssl, 55, 0, hostname).
        # Many CDNs/servers refuse TLS without SNI, so this is mandatory.
        var sni_rc = self._libssl.value()[].call["SSL_ctrl", c_int](
            ssl,
            SSL_CTRL_SET_TLSEXT_HOSTNAME,
            TLSEXT_NAMETYPE_host_name,
            hostname.unsafe_ptr(),
        )
        if sni_rc != c_int(1):
            raise ssl_error(
                String(t"SNI (SSL_set_tlsext_host_name) failed for {hostname}")
            )

        # Perform the handshake.
        var connect_rc = self._libssl.value()[].call["SSL_connect", c_int](ssl)
        if connect_rc != c_int(1):
            var err = _get_ssl_error(self._libssl.value()[], ssl, connect_rc)
            raise ssl_error(
                String(t"TLS handshake failed for {hostname}: {err}")
            )

        self._closed = False

    def send_all(mut self, data: String) raises:
        """Send the full request string over TLS, looping over partial SSL_write calls.
        """
        var ptr = data.unsafe_ptr()
        var remaining = data.byte_length()
        var offset = 0
        while remaining > 0:
            var written = self._libssl.value()[].call["SSL_write", c_int](
                self._ssl.value(), ptr + offset, c_int(remaining)
            )
            if written <= c_int(0):
                raise ssl_error("SSL_write failed or connection closed")
            offset += Int(written)
            remaining -= Int(written)

    def recv_all(mut self) raises -> List[UInt8]:
        """Read until the peer closes the TLS connection. Returns the full body+headers as raw bytes.
        """
        var all: List[UInt8] = []
        var buf = alloc[UInt8](CHUNK_SIZE)
        while True:
            var n = self._libssl.value()[].call["SSL_read", c_int](
                self._ssl.value(), buf, c_int(CHUNK_SIZE)
            )
            if n <= c_int(0):
                break
            var count = Int(n)
            for i in range(count):
                all.append(buf[i])
        buf.free()
        return all^

    def close(mut self):
        if self._closed:
            return
        self._closed = True
        if self._libssl != None:
            if self._ssl != None:
                _ = self._libssl.value()[].call["SSL_shutdown", c_int](
                    self._ssl.value()
                )
                _ = self._libssl.value()[].call["SSL_free", c_int](
                    self._ssl.value()
                )
                self._ssl = None
            if self._ctx != None:
                _ = self._libssl.value()[].call["SSL_CTX_free", c_int](
                    self._ctx.value()
                )
                self._ctx = None

    def _ssl_read_raw(
        mut self, buf: UnsafePointer[UInt8, MutUntrackedOrigin], max_bytes: Int
    ) raises -> c_int:
        """Single SSL_read call. Returns byte count, or <=0 on close/error."""
        return self._libssl.value()[].call["SSL_read", c_int](
            self._ssl.value(), buf, c_int(max_bytes)
        )

    def _steal_ssl(
        mut self,
    ) -> Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]:
        """Transfer ownership of the SSL* pointer out (so close() won't free it). Used for streaming.
        """
        var s = self._ssl
        self._ssl = None
        return s

    def _steal_libssl(mut self) -> Optional[OwnedPointer[OwnedDLHandle]]:
        """Transfer ownership of the libssl handle out (so close() won't drop it). Used for streaming.
        """
        var h = self._libssl^
        self._libssl = None
        return h^

    def _disown(mut self):
        """Mark this connection as no longer owning its resources (prevents double-close). Used for streaming.
        """
        self._closed = True
        self._ssl = None
        self._ctx = None
        self._libssl = None


comptime CHUNK_SIZE = 8192


# --- libssl auto-discovery (per-instance handle) -------------------------


# Candidate library paths, tried in order. Covers macOS Homebrew, macOS /usr/local,
# and Linux standard locations, plus a bare name as a last resort (lets the dynamic
# loader resolve via DYLD_LIBRARY_PATH / ldconfig).
def _load_libssl() raises -> OwnedDLHandle:
    """Discover and dlopen libssl. Each TLSConnection owns its handle (no global cache: Mojo has no mutable globals).
    """
    var candidates: List[String] = [
        "/opt/homebrew/lib/libssl.3.dylib",
        "/opt/homebrew/lib/libssl.dylib",
        "/usr/local/lib/libssl.3.dylib",
        "/usr/local/lib/libssl.dylib",
        "/usr/lib/libssl.so",
        "/usr/lib/libssl.so.1.1",
        "/usr/lib64/libssl.so",
        "/lib64/libssl.so",
        "/lib/libssl.so",
        "libssl.3.dylib",
        "libssl.dylib",
        "libssl.so.1.1",
        "libssl.so",
    ]

    var tried = String()
    for path in candidates:
        tried += path + ", "
        try:
            return OwnedDLHandle(path)
        except _:
            pass

    raise ssl_error(String(t"could not find libssl. Tried: {tried}"))


# --- error diagnostics ----------------------------------------------------


def _get_ssl_error(
    ref libssl: OwnedDLHandle,
    ssl: UnsafePointer[UInt8, MutUntrackedOrigin],
    rc: c_int,
) -> String:
    """Produce a human-readable TLS error string. Falls back to the rc if diagnosis fails.
    """
    var code = libssl.call["SSL_get_error", c_int](ssl, rc)
    if code == SSL_ERROR_SSL:
        return "SSL protocol error"
    if code == SSL_ERROR_SYSCALL:
        return "underlying socket I/O error"
    return String(t"SSL_get_error={code}")
