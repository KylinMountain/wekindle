#!/bin/sh
# Explicit release signing. The private key is never read from the repository.
set -eu

ARCHIVE="${1:-}"
SECRET_KEY="${2:-}"

if [ ! -f "$ARCHIVE" ] || [ ! -f "$SECRET_KEY" ]; then
    printf 'usage: %s ARCHIVE MINISIGN_SECRET_KEY\n' "$0" >&2
    exit 2
fi
if ! command -v minisign >/dev/null 2>&1; then
    printf 'minisign is required to sign releases\n' >&2
    exit 2
fi

minisign -S -s "$SECRET_KEY" -m "$ARCHIVE"
printf 'signed %s\n' "$ARCHIVE"
