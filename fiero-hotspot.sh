#!/bin/bash
set -u

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
    sudo -u "${TARGET_USER:-fiero}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID:-1000}/bus" \
        /usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "$msg" --icon=network-wireless 2>/dev/null || true
}

for cmd in iw pgrep pkill create_ap; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERR" "Required command not found: $cmd. Run install.sh first."
        exit 1
    fi
done

if [ -f "$CONFIG_FILE" ]; then
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
if [ -z "$SUPPORTED_CHANNELS" ]; then
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
    pkill -f "create_ap" 2>/dev/null || true
    for dev in $(iw dev 2>/dev/null | awk '$1=="Interface" && $2 ~ /^ap[0-9]+/ {print $2}'); do
		ip link set dev "$dev" down 2>/dev/null || true
        iw dev "$dev" del 2>/dev/null || true
        ip link delete "$dev" 2>/dev/null || true
    done
    # Note: Deliberately skipping p2p-dev-$INTERFACE deletion to prevent iwlwifi firmware crashes
    rm -rf /tmp/create_ap* 2>/dev/null || true
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
        exit 1
    fi

    if [[ ",$SUPPORTED_CHANNELS," != *",$CHANNEL,"* ]]; then
        log "ERR" "Channel $CHANNEL is not supported for AP broadcast on this hardware. Aborting."
        exit 1
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
            rm -f /tmp/fiero-shutting-down.lock
            while true; do
                if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
					if [ -f "/tmp/fiero-shutting-down.lock" ]; then
						rm -f /tmp/fiero-shutting-down.lock
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
	touch /tmp/fiero-shutting-down.lock
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
