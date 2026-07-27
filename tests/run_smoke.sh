#!/bin/sh
# Run the standalone-stack smoke test: local stub server + real libcurl +
# real SQLite + real weread-core. No WeRead account required.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${WEREADER_SMOKE_PORT:-8321}"

export LUA_PATH="$ROOT/core/lua/?.lua;$ROOT/platform/standalone/?.lua;$ROOT/third_party/?.lua;;"

python3 "$ROOT/tools/smoke/stub_server.py" "$PORT" &
STUB_PID=$!
trap 'kill $STUB_PID 2>/dev/null' EXIT
sleep 1

luajit "$ROOT/tools/smoke/smoke_stack.lua" "$PORT"
