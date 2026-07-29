#!/bin/sh
# Build a content-free, redacted support bundle on the Kindle.
set -eu

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${WEREADER_DATA_DIR:-$(dirname "$APP_DIR")/wereader-data}"
OUTPUT="${1:-$DATA_DIR/diagnostics/wereader-diagnostics-$(date +%Y%m%d-%H%M%S).tar.gz}"
TMP="/var/tmp/wereader-diagnostics.$$"

case "$TMP" in /var/tmp/wereader-diagnostics.*) ;; *) exit 2 ;; esac
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$TMP" "$(dirname "$OUTPUT")"
if [ -x "$APP_DIR/tools/probe_device.sh" ]; then
    "$APP_DIR/tools/probe_device.sh" > "$TMP/probe.txt" 2>&1 || true
fi
if [ -f "$APP_DIR/version.json" ]; then
    cp "$APP_DIR/version.json" "$TMP/version.json"
fi
{
    printf 'collected_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
    printf 'free_space_kb=%s\n' "$(df -kP "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    printf 'app_processes=%s\n' "$(ps 2>/dev/null | awk '/[l]uajit.*wereader/ {count++} END {print count+0}')"
} > "$TMP/runtime.txt"

if [ -f "$DATA_DIR/logs/wereader.log" ]; then
    tail -n 500 "$DATA_DIR/logs/wereader.log" |
        "$APP_DIR/redact_stream.sh" > "$TMP/logs-redacted.txt"
fi
if [ -d "$DATA_DIR/crash" ]; then
    for crash in "$DATA_DIR"/crash/*.log; do
        [ -f "$crash" ] || continue
        tail -n 300 "$crash" |
            "$APP_DIR/redact_stream.sh" >> "$TMP/crashes-redacted.txt"
    done
fi

(cd "$TMP" && tar -czf "$OUTPUT" .)
printf 'diagnostics written: %s\n' "$OUTPUT"
