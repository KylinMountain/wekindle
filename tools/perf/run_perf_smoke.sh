#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULT="${1:-/tmp/wereader-performance.txt}"
START="$(python3 -c 'import time; print(time.monotonic())')"
luajit "$ROOT/apps/standalone/app.lua" --selftest
END="$(python3 -c 'import time; print(time.monotonic())')"
COLD_MS="$(python3 -c "print(round((${END} - ${START}) * 1000, 2))")"
{
    printf 'cold_start_selftest_ms=%s\n' "$COLD_MS"
    luajit "$ROOT/tools/perf/benchmark_reader.lua"
} > "$RESULT"
python3 - "$COLD_MS" <<'PY'
import sys
if float(sys.argv[1]) > 4000:
    raise SystemExit("cold startup exceeds 4000ms")
PY
cat "$RESULT"
