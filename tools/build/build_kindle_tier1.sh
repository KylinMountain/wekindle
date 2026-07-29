#!/bin/sh
# Build tier-1 Kindle (armv7 softfp) libraries: zlib, LuaJIT, sqlite3, FBInk.
# Requires tools/build/xenv-kindle.sh environment.
set -eu
. "$(dirname "$0")/xenv-kindle.sh"

SRC="$HOME/x-tools/src"
STAGE="$HOME/x-tools/stage"
GCCDIR="$XROOT/lib/gcc/arm-kindlepw2-linux-gnueabi/14.2.0"
LLVM="/opt/homebrew/opt/llvm/bin"

xcc()  { "$LLVM/clang"   --target=arm-linux-gnueabihf -mfloat-abi=softfp -mfpu=vfpv3 --sysroot="$XSYSROOT" -B"$GCCDIR" -L"$GCCDIR" "$@"; }
xcxx() { "$LLVM/clang++" --target=arm-linux-gnueabihf -mfloat-abi=softfp -mfpu=vfpv3 --sysroot="$XSYSROOT" -B"$GCCDIR" -L"$GCCDIR" "$@"; }

# ---------------- zlib (static is fine) ----------------
if [ ! -f "$STAGE/lib/libz.a" ]; then
    echo "== zlib"
    cd "$SRC/zlib-1.3.1"
    # zlib's configure hardcodes the macOS libtool on Darwin; bypass it and
    # build the amalgamated objects directly.
    for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite \
             infback inffast inflate inftrees trees uncompr zutil; do
        xcc -O2 -fPIC -c "$f.c" -o "$f.o"
    done
    "$LLVM/llvm-ar" rcu "$STAGE/lib/libz.a" adler32.o compress.o crc32.o \
        deflate.o gzclose.o gzlib.o gzread.o gzwrite.o infback.o inffast.o \
        inflate.o inftrees.o trees.o uncompr.o zutil.o
    "$LLVM/llvm-ranlib" "$STAGE/lib/libz.a"
    cp zlib.h zconf.h "$STAGE/include/"
fi

# ---------------- LuaJIT ----------------
if [ ! -f "$STAGE/bin/luajit" ]; then
    echo "== luajit"
    cd "$SRC/LuaJIT-2.1"
    export MACOSX_DEPLOYMENT_TARGET=15.0
    make -j8 clean > /dev/null
    # host tools build for macOS, target for armv7
    make -j8 \
        HOST_CC="/usr/bin/clang" \
        CC="$LLVM/clang" \
        TARGET_CC="$LLVM/clang --target=arm-linux-gnueabihf -mfloat-abi=softfp -mfpu=vfpv3 --sysroot=$XSYSROOT" \
        TARGET_AR="$LLVM/llvm-ar rcus" \
        TARGET_RANLIB="$LLVM/llvm-ranlib" \
        TARGET_STRIP="echo" \
        TARGET_SYS=Linux \
        TARGET_CFLAGS="-B$GCCDIR" \
        TARGET_LDFLAGS="-B$GCCDIR -L$GCCDIR" \
        BUILDMODE=mixed \
        PREFIX="$STAGE" > /tmp/luajit-build.log 2>&1 || { tail -20 /tmp/luajit-build.log; exit 1; }
    cp src/luajit "$STAGE/bin/luajit"
    cp src/libluajit.a "$STAGE/lib/libluajit.a"
fi

# ---------------- sqlite3 ----------------
if [ ! -f "$STAGE/lib/libsqlite3.so" ]; then
    echo "== sqlite3"
    xcc -O2 -fPIC -shared \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 \
        "$SRC/sqlite-3.50.4/sqlite3.c" \
        -o "$STAGE/lib/libsqlite3.so" -lm
    cp "$SRC/sqlite-3.50.4/sqlite3.h" "$STAGE/include/"
fi

# ---------------- FBInk ----------------
if [ ! -f "$STAGE/lib/libfbink.so" ]; then
    echo "== fbink"
    cd "$SRC/FBInk-1.25.0"
    mkdir -p build
    xcc -O2 -fPIC -shared -DFBINK_FOR_KINDLE -DFBINK_WITH_IMAGE \
        -I. -Icutef8 \
        fbink.c cutef8/cutef8.c fbink_button_scan.c fbink_input_helpers.c \
        -o "$STAGE/lib/libfbink.so" \
        -lpthread 2> /tmp/fbink-build.log || { tail -20 /tmp/fbink-build.log; exit 1; }
    cp fbink.h "$STAGE/include/"
fi

echo "== tier1 done"
ls "$STAGE/bin" "$STAGE/lib"
