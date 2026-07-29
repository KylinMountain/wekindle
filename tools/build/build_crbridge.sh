#!/bin/sh
# Build the crengine bridge (libcrbridge) with the KOReader crengine fork.
# Requires: cmake, ninja, pkg-config, freetype, harfbuzz, fribidi, libpng,
# libjpeg, zstd, libunibreak, fontconfig, xxhash and gettext/libintl.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK="$ROOT/third_party/dependencies.lock"
CR_SRC="$ROOT/third_party/src/koreader-crengine"
COOL_SRC="$ROOT/third_party/src/coolreader"

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
        mkdir -p "$ROOT/third_party/src"
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

ensure_checkout crengine "$CR_SRC"
ensure_checkout coolreader "$COOL_SRC"

# antiword / chmlib are separate static libs used by wordfmt/chmfmt.
for lib in antiword chmlib; do
    if [ ! -f "$COOL_SRC/thirdparty_unman/$lib/build/lib$lib.a" ]; then
        cmake -G Ninja -S "$COOL_SRC/thirdparty_unman/$lib" \
            -B "$COOL_SRC/thirdparty_unman/$lib/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON > /dev/null
        if [ "$lib" = "antiword" ]; then
            cmake -G Ninja -S "$COOL_SRC/thirdparty_unman/$lib" \
                -B "$COOL_SRC/thirdparty_unman/$lib/build" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                -DCR3_ANTIWORD_PATCH=1 \
                -DCMAKE_C_FLAGS=-DCR3_ANTIWORD_PATCH=1 > /dev/null
        fi
        cmake --build "$COOL_SRC/thirdparty_unman/$lib/build" > /dev/null
    fi
done

cmake -G Ninja -S "$ROOT/reader/crengine_bridge" \
    -B "$ROOT/reader/crengine_bridge/build" \
    -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$ROOT/reader/crengine_bridge/build"

printf 'built crengine bridge in %s\n' \
    "$ROOT/reader/crengine_bridge/build"
