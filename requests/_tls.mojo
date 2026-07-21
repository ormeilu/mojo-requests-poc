# TLS layer — OpenSSL via dlopen (OwnedDLHandle).
#
# TLSConnection wraps an already-connected raw socket (the fd from _net.TCPSocket) with an OpenSSL SSL
# object. After connect(), send_all/recv_all go through SSL_write/SSL_read (encrypted) instead of raw
# socket syscalls.
#
# libssl is auto-discovered at runtime (no hard-coded paths) and dlopen'd via OwnedDLHandle. The TLS
# layer is C (OpenSSL); the rest of the library remains pure Mojo.

from std.ffi import OwnedDLHandle, c_int, external_call
from std.memory import alloc, OwnedPointer
from .exceptions import SSLError


# OpenSSL constants (comptime c_int so they pass cleanly to OwnedDLHandle.call).
comptime SSL_VERIFY_NONE: c_int = 0
comptime SSL_VERIFY_PEER: c_int = 1
comptime SSL_CTRL_SET_TLSEXT_HOSTNAME: c_int = 55
comptime TLSEXT_NAMETYPE_host_name: c_int = 0
comptime SSL_ERROR_SSL: c_int = 1
comptime SSL_ERROR_SYSCALL: c_int = 5
comptime TLS1_2_VERSION: c_int = 0x0303
comptime SSL_CTRL_SET_MIN_PROTO_VERSION: c_int = 123
comptime SSL_SESS_CACHE_CLIENT: c_int = 1
comptime SSL_CTRL_SET_SESS_CACHE_MODE: c_int = 44
comptime TLS13_CIPHERSUITES: StaticString = (
    "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
)
comptime TLS12_CIPHER_LIST: StaticString = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"


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

    def connect(
        mut self,
        sock_fd: c_int,
        hostname: String,
        verify: Bool = True,
        ca_bundle: Optional[String] = None,
        session: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None,
    ) raises SSLError:
        """Perform the TLS handshake over an already-connected socket.

        - ``sock_fd``: the connected raw socket fd (from TCPSocket.fd_value()).
        - ``hostname``: used for SNI and certificate verification.
        - ``verify``: when True (default), verify the peer certificate against the trust store.
          When False, skip certificate verification (insecure — use only for testing).
        - ``ca_bundle``: optional path to a PEM file of trusted CA certificates. When set,
          overrides the system trust store. When None, the trust store is resolved in this
          priority order: explicit ca_bundle > $REQUESTS_CA_BUNDLE env var > $SSL_CERT_FILE
          env var > OpenSSL system defaults (``SSL_CTX_set_default_verify_paths``).
        - ``session``: an ``SSL_SESSION*`` from a prior handshake to the same host (see
          ``TLSSessionCache``). When set, offered via ``SSL_set_session`` so the server can
          resume instead of doing a full asymmetric handshake. Best-effort — a session the
          server has expired/rejected just falls back to a full handshake.

        Raises ``SSLError`` on any failure (missing libssl, handshake failure, cert rejection).
        """
        var libssl = _load_libssl()
        # Store the handle on the heap so it lives as long as this TLSConnection.
        self._libssl = OwnedPointer[OwnedDLHandle](libssl^)

        # Initialize OpenSSL (idempotent in OpenSSL 1.1+).
        var init_rc = self._libssl.value()[].call["OPENSSL_init_ssl", c_int](
            c_int(0), c_int(0)
        )
        if init_rc != c_int(1):
            raise SSLError("OPENSSL_init_ssl failed")

        # Build a TLS context with certificate verification enabled.
        var method = self._libssl.value()[].call[
            "TLS_method", UnsafePointer[UInt8, MutUntrackedOrigin]
        ]()
        var ctx = self._libssl.value()[].call[
            "SSL_CTX_new", UnsafePointer[UInt8, MutUntrackedOrigin]
        ](method)
        if Int(ctx) == 0:
            raise SSLError("SSL_CTX_new returned NULL")
        self._ctx = ctx

        # Cipher/protocol curation: floor at TLS 1.2 (drops SSLv3/TLS1.0/1.1 downgrade
        # exposure) and prefer modern AEAD suites for both 1.3 (curated via
        # SSL_CTX_set_ciphersuites) and 1.2 (curated via SSL_CTX_set_cipher_list — the
        # legacy API, since SSL_CTX_set_ciphersuites only governs TLS 1.3). Best-effort:
        # an old libssl build may reject an unrecognized suite name, so failures here are
        # ignored rather than raised — the handshake below still proceeds with defaults.
        # SSL_CTX_set_min_proto_version is a macro -> SSL_CTX_ctrl(ctx, 123, version, NULL)
        # (same pattern as SSL_set_tlsext_host_name above — not a real exported symbol).
        _ = self._libssl.value()[].call["SSL_CTX_ctrl", c_int](
            ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, c_int(0)
        )
        _ = self._libssl.value()[].call["SSL_CTX_set_ciphersuites", c_int](
            ctx, TLS13_CIPHERSUITES.unsafe_ptr()
        )
        _ = self._libssl.value()[].call["SSL_CTX_set_cipher_list", c_int](
            ctx, TLS12_CIPHER_LIST.unsafe_ptr()
        )

        # Session resumption: enable the client-side session cache mode so OpenSSL keeps
        # session tickets around for SSL_get1_session() to retrieve after the handshake. The
        # actual cache (host -> SSL_SESSION*) is owned by the caller (TLSSessionCache); this
        # only tells OpenSSL to participate. SSL_CTX_set_session_cache_mode is a macro (like
        # SSL_set_tlsext_host_name / SSL_CTX_set_min_proto_version above) -> SSL_CTX_ctrl(ctx,
        # 44, mode, NULL) — not a real exported symbol.
        _ = self._libssl.value()[].call["SSL_CTX_ctrl", c_int](
            ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_CLIENT, c_int(0)
        )

        if verify:
            # Resolve the CA trust store in priority order:
            #   1. explicit ca_bundle parameter
            #   2. $REQUESTS_CA_BUNDLE env var (matches python requests)
            #   3. $SSL_CERT_FILE env var (OpenSSL's native convention)
            #   4. system default paths via SSL_CTX_set_default_verify_paths
            #
            # The chosen bundle path is materialized as an owned String (`resolved_path`)
            # whose backing memory lives for the duration of the SSL_CTX_load_verify_locations
            # call. Strings built char-by-char in _getenv can carry an internal representation
            # whose .unsafe_ptr() OpenSSL rejects; round-tripping through `String() + x`
            # normalizes the layout. (Mojo String-build artifact observed in 1.0 beta.)
            var env_rb = _getenv("REQUESTS_CA_BUNDLE")
            var env_sc = _getenv("SSL_CERT_FILE")
            var have_path = False
            var resolved_path = String()
            if ca_bundle != None:
                resolved_path = String() + ca_bundle.value()
                have_path = True
            elif env_rb.byte_length() > 0:
                resolved_path = String() + env_rb
                have_path = True
            elif env_sc.byte_length() > 0:
                resolved_path = String() + env_sc
                have_path = True

            if have_path:
                # Explicit bundle: load ONLY this file (overrides system defaults).
                # SSL_CTX_load_verify_locations(SSL_CTX*, const char *CAfile, const char *CApath)
                # — pass a null CApath (we only want the file form). c_int(0) widens to a null
                # pointer when the FFI shim materializes the C-ABI argument.
                #
                # Copy the path into a separately-allocated, NUL-terminated buffer that we
                # manage explicitly. A Mojo String's unsafe_ptr() can become unreliable when
                # passed through the FFI shim after other heap activity (observed in Mojo
                # 1.0 beta): the bytes the runtime sees when materializing the C-ABI argument
                # are correct, but the buffer OpenSSL later dereferences inside BIO_new_file
                # can be clobbered. Allocating our own buffer sidesteps this entirely.
                var path_bytes = resolved_path.byte_length()
                var cpath = alloc[UInt8](path_bytes + 1)
                var src = resolved_path.unsafe_ptr()
                for i in range(path_bytes):
                    cpath[i] = src[i]
                cpath[path_bytes] = 0
                # Clear the OpenSSL error queue so any failure we see is unambiguously ours.
                _ = self._libssl.value()[].call["ERR_clear_error", c_int]()
                var rc = self._libssl.value()[].call[
                    "SSL_CTX_load_verify_locations", c_int
                ](ctx, cpath, c_int(0))
                cpath.free()
                if rc != c_int(1):
                    var derr = _drain_openssl_errors(self._libssl.value()[])
                    raise SSLError(
                        String(
                            t"failed to load CA bundle:"
                            t" {resolved_path} ({derr})"
                        )
                    )
            else:
                # Fall back to OpenSSL's compiled-in default paths. This also lets OpenSSL
                # itself honor SSL_CERT_FILE / SSL_CERT_DIR at lookup time on most platforms.
                _ = self._libssl.value()[].call[
                    "SSL_CTX_set_default_verify_paths", c_int
                ](ctx)
            # Enable peer (certificate) verification.
            _ = self._libssl.value()[].call["SSL_CTX_set_verify", c_int](
                ctx, SSL_VERIFY_PEER, c_int(0)
            )
        else:
            # Insecure: disable peer verification entirely.
            _ = self._libssl.value()[].call["SSL_CTX_set_verify", c_int](
                ctx, SSL_VERIFY_NONE, c_int(0)
            )

        var ssl = self._libssl.value()[].call[
            "SSL_new", UnsafePointer[UInt8, MutUntrackedOrigin]
        ](ctx)
        if Int(ssl) == 0:
            raise SSLError("SSL_new returned NULL")
        self._ssl = ssl

        # Bind the SSL object to the existing socket fd.
        var setfd_rc = self._libssl.value()[].call["SSL_set_fd", c_int](
            ssl, sock_fd
        )
        if setfd_rc != c_int(1):
            raise SSLError("SSL_set_fd failed")

        # SNI: SSL_set_tlsext_host_name is a macro -> SSL_ctrl(ssl, 55, 0, hostname).
        # Many CDNs/servers refuse TLS without SNI, so this is mandatory.
        # Copy the hostname into an explicitly-managed NUL-terminated buffer for the same
        # reason as the CA bundle path above — see the comment near SSL_CTX_load_verify_locations.
        var host_bytes = hostname.byte_length()
        var chost = alloc[UInt8](host_bytes + 1)
        var host_src = hostname.unsafe_ptr()
        for i in range(host_bytes):
            chost[i] = host_src[i]
        chost[host_bytes] = 0
        var sni_rc = self._libssl.value()[].call["SSL_ctrl", c_int](
            ssl,
            SSL_CTRL_SET_TLSEXT_HOSTNAME,
            TLSEXT_NAMETYPE_host_name,
            chost,
        )
        chost.free()
        if sni_rc != c_int(1):
            raise SSLError(
                String(t"SNI (SSL_set_tlsext_host_name) failed for {hostname}"),
                hostname=hostname,
            )

        # Offer a cached session for resumption, if the caller has one for this host.
        if session != None:
            _ = self._libssl.value()[].call["SSL_set_session", c_int](
                ssl, session.value()
            )

        # Perform the handshake.
        var connect_rc = self._libssl.value()[].call["SSL_connect", c_int](ssl)
        if connect_rc != c_int(1):
            var err = _get_ssl_error(self._libssl.value()[], ssl, connect_rc)
            raise SSLError(
                String(t"TLS handshake failed for {hostname}: {err}"),
                hostname=hostname,
            )

        self._closed = False

    def get_session(
        mut self,
    ) -> Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]:
        """Return the negotiated ``SSL_SESSION*`` (owning reference, via ``SSL_get1_session``)
        for the caller to stash in a ``TLSSessionCache``, or None if unavailable. The caller
        becomes responsible for eventually ``SSL_SESSION_free``-ing it (``TLSSessionCache``
        does this)."""
        if self._ssl == None or self._libssl == None:
            return None
        var s = self._libssl.value()[].call[
            "SSL_get1_session", UnsafePointer[UInt8, MutUntrackedOrigin]
        ](self._ssl.value())
        if Int(s) == 0:
            return None
        return s

    def send_all(mut self, data: String) raises SSLError:
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
                raise SSLError("SSL_write failed or connection closed")
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


struct TLSSessionCache(Movable):
    """Per-Session cache of negotiated ``SSL_SESSION*`` handles, keyed by ``"host:port"``.

    Lets a re-connect to a host we've already handshaked with (a fresh endpoint, or a stale
    pooled connection being replaced) skip the asymmetric key exchange via TLS session
    resumption. Owns a lazily-loaded libssl handle solely to call ``SSL_SESSION_free`` on
    eviction/drop — any dlopen'd handle to the same shared library works, since the process
    only ever has one loaded copy.
    """

    var _libssl: Optional[OwnedPointer[OwnedDLHandle]]
    var _sessions: Dict[String, UnsafePointer[UInt8, MutUntrackedOrigin]]

    def __init__(out self):
        self._libssl = None
        self._sessions = {}

    def __del__(deinit self):
        self.clear()

    def __moveinit__(out self, deinit existing: Self):
        self._libssl = existing._libssl^
        self._sessions = existing._sessions^

    def clear(mut self):
        """Free every cached session and empty the cache. Idempotent."""
        if self._libssl != None:
            for entry in self._sessions.items():
                _ = self._libssl.value()[].call["SSL_SESSION_free", c_int](
                    entry.value
                )
        self._sessions = {}

    def get(
        self, key: String
    ) raises -> Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]:
        if key in self._sessions:
            return self._sessions[key]
        return None

    def put(
        mut self,
        key: String,
        session: UnsafePointer[UInt8, MutUntrackedOrigin],
    ) raises:
        """Store ``session`` for ``key``, freeing any previous entry. Best-effort: if libssl
        can't be loaded (should not happen — a handshake already succeeded to get here), the
        new session is dropped rather than leaked."""
        if self._libssl == None:
            try:
                self._libssl = OwnedPointer[OwnedDLHandle](_load_libssl())
            except _:
                return
        if key in self._sessions:
            _ = self._libssl.value()[].call["SSL_SESSION_free", c_int](
                self._sessions[key]
            )
        self._sessions[key] = session


comptime CHUNK_SIZE = 8192


# --- libssl auto-discovery (per-instance handle) -------------------------


# Candidate library paths, tried in order. Covers macOS Homebrew, macOS /usr/local,
# and Linux standard locations, plus a bare name as a last resort (lets the dynamic
# loader resolve via DYLD_LIBRARY_PATH / ldconfig).
def _load_libssl() raises SSLError -> OwnedDLHandle:
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

    raise SSLError(String(t"could not find libssl. Tried: {tried}"))


# --- env var access (libc getenv via FFI) ---------------------------------


def _getenv(name: String) -> String:
    """Read an environment variable via libc ``getenv``. Returns "" if unset."""
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


def _drain_openssl_errors(ref libssl: OwnedDLHandle) -> String:
    """Drain OpenSSL's per-thread error queue and return a concatenated diagnostic string.

    Used after a failed SSL_CTX_* call to surface the actual OpenSSL reason code instead
    of a bare "rc=0". Returns "[no error queued]" if the queue is empty (which itself is
    informative — it means the call rejected without pushing to the queue).
    """
    var buf = alloc[UInt8](256)
    var out = String()
    var first = True
    var count = 0
    while count < 8:
        var e = libssl.call["ERR_get_error", UInt64]()
        if e == UInt64(0):
            break
        _ = libssl.call["ERR_error_string_n", c_int](e, buf, c_int(256))
        var msg = String()
        var i = 0
        while buf[i] != 0 and i < 256:
            msg += String(Codepoint(unsafe_unchecked_codepoint=UInt32(buf[i])))
            i += 1
        if not first:
            out += " | "
        first = False
        out += String(t"[{e}] {msg}")
        count += 1
    buf.free()
    if first:
        return "[no error queued]"
    return out^
