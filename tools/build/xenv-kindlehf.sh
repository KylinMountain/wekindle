#!/bin/sh
# Cross-compile environment for Kindle HF (armv7 hard-float, koxtoolchain
# kindlehf sysroot + host clang/lld). Replaces xenv-kindle.sh.
XROOT="$HOME/x-tools/kindlehf/x-tools/arm-kindlehf-linux-gnueabihf"
export XROOT
export XSYSROOT="$XROOT/arm-kindlehf-linux-gnueabihf/sysroot"

XGCCVER="$(ls "$XROOT/lib/gcc/arm-kindlehf-linux-gnueabihf" | head -1)"
export XGCCDIR="$XROOT/lib/gcc/arm-kindlehf-linux-gnueabihf/$XGCCVER"
export XCXXINC="$XROOT/arm-kindlehf-linux-gnueabihf/include/c++/$XGCCVER;$XROOT/arm-kindlehf-linux-gnueabihf/include/c++/$XGCCVER/arm-kindlehf-linux-gnueabihf"

XLLVM="/opt/homebrew/opt/llvm/bin"
export XCC="$XLLVM/clang --target=arm-linux-gnueabihf --sysroot=$XSYSROOT -B$XGCCDIR -L$XGCCDIR"
export XCXX="$XLLVM/clang++ --target=arm-linux-gnueabihf --sysroot=$XSYSROOT -B$XGCCDIR -L$XGCCDIR"
