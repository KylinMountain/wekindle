#!/bin/sh
# User-invoked, signed, hash-verified atomic update with one-version rollback.
set -eu

CURRENT="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(dirname "$CURRENT")"
ARCHIVE="${1:-}"
CHECKSUM="${2:-}"
SIGNATURE="${3:-}"
PUBLIC_KEY="${4:-$CURRENT/update-public.key}"
STAGING="$PARENT/.wereader-update.$$"
SHARED_DATA="${WEREADER_DATA_DIR:-$PARENT/wereader-data}"

for file in "$ARCHIVE" "$CHECKSUM" "$SIGNATURE" "$PUBLIC_KEY"; do
    if [ ! -f "$file" ]; then
        printf 'missing update input: %s\n' "$file" >&2
        exit 2
    fi
done
MINISIGN="$(command -v minisign 2>/dev/null || true)"
if [ -z "$MINISIGN" ] && [ -x "$CURRENT/bin/minisign" ]; then
    MINISIGN="$CURRENT/bin/minisign"
fi
if [ -z "$MINISIGN" ]; then
    printf 'minisign is required; update was not installed\n' >&2
    exit 2
fi

expected="$(awk 'NR==1 {print $1}' "$CHECKSUM")"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
else
    printf 'no SHA-256 implementation available; update was not installed\n' >&2
    exit 2
fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    printf 'update checksum mismatch\n' >&2
    exit 3
fi
"$MINISIGN" -V -p "$PUBLIC_KEY" -m "$ARCHIVE" -x "$SIGNATURE"

case "$STAGING" in "$PARENT"/.wereader-update.*) ;; *) exit 2 ;; esac
cleanup() {
    if [ -d "$STAGING" ]; then rm -rf "$STAGING"; fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$STAGING"
unzip -q "$ARCHIVE" -d "$STAGING"
NEW="$STAGING/wereader"
for required in launch.sh menu.json version.json bin/luajit; do
    if [ ! -e "$NEW/$required" ]; then
        printf 'invalid update: missing %s\n' "$required" >&2
        exit 3
    fi
done

mkdir -p "$SHARED_DATA/update-backups"
if [ -f "$SHARED_DATA/wereader.db" ]; then
    cp "$SHARED_DATA/wereader.db" \
        "$SHARED_DATA/update-backups/wereader.db.$(date +%Y%m%d-%H%M%S)"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
PREVIOUS="$PARENT/wereader.previous.$stamp"
mv "$CURRENT" "$PREVIOUS"
if ! mv "$NEW" "$CURRENT"; then
    mv "$PREVIOUS" "$CURRENT"
    printf 'update activation failed; previous version restored\n' >&2
    exit 4
fi
printf '%s\n' "$PREVIOUS" > "$CURRENT/.update-pending"
trap - EXIT HUP INT TERM
if [ -d "$STAGING" ]; then rm -rf "$STAGING"; fi
printf 'update installed; first successful launch will confirm it\n'
