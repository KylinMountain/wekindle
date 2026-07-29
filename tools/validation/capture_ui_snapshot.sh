#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="${1:-/tmp/wereader-standalone-selftest.ppm}"
luajit "$ROOT/apps/standalone/app.lua" --selftest --snapshot "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if not data.startswith(b"P5\n600 800\n255\n"):
    raise SystemExit("unexpected snapshot format or dimensions")
if len(data) != len(b"P5\n600 800\n255\n") + 600 * 800:
    raise SystemExit("truncated snapshot")
print(f"snapshot={path}")
print(f"sha256={hashlib.sha256(data).hexdigest()}")
PY
