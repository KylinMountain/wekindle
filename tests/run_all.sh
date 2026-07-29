#!/bin/sh
# Run all weread-core unit tests. No KOReader environment required.
# Usage: tests/run_all.sh [lua-binary]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUA="${1:-luajit}"

export LUA_PATH="$ROOT/core/lua/?.lua;$ROOT/apps/standalone/?.lua;$ROOT/platform/mock/?.lua;$ROOT/platform/standalone/?.lua;$ROOT/platform/linux/?.lua;$ROOT/platform/?.lua;$ROOT/third_party/?.lua;$ROOT/apps/koreader-plugin/?.lua;;"

pass=0
fail=0
for f in "$ROOT"/tests/spec/*_spec.lua; do
    out=$(cd "$ROOT" && "$LUA" "$f" 2>&1)
    code=$?
    if [ $code -eq 0 ]; then
        pass=$((pass + 1))
        printf 'PASS %s — %s\n' "$(basename "$f")" "$(printf '%s\n' "$out" | tail -1)"
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n%s\n' "$(basename "$f")" "$out"
    fi
done

printf '== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
