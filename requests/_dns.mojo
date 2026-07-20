# DNS resolution via libc — pure Mojo, no Python.
#
# `resolve(host)` returns an IPv4 address as a host-byte-order UInt32 (the in-memory representation
# expected by `sockaddr_in.sin_addr`). It first tries `inet_pton` for dotted-decimal input, then falls
# back to `getaddrinfo` (thread-safe, heap-allocated) for hostnames.

from std.ffi import external_call, c_int
from std.memory import alloc
from .exceptions import ConnectionError


# POSIX constants
comptime AF_INET: c_int = 2
comptime SOCK_STREAM: c_int = 1
comptime AI_NUMERICHOST: c_int = 0x4  # macOS/Linux


@fieldwise_init
struct InAddr:
    """libc `struct in_addr { in_addr_t s_addr; }` — a 32-bit address."""

    var s_addr: UInt32


# Minimal mirror of `struct sockaddr_in` (16 bytes).
@fieldwise_init
struct SockAddrIn:
    var sin_family: UInt16
    var sin_port: UInt16
    var sin_addr: UInt32
    var sin_zero: SIMD[DType.uint8, 8]


# Minimal mirror of `struct addrinfo` (we only read ai_family, ai_addrlen, ai_addr, ai_next).
@fieldwise_init
struct AddrInfo:
    var ai_flags: c_int
    var ai_family: c_int
    var ai_socktype: c_int
    var ai_protocol: c_int
    var ai_addrlen: UInt64
    var ai_canonname: UInt64
    var ai_addr: UInt64
    var ai_next: UInt64


# Minimal mirror of `struct timespec { time_t tv_sec; long tv_nsec; }` for nanosleep.
@fieldwise_init
struct Timespec:
    var tv_sec: Int64
    var tv_nsec: Int64


def resolve(host: String) raises ConnectionError -> UInt32:
    """Resolve a host string to an IPv4 address (host byte order).

    Accepts dotted-decimal ("127.0.0.1", "8.8.8.8") or a hostname ("example.com").
    Raises ``ConnectionError`` on failure.
    """
    # Try dotted-decimal first via inet_pton (returns 1 on success, 0 on malformed).
    var dst = alloc[InAddr](1)
    var rc = external_call["inet_pton", c_int](AF_INET, host.unsafe_ptr(), dst)
    if rc == c_int(1):
        var addr = dst[].s_addr
        dst.free()
        return addr
    dst.free()

    # Fall back to getaddrinfo for hostnames.
    return _resolve_by_name(host)


def _resolve_by_name(host: String) raises ConnectionError -> UInt32:
    """Resolve a hostname via libc ``getaddrinfo`` (thread-safe, heap-allocated — unlike gethostbyname).

    Retries up to 5 times with exponential backoff (50ms, 100ms, 200ms, 400ms): the first
    ``getaddrinfo`` in a fresh process can fail transiently on some systems (lazy resolver init /
    heap-state-dependent behavior observed in Mojo 1.0 beta). The caller's Session also warms up
    with a localhost resolve, but network resolvers can still hiccup on first contact with a real
    hostname.
    """
    var hints = alloc[AddrInfo](1)
    hints[].ai_flags = 0
    hints[].ai_family = AF_INET
    hints[].ai_socktype = SOCK_STREAM
    hints[].ai_protocol = 0
    hints[].ai_addrlen = 0
    hints[].ai_canonname = 0
    hints[].ai_addr = 0
    hints[].ai_next = 0

    var result_addr = alloc[UnsafePointer[AddrInfo, MutUntrackedOrigin]](1)

    var rc = c_int(-1)
    var attempt = 0
    while attempt < 5:
        rc = external_call["getaddrinfo", c_int](
            host.unsafe_ptr(),
            c_int(
                0
            ),  # service = NULL (we only want address resolution, not port)
            hints,
            result_addr,
        )
        if rc == c_int(0):
            break
        # Exponential backoff: 50ms, 100ms, 200ms, 400ms. nanosleep via libc {sec=0, nsec=N}.
        var req = alloc[Timespec](1)
        req[].tv_sec = 0
        req[].tv_nsec = Int64(50_000_000 * (1 << attempt))
        _ = external_call["nanosleep", c_int](req, 0)
        req.free()
        attempt += 1

    hints.free()
    if rc != c_int(0):
        result_addr.free()
        raise ConnectionError(
            String(t"DNS resolution failed for host: {host}"), host=host
        )

    var first = result_addr[]
    result_addr.free()
    if Int(first) == 0:
        raise ConnectionError(
            String(t"DNS returned no addresses for host: {host}"), host=host
        )

    # ai_addr points to a sockaddr; for AF_INET it's a sockaddr_in. Reinterpret and read sin_addr.
    var ai_addr = first[].ai_addr
    if ai_addr == 0:
        _ = external_call["freeaddrinfo", NoneType](first)
        raise ConnectionError(
            String(t"DNS entry has no address for host: {host}"), host=host
        )

    var sockaddr_ptr = UnsafePointer[SockAddrIn, MutUntrackedOrigin](
        unsafe_from_address=Int(ai_addr)
    )
    var ip = sockaddr_ptr[].sin_addr

    _ = external_call["freeaddrinfo", NoneType](first)
    return ip
