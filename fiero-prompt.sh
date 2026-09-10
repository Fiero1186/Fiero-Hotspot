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

# Static PATH: never resolve binaries from caller-controlled dirs
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# Prevent udev bounce spam with non-blocking lock
USER_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fiero-prompt.lock"
exec 9>"$USER_LOCK"
if ! flock -n 9; then
    exit 0
fi

CONFIG_FILE="/etc/fiero-hotspot.conf"
if [ -r "$CONFIG_FILE" ]; then
    conf_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
    conf_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    if [ "$conf_owner" = "root" ] && { [ "$conf_perms" = "640" ] || [ "$conf_perms" = "600" ]; }; then
        source "$CONFIG_FILE"
    fi
fi

INTERFACE="${INTERFACE:-$(iw dev 2>/dev/null | awk '$1=="Interface" && $2 !~ /^ap[0-9]+/ {print $2; exit}')}"
SUPPORTED_CHANNELS="${SUPPORTED_CHANNELS:-1,2,3,4,5,6,7,8,9,10,11,36,40,44,48}"

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

    # Only trust well-formed numeric fields from the user-writable state file
    if [[ "${old_pid:-}" =~ ^[0-9]+$ ]] && [[ "${old_ts:-}" =~ ^[0-9]+$ ]]; then
        if [ "$old_state" = "$current_state" ] && [ $((now - ${old_ts:-0})) -lt $COOLDOWN ]; then
            # Duplicate event within the cooldown window -> debounced.
            exit 0
        fi
        if [ "$old_state" != "$current_state" ]; then
            # Power state flipped while a prompt was pending -> kill it and its
            # notify-send child so the stale fallback never executes.
            if [ -d "/proc/$old_pid" ] && grep -q "fiero" "/proc/$old_pid/cmdline" 2>/dev/null; then
                pkill -P "$old_pid" 2>/dev/null || true
                kill "$old_pid" 2>/dev/null || true
            fi
        fi
    fi
fi

echo "$now:$current_state:$$" > "$STATE_FILE"

if [ "$current_state" = "online" ]; then
	CURRENT_FREQ=$(iw dev "$INTERFACE" link 2>/dev/null | grep -oE 'freq: [0-9]+' | awk '{print $2}')
		CURRENT_CHANNEL=""
		if [ -n "$CURRENT_FREQ" ]; then
			if [ "$CURRENT_FREQ" -ge 2412 ] && [ "$CURRENT_FREQ" -le 2472 ]; then
				CURRENT_CHANNEL=$(( (CURRENT_FREQ - 2407) / 5 ))
			elif [ "$CURRENT_FREQ" -eq 2484 ]; then
				CURRENT_CHANNEL=14
			elif [ "$CURRENT_FREQ" -ge 5000 ]; then
				CURRENT_CHANNEL=$(( (CURRENT_FREQ - 5000) / 5 ))
			fi
		fi
		if [ -z "$CURRENT_CHANNEL" ]; then
			CURRENT_CHANNEL=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2; exit}')
		fi

		if [ -z "$CURRENT_CHANNEL" ]; then
			/usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "Hotspot not started: not connected to WiFi" \
				--icon=network-wireless
			exit 0
		fi

		if [[ ",$SUPPORTED_CHANNELS," != *",$CURRENT_CHANNEL,"* ]]; then
			/usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "Hotspot not started: Channel $CURRENT_CHANNEL is unsupported" \
				--icon=network-wireless
			exit 0
		fi
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
    sudo -n /usr/bin/systemctl start fiero-hotspot.service
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
    sudo -n /usr/bin/systemctl stop fiero-hotspot.service
fi

# END OF FILE
