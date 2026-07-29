#!/bin/sh
# Build the FBInk/LVGL Kindle host against pinned upstream revisions.
#
# Native Linux compile check:
#   tools/build/build_kindle_host.sh linux
#
# Kindle cross build (activate the desired koxtoolchain first):
#   tools/build/build_kindle_host.sh kindle-armv7
#   tools/build/build_kindle_host.sh kindle-aarch64
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/third_party/dependencies.lock"
SOURCE_ROOT="$ROOT/third_party/src"
TARGET="${1:-linux}"

lock_field() {
    awk -F '|' -v name="$1" '$1 == name { print $'"$2"'; exit }' "$LOCK"
}

ensure_checkout() {
    dependency_name=$1
    dependency_path=$2
    dependency_url=$(lock_field "$dependency_name" 2)
    dependency_commit=$(lock_field "$dependency_name" 3)
    if [ -z "$dependency_url" ] || [ -z "$dependency_commit" ]; then
        printf 'dependency missing from lock: %s\n' "$dependency_name" >&2
        exit 2
    fi
    if [ ! -d "$dependency_path/.git" ]; then
        mkdir -p "$SOURCE_ROOT"
        git clone --filter=blob:none --no-checkout \
            "$dependency_url" "$dependency_path"
        git -C "$dependency_path" fetch --depth 1 origin "$dependency_commit"
        git -C "$dependency_path" checkout --detach "$dependency_commit"
    fi
    dependency_actual=$(git -C "$dependency_path" rev-parse HEAD)
    if [ "$dependency_actual" != "$dependency_commit" ]; then
        printf '%s checkout mismatch\nexpected: %s\nactual:   %s\n' \
            "$dependency_name" "$dependency_commit" "$dependency_actual" >&2
        printf 'refusing to overwrite an existing dependency checkout\n' >&2
        exit 2
    fi
}

case "$TARGET" in
    linux)
        fbink_platform="LINUX=true"
        ;;
    kindle-armv7|kindle-aarch64)
        fbink_platform="KINDLE=true"
        if [ -z "${CC:-}" ] && [ -z "${CROSS_TC:-}" ] && [ -z "${CROSS_COMPILE:-}" ]; then
            printf 'activate a Kindle cross toolchain (CC, CROSS_TC or CROSS_COMPILE)\n' >&2
            exit 2
        fi
        ;;
    *)
        printf 'unsupported target: %s\n' "$TARGET" >&2
        exit 2
        ;;
esac

LVGL_SOURCE="$SOURCE_ROOT/lvgl"
FBINK_SOURCE="$SOURCE_ROOT/FBInk"
ensure_checkout LVGL "$LVGL_SOURCE"
ensure_checkout FBInk "$FBINK_SOURCE"

# FBInk's release target builds a stripped shared library. IMAGE support is
# retained because startup/exit restoration uses its dump API.
make -C "$FBINK_SOURCE" release "$fbink_platform"

FBINK_LIBRARY="$FBINK_SOURCE/Release/libfbink.so"
if [ ! -e "$FBINK_LIBRARY" ]; then
    printf 'FBInk build did not produce %s\n' "$FBINK_LIBRARY" >&2
    exit 2
fi

BUILD_DIR="$ROOT/platform/kindle/host/build/$TARGET"
cmake_args=""
if [ -n "${CC:-}" ]; then
    cmake_args="-DCMAKE_C_COMPILER=$CC"
fi

# shellcheck disable=SC2086
cmake -G Ninja \
    -S "$ROOT/platform/kindle/host" \
    -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLVGL_SOURCE_DIR="$LVGL_SOURCE" \
    -DFBINK_SOURCE_DIR="$FBINK_SOURCE" \
    -DFBINK_LIBRARY="$FBINK_LIBRARY" \
    $cmake_args
cmake --build "$BUILD_DIR"

printf 'built Kindle host for %s in %s\n' "$TARGET" "$BUILD_DIR"
