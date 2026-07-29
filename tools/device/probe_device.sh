#!/bin/sh
# Read-only Kindle capability probe.
#
# Run directly on a device:
#   sh probe_device.sh
#
# The report deliberately omits serial numbers, MAC addresses, IP addresses,
# credentials and user content. It is safe to attach to a bug report.
set -u

LC_ALL=C
export LC_ALL

sanitize() {
    printf '%s' "${1:-}" |
        tr '\r\n\t' '   ' |
        sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

emit() {
    probe_key=$1
    shift
    probe_value=$(sanitize "$*")
    printf '%s=%s\n' "$probe_key" "$probe_value"
}

has_command() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'yes'
    else
        printf 'no'
    fi
}

read_first() {
    for probe_path in "$@"; do
        if [ -r "$probe_path" ]; then
            head -n 1 "$probe_path" 2>/dev/null
            return 0
        fi
    done
    printf 'unavailable'
}

list_names() {
    probe_dir=$1
    if [ -d "$probe_dir" ]; then
        (
            cd "$probe_dir" 2>/dev/null || exit 0
            for probe_name in *; do
                [ "$probe_name" = "*" ] || printf '%s ' "$probe_name"
            done
        )
    else
        printf 'unavailable'
    fi
}

file_exists_any() {
    for probe_path in "$@"; do
        if [ -e "$probe_path" ]; then
            printf 'yes:%s' "$probe_path"
            return 0
        fi
    done
    printf 'no'
}

df_summary() {
    probe_mount=$1
    probe_df=$(df -kP "$probe_mount" 2>/dev/null | awk 'NR == 2 {
        print "total_kib:" $2 ";available_kib:" $4 ";mounted:" $6
    }')
    if [ -n "$probe_df" ]; then
        printf '%s' "$probe_df"
    else
        printf 'unavailable'
    fi
}

emit report.format "wereader-device-probe-v1"
emit report.privacy "serial-mac-ip-credentials-content-omitted"
emit report.time_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unavailable)"

emit os.uname "$(uname -a 2>/dev/null || printf unavailable)"
emit os.kernel "$(uname -r 2>/dev/null || printf unavailable)"
emit os.arch "$(uname -m 2>/dev/null || printf unavailable)"
emit os.pretty_version "$(read_first \
    /etc/prettyversion.txt \
    /etc/version.txt \
    /etc/os-release)"
emit device.model "$(read_first \
    /proc/device-tree/model \
    /sys/firmware/devicetree/base/model \
    /sys/devices/soc0/machine)"

if [ -r /proc/cpuinfo ]; then
    emit cpu.summary "$(awk -F: '
        /^(Hardware|Processor|model name|Features)[[:space:]]*:/ {
            key=$1; value=$2
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            if (value != "") printf "%s:%s; ", key, value
        }
    ' /proc/cpuinfo)"
else
    emit cpu.summary "unavailable"
fi

if [ -r /proc/meminfo ]; then
    emit memory.total_kib "$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
else
    emit memory.total_kib "unavailable"
fi

emit framebuffer.devices "$(list_names /sys/class/graphics)"
emit framebuffer.virtual_size "$(read_first /sys/class/graphics/fb0/virtual_size)"
emit framebuffer.bits_per_pixel "$(read_first /sys/class/graphics/fb0/bits_per_pixel)"
emit framebuffer.rotate "$(read_first /sys/class/graphics/fb0/rotate)"
emit framebuffer.epdc "$(file_exists_any \
    /sys/devices/platform/mxc_epdc_fb \
    /sys/devices/platform/epdc \
    /proc/driver/epdc)"

if [ -r /proc/bus/input/devices ]; then
    emit input.devices "$(awk '
        /^N: Name=/ || /^H: Handlers=/ {
            gsub(/"/, "", $0)
            printf "%s; ", $0
        }
    ' /proc/bus/input/devices)"
else
emit input.devices "unavailable"
fi

emit network.interfaces "$(list_names /sys/class/net)"
emit storage.root "$(df_summary /)"
emit storage.userstore "$(df_summary /mnt/us)"

emit capability.lipc_get "$(has_command lipc-get-prop)"
emit capability.lipc_set "$(has_command lipc-set-prop)"
emit capability.eips "$(has_command eips)"
emit capability.fbink_binary "$(has_command fbink)"
emit capability.fbink_library "$(file_exists_any \
    /usr/lib/libfbink.so \
    /usr/local/lib/libfbink.so \
    /mnt/us/lib/libfbink.so)"
emit capability.evtest "$(has_command evtest)"
emit capability.lua "$(has_command lua)"
emit capability.luajit "$(has_command luajit)"
emit capability.curl "$(has_command curl)"
emit capability.sqlite3 "$(has_command sqlite3)"
emit capability.tar "$(has_command tar)"
emit capability.unzip "$(has_command unzip)"
emit capability.sha256 "$(has_command sha256sum)"

emit kindle.kual "$(file_exists_any \
    /mnt/us/extensions \
    /mnt/us/extensions/KUAL \
    /mnt/us/documents/KUAL-KDK-2.0.azw2)"
emit kindle.mrpi "$(file_exists_any \
    /mnt/us/mrpackages \
    /mnt/us/extensions/MRInstaller)"
emit kindle.appreg "$(file_exists_any \
    /var/local/appreg.db \
    /var/local/appreg)"

if command -v lipc-get-prop >/dev/null 2>&1; then
    emit power.state "$(lipc-get-prop com.lab126.powerd state 2>/dev/null || printf unavailable)"
    emit power.prevent_suspend "$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null || printf unavailable)"
else
    emit power.state "unavailable"
    emit power.prevent_suspend "unavailable"
fi

emit report.complete "yes"
