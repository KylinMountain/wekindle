#!/bin/sh
# Assemble a deterministic KUAL extension from prebuilt target libraries.
#
# Required:
#   KINDLE_RUNTIME_DIR/bin/luajit
#   KINDLE_RUNTIME_DIR/lib/*.so*
#   KINDLE_HOST_BUILD_DIR/liblvgl.so
#   KINDLE_HOST_BUILD_DIR/libwereader_kindledisplay.so
#   KINDLE_FBINK_LIBRARY
#   KINDLE_CRBRIDGE_LIBRARY
#   KINDLE_FONT_FILE
#   WEREADER_UPDATE_PUBLIC_KEY
#   KINDLE_RUNTIME_DIR/bin/minisign
#   KINDLE_RUNTIME_DIR/share/runtime-dependencies.lock
#   KINDLE_RUNTIME_DIR/share/licenses/*
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ABI="${1:-}"
VERSION="${WEREADER_VERSION:-0.1.0-dev}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
MIN_FIRMWARE="${WEREADER_MIN_FIRMWARE:-5.10.0}"
SOURCE_REVISION="${WEREADER_SOURCE_REVISION:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)}"

case "$ABI" in
    kindle-armv7|kindle-aarch64) ;;
    *)
        printf 'usage: %s kindle-armv7|kindle-aarch64\n' "$0" >&2
        exit 2
        ;;
esac

require_file() {
    if [ ! -f "$1" ]; then
        printf 'required file missing: %s\n' "$1" >&2
        exit 2
    fi
}

RUNTIME="${KINDLE_RUNTIME_DIR:-}"
HOST_BUILD="${KINDLE_HOST_BUILD_DIR:-$ROOT/platform/kindle/host/build/$ABI}"
FBINK="${KINDLE_FBINK_LIBRARY:-}"
CRBRIDGE="${KINDLE_CRBRIDGE_LIBRARY:-}"
FONT="${KINDLE_FONT_FILE:-}"
UPDATE_PUBLIC_KEY="${WEREADER_UPDATE_PUBLIC_KEY:-}"
RUNTIME_LOCK="$RUNTIME/share/runtime-dependencies.lock"

require_file "$RUNTIME/bin/luajit"
require_file "$RUNTIME/bin/minisign"
require_file "$RUNTIME_LOCK"
require_file "$HOST_BUILD/liblvgl.so"
require_file "$HOST_BUILD/libwereader_kindledisplay.so"
require_file "$FBINK"
require_file "$CRBRIDGE"
require_file "$FONT"
require_file "$UPDATE_PUBLIC_KEY"
if [ ! -d "$RUNTIME/share/licenses" ] \
    || ! find "$RUNTIME/share/licenses" -type f -print -quit \
        | grep -q .; then
    printf 'runtime license bundle is missing: %s\n' \
        "$RUNTIME/share/licenses" >&2
    exit 2
fi

STAGE="$ROOT/dist/$ABI/wereader"
ARCHIVE="$ROOT/dist/wereader-$VERSION-$ABI.zip"
rm -rf "$STAGE"
mkdir -p \
    "$STAGE/app" \
    "$STAGE/bin" \
    "$STAGE/lib" \
    "$STAGE/share/fonts" \
    "$STAGE/share/licenses" \
    "$STAGE/tools"

cp "$ROOT/platform/kindle/package/menu.json" "$STAGE/menu.json"
cp "$ROOT/platform/kindle/package/launch.sh" "$STAGE/launch.sh"
cp "$ROOT/platform/kindle/package/update.sh" "$STAGE/update.sh"
cp "$ROOT/platform/kindle/package/redact_stream.sh" "$STAGE/redact_stream.sh"
cp "$ROOT/platform/kindle/package/collect_diagnostics.sh" \
    "$STAGE/collect_diagnostics.sh"
cp "$ROOT/tools/device/probe_device.sh" "$STAGE/tools/probe_device.sh"
cp "$RUNTIME/bin/luajit" "$STAGE/bin/luajit"
cp "$RUNTIME/bin/minisign" "$STAGE/bin/minisign"
cp "$UPDATE_PUBLIC_KEY" "$STAGE/update-public.key"
cp "$HOST_BUILD/liblvgl.so" "$STAGE/lib/liblvgl.so"
cp "$HOST_BUILD/libwereader_kindledisplay.so" \
    "$STAGE/lib/libwereader_kindledisplay.so"
cp "$FBINK" "$STAGE/lib/libfbink.so.1"
ln -s libfbink.so.1 "$STAGE/lib/libfbink.so"
cp "$CRBRIDGE" "$STAGE/lib/libcrbridge.so"
cp "$FONT" "$STAGE/share/fonts/NotoSansCJKsc-Regular.otf"

if [ -d "$RUNTIME/lib" ]; then
    find "$RUNTIME/lib" -maxdepth 1 -type f -name '*.so*' -exec cp {} "$STAGE/lib/" \;
fi

cp -R "$ROOT/core/lua/weread" "$STAGE/app/weread"
cp "$ROOT"/apps/standalone/*.lua "$STAGE/app/"
cp "$ROOT"/platform/standalone/*.lua "$STAGE/app/"
cp "$ROOT/platform/linux/lv.lua" "$STAGE/app/lv.lua"
cp "$ROOT/platform/linux/reader_bridge.lua" "$STAGE/app/reader_bridge.lua"
cp "$ROOT/platform/ui_backend.lua" "$STAGE/app/ui_backend.lua"
mkdir -p "$STAGE/app/kindle"
cp "$ROOT"/platform/kindle/*.lua "$STAGE/app/kindle/"
cp "$ROOT/third_party/dkjson.lua" "$STAGE/app/dkjson.lua"

cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/NOTICE" "$STAGE/NOTICE"
cp "$ROOT/third_party/dependencies.lock" "$STAGE/share/dependencies.lock"
cp "$RUNTIME_LOCK" "$STAGE/share/runtime-dependencies.lock"
cp -R "$RUNTIME/share/licenses/." "$STAGE/share/licenses/"
cp "$ROOT/apps/koreader-plugin/LICENSE" \
    "$STAGE/share/licenses/weread-koplugin-AGPL-3.0.txt"
python3 "$ROOT/tools/packaging/generate_release_metadata.py" \
    --lock "$ROOT/third_party/dependencies.lock" \
    --lock "$RUNTIME_LOCK" \
    --require-component LuaJIT \
    --require-component libcurl \
    --require-component SQLite \
    --require-component minisign \
    --require-component NotoSansCJK \
    --output-dir "$STAGE/share" \
    --version "$VERSION" \
    --abi "$ABI"

{
    printf '{\n'
    printf '  "name": "wereader",\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "abi": "%s",\n' "$ABI"
    printf '  "minimum_firmware": "%s",\n' "$MIN_FIRMWARE"
    printf '  "source_revision": "%s",\n' "$SOURCE_REVISION"
    printf '  "source_date_epoch": %s\n' "$SOURCE_DATE_EPOCH"
    printf '}\n'
} > "$STAGE/version.json"

chmod 755 \
    "$STAGE/launch.sh" \
    "$STAGE/update.sh" \
    "$STAGE/redact_stream.sh" \
    "$STAGE/collect_diagnostics.sh" \
    "$STAGE/tools/probe_device.sh" \
    "$STAGE/bin/luajit" \
    "$STAGE/bin/minisign"
find "$STAGE" -type f -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true

rm -f "$ARCHIVE"
python3 "$ROOT/tools/packaging/deterministic_zip.py" \
    "$STAGE" "$ARCHIVE" --epoch "$SOURCE_DATE_EPOCH"

if command -v sha256sum >/dev/null 2>&1; then
    archive_hash="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
else
    archive_hash="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
fi
printf '%s  %s\n' "$archive_hash" "$(basename "$ARCHIVE")" \
    > "$ARCHIVE.sha256"

printf 'built %s\n' "$ARCHIVE"
