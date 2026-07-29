#!/bin/sh
# KUAL entry point. Business logic stays in Lua; this script owns only the
# Kindle process/framework lifecycle and must restore system state on every exit.
set -u

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSIONS_DIR="$(dirname "$APP_DIR")"
DEFAULT_DATA_DIR="$EXTENSIONS_DIR/wereader-data"
if [ -z "${WEREADER_DATA_DIR:-}" ] && [ -d "$APP_DIR/data" ] \
    && [ ! -e "$DEFAULT_DATA_DIR" ]; then
    # One-time migration from early packages that kept mutable data inside the
    # application directory. Future binary updates never touch this directory.
    mv "$APP_DIR/data" "$DEFAULT_DATA_DIR"
fi
DATA_DIR="${WEREADER_DATA_DIR:-$DEFAULT_DATA_DIR}"
LOG_DIR="$DATA_DIR/logs"
CRASH_DIR="$DATA_DIR/crash"
LOCK_DIR="/var/tmp/wereader-launch.lock"
FRAMEWORK_STOPPED=no
EXIT_CODE=0

mkdir -p "$LOG_DIR" "$CRASH_DIR" "$DATA_DIR/cache" "$DATA_DIR/exports"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if command -v eips >/dev/null 2>&1; then
        eips 2 2 "Wereader 已经在运行"
    fi
    exit 3
fi

restore_system() {
    cleanup_code=$?
    trap - EXIT HUP INT TERM

    # A failed Lua/native task must never leave the device unable to sleep.
    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || true
    fi

    if [ "$FRAMEWORK_STOPPED" = yes ]; then
        if [ -x /etc/init.d/framework ]; then
            (cd / && /etc/init.d/framework start) >/dev/null 2>&1 || true
        elif command -v start >/dev/null 2>&1; then
            (cd / && start lab126_gui) >/dev/null 2>&1 || true
        fi
    fi

    if command -v lipc-set-prop >/dev/null 2>&1; then
        lipc-set-prop com.lab126.appmgrd start \
            app://com.lab126.booklet.home >/dev/null 2>&1 || true
    fi
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
    exit "$cleanup_code"
}
trap restore_system EXIT HUP INT TERM

# Stop the stock UI while we own the raw framebuffer and evdev touchscreen.
# Upstart may propagate TERM to the KUAL child, hence the temporary ignore.
if [ "${WEREADER_KEEP_FRAMEWORK:-0}" != "1" ]; then
    trap '' TERM
    if [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework stop >/dev/null 2>&1
        FRAMEWORK_STOPPED=yes
    elif command -v stop >/dev/null 2>&1; then
        stop lab126_gui >/dev/null 2>&1
        FRAMEWORK_STOPPED=yes
    fi
    trap restore_system EXIT HUP INT TERM
fi

if [ -f "$LOG_DIR/wereader.log" ]; then
    log_size=$(wc -c < "$LOG_DIR/wereader.log" 2>/dev/null || printf 0)
    if [ "${log_size:-0}" -gt 1048576 ]; then
        mv "$LOG_DIR/wereader.log" "$LOG_DIR/wereader.previous.log"
    fi
fi

export WEREADER_PLATFORM=kindle
export WEREADER_DATA_DIR="$DATA_DIR"
export LD_LIBRARY_PATH="$APP_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LVGL_PATH="$APP_DIR/lib/liblvgl.so"
export WEREADER_KINDLE_HOST_PATH="$APP_DIR/lib/libwereader_kindledisplay.so"
export CRBRIDGE_PATH="$APP_DIR/lib/libcrbridge.so"
export CURL_TRANSPORT_PATH="$APP_DIR/lib/libcurl.so"
export CURL_CA_BUNDLE="/etc/ssl/certs/ca-certificates-prod.crt"
export CR_FONT_DIR="$APP_DIR/share/fonts"
export CR_FONT_PATH="$APP_DIR/share/fonts/NotoSansCJKsc-Regular.otf"

# -joff: LuaJIT's JIT-compiled code segfaults on this armv7 build (crash PC
# lands in the anonymous mcode area, faulting on small offsets like 0x31).
# The heavy lifting is all in C (LVGL/crengine/libjpeg/libcurl), so running
# the interpreter costs nothing measurable and is stable.
ulimit -c unlimited 2>/dev/null || true
"$APP_DIR/bin/luajit" -joff "$APP_DIR/app/app.lua" \
    >> "$LOG_DIR/wereader.log" 2>&1 || EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf unknown)
    {
        printf 'exit_code=%s\n' "$EXIT_CODE"
        printf 'time=%s\n' "$timestamp"
        printf 'firmware=%s\n' "$(head -n 1 /etc/prettyversion.txt 2>/dev/null || printf unknown)"
        printf 'arch=%s\n' "$(uname -m 2>/dev/null || printf unknown)"
        if [ -x "$APP_DIR/redact_stream.sh" ]; then
            tail -n 200 "$LOG_DIR/wereader.log" 2>/dev/null |
                "$APP_DIR/redact_stream.sh"
        else
            printf '[log omitted: redactor unavailable]\n'
        fi
    } > "$CRASH_DIR/crash-$timestamp.log"
fi

if [ -f "$APP_DIR/.update-pending" ]; then
    if [ "$EXIT_CODE" -eq 0 ]; then
        rm -f "$APP_DIR/.update-pending"
    else
        previous="$(head -n 1 "$APP_DIR/.update-pending" 2>/dev/null || true)"
        case "$previous" in
            "$EXTENSIONS_DIR"/wereader.previous.*)
                failed="$EXTENSIONS_DIR/wereader.failed.$timestamp"
                if mv "$APP_DIR" "$failed" && mv "$previous" "$APP_DIR"; then
                    printf 'first launch failed; rolled back to %s\n' \
                        "$previous" >> "$LOG_DIR/wereader.log"
                fi
                ;;
        esac
    fi
fi

exit "$EXIT_CODE"
