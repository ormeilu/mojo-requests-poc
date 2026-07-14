#!/usr/bin/env bash
# Benchmark: python requests vs python httpx vs mojo-requests.
#
# Runs hyperfine comparing 4 variants against a local HTTP server:
#   1. python requests   (sync, keep-alive Session)
#   2. python httpx      (sync Client)
#   3. mojo run          (includes compile time — not fair, shown for reference)
#   4. mojo (pre-built)  (compile excluded — the fair comparison)
#
# Usage:
#   pixi run bench                    # default: 200 requests
#   BENCH_COUNT=500 pixi run bench    # custom count
#
# Requires: hyperfine, python3 with requests + httpx installed.

set -euo pipefail

cd "$(dirname "$0")/.."  # project root

PORT=18099
COUNT="${BENCH_COUNT:-200}"
URL="http://127.0.0.1:${PORT}/"
BENCH_DIR="$(pwd)/benchmark"
PY_REQ="${BENCH_DIR}/bench_python_requests.py"
PY_HTTPX="${BENCH_DIR}/bench_python_httpx.py"

echo "═══════════════════════════════════════════════════════════════"
echo "  mojo-requests benchmark  (${COUNT} requests per run)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# --- 1. Start a local HTTP server (stable, reproducible, no network variance) ---
echo "▶ Starting local HTTP server on :${PORT} ..."
# Use nohup + setsid to ensure the server survives subprocess transitions (pixi/hyperfine spawn children).
nohup python3 -m http.server "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1 &
SRV_PID=$!
trap 'kill ${SRV_PID} 2>/dev/null || true' EXIT

# Wait for the server to be ready (poll up to 5 seconds).
for i in $(seq 1 10); do
    if python3 -c "import urllib.request; urllib.request.urlopen('${URL}')" 2>/dev/null; then
        break
    fi
    sleep 0.5
    if [ "$i" -eq 10 ]; then
        echo "✗ Server did not start on :${PORT}"
        exit 1
    fi
done
echo "✓ Server ready (pid ${SRV_PID})"
echo ""

# --- 2. Pre-build the mojo binary (compile time NOT measured) ---
echo "▶ Building mojo benchmark binary (compile excluded from measurement) ..."
mojo build -I . "${BENCH_DIR}/bench_mojo_requests.mojo" -o "${BENCH_DIR}/bench_mojo_requests" 2>/dev/null
echo "✓ Binary built"

# Copy Python benchmarks to /tmp so they don't pick up the local requests/ Mojo package dir.
cp "${PY_REQ}" "${PY_HTTPX}" /tmp/
PY_REQ_TMP="/tmp/$(basename "${PY_REQ}")"
PY_HTTPX_TMP="/tmp/$(basename "${PY_HTTPX}")"
echo ""

# --- 3. Run hyperfine ---
export BENCH_URL="${URL}"
export BENCH_COUNT="${COUNT}"

echo "▶ Running hyperfine (warmup=3, runs=10) ..."
echo ""
# Python commands cd to /tmp first to avoid the local requests/ Mojo package dir shadowing pip's requests.
# Mojo commands run from project root (need -I . for package resolution).
hyperfine \
    --warmup 3 \
    --runs 10 \
    --export-markdown "${BENCH_DIR}/results.md" \
    --style basic \
    --command-name "python requests" \
        "cd /tmp && python3 '${PY_REQ_TMP}'" \
    --command-name "python httpx" \
        "cd /tmp && python3 '${PY_HTTPX_TMP}'" \
    --command-name "mojo (pre-built)" \
        "'${BENCH_DIR}/bench_mojo_requests'" \
    --command-name "mojo run (incl. compile)" \
        "cd '${BENCH_DIR}/..' && mojo -I . '${BENCH_DIR}/bench_mojo_requests.mojo'"

echo ""
echo "✓ Results exported to benchmark/results.md"
