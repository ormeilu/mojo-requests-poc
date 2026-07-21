# DNS resolution via libc — pure Mojo, no Python.
#
# `resolve(host)` returns a `ResolvedAddress` carrying an IPv4 (host-byte-order UInt32, the
# in-memory representation expected by `sockaddr_in.sin_addr`) or an IPv6 address (16 network-
# order bytes, as expected by `sockaddr_in6.sin6_addr`).
#
# Resolution order:
#   1. `inet_pton(AF_INET, …)`                 — dotted-decimal literal → IPv4.
#   2. `getaddrinfo(host, AI_NUMERICHOST)`      — IPv6 literal (e.g. "::1", "fe80::1") → IPv6.
#   3. `getaddrinfo(host, AF_UNSPEC)`           — hostname; returns A + AAAA records. We
#      **prefer IPv4** (first AF_INET result) for backward compatibility with IPv4-only targets
#      and fall back to the first AF_INET6 when no IPv4 record is available. A real
#      happy-eyeballs (RFC 8305) client would race both — that's deferred (see TODO.md).

from std.ffi import external_call, c_int
from std.memory import alloc
from std.time import sleep
from .exceptions import ConnectionError


# POSIX constants.
# AF_INET (2), AF_UNSPEC (0), SOCK_STREAM (1), and AI_NUMERICHOST (0x4) are identical on
# macOS and Linux. **AF_INET6 is NOT portable** — it's 30 on macOS/BSD and 10 on Linux — so we
# never hard-code it; for IPv6 literal parsing we go through getaddrinfo (which reports the
# correct ai_family per-platform) instead of inet_pton(AF_INET6, ...).
comptime AF_INET: c_int = 2
comptime AF_UNSPEC: c_int = 0
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


# Minimal mirror of `struct sockaddr_in6` (28 bytes — identical layout on macOS + Linux):
#   sa_family_t     sin6_family;    // u16
#   in_port_t       sin6_port;      // u16
#   uint32_t        sin6_flowinfo;  // u32
#   struct in6_addr sin6_addr;      // 16 bytes
#   uint32_t        sin6_scope_id;  // u32
@fieldwise_init
struct SockAddrIn6:
    var sin6_family: UInt16
    var sin6_port: UInt16
    var sin6_flowinfo: UInt32
    var sin6_addr: SIMD[DType.uint8, 16]
    var sin6_scope_id: UInt32


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


@fieldwise_init
struct ResolvedAddress(Movable):
    """A resolved endpoint address, carrying either an IPv4 or IPv6 address.

    - ``family == 4``: ``ipv4`` holds the address in host byte order (the in-memory form
      expected by ``sockaddr_in.sin_addr``); ``ipv6`` is zeroed.
    - ``family == 6``: ``ipv6`` holds the 16 network-order bytes (as expected by
      ``sockaddr_in6.sin6_addr``); ``ipv4`` is zeroed.

    ``pf`` is the platform address-family integer to pass to ``socket()`` and store in
    ``sin_family``/``sin6_family`` — it's the raw ``ai_family`` from ``getaddrinfo``. We carry it
    explicitly because ``AF_INET6`` is NOT a portable constant (30 on macOS/BSD, 10 on Linux);
    ``AF_INET`` (2) is, so v4 just uses the comptime ``AF_INET``.

    The zeroed sibling address field keeps the struct trivially default-constructible.
    """

    var family: Int8  # abstract: 4 or 6
    var pf: Int8  # platform ai_family (AF_INET=2 / AF_INET6=platform-specific)
    var ipv4: UInt32
    var ipv6: SIMD[DType.uint8, 16]

    def is_ipv4(self) -> Bool:
        return self.family == Int8(4)

    def is_ipv6(self) -> Bool:
        return self.family == Int8(6)


def _v4(addr: UInt32) -> ResolvedAddress:
    """Build an IPv4 ResolvedAddress (host byte order)."""
    return ResolvedAddress(
        Int8(4), Int8(2), addr, SIMD[DType.uint8, 16]()
    )  # pf = AF_INET (2, portable)


def _v6(pf: c_int, bytes: SIMD[DType.uint8, 16]) -> ResolvedAddress:
    """Build an IPv6 ResolvedAddress (network order, 16 bytes).

    ``pf`` is the platform ``ai_family`` (AF_INET6) from ``getaddrinfo`` — passed in explicitly
    because its integer value varies by platform.
    """
    return ResolvedAddress(Int8(6), Int8(pf), UInt32(0), bytes)


def _take(imm opt: Optional[ResolvedAddress]) -> ResolvedAddress:
    """Read the inner value out of a non-empty Optional[ResolvedAddress].

    All of ``ResolvedAddress``'s fields are trivial register types, so we copy them out field-by-
    field through the borrow rather than fighting Mojo's non-copyable move semantics for
    ``Optional`` payloads — ``Optional.value()^`` has no origin to transfer from in this build.
    """
    return ResolvedAddress(
        opt.value().family,
        opt.value().pf,
        opt.value().ipv4,
        opt.value().ipv6,
    )


def _cstr(s: String) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Copy a Mojo ``String`` into an explicitly-allocated, NUL-terminated buffer.

    A Mojo ``String``'s backing buffer can be clobbered between the moment the FFI shim
    materializes a C-ABI argument and the moment the C library (``getaddrinfo`` / ``inet_pton``)
    dereferences it — especially after other allocations in the same call (alloc[AddrInfo],
    Dict work in the caller). This bites hosts sliced out of a URL by ``parse_url`` in
    particular. Owning the buffer sidesteps the issue entirely. Caller must ``.free()`` the
    returned pointer. (Same fix as ``_tls.mojo``'s CA-path / SNI-hostname buffers; see
    AGENTS.md §1.1 / STRUGGLES.md §1.1.)
    """
    var n = s.byte_length()
    var buf = alloc[UInt8](n + 1)
    var src = s.unsafe_ptr()
    for i in range(n):
        buf[i] = src[i]
    buf[n] = 0
    return buf


def resolve(host: String) raises ConnectionError -> ResolvedAddress:
    """Resolve a host string to a ``ResolvedAddress`` (IPv4 or IPv6).

    Accepts a dotted-decimal IPv4 literal ("127.0.0.1"), an IPv6 literal ("::1",
    "fe80::1", "2001:db8::1"), or a hostname ("example.com") resolved via ``getaddrinfo``.
    Raises ``ConnectionError`` on failure.
    """
    # Try IPv4 dotted-decimal first via inet_pton (returns 1 on success, 0 on malformed).
    # AF_INET (2) is portable; this fast-path avoids a getaddrinfo round-trip for the common case.
    # The host String is copied into an alloc'd NUL-terminated buffer (see _cstr) because a sliced
    # String (e.g. from parse_url) handed via unsafe_ptr() can be clobbered across the FFI boundary.
    var chost4 = _cstr(host)
    var dst4 = alloc[InAddr](1)
    var rc4 = external_call["inet_pton", c_int](AF_INET, chost4, dst4)
    var v4_addr = dst4[].s_addr if rc4 == c_int(1) else UInt32(0)
    dst4.free()
    chost4.free()
    if rc4 == c_int(1):
        return _v4(v4_addr)

    # IPv6 literal or hostname: both go through getaddrinfo. We don't use inet_pton(AF_INET6, ...)
    # because AF_INET6 is NOT a portable comptime value (30 on macOS/BSD, 10 on Linux) —
    # getaddrinfo reports the correct ai_family per-platform. AI_NUMERICHOST (set in the first
    # attempt) makes the call fail instantly for non-literals, so there's no DNS round-trip cost
    # for the IPv6-literal probe; only real hostnames reach the retry/backoff path.
    var numeric = _getaddrinfo(host, numeric=True)
    if numeric != None:
        return _take(numeric)
    return _resolve_by_name(host)


def _resolve_by_name(host: String) raises ConnectionError -> ResolvedAddress:
    """Resolve a hostname via libc ``getaddrinfo`` (thread-safe, heap-allocated — unlike gethostbyname).

    Queries both IPv4 (A) and IPv6 (AAAA) records via ``AF_UNSPEC`` and **prefers IPv4** for
    backward compatibility with IPv4-only targets (the local test server, in particular). Falls
    back to the first IPv6 record only when no IPv4 record is returned.

    Retries up to 5 times with exponential backoff (50ms, 100ms, 200ms, 400ms): the first
    ``getaddrinfo`` in a fresh process can fail transiently on some systems (lazy resolver init /
    heap-state-dependent behavior observed in Mojo 1.0 beta). The caller's Session also warms up
    with a localhost resolve, but network resolvers can still hiccup on first contact with a real
    hostname.
    """
    var resolved = _getaddrinfo(host, numeric=False)
    if resolved != None:
        return _take(resolved)
    raise ConnectionError(
        String(t"DNS returned no usable addresses for host: {host}"), host=host
    )


def _getaddrinfo(
    host: String, numeric: Bool
) raises ConnectionError -> Optional[ResolvedAddress]:
    """Run ``getaddrinfo`` and pick one address (prefer IPv4, fall back to IPv6).

    ``numeric=True`` sets ``AI_NUMERICHOST`` so the call only accepts IP literals (no DNS) and
    fails instantly for hostnames — used by ``resolve()`` as the IPv6-literal probe. ``numeric=False``
    is the real hostname path with retry/backoff.

    Returns ``None`` when the lookup yields no usable address (numeric probe against a hostname,
    or an empty result list); raises ``ConnectionError`` on a retry-exhausted name-resolution
    failure (only on the non-numeric path — a failed numeric probe returns None).

    Family detection: ``getaddrinfo`` reports the platform-correct family in each node's
    ``ai_family``. We treat ``AF_INET`` (portable: 2) as IPv4 and **anything else** as IPv6 —
    this avoids hard-coding ``AF_INET6`` (which is 30 on macOS/BSD, 10 on Linux). With our hints
    (``AF_UNSPEC`` + ``SOCK_STREAM``) getaddrinfo only ever returns AF_INET or AF_INET6.
    """
    var hints = alloc[AddrInfo](1)
    hints[].ai_flags = AI_NUMERICHOST if numeric else 0
    hints[].ai_family = AF_UNSPEC
    hints[].ai_socktype = SOCK_STREAM
    hints[].ai_protocol = 0
    hints[].ai_addrlen = 0
    hints[].ai_canonname = 0
    hints[].ai_addr = 0
    hints[].ai_next = 0

    var result_addr = alloc[UnsafePointer[AddrInfo, MutUntrackedOrigin]](1)

    # Copy the host into an alloc'd NUL-terminated buffer that we own — a sliced String's
    # unsafe_ptr() (e.g. host extracted by parse_url) can be clobbered across the FFI boundary
    # when other allocations happen nearby. Reused across all retry attempts. See _cstr docstring.
    var chost = _cstr(host)

    var rc = c_int(-1)
    var attempt = 0
    # Numeric probes are all-or-nothing (no DNS) — one attempt, no retry/backoff.
    var max_attempts = 1 if numeric else 5
    while attempt < max_attempts:
        rc = external_call["getaddrinfo", c_int](
            chost,
            c_int(
                0
            ),  # service = NULL (we only want address resolution, not port)
            hints,
            result_addr,
        )
        if rc == c_int(0):
            break
        # Exponential backoff: 50ms, 100ms, 200ms, 400ms.
        sleep(Float64(0.05) * Float64(1 << attempt))
        attempt += 1

    hints.free()
    chost.free()
    if rc != c_int(0):
        result_addr.free()
        # Numeric probe miss (hostname, not a literal) → None, not an error.
        # Name-resolution retry exhaustion → ConnectionError.
        if numeric:
            return None
        raise ConnectionError(
            String(t"DNS resolution failed for host: {host}"), host=host
        )

    var first = result_addr[]
    result_addr.free()
    if Int(first) == 0:
        if numeric:
            return None
        raise ConnectionError(
            String(t"DNS returned no addresses for host: {host}"), host=host
        )

    # Walk the addrinfo linked list. Prefer AF_INET; remember the first non-AF_INET as a fallback.
    # Read fields through the pointer (AddrInfo is not ImplicitlyCopyable, so `var node = cur[]`
    # would not compile) and stash the chosen bytes into locals (Optional[ResolvedAddress] is not
    # ImplicitlyCopyable either, so it can't be moved out with `^` at the return site).
    var have_v4 = False
    var v4_addr: UInt32 = 0
    var have_v6 = False
    var v6_pf: c_int = c_int(0)
    var v6_bytes: SIMD[DType.uint8, 16] = SIMD[DType.uint8, 16]()
    var cur = first
    while Int(cur) != 0:
        var family = cur[].ai_family
        var ai_addr = cur[].ai_addr
        if ai_addr != 0:
            if family == AF_INET and not have_v4:
                # ai_addr points to a sockaddr_in for AF_INET. Read sin_addr.
                var sockaddr_ptr = UnsafePointer[
                    SockAddrIn, MutUntrackedOrigin
                ](unsafe_from_address=Int(ai_addr))
                v4_addr = sockaddr_ptr[].sin_addr
                have_v4 = True
            elif family != AF_INET and not have_v6:
                # ai_addr points to a sockaddr_in6 for AF_INET6. Read sin6_addr.
                var sockaddr_ptr = UnsafePointer[
                    SockAddrIn6, MutUntrackedOrigin
                ](unsafe_from_address=Int(ai_addr))
                v6_bytes = sockaddr_ptr[].sin6_addr
                v6_pf = family
                have_v6 = True
        cur = UnsafePointer[AddrInfo, MutUntrackedOrigin](
            unsafe_from_address=Int(cur[].ai_next)
        )

    _ = external_call["freeaddrinfo", NoneType](first)

    if have_v4:
        return _v4(v4_addr)
    if have_v6:
        return _v6(v6_pf, v6_bytes)
    return None
