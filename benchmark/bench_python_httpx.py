#!/usr/bin/env python3
"""Benchmark: Python httpx (sync Client).

Env: BENCH_URL, BENCH_COUNT
"""
import os
import httpx

def main():
    url = os.environ.get("BENCH_URL", "http://127.0.0.1:18099/")
    count = int(os.environ.get("BENCH_COUNT", "100"))
    with httpx.Client() as client:
        for _ in range(count):
            r = client.get(url)
            r.raise_for_status()

if __name__ == "__main__":
    main()
