#!/usr/bin/env python3
"""Benchmark: Python requests (sync, keep-alive Session).

Env: BENCH_URL, BENCH_COUNT
"""
import os
import requests

def main():
    url = os.environ.get("BENCH_URL", "http://127.0.0.1:18099/")
    count = int(os.environ.get("BENCH_COUNT", "100"))
    session = requests.Session()
    for _ in range(count):
        r = session.get(url)
        r.raise_for_status()

if __name__ == "__main__":
    main()
