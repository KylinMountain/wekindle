#!/bin/sh
# Rebuild every native lib for Kindle HF (armv7 hard-float).
set -eu
. "$(dirname "$0")/xenv-kindlehf.sh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

SRC="$HOME/x-tools/src"
STAGE="$HOME/x-tools/stage-hf"
KRLIBS="$HOME/x-tools/koreader-libs"
LLVM="/opt/homebrew/opt/llvm/bin"
mkdir -p "$STAGE"

xcc()  { "$LLVM/clang"   --target=arm-linux-gnueabihf --sysroot="$XSYSROOT" -B"$XGCCDIR" -L"$XGCCDIR" "$@"; }
xcxx() { "$LLVM/clang++" --target=arm-linux-gnueabihf --sysroot="$XSYSROOT" -B"$XGCCDIR" -L"$XGCCDIR" "$@"; }
xcmake() {
    src_dir="$1" build_dir="$2"
    shift 2
    rm -rf "$build_dir"
    cmake -G Ninja -S "$src_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
        -DCMAKE_OSX_ARCHITECTURES= -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_COMPILER="$LLVM/clang" -DCMAKE_CXX_COMPILER="$LLVM/clang++" \
        -DCMAKE_C_FLAGS="--target=arm-linux-gnueabihf --sysroot=$XSYSROOT -B$XGCCDIR -L$XGCCDIR" \
        -DCMAKE_CXX_FLAGS="--target=arm-linux-gnueabihf --sysroot=$XSYSROOT -B$XGCCDIR -L$XGCCDIR" \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
        "$@"
}

# ---------------- zlib ----------------
echo "== zlib"
mkdir -p "$STAGE/lib" "$STAGE/include"
cd "$SRC/zlib-1.3.1"
for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite \
         infback inffast inflate inftrees trees uncompr zutil; do
    xcc -O2 -fPIC -c "$f.c" -o "$f.o"
done
"$LLVM/llvm-ar" rcu "$STAGE/lib/libz.a" adler32.o compress.o crc32.o \
    deflate.o gzclose.o gzlib.o gzread.o gzwrite.o infback.o inffast.o \
    inflate.o inftrees.o trees.o uncompr.o zutil.o
"$LLVM/llvm-ranlib" "$STAGE/lib/libz.a"
cp zlib.h zconf.h "$STAGE/include/"

# ---------------- curl ----------------
if [ ! -f "$STAGE/lib/libcurl.so" ]; then
    echo "== curl"
    cd "$SRC/curl-8.15.0"
    xcmake . build-hf \
        -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
        -DCURL_USE_OPENSSL=ON -DOPENSSL_INCLUDE_DIR="$SRC/openssl-3.0.18/include" \
        -DOPENSSL_SSL_LIBRARY="$KRLIBS/libssl.so.60" -DOPENSSL_CRYPTO_LIBRARY="$KRLIBS/libcrypto.so.57" \
        -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
        -DUSE_NGHTTP2=OFF -DUSE_NGTCP2=OFF -DUSE_QUICHE=OFF \
        -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON \
        -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_TELNET=ON \
        -DCURL_DISABLE_TFTP=ON -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_IMAP=ON \
        -DCURL_DISABLE_SMB=ON -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_GOPHER=ON \
        -DCURL_DISABLE_MQTT=ON -DCURL_DISABLE_MANUAL=ON \
        -DCURL_ZLIB=ON -DZLIB_INCLUDE_DIR="$STAGE/include" -DZLIB_LIBRARY="$STAGE/lib/libz.a" \
        -DCMAKE_INSTALL_PREFIX="$STAGE"
    cmake --build build-hf -j8 > /dev/null
    cmake --install build-hf > /dev/null
fi

# ---------------- FBInk ----------------
echo "== fbink"
cd "$SRC/FBInk-master"
xcc -O2 -fPIC -shared -fuse-ld=lld -DFBINK_FOR_KINDLE -DFBINK_MINIMAL -I. \
    fbink.c -o "$STAGE/lib/libfbink.so"
cp fbink.h "$STAGE/include/"

# ---------------- LVGL + Kindle host ----------------
echo "== lvgl + kindledisplay"
xcmake "$REPO/platform/kindle/host" /tmp/lvgl-khf-build \
    -DLVGL_SOURCE_DIR="$REPO/third_party/src/lvgl" \
    -DFBINK_SOURCE_DIR="$SRC/FBInk-master" \
    -DFBINK_LIBRARY="$STAGE/lib/libfbink.so" \
    -DFREETYPE_INCLUDE_DIR_freetype2="$SRC/freetype-2.13.3/include" \
    -DFREETYPE_INCLUDE_DIR_ft2build="$SRC/freetype-2.13.3/include" \
    -DFREETYPE_LIBRARY="$KRLIBS/libfreetype.so.6" \
    -DWEREADER_JPEG_INCLUDE="$SRC/libjpeg-turbo-3.1.2" \
    -DWEREADER_JPEG_LIBRARY="$KRLIBS/libjpeg.so.8"
cmake --build /tmp/lvgl-khf-build -j8 > /dev/null
cp /tmp/lvgl-khf-build/liblvgl.so "$STAGE/lib/"
cp /tmp/lvgl-khf-build/libwereader_kindledisplay.so "$STAGE/lib/"

# ---------------- antiword + chmlib ----------------
TP="$REPO/third_party/src/coolreader/thirdparty_unman"
if [ ! -f /tmp/antiword-hf-build/libantiword.a ]; then
    echo "== antiword"
    xcmake "$TP/antiword" /tmp/antiword-hf-build -DCR3_ANTIWORD_PATCH=1
    cmake --build /tmp/antiword-hf-build -j8 > /dev/null
    cd /tmp/antiword-hf-build
    mkdir -p objfix && cd objfix
    "$LLVM/llvm-ar" x ../libantiword.a misc.o
    "$LLVM/llvm-objcopy" --localize-symbol=bReadBytes misc.o misc_fixed.o
    "$LLVM/llvm-ar" d ../libantiword.a misc.o
    "$LLVM/llvm-ar" r ../libantiword.a misc_fixed.o
fi
if [ ! -f /tmp/chmlib-hf-build/libchmlib.a ]; then
    echo "== chmlib"
    xcmake "$TP/chmlib" /tmp/chmlib-hf-build
    cmake --build /tmp/chmlib-hf-build -j8 > /dev/null
fi

# ---------------- crbridge ----------------
echo "== crbridge"
KDINC="$XCXXINC;$SRC/freetype-2.13.3/include;$SRC/harfbuzz-10.4.0/src;$SRC/fribidi-1.0.16/lib;$SRC/libpng-1.6.50;$SRC/libjpeg-turbo-3.1.2;$SRC/zstd-1.5.7/lib;/opt/homebrew/opt/libunibreak/include;/opt/homebrew/opt/xxhash/include;$SRC/zlib-1.3.1"
xcmake "$REPO/reader/crengine_bridge" /tmp/crbridge-hf-build \
    -DWEREADER_KINDLE_LIBS="$KRLIBS" \
    -DWEREADER_KINDLE_DEPS_INC="$KDINC"
# swap in the hf static libs at the paths the CMakeLists expects
TPU="$REPO/third_party/src/coolreader/thirdparty_unman"
cp /tmp/antiword-hf-build/libantiword.a "$TPU/antiword/build/libantiword.a"
cp /tmp/chmlib-hf-build/libchmlib.a "$TPU/chmlib/build/libchmlib.a"
cmake --build /tmp/crbridge-hf-build -j8 > /dev/null
cp /tmp/crbridge-hf-build/libcrbridge.so "$STAGE/lib/"

echo "== all hf libs built"
ls "$STAGE/lib"
