#!/bin/sh
# Host-independent compile-time API check for the Kindle bridge.
# FBINK_HEADER may point at the exact pinned fbink.h; the build script's
# checkout is used by default.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FBINK_HEADER="${FBINK_HEADER:-$ROOT/third_party/src/FBInk/fbink.h}"
LVGL_SOURCE="${LVGL_SOURCE_DIR:-$ROOT/third_party/src/lvgl}"

if [ ! -r "$FBINK_HEADER" ]; then
    printf 'SKIP Kindle host syntax: pinned fbink.h is not checked out\n'
    exit 0
fi
if [ ! -r "$LVGL_SOURCE/lvgl.h" ]; then
    printf 'SKIP Kindle host syntax: pinned LVGL is not checked out\n'
    exit 0
fi

HEADER_DIR=$(dirname "$FBINK_HEADER")
"${CC:-cc}" -std=c11 -fsyntax-only \
    -D_GNU_SOURCE \
    -DLV_CONF_INCLUDE_SIMPLE \
    -I"$ROOT/tests/native_stubs" \
    -I"$ROOT/platform/kindle/host" \
    -I"$HEADER_DIR" \
    -I"$LVGL_SOURCE" \
    -I"$LVGL_SOURCE/src" \
    "$ROOT/platform/kindle/host/kindle_host.c"

printf 'Kindle host syntax: OK\n'
