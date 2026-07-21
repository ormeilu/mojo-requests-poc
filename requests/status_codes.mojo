# Status-code lookup, mirroring Python's ``requests.codes``.
#
# Python exposes ``requests.codes.ok == 200``, ``requests.codes.not_found == 404``, etc.
# Here the same table is a struct with named fields plus a ``get(name)`` lookup, obtained
# via the module-level ``codes()`` factory (Mojo has no attribute-access module singleton).

from .exceptions import RequestException


struct StatusCodes(Movable):
    """Named HTTP status codes (a subset of Python's ``requests.codes``)."""

    # 2xx
    var ok: Int
    var created: Int
    var accepted: Int
    var no_content: Int
    # 3xx
    var moved_permanently: Int
    var found: Int
    var see_other: Int
    var not_modified: Int
    var temporary_redirect: Int
    var permanent_redirect: Int
    # 4xx
    var bad_request: Int
    var unauthorized: Int
    var forbidden: Int
    var not_found: Int
    var method_not_allowed: Int
    var request_timeout: Int
    var conflict: Int
    var gone: Int
    var too_many_requests: Int
    # 5xx
    var internal_server_error: Int
    var not_implemented: Int
    var bad_gateway: Int
    var service_unavailable: Int
    var gateway_timeout: Int

    def __init__(out self):
        self.ok = 200
        self.created = 201
        self.accepted = 202
        self.no_content = 204
        self.moved_permanently = 301
        self.found = 302
        self.see_other = 303
        self.not_modified = 304
        self.temporary_redirect = 307
        self.permanent_redirect = 308
        self.bad_request = 400
        self.unauthorized = 401
        self.forbidden = 403
        self.not_found = 404
        self.method_not_allowed = 405
        self.request_timeout = 408
        self.conflict = 409
        self.gone = 410
        self.too_many_requests = 429
        self.internal_server_error = 500
        self.not_implemented = 501
        self.bad_gateway = 502
        self.service_unavailable = 503
        self.gateway_timeout = 504

    def get(self, name: String) raises -> Int:
        """Look up a code by name (e.g. ``codes.get("not_found") == 404``).

        Raises RequestException for an unknown name.
        """
        if name == "ok":
            return self.ok
        if name == "created":
            return self.created
        if name == "accepted":
            return self.accepted
        if name == "no_content":
            return self.no_content
        if name == "moved_permanently":
            return self.moved_permanently
        if name == "found":
            return self.found
        if name == "see_other":
            return self.see_other
        if name == "not_modified":
            return self.not_modified
        if name == "temporary_redirect":
            return self.temporary_redirect
        if name == "permanent_redirect":
            return self.permanent_redirect
        if name == "bad_request":
            return self.bad_request
        if name == "unauthorized":
            return self.unauthorized
        if name == "forbidden":
            return self.forbidden
        if name == "not_found":
            return self.not_found
        if name == "method_not_allowed":
            return self.method_not_allowed
        if name == "request_timeout":
            return self.request_timeout
        if name == "conflict":
            return self.conflict
        if name == "gone":
            return self.gone
        if name == "too_many_requests":
            return self.too_many_requests
        if name == "internal_server_error":
            return self.internal_server_error
        if name == "not_implemented":
            return self.not_implemented
        if name == "bad_gateway":
            return self.bad_gateway
        if name == "service_unavailable":
            return self.service_unavailable
        if name == "gateway_timeout":
            return self.gateway_timeout
        raise RequestException(String(t"unknown status code name: {name}"))


def codes() -> StatusCodes:
    """Return the status-code table (like Python's ``requests.codes``).

    Usage: ``requests.codes().ok`` or ``requests.codes().get("not_found")``.
    """
    return StatusCodes()
