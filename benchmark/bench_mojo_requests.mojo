# Benchmark: mojo-requests (sync Session).
#
# Usage:
#   BENCH_URL=http://127.0.0.1:18099/ BENCH_COUNT=100 mojo run -I . benchmark/bench_mojo_requests.mojo
#   BENCH_URL=http://127.0.0.1:18099/ BENCH_COUNT=100 ./bench_mojo_requests
#
# Issues BENCH_COUNT GET requests to BENCH_URL using a Session, with no per-request output.

import requests
from std.os import getenv


def main() raises:
    var url = "http://127.0.0.1:18099/"
    var count = 100

    var env_url = getenv("BENCH_URL")
    if env_url:
        url = env_url

    var env_count = getenv("BENCH_COUNT")
    if env_count:
        var parsed = _parse_count(env_count)
        if parsed > 0:
            count = parsed

    var s = requests.Session()
    for _ in range(count):
        var r = s.get(url)
        r.raise_for_status()


def _parse_count(s: String) -> Int:
    var sp = s.unsafe_ptr()
    var n = s.byte_length()
    var v = 0
    for i in range(n):
        var b = sp[i]
        if b < 0x30 or b > 0x39:
            return v
        v = v * 10 + Int(b - 0x30)
    return v
