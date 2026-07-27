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

# Poll until the stub accepts connections (fixed sleep is flaky on slow CI).
ready=0
for _i in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1', $PORT)); s.close()" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "stub server did not start on port $PORT" >&2
    exit 1
fi

luajit "$ROOT/tools/smoke/smoke_stack.lua" "$PORT"
