# DNS resolution via libc — pure Mojo, no Python.
#
# `resolve(host)` returns an IPv4 address as a host-byte-order UInt32 (the in-memory representation
# expected by `sockaddr_in.sin_addr`). It first tries `inet_pton` for dotted-decimal input, then falls
# back to `gethostbyname` for hostnames.

from std.ffi import external_call, c_int
from std.memory import alloc
from .exceptions import connection_error


# AF_INET == 2
comptime AF_INET: c_int = 2


@fieldwise_init
struct InAddr:
    """libc `struct in_addr { in_addr_t s_addr; }` — a 32-bit address."""
    var s_addr: UInt32


@fieldwise_init
struct Hostent:
    """Minimal mirror of libc ``struct hostent`` — only the fields we read."""
    var h_name: UInt64
    var h_aliases: UInt64
    var h_addrtype: c_int
    var h_length: c_int
    var h_addr_list: UInt64


def resolve(host: String) raises -> UInt32:
    """Resolve a host string to an IPv4 address (host byte order).

    Accepts dotted-decimal ("127.0.0.1", "8.8.8.8") or a hostname ("example.com").
    Raises ``connection_error`` on failure.
    """
    # Try dotted-decimal first via inet_pton (returns 1 on success, 0 on malformed).
    var dst = alloc[InAddr](1)
    var rc = external_call["inet_pton", c_int](AF_INET, host.unsafe_ptr(), dst)
    if rc == c_int(1):
        var addr = dst[].s_addr
        dst.free()
        return addr
    dst.free()

    # Fall back to gethostbyname for hostnames.
    return _resolve_by_name(host)


def _resolve_by_name(host: String) raises -> UInt32:
    """Resolve a hostname via libc ``gethostbyname``.

    gethostbyname is thread-unsafe/obsolete but ubiquitous and sufficient for a v1 client. We call it single-threaded from Mojo, fine for sequential request issuance.
    """
    var he = external_call["gethostbyname", UnsafePointer[Hostent, MutUntrackedOrigin]](host.unsafe_ptr())
    # gethostbyname returns NULL (address 0) on failure. Compare via the raw address.
    if Int(he) == 0:
        raise connection_error(String(t"DNS resolution failed for host: {host}"))

    # h_addr_list is a `char**` stored as a raw address (UInt64). Reconstruct the pointer-to-pointer.
    var addr_list_addr = he[].h_addr_list
    if addr_list_addr == 0:
        raise connection_error(String(t"DNS returned no addresses for host: {host}"))
    var addr_ptr_ptr = UnsafePointer[UnsafePointer[UInt32, MutUntrackedOrigin], MutUntrackedOrigin](
        unsafe_from_address=Int(addr_list_addr)
    )
    # h_addr_list is a NULL-terminated list of pointers; the first entry is the primary address.
    var first = addr_ptr_ptr[]
    if Int(first) == 0:
        raise connection_error(String(t"DNS returned no addresses for host: {host}"))

    return first[]
