#!/bin/sh
# Execute the read-only capability probe over SSH without installing it.
# Usage:
#   tools/device/run_remote_probe.sh user@kindle [port] [output-file]
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE="$ROOT/tools/device/probe_device.sh"
TARGET="${1:-${KINDLE_SSH_TARGET:-}}"
PORT="${2:-${KINDLE_SSH_PORT:-22}}"
OUTPUT="${3:-}"

if [ -z "$TARGET" ]; then
    printf 'usage: %s user@kindle [port] [output-file]\n' "$0" >&2
    exit 2
fi

if [ ! -r "$PROBE" ]; then
    printf 'probe script not found: %s\n' "$PROBE" >&2
    exit 2
fi

if [ -n "$OUTPUT" ]; then
    ssh -p "$PORT" \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "$TARGET" 'sh -s' < "$PROBE" > "$OUTPUT"
    printf 'device report saved: %s\n' "$OUTPUT"
else
    ssh -p "$PORT" \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        "$TARGET" 'sh -s' < "$PROBE"
fi
