# TCP socket layer — pure Mojo over libc FFI.
#
# `TCPSocket` wraps a POSIX socket file descriptor. All syscalls go through `external_call`
# against libc (`socket`, `connect`, `send`, `recv`, `setsockopt`, `close`).
# No Python, no libcurl.

from std.ffi import external_call, c_int
from std.memory import alloc
from .exceptions import ConnectionError, Timeout


# POSIX socket constants (kept as comptime c_int so they pass to external_call cleanly).
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime SOL_SOCKET: c_int = 0xFFFF
comptime SO_RCVTIMEO: c_int = 0x1006
comptime SO_SNDTIMEO: c_int = 0x1005
# NOTE: AF_INET6 is intentionally NOT a comptime const here — its value differs by platform
# (30 on macOS/BSD, 10 on Linux). The platform-correct value arrives in ResolvedAddress.pf
# (sourced from getaddrinfo's ai_family in _dns.mojo), so _connect_addr reads addr.pf instead.

# send/recv flags
comptime SEND_FLAGS: c_int = 0
comptime RECV_FLAGS: c_int = 0

# Errno values for timeout detection. EAGAIN and EWOULDBLOCK are equal on every supported
# platform (macOS: 35, Linux: 11), so we accept both values to stay portable without a
# platform check. When a connect/send/recv syscall fails on a socket that had
# SO_RCVTIMEO/SO_SNDTIMEO set and the socket's SO_ERROR matches one of these, we raise
# ``Timeout`` instead of ``ConnectionError``.
comptime SO_ERROR: c_int = 0x1007
comptime EAGAIN_MACOS: c_int = 35
comptime EAGAIN_LINUX: c_int = 11


@fieldwise_init
struct SockAddrIn:
    """libc ``struct sockaddr_in`` (macOS/Linux, same layout).

    - ``sin_family`` / ``sin_port`` are 16-bit
    - ``sin_addr`` is a 32-bit network-order address
    - ``sin_zero`` pads to 16 bytes total
    """

    var sin_family: UInt16
    var sin_port: UInt16
    var sin_addr: UInt32
    var sin_zero: SIMD[DType.uint8, 8]


@fieldwise_init
struct SockAddrIn6:
    """libc ``struct sockaddr_in6`` (28 bytes — identical layout on macOS + Linux):

    sa_family_t     sin6_family;    // u16
    in_port_t       sin6_port;      // u16
    uint32_t        sin6_flowinfo;  // u32
    struct in6_addr sin6_addr;      // 16 bytes
    uint32_t        sin6_scope_id;  // u32
    """

    var sin6_family: UInt16
    var sin6_port: UInt16
    var sin6_flowinfo: UInt32
    var sin6_addr: SIMD[DType.uint8, 16]
    var sin6_scope_id: UInt32


@fieldwise_init
struct Timeval:
    """libc ``struct timeval { long tv_sec; long tv_usec; }``."""

    var tv_sec: Int64
    var tv_usec: Int64


def htons(port: UInt16) -> UInt16:
    """Host -> network byte order for a 16-bit port."""
    return (port << 8) | (port >> 8)


def _do_connect(fd: c_int, addr: ResolvedAddress, port: Int) -> c_int:
    """Build the right sockaddr for ``addr``'s family and call ``connect``.

    - IPv4: ``sockaddr_in`` (16 bytes) with ``sin_family = AF_INET`` (portable: 2).
    - IPv6: ``sockaddr_in6`` (28 bytes on macOS + Linux) with ``sin6_family = addr.pf`` — the
      platform AF_INET6 value (30 macOS / 10 Linux), sourced from getaddrinfo's ai_family.

    Returns the ``connect`` rc (0 = success, <0 = failure).
    """
    if addr.is_ipv4():
        var sa = alloc[SockAddrIn](1)
        sa[].sin_family = UInt16(AF_INET)
        sa[].sin_port = htons(UInt16(port))
        sa[].sin_addr = addr.ipv4
        sa[].sin_zero = SIMD[DType.uint8, 8]()
        var rc = external_call["connect", c_int](fd, sa, c_int(16))
        sa.free()
        return rc
    var sa = alloc[SockAddrIn6](1)
    sa[].sin6_family = UInt16(c_int(addr.pf))
    sa[].sin6_port = htons(UInt16(port))
    sa[].sin6_flowinfo = UInt32(0)
    sa[].sin6_addr = addr.ipv6
    sa[].sin6_scope_id = UInt32(0)
    var rc = external_call["connect", c_int](fd, sa, c_int(28))
    sa.free()
    return rc


struct TCPSocket:
    """A connected TCP socket over libc.

    Use ``connect`` to create, then ``send_all`` / ``recv_all`` for full-duplex I/O.
    The socket is closed in ``__del__``; you may also call ``close`` explicitly.
    """

    var fd: c_int
    var closed: Bool
    var _has_timeout: Bool

    def __init__(out self):
        self.fd = c_int(-1)
        self.closed = True
        self._has_timeout = False

    def __del__(deinit self):
        self.close()

    def fd_value(self) -> c_int:
        """The raw socket file descriptor (for binding to a TLS layer)."""
        return self.fd

    def connect(
        mut self, host: String, port: Int, timeout: Optional[Float64] = None
    ) raises:
        """Open a TCP connection to ``host:port``.

        ``host`` may be a dotted-decimal IPv4 literal, an IPv6 literal (``::1``), or a hostname
        (resolved via ``_dns``). ``timeout`` (seconds) applies to this connect + send/recv.
        """
        var addr = _dns_resolve(host)
        self._connect_addr(addr, port, timeout, host)

    def connect_ip(
        mut self, addr: UInt32, port: Int, timeout: Optional[Float64] = None
    ) raises:
        """Open a TCP connection to a pre-resolved IPv4 address (host byte order).

        Use this when DNS was already resolved by the caller (avoids re-resolution).
        Kept for backward compatibility; new callers should prefer the
        ``connect_ip(ResolvedAddress, …)`` overload, which carries both families.
        """
        self._connect_addr(
            ResolvedAddress(Int8(4), Int8(2), addr, SIMD[DType.uint8, 16]()),
            port,
            timeout,
            String(),
        )

    def connect_ip(
        mut self,
        addr: ResolvedAddress,
        port: Int,
        timeout: Optional[Float64] = None,
    ) raises:
        """Open a TCP connection to a pre-resolved ``ResolvedAddress`` (IPv4 or IPv6).

        Use this when DNS was already resolved by the caller (avoids re-resolution).
        """
        self._connect_addr(addr, port, timeout, String())

    def _connect_addr(
        mut self,
        addr: ResolvedAddress,
        port: Int,
        timeout: Optional[Float64],
        host_label: String,
    ) raises:
        # PF is the platform address-family integer (AF_INET=2 portable; AF_INET6 non-portable,
        # sourced from getaddrinfo's ai_family via ResolvedAddress.pf).
        var raw_fd = external_call["socket", c_int](
            c_int(addr.pf), SOCK_STREAM, c_int(0)
        )
        if raw_fd < c_int(0):
            raise ConnectionError("socket() failed")
        self.fd = raw_fd
        self.closed = False

        # Set send/recv timeouts before connecting so blocking calls can't hang forever.
        if timeout != None:
            self._set_timeouts(timeout.value())

        # connect() against the resolved address. The sockaddr layout + connect() addrlen differ
        # by family (sockaddr_in = 16 bytes, sockaddr_in6 = 28 bytes on macOS + Linux); see
        # _do_connect. pf is the platform address-family integer for IPv6 (AF_INET6 value varies
        # by platform — sourced from getaddrinfo's ai_family via ResolvedAddress.pf).
        var rc = _do_connect(self.fd, addr, port)

        if rc < c_int(0):
            # Query SO_ERROR *before* closing the fd (getsockopt needs a live socket).
            var was_timeout = self._is_timeout()
            self._raw_close()
            if host_label.byte_length() > 0:
                self._io_failure(
                    String(t"connect() to {host_label}:{String(port)} failed"),
                    host=host_label,
                    was_timeout=was_timeout,
                )
            self._io_failure(
                String(t"connect() to port {String(port)} failed"),
                was_timeout=was_timeout,
            )

    def _set_timeouts(mut self, timeout_secs: Float64) raises:
        var tv = alloc[Timeval](1)
        tv[].tv_sec = Int64(timeout_secs)
        tv[].tv_usec = Int64(
            (timeout_secs - Float64(Int64(timeout_secs))) * 1_000_000.0
        )
        var size = c_int(16)  # sizeof(struct timeval) on 64-bit
        _ = external_call["setsockopt", c_int](
            self.fd, SOL_SOCKET, SO_RCVTIMEO, tv, size
        )
        _ = external_call["setsockopt", c_int](
            self.fd, SOL_SOCKET, SO_SNDTIMEO, tv, size
        )
        tv.free()
        self._has_timeout = True

    def _is_timeout(mut self) -> Bool:
        """True if the socket's pending error (SO_ERROR) looks like an SO_RCVTIMEO/SO_SNDTIMEO
        expiry on a socket that has a timeout set.

        Uses ``getsockopt(SO_ERROR)`` — portable across macOS/Linux (unlike the ``__error`` /
        ``__errno_location`` errno accessors, which require platform-specific symbol resolution
        and ``external_call`` does not raise on a missing symbol, it JIT-crashes). EAGAIN and
        EWOULDBLOCK are equal on every supported platform (macOS: 35, Linux: 11); accept both.
        """
        if not self._has_timeout:
            return False
        var err = alloc[c_int](1)
        err[] = c_int(0)
        var lenp = alloc[c_int](1)
        lenp[] = c_int(4)
        _ = external_call["getsockopt", c_int](
            self.fd, SOL_SOCKET, SO_ERROR, err, lenp
        )
        var e = err[]
        err.free()
        lenp.free()
        return e == EAGAIN_MACOS or e == EAGAIN_LINUX

    def _io_failure(
        self, msg: String, *, host: String = "", was_timeout: Bool = False
    ) raises:
        """Raise ``Timeout`` if ``was_timeout`` is set (caller pre-queried SO_ERROR before
        closing the socket); otherwise raise ``ConnectionError``.

        ``was_timeout`` is passed explicitly because callers must query SO_ERROR while the fd
        is still live (before ``_raw_close``), then close, then come here to raise.

        Mojo 1.0 has no multi-type ``raises`` union, so this helper is bare ``raises`` and
        callers (which also raise both categories) propagate as bare ``raises``.
        """
        if was_timeout:
            raise Timeout(msg, host=host)
        raise ConnectionError(msg, host=host)

    def send_all(mut self, data: String) raises:
        """Send the full request string, looping over partial sends."""
        var ptr = data.unsafe_ptr()
        var remaining = data.byte_length()
        var offset = 0
        while remaining > 0:
            var sent = external_call["send", c_int](
                self.fd, ptr + offset, c_int(remaining), SEND_FLAGS
            )
            if sent <= c_int(0):
                self._io_failure(
                    "send() failed or connection closed",
                    was_timeout=self._is_timeout(),
                )
            offset += Int(sent)
            remaining -= Int(sent)

    def send_all(mut self, data: List[UInt8]) raises:
        """Send raw bytes, looping over partial sends."""
        var ptr = data.unsafe_ptr()
        var remaining = len(data)
        var offset = 0
        while remaining > 0:
            var sent = external_call["send", c_int](
                self.fd, ptr + offset, c_int(remaining), SEND_FLAGS
            )
            if sent <= c_int(0):
                self._io_failure(
                    "send() failed or connection closed",
                    was_timeout=self._is_timeout(),
                )
            offset += Int(sent)
            remaining -= Int(sent)

    def recv_all(mut self) raises -> List[UInt8]:
        """Read until the peer closes the connection (Connection: close / HTTP/1.0 style).

        Returns the full body+headers as raw bytes. Callers separate headers from body in ``_http``.
        """
        var all: List[UInt8] = []
        var buf = alloc[UInt8](CHUNK_SIZE)
        while True:
            var n = external_call["recv", c_int](
                self.fd, buf, c_int(CHUNK_SIZE), RECV_FLAGS
            )
            if n <= c_int(0):
                break
            var count = Int(n)
            for i in range(count):
                all.append(buf[i])
        buf.free()
        return all^

    def close(mut self):
        if not self.closed:
            self._raw_close()

    def _recv_raw(
        mut self, buf: UnsafePointer[UInt8, MutUntrackedOrigin], max_bytes: Int
    ) raises -> c_int:
        """Single recv() call. Returns byte count, or <=0 on close/error."""
        return external_call["recv", c_int](
            self.fd, buf, c_int(max_bytes), RECV_FLAGS
        )

    def _disown(mut self):
        """Mark this socket as not owning its fd (so __del__/close won't close it). Used for streaming.
        """
        self.closed = True
        self.fd = c_int(-1)

    def _raw_close(mut self):
        if self.fd >= c_int(0):
            _ = external_call["close", c_int](self.fd)
        self.fd = c_int(-1)
        self.closed = True


comptime CHUNK_SIZE = 8192


# Re-export the resolver from _dns so callers only need _net. We import lazily here to avoid a
# circular module reference at parse time; the helper just forwards.
from ._dns import resolve as _dns_resolve
from ._dns import ResolvedAddress
