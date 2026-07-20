# TCP socket layer — pure Mojo over libc FFI.
#
# `TCPSocket` wraps a POSIX socket file descriptor. All syscalls go through `external_call`
# against libc (`socket`, `connect`, `send`, `recv`, `setsockopt`, `close`).
# No Python, no libcurl.

from std.ffi import external_call, c_int
from std.memory import alloc
from .exceptions import connection_error, timeout_error


# POSIX socket constants (kept as comptime c_int so they pass to external_call cleanly).
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime SOL_SOCKET: c_int = 0xFFFF
comptime SO_RCVTIMEO: c_int = 0x1006
comptime SO_SNDTIMEO: c_int = 0x1005

# send/recv flags
comptime SEND_FLAGS: c_int = 0
comptime RECV_FLAGS: c_int = 0


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
struct Timeval:
    """libc ``struct timeval { long tv_sec; long tv_usec; }``."""

    var tv_sec: Int64
    var tv_usec: Int64


def htons(port: UInt16) -> UInt16:
    """Host -> network byte order for a 16-bit port."""
    return (port << 8) | (port >> 8)


struct TCPSocket:
    """A connected TCP socket over libc.

    Use ``connect`` to create, then ``send_all`` / ``recv_all`` for full-duplex I/O.
    The socket is closed in ``__del__``; you may also call ``close`` explicitly.
    """

    var fd: c_int
    var closed: Bool

    def __init__(out self):
        self.fd = c_int(-1)
        self.closed = True

    def __del__(deinit self):
        self.close()

    def fd_value(self) -> c_int:
        """The raw socket file descriptor (for binding to a TLS layer)."""
        return self.fd

    def connect(
        mut self, host: String, port: Int, timeout: Optional[Float64] = None
    ) raises:
        """Open a TCP connection to ``host:port``.

        ``host`` may be a dotted-decimal IP or a hostname (resolved via ``_dns``).
        ``timeout`` (seconds) applies to this connect and subsequent send/recv.
        """
        var addr = _dns_resolve(host)
        self._connect_addr(addr, port, timeout, host)

    def connect_ip(
        mut self, addr: UInt32, port: Int, timeout: Optional[Float64] = None
    ) raises:
        """Open a TCP connection to a pre-resolved IPv4 address (host byte order).

        Use this when DNS was already resolved by the caller (avoids re-resolution).
        """
        self._connect_addr(addr, port, timeout, String())

    def _connect_addr(
        mut self,
        addr: UInt32,
        port: Int,
        timeout: Optional[Float64],
        host_label: String,
    ) raises:
        var raw_fd = external_call["socket", c_int](
            AF_INET, SOCK_STREAM, c_int(0)
        )
        if raw_fd < c_int(0):
            raise connection_error("socket() failed")
        self.fd = raw_fd
        self.closed = False

        # Set send/recv timeouts before connecting so blocking calls can't hang forever.
        if timeout != None:
            self._set_timeouts(timeout.value())

        var sa = alloc[SockAddrIn](1)
        sa[].sin_family = UInt16(AF_INET)
        sa[].sin_port = htons(UInt16(port))
        sa[].sin_addr = addr
        sa[].sin_zero = SIMD[DType.uint8, 8]()

        var rc = external_call["connect", c_int](self.fd, sa, c_int(16))
        sa.free()
        if rc < c_int(0):
            self._raw_close()
            if host_label.byte_length() > 0:
                raise connection_error(
                    String(t"connect() to {host_label}:{String(port)} failed")
                )
            raise connection_error(
                String(t"connect() to port {String(port)} failed")
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
                raise connection_error("send() failed or connection closed")
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
                raise connection_error("send() failed or connection closed")
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
