# Streaming connection — holds a live socket/TLS connection for incremental body reads.
#
# A StreamingConn owns the socket fd (and optionally a libssl handle for HTTPS). read_chunk() pulls
# body bytes on demand via recv()/SSL_read(). The connection is closed in __del__ (when the
# owning Response is dropped) or explicitly via close().

from std.ffi import external_call, OwnedDLHandle, c_int
from std.memory import OwnedPointer, alloc
from .exceptions import request_exception


# POSIX constants (mirror _net.mojo / _tls.mojo).
comptime CHUNK_SIZE = 8192


struct StreamingConn(Movable):
    """A live connection for streaming response bodies.

    - ``fd``: the raw socket file descriptor (owned; closed on close/__del__).
    - ``libssl``: optional libssl handle (present for HTTPS, None for HTTP).
    - ``ssl``: the SSL* pointer (when HTTPS), else None.
    - ``buffer``: body bytes already read while fetching headers (drained first).
    - ``content_length``: expected body size (-1 = read until close).
    - ``body_read``: body bytes consumed so far.
    - ``chunked``: True if Transfer-Encoding: chunked.
    - ``closed``: whether the connection has been closed.
    """

    var fd: c_int
    var libssl: Optional[OwnedPointer[OwnedDLHandle]]
    var ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]]
    var buffer: List[UInt8]
    var buffer_pos: Int  # how many bytes of buffer have been consumed
    var content_length: Int
    var body_read: Int
    var chunked: Bool
    var closed: Bool

    def __init__(
        out self,
        fd: c_int,
        var libssl: Optional[OwnedPointer[OwnedDLHandle]],
        var ssl: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]],
        var buffer: List[UInt8],
        content_length: Int,
        chunked: Bool,
    ):
        self.fd = fd
        self.libssl = libssl^
        self.ssl = ssl^
        self.buffer = buffer^
        self.buffer_pos = 0
        self.content_length = content_length
        self.body_read = 0
        self.chunked = chunked
        self.closed = False

    def __moveinit__(out self, mut existing: Self):
        """Transfer ownership of the live connection. Marks the source as closed so its
        destructor doesn't double-close the fd / free the SSL handle."""
        self.fd = existing.fd
        self.libssl = existing.libssl^
        self.ssl = existing.ssl^
        self.buffer = existing.buffer^
        self.buffer_pos = existing.buffer_pos
        self.content_length = existing.content_length
        self.body_read = existing.body_read
        self.chunked = existing.chunked
        self.closed = existing.closed
        existing.closed = True
        existing.fd = c_int(-1)

    def __del__(deinit self):
        self.close()

    def read_chunk(mut self, chunk_size: Int) raises -> Optional[List[UInt8]]:
        """Read up to ``chunk_size`` body bytes. Returns None when the body is fully consumed.
        """
        if self.closed:
            return None
        # For chunked encoding we don't fully implement incremental dechunking here; instead we
        # read until close (the server closes after the chunked body for Connection: close).
        # This is a simplification; proper incremental chunked streaming is future work.
        if self.chunked:
            return self._read_chunk_until_close(chunk_size)

        # Content-Length or read-until-close.
        if self.content_length >= 0 and self.body_read >= self.content_length:
            return None

        var out = List[UInt8]()
        # First drain any bytes already buffered (leftover from the header read).
        while self.buffer_pos < len(self.buffer) and len(out) < chunk_size:
            # Respect Content-Length if known.
            if (
                self.content_length >= 0
                and self.body_read >= self.content_length
            ):
                break
            out.append(self.buffer[self.buffer_pos])
            self.buffer_pos += 1
            self.body_read += 1

        if len(out) >= chunk_size:
            return out^
        if self.content_length >= 0 and self.body_read >= self.content_length:
            return out^

        # Read fresh bytes from the socket/TLS connection.
        var needed = chunk_size - len(out)
        if self.content_length >= 0:
            var remaining = self.content_length - self.body_read
            if remaining < needed:
                needed = remaining
        if needed <= 0:
            return out^

        var fresh = self._recv(needed)
        for b in fresh:
            out.append(b)
        self.body_read += len(fresh)
        return out^

    def _read_chunk_until_close(
        mut self, chunk_size: Int
    ) raises -> Optional[List[UInt8]]:
        """For chunked encoding: drain buffer, then read until the connection closes.
        """
        var out = List[UInt8]()
        while self.buffer_pos < len(self.buffer) and len(out) < chunk_size:
            out.append(self.buffer[self.buffer_pos])
            self.buffer_pos += 1
        if len(out) >= chunk_size:
            return out^
        var needed = chunk_size - len(out)
        var fresh = self._recv(needed)
        if len(fresh) == 0 and len(out) == 0:
            return None  # connection closed, nothing left
        for b in fresh:
            out.append(b)
        return out^

    def _recv(mut self, max_bytes: Int) raises -> List[UInt8]:
        """Read up to ``max_bytes`` from the socket (HTTP) or SSL (HTTPS)."""
        if max_bytes <= 0:
            var empty = List[UInt8]()
            return empty^
        var buf = List[UInt8]()
        if self.ssl:
            # HTTPS: SSL_read via the libssl handle.
            var raw = alloc[UInt8](max_bytes)
            var n = self.libssl.value()[].call["SSL_read", c_int](
                self.ssl.value(), raw, c_int(max_bytes)
            )
            if n > c_int(0):
                for i in range(Int(n)):
                    buf.append(raw[i])
            raw.free()
        else:
            # HTTP: raw recv.
            var raw = alloc[UInt8](max_bytes)
            var n = external_call["recv", c_int](
                self.fd, raw, c_int(max_bytes), c_int(0)
            )
            if n > c_int(0):
                for i in range(Int(n)):
                    buf.append(raw[i])
            raw.free()
        return buf^

    def close(mut self):
        if self.closed:
            return
        self.closed = True
        if self.ssl:
            _ = self.libssl.value()[].call["SSL_shutdown", c_int](
                self.ssl.value()
            )
            _ = self.libssl.value()[].call["SSL_free", c_int](self.ssl.value())
            self.ssl = None
        if self.fd >= c_int(0):
            _ = external_call["close", c_int](self.fd)
            self.fd = c_int(-1)
