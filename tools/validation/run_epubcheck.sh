#!/bin/sh
set -eu

EPUB="${1:-}"
if [ ! -f "$EPUB" ]; then
    printf 'usage: %s FILE.epub\n' "$0" >&2
    exit 2
fi

VERSION=5.3.0
EXPECTED=6c07e68584b2e2ce2f89fe06e1246dfead3eb36b46b340e7d93524f29dcff6c5
CACHE="${WEREADER_TOOL_CACHE:-/tmp/wereader-tools}"
ARCHIVE="$CACHE/epubcheck-$VERSION.zip"
DIR="$CACHE/epubcheck-$VERSION"
mkdir -p "$CACHE"

if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 \
        "https://github.com/w3c/epubcheck/releases/download/v$VERSION/epubcheck-$VERSION.zip" \
        -o "$ARCHIVE"
fi
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
fi
if [ "$actual" != "$EXPECTED" ]; then
    printf 'EPUBCheck archive checksum mismatch\n' >&2
    exit 3
fi
if [ ! -f "$DIR/epubcheck.jar" ]; then
    mkdir -p "$DIR"
    unzip -q -o "$ARCHIVE" -d "$CACHE"
fi
JAVA="${JAVA_CMD:-}"
if [ -z "$JAVA" ] && [ -x /opt/homebrew/opt/openjdk/bin/java ]; then
    JAVA=/opt/homebrew/opt/openjdk/bin/java
fi
if [ -z "$JAVA" ]; then JAVA="$(command -v java)"; fi
"$JAVA" -jar "$DIR/epubcheck.jar" "$EPUB"
