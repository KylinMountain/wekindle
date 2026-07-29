#!/bin/sh
# Cross-compile environment for Kindle (armv7 softfp, koxtoolchain sysroot
# + host clang/lld). Source this before building:  . tools/build/xenv-kindle.sh

XROOT="$HOME/x-tools/kindlepw2/x-tools/arm-kindlepw2-linux-gnueabi"
export XROOT
export XSYSROOT="$XROOT/arm-kindlepw2-linux-gnueabi/sysroot"

XLLVM="/opt/homebrew/opt/llvm/bin"
XLLD="/opt/homebrew/opt/lld/bin"

XTARGET="arm-linux-gnueabihf"
XFLAGS="--target=$XTARGET -mfloat-abi=softfp -mfpu=vfpv3 --sysroot=$XSYSROOT"

export XCC="$XLLVM/clang $XFLAGS"
export XCXX="$XLLVM/clang++ $XFLAGS"
export XAR="$XLLVM/llvm-ar"
export XRANLIB="$XLLVM/llvm-ranlib"
export XLD="--fuse-ld=lld"

# gcc runtime libs (libgcc, crt) live next to the toolchain gcc
XGCC_LIB="$XROOT/lib/gcc/arm-kindlepw2-linux-gnueabi"
if [ -d "$XGCC_LIB" ]; then
    XVER="$(ls "$XGCC_LIB" | head -1)"
    export XGCC_LIBDIR="$XGCC_LIB/$XVER"
fi

export CC_FOR_BUILD="/usr/bin/clang"
