#!/bin/sh
# Assemble a standalone weread.koplugin directory that can be copied into
# koreader/plugins/ directly: plugin tree + weread-core modules merged in,
# so the result has no dependency on the monorepo ../../core/lua layout.
#
# Usage: tools/packaging/build_koreader_plugin.sh [output-dir]
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/dist}/weread.koplugin"

rm -rf "$OUT"
mkdir -p "$OUT/weread"

# Plugin-owned files (KOReader entry, UI, adapters, platform glue).
for item in main.lua _meta.lua LICENSE NOTICE; do
    cp "$ROOT/apps/koreader-plugin/$item" "$OUT/"
done
cp -R "$ROOT/apps/koreader-plugin/weread/." "$OUT/weread/"
if [ -d "$ROOT/apps/koreader-plugin/fonts" ]; then
    cp -R "$ROOT/apps/koreader-plugin/fonts" "$OUT/fonts"
fi

# weread-core modules: copied into the plugin tree so no ../../core path
# is needed at runtime. Plugin-side files win on name clash (there are
# none by construction; core and plugin module sets are disjoint).
cp -R "$ROOT/core/lua/weread/lib/." "$OUT/weread/lib/"

echo "built $OUT"
find "$OUT" -name '*.lua' | wc -l | tr -d ' ' | xargs -I{} echo "{} lua files"
