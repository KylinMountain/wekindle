#!/bin/sh
# Download and unpack all sources needed for the Kindle (armv7) build.
set -eu
. "$(dirname "$0")/xenv-kindle.sh"

SRC="$HOME/x-tools/src"
mkdir -p "$SRC"
cd "$SRC"

dl() {
    name="$1" url="$2" dir="$3"
    if [ -d "$dir" ]; then
        echo "== $name already present"
        return
    fi
    echo "== fetching $name"
    curl -fsSL "$url" -o "/tmp/$name.src"
    mkdir -p "$dir"
    tar -xf "/tmp/$name.src" -C "$dir" --strip-components=1
}

dl zlib      https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz                                   zlib-1.3.1
dl luajit    https://github.com/LuaJIT/LuaJIT/archive/refs/tags/v2.1.1753364724.tar.gz             LuaJIT-2.1
dl sqlite    https://www.sqlite.org/2025/sqlite-amalgamation-3500400.zip          sqlite-3.50.4
dl fbink     https://github.com/NiLuJe/FBInk/archive/refs/tags/v1.25.0.tar.gz     FBInk-1.25.0
dl mbedtls   https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v3.6.4.tar.gz  mbedtls-3.6.4
dl curl      https://curl.se/download/curl-8.15.0.tar.gz                          curl-8.15.0
dl freetype  https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz freetype-2.13.3
dl harfbuzz  https://github.com/harfbuzz/harfbuzz/releases/download/10.4.0/harfbuzz-10.4.0.tar.xz harfbuzz-10.4.0
dl fribidi   https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz fribidi-1.0.16
dl libpng    https://download.sourceforge.net/libpng/libpng-1.6.50.tar.xz         libpng-1.6.50
dl jpeg      https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.2/libjpeg-turbo-3.1.2.tar.gz libjpeg-turbo-3.1.2
dl zstd      https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz zstd-1.5.7
dl unibreak  https://github.com/adasiunas/libunibreak/archive/refs/tags/libunibreak_6_1.tar.gz  libunibreak-6.1
dl xxhash    https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz   xxHash-0.8.3

echo "== all sources ready in $SRC"
