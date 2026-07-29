#!/bin/sh
# Build the remaining Kindle (armv7 softfp) natives that KOReader does not
# provide: mbedtls + curl, LVGL, the crengine bridge, and the Kindle host.
# crengine deps come from ~/x-tools/koreader-libs (pulled off the device).
set -eu
. "$(dirname "$0")/xenv-kindle.sh"

SRC="$HOME/x-tools/src"
STAGE="$HOME/x-tools/stage"
KRLIBS="$HOME/x-tools/koreader-libs"
GCCDIR="$XROOT/lib/gcc/arm-kindlepw2-linux-gnueabi/14.2.0"
LLVM="/opt/homebrew/opt/llvm/bin"

XCFLAGS="--target=arm-linux-gnueabihf -mfloat-abi=softfp -mfpu=vfpv3 --sysroot=$XSYSROOT -B$GCCDIR -L$GCCDIR"

# ---------------- OpenSSL headers (link against KOReader's libssl/libcrypto) ---
OSSL_INC="$SRC/openssl-3.0.18/include"
# several headers are generated at configure time upstream; ship the
# pre-generated variants from the tarball's include tree
if [ ! -d "$OSSL_INC/openssl" ]; then
    echo "== openssl headers missing"
    exit 1
fi

# ---------------- curl ----------------
if [ ! -f "$STAGE/lib/libcurl.so" ]; then
    echo "== curl"
    cd "$SRC/curl-8.15.0"
    rm -rf build-cmake
    cmake -G Ninja -S . -B build-cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_OSX_ARCHITECTURES= -DCMAKE_C_COMPILER="$LLVM/clang" \
        -DCMAKE_C_FLAGS="$XCFLAGS -I$STAGE/include" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -L$STAGE/lib" \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -L$STAGE/lib" \
        -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
        -DCURL_USE_OPENSSL=ON -DOPENSSL_INCLUDE_DIR="$OSSL_INC" \
        -DOPENSSL_SSL_LIBRARY="$KRLIBS/libssl.so.60" -DOPENSSL_CRYPTO_LIBRARY="$KRLIBS/libcrypto.so.57" \
        -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
        -DUSE_NGHTTP2=OFF -DUSE_NGTCP2=OFF -DUSE_QUICHE=OFF \
        -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON \
        -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_TELNET=ON \
        -DCURL_DISABLE_TFTP=ON -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_IMAP=ON \
        -DCURL_DISABLE_SMB=ON -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_GOPHER=ON \
        -DCURL_DISABLE_MQTT=ON -DCURL_DISABLE_DOCS=ON -DCURL_DISABLE_MANUAL=ON \
        -DCURL_ZLIB=ON -DZLIB_INCLUDE_DIR="$STAGE/include" -DZLIB_LIBRARY="$STAGE/lib/libz.a" \
        -DCMAKE_INSTALL_PREFIX="$STAGE" > /tmp/curl-conf.log
    cmake --build build-cmake -j8 > /dev/null
    cmake --install build-cmake > /dev/null
fi

# ---------------- LVGL ----------------
if [ ! -f "$STAGE/lib/liblvgl.so" ]; then
    echo "== lvgl"
    rm -rf /tmp/lvgl-kindle-build
    cmake -G Ninja -S platform/linux/lvgl_build -B /tmp/lvgl-kindle-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_OSX_ARCHITECTURES= -DCMAKE_C_COMPILER="$LLVM/clang" \
        -DCMAKE_C_FLAGS="$XCFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
        > /tmp/lvgl-conf.log
    cmake --build /tmp/lvgl-kindle-build -j8 > /dev/null
    cp /tmp/lvgl-kindle-build/liblvgl.so "$STAGE/lib/liblvgl.so" 2>/dev/null \
        || cp /tmp/lvgl-kindle-build/liblvgl.dylib "$STAGE/lib/liblvgl.so"
fi

# ---------------- crengine bridge ----------------
if [ ! -f "$STAGE/lib/libcrbridge.so" ]; then
    echo "== crbridge"
    rm -rf /tmp/crbridge-kindle-build
    cmake -G Ninja -S reader/crengine_bridge -B /tmp/crbridge-kindle-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_OSX_ARCHITECTURES= -DCMAKE_C_COMPILER="$LLVM/clang" \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm -DCMAKE_OSX_ARCHITECTURES= -DCMAKE_CXX_COMPILER="$LLVM/clang++" \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
        -DCMAKE_C_FLAGS="$XCFLAGS" -DCMAKE_CXX_FLAGS="$XCFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -L$KRLIBS -L$STAGE/lib" \
        -DWEREADER_KINDLE_LIBS="$KRLIBS" \
        > /tmp/crbridge-conf.log
    cmake --build /tmp/crbridge-kindle-build -j8 > /dev/null
    cp /tmp/crbridge-kindle-build/libcrbridge.so "$STAGE/lib/libcrbridge.so" 2>/dev/null \
        || cp /tmp/crbridge-kindle-build/libcrbridge.dylib "$STAGE/lib/libcrbridge.so"
fi

echo "== kindle tier done"
ls "$STAGE/lib"
