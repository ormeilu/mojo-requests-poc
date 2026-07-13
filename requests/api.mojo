# Module-level request API — requests.get(url), requests.post(url, ...).
#
# Each function creates a throwaway Session (with default headers) and delegates to it, mirroring Python's `requests` top-level functions.

from .session import Session
from .models import Response


def request(
    method: String,
    url: String,
    params: Optional[Dict[String, String]] = None,
    headers: Optional[Dict[String, String]] = None,
    data: Optional[String] = None,
    json: Optional[String] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP request and return a Response."""
    var s = Session()
    return s.request(method, url, params=params, headers=headers, data=data, json=json, timeout=timeout)


def get(
    url: String,
    params: Optional[Dict[String, String]] = None,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP GET request."""
    var s = Session()
    return s.get(url, params=params, headers=headers, timeout=timeout)


def post(
    url: String,
    data: Optional[String] = None,
    json: Optional[String] = None,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP POST request."""
    var s = Session()
    return s.post(url, data=data, json=json, headers=headers, timeout=timeout)


def put(
    url: String,
    data: Optional[String] = None,
    json: Optional[String] = None,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP PUT request."""
    var s = Session()
    return s.put(url, data=data, json=json, headers=headers, timeout=timeout)


def patch(
    url: String,
    data: Optional[String] = None,
    json: Optional[String] = None,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP PATCH request."""
    var s = Session()
    return s.patch(url, data=data, json=json, headers=headers, timeout=timeout)


def delete(
    url: String,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP DELETE request."""
    var s = Session()
    return s.delete(url, headers=headers, timeout=timeout)


def head(
    url: String,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP HEAD request."""
    var s = Session()
    return s.head(url, headers=headers, timeout=timeout)


def options(
    url: String,
    headers: Optional[Dict[String, String]] = None,
    timeout: Optional[Float64] = None,
) raises -> Response:
    """Send an HTTP OPTIONS request."""
    var s = Session()
    return s.options(url, headers=headers, timeout=timeout)
