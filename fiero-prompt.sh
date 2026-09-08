#!/bin/bash
set -u

# Triggered by udev on AC state changes, run as the desktop user (fiero/uid 1000)
# via: su - fiero -c /usr/local/bin/fiero-prompt.sh
# Needs the Wayland session bus to reach the KDE notification daemon.
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

STATE_FILE="/run/user/$(id -u)/fiero-prompt.state"
COOLDOWN=11

ac_online() {
    local supply
    for supply in /sys/class/power_supply/*; do
        if [ -f "$supply/type" ] && grep -q "^Mains$" "$supply/type" \
            && [ "$(cat "$supply/online" 2>/dev/null)" = "1" ]; then
            return 0
        fi
    done
    return 1
}

if ac_online; then
    current_state="online"
else
    current_state="offline"
fi

# --- Service state awareness: don't prompt when there is nothing to do.
if [ "$current_state" = "online" ] && systemctl is-active --quiet fiero-hotspot.service; then
    exit 0
fi
if [ "$current_state" = "offline" ] && ! systemctl is-active --quiet fiero-hotspot.service; then
    exit 0
fi

# --- Timestamp cooldown debounce: udev power events fire in clusters 1-3s apart.
# The state file persists (never deleted) so duplicate events stay blocked even if
# the user clicks an action immediately after our run.
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
now=$(date +%s)

if [ -f "$STATE_FILE" ]; then
    old_ts=$(cut -d: -f1 "$STATE_FILE")
    old_state=$(cut -d: -f2 "$STATE_FILE")
    old_pid=$(cut -d: -f3 "$STATE_FILE")

    if [ "$old_state" = "$current_state" ] && [ $((now - old_ts)) -lt $COOLDOWN ]; then
        # Duplicate event within the cooldown window -> debounced.
        exit 0
    fi
    if [ "$old_state" != "$current_state" ]; then
        # Power state flipped while a prompt was pending -> kill it and its
        # notify-send child so the stale fallback never executes.
        pkill -P "$old_pid" 2>/dev/null || true
        kill "$old_pid" 2>/dev/null || true
    fi
fi

echo "$now:$current_state:$$" > "$STATE_FILE"

if [ "$current_state" = "online" ]; then
    result=$(/usr/bin/notify-send -a "Fiero Hotspot" "AC connected. Start Fiero Hotspot?" \
        --icon=network-wireless \
        --expire-time=10000 \
        --action="start=Start" \
        --action="ignore=Ignore")
    # Explicit ignore -> exit. Timeout -> fallback only if still on AC.
    if [ "$result" = "ignore" ]; then
        exit 0
    fi
    if [ -z "$result" ] && ! ac_online; then
        exit 0
    fi
    sudo /usr/bin/systemctl start fiero-hotspot.service
else
    result=$(/usr/bin/notify-send -a "Fiero Hotspot" "AC disconnected. Stop Fiero Hotspot?" \
        --icon=network-wireless \
        --expire-time=10000 \
        --action="stop=Stop" \
        --action="keep=Keep Running")
    # Explicit keep -> exit. Timeout -> fallback only if still unplugged.
    if [ "$result" = "keep" ]; then
        exit 0
    fi
    if [ -z "$result" ] && ac_online; then
        exit 0
    fi
    sudo /usr/bin/systemctl stop fiero-hotspot.service
fi