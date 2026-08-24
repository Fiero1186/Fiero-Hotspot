#!/bin/bash

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

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    log "ERR" "Config file not found at $CONFIG_FILE. Run install.sh first."
    exit 1
fi

if [ -z "$SSID" ] || [ -z "$PASSWORD" ] || [ -z "$INTERFACE" ] || [ -z "$POWER_SUPPLY" ]; then
    log "ERR" "Config file is missing required values (SSID, PASSWORD, INTERFACE, POWER_SUPPLY)."
    exit 1
fi

# --- NEW v0.3 ADDITION: Backward Compatibility Check ---
if [ -z "$SUPPORTED_CHANNELS" ]; then
    log "WARN" "SUPPORTED_CHANNELS not found in config. Was install.sh v0.3 run? Using safe defaults."
    SUPPORTED_CHANNELS="1,2,3,4,5,6,7,8,9,10,11,36,40,44,48"
fi
# -------------------------------------------------------

notify() {
    local msg="$1"
    log "INFO" "UI Notify: $msg"
    local user
    local uid

    user=$(loginctl list-sessions --no-legend | awk '{print $3}' | head -n 1)
    uid=$(id -u "$user" 2>/dev/null)

    if [ -n "$uid" ]; then
        sudo -u "$user" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        /usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "$msg" --icon=network-wireless 2>/dev/null
    fi
}

start_hotspot() {
    log "INFO" "Starting hotspot process..."
    log "INFO" "Cleaning up stale create_ap and virtual interfaces..."
    # 2>&1 routes errors to the journal. || true prevents the script from halting.
    pkill -x create_ap 2>&1 || true
    create_ap --stop "$INTERFACE" 2>&1 || true
    iw dev ap0 del 2>&1 || true
    iw dev ap1 del 2>&1 || true
    # Note: Deliberately skipping p2p-dev-$INTERFACE deletion to prevent iwlwifi firmware crashes

    AC_STATUS=$(cat "/sys/class/power_supply/$POWER_SUPPLY/online" 2>/dev/null)

    if [ "$AC_STATUS" != "1" ]; then
        log "WARN" "Not on AC power. Aborting."
        notify "Hotspot not started: charger not connected"
        exit 0
    fi

    WIFI_STATE=$(cat "/sys/class/net/$INTERFACE/operstate" 2>/dev/null)
    if [ "$WIFI_STATE" = "down" ]; then
        log "WARN" "WiFi is off. Aborting."
        notify "Hotspot not started: WiFi is off"
        exit 0
    fi

    CONNECTED=$(iw dev "$INTERFACE" link | grep "Connected to")
    if [ -z "$CONNECTED" ]; then
        log "WARN" "WiFi not connected to any network. Aborting."
        notify "Hotspot not started: not connected to WiFi"
        exit 0
    fi

    CHANNEL=$(iw dev "$INTERFACE" info | grep channel | awk '{print $2}')
    if [ -z "$CHANNEL" ]; then
        log "ERR" "Could not detect WiFi channel from 'iw dev info'. Aborting."
        notify "Hotspot not started: channel detect failed"
        exit 0
    fi

    log "INFO" "Detected upstream channel: $CHANNEL"

    # --- Runtime Channel Check ---
    if [[ ",$SUPPORTED_CHANNELS," != *",$CHANNEL,"* ]]; then
        log "ERR" "Channel $CHANNEL is not supported for AP broadcast on this hardware. Aborting."
        notify "Hotspot not started: Channel $CHANNEL is unsupported"
        exit 0
    fi
    # -----------------------------

    notify "Starting hotspot on channel $CHANNEL..."

    log "INFO" "Launching create_ap in background..."
    # Output is preserved so systemd captures create_ap's stdout/stderr directly into the journal
    create_ap "$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD" -c "$CHANNEL" &

    sleep 3

    if pgrep -x "create_ap" >/dev/null; then
        log "INFO" "create_ap process is running."
        notify "Hotspot is live! SSID: $SSID"
    else
        log "ERR" "create_ap failed to start or crashed immediately."
        notify "Hotspot failed to start. Check logs."
    fi
}

stop_hotspot() {
    if pgrep -x "create_ap" >/dev/null || iw dev | grep -q "ap[0-9]"; then
        log "INFO" "Stopping hotspot..."
        notify "Hotspot stopped (charger unplugged)"

        pkill -x create_ap 2>&1 || true
        create_ap --stop "$INTERFACE" 2>&1 || true
        iw dev ap0 del 2>&1 || true
        iw dev ap1 del 2>&1 || true

        log "INFO" "Hotspot cleanup complete."
    else
        log "INFO" "Hotspot is not running, nothing to stop."
    fi
}

case "$1" in
    start) start_hotspot ;;
    stop) stop_hotspot ;;
    *) start_hotspot ;;
esac
