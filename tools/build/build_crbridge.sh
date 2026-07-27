#!/bin/sh
# Build the crengine bridge (libcrbridge) with the KOReader crengine fork.
# Requires: cmake, ninja, and brew deps (freetype harfbuzz fribidi libpng
# jpeg-turbo zstd libunibreak fontconfig xxhash gettext).
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CR_SRC="$ROOT/third_party/src/koreader-crengine"
COOL_SRC="$ROOT/third_party/src/coolreader"

if [ ! -d "$CR_SRC" ]; then
    echo "cloning koreader/crengine..." >&2
    mkdir -p "$ROOT/third_party/src"
    git clone --depth 1 https://github.com/koreader/crengine.git "$CR_SRC" >&2
fi
if [ ! -d "$COOL_SRC" ]; then
    echo "cloning buggins/coolreader (for antiword/chmlib/nanosvg)..." >&2
    git clone --depth 1 https://github.com/buggins/coolreader.git "$COOL_SRC" >&2
fi

# antiword / chmlib are separate static libs used by wordfmt/chmfmt.
for lib in antiword chmlib; do
    if [ ! -f "$COOL_SRC/thirdparty_unman/$lib/build/lib$lib.a" ]; then
        cmake -G Ninja -S "$COOL_SRC/thirdparty_unman/$lib" \
            -B "$COOL_SRC/thirdparty_unman/$lib/build" \
            -DCMAKE_BUILD_TYPE=Release ${lib:+} > /dev/null
        if [ "$lib" = "antiword" ]; then
            cmake -G Ninja -S "$COOL_SRC/thirdparty_unman/$lib" \
                -B "$COOL_SRC/thirdparty_unman/$lib/build" \
                -DCMAKE_BUILD_TYPE=Release -DCR3_ANTIWORD_PATCH=1 > /dev/null
        fi
        cmake --build "$COOL_SRC/thirdparty_unman/$lib/build" > /dev/null
    fi
done

# antiword's misc.c ships a duplicate bReadBytes (its ANTIWORD_EXTERNAL_IO
# guard is commented out); hide it so crengine's stream-aware version wins.
if ! nm "$COOL_SRC/thirdparty_unman/antiword/build/libantiword.a" 2>/dev/null \
        | grep -q 'T _bReadBytes'; then
    :
else
    FIXDIR="$COOL_SRC/thirdparty_unman/antiword/build/objfix"
    mkdir -p "$FIXDIR"
    (cd "$FIXDIR" \
        && ar x ../libantiword.a misc.o \
        && ld -r misc.o -unexported_symbol _bReadBytes -o misc_fixed.o \
        && ar d ../libantiword.a misc.o \
        && ar r ../libantiword.a misc_fixed.o \
        && ranlib ../libantiword.a)
fi

cmake -G Ninja -S "$ROOT/reader/crengine_bridge" \
    -B "$ROOT/reader/crengine_bridge/build" \
    -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$ROOT/reader/crengine_bridge/build"

echo "built $ROOT/reader/crengine_bridge/build/libcrbridge.dylib"
