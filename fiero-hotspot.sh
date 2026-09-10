#!/bin/bash
#
# Fiero Hotspot - Automated Wi-Fi repeater daemon for Linux
# Copyright (C) 2026 Fiero
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

set -u

# Static PATH: root must never resolve binaries from caller-controlled dirs
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

SHUTDOWN_LOCK="/run/fiero-shutting-down.lock"

CONFIG_FILE="/etc/fiero-hotspot.conf"

# --- Logging Setup ---
log() {
    local level="$1"
    shift
    if [ "$level" = "ERR" ]; then
        echo "[$level] $*" >&2
    else
        echo "[$level] $*"
    fi
}

notify() {
    local msg="$1"
    if [ -z "${TARGET_USER:-}" ] || [ -z "${TARGET_UID:-}" ]; then
        echo "[ERR] /etc/fiero-hotspot.conf is missing TARGET_USER or TARGET_UID." >&2
        exit 1
    fi
    sudo -u "$TARGET_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        /usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "$msg" --icon=network-wireless 2>/dev/null || true
}

for cmd in iw pgrep pkill create_ap nmcli; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERR" "Required command not found: $cmd. Run install.sh first."
        exit 1
    fi
done

if [ -f "$CONFIG_FILE" ]; then
    conf_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
    conf_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    if [ "$conf_owner" != "root" ] || { [ "$conf_perms" != "640" ] && [ "$conf_perms" != "600" ]; }; then
        log "ERR" "Config file $CONFIG_FILE has unsafe permissions ($conf_perms, owner=$conf_owner). Expected 600 or 640 root:*. Refusing to source."
        exit 1
    fi
    source "$CONFIG_FILE"
else
    log "ERR" "Config file not found at $CONFIG_FILE. Run install.sh first."
    exit 1
fi

if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ] || [ -z "${INTERFACE:-}" ]; then
    log "ERR" "Config file is missing required values (SSID, PASSWORD, INTERFACE)."
    exit 1
fi

# --- v0.3 Backward Compatibility Check ---
if [ -z "${SUPPORTED_CHANNELS:-}" ]; then
    log "WARN" "SUPPORTED_CHANNELS not found in config. Was install.sh v0.3 run? Using safe defaults."
    SUPPORTED_CHANNELS="1,2,3,4,5,6,7,8,9,10,11,36,40,44,48"
fi

CREATE_AP_PID=""

cleanup() {
    if [ "${SKIP_CLEANUP:-0}" = "1" ]; then
        return 0
    fi
    create_ap --stop "$INTERFACE" 2>/dev/null || true
    if [ -n "$CREATE_AP_PID" ]; then
        kill "$CREATE_AP_PID" 2>/dev/null || true
    fi
    local escaped_if
    escaped_if=$(printf '%s' "$INTERFACE" | sed 's/[.[\*^$()+?{|]/\\&/g')
    pkill -f "create_ap.*$escaped_if" 2>/dev/null || true
    for dev in $(iw dev 2>/dev/null | awk '$1=="Interface" && $2 ~ /^ap[0-9]+/ {print $2}'); do
		ip link set dev "$dev" down 2>/dev/null || true
        iw dev "$dev" del 2>/dev/null || true
        ip link delete "$dev" 2>/dev/null || true
    done
    # Note: Deliberately skipping p2p-dev-$INTERFACE deletion to prevent iwlwifi firmware crashes
    find /tmp -maxdepth 1 -name "create_ap*" -uid 0 ! -type l -exec rm -rf {} + 2>/dev/null || true
}
# trap fires on normal exit and on SIGINT/SIGTERM; cleanup is idempotent
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 0' TERM

detect_channel() {
    CHANNEL=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2; exit}')
    [ -n "$CHANNEL" ]
}

start_hotspot() {
    exec 9>/run/fiero-hotspot.lock
    flock -n 9 || { log "INFO" "Another instance is running. Exiting."; SKIP_CLEANUP=1; exit 0; }

    if pgrep -x create_ap >/dev/null && iw dev | grep -qE '^\s*Interface ap[0-9]'; then
        log "INFO" "Hotspot already running. Skipping."
        SKIP_CLEANUP=1
        exit 0
    fi

    log "INFO" "Starting hotspot process..."

    if ! detect_channel; then
        log "ERR" "Could not detect WiFi channel on $INTERFACE. Aborting."
        notify "Hotspot could not start: no upstream Wi-Fi detected"
        exit 0
    fi

    if [[ ",$SUPPORTED_CHANNELS," != *",$CHANNEL,"* ]]; then
        log "ERR" "Channel $CHANNEL is not supported for AP broadcast on this hardware. Aborting."
        notify "Hotspot could not start: Channel $CHANNEL is unsupported"
        exit 0
    fi

    log "INFO" "Cleaning up stale create_ap and virtual interfaces..."
    cleanup

    notify "Starting hotspot on channel $CHANNEL..."

    log "INFO" "Launching create_ap in background..."
    create_ap "$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD" -c "$CHANNEL" &
    CREATE_AP_PID=$!

    for ((attempt = 1; attempt <= 8; attempt++)); do
        if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
            break
        fi
        if iw dev 2>/dev/null | grep -qE '^\s*Interface ap[0-9]+' && pgrep -f "hostapd.*/tmp/create_ap" >/dev/null; then
            log "INFO" "create_ap is live (pid $CREATE_AP_PID, AP interface up)."
            notify "Hotspot is live! SSID: $SSID"
            local drop_counter=0
            local max_drops=3
            rm -f "$SHUTDOWN_LOCK"
            while true; do
                if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
					if [ -f "$SHUTDOWN_LOCK" ]; then
						rm -f "$SHUTDOWN_LOCK"
						break
					fi
					log "ERR" "create_ap process exited unexpectedly. Shutting down hotspot."
					notify "Hotspot stopped: create_ap process exited"
					break
				fi

                if iw dev "$INTERFACE" link 2>/dev/null | grep -q "Connected to"; then
                    drop_counter=0
                else
                    drop_counter=$((drop_counter + 1))
                    if [ "$drop_counter" -ge "$max_drops" ]; then
                        log "ERR" "Upstream Wi-Fi disconnected permanently. Shutting down hotspot."
                        notify "Hotspot stopped: upstream Wi-Fi disconnected"
                        break
                    fi
                fi

                sleep 2
            done
            cleanup
            return 0
        fi
        sleep 1
    done

    log "ERR" "create_ap failed to start (pid $CREATE_AP_PID, no AP interface within 8s)."
    cleanup
    exit 1
}

stop_hotspot() {
	touch "$SHUTDOWN_LOCK"
    log "INFO" "Stopping hotspot..."
    local ac_connected=0
    for supply in /sys/class/power_supply/*; do
        if [ -f "$supply/type" ] && grep -q "^Mains$" "$supply/type" \
            && [ "$(cat "$supply/online" 2>/dev/null)" = "1" ]; then
            ac_connected=1
            break
        fi
    done
    if [ "$ac_connected" -eq 1 ]; then
        notify "Hotspot stopped manually"
    else
        notify "Hotspot stopped (charger unplugged)"
    fi
    # Teardown is handled automatically by the EXIT trap
}

case "${1:-}" in
    start) start_hotspot ;;
    stop) stop_hotspot ;;
    *) start_hotspot ;;
esac

# END OF FILE
