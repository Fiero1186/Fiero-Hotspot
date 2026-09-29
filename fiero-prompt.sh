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

# --- Event watcher mode: `fiero-prompt watch` ---
# Unprivileged daemon that tails /run/fiero-hotspot/events (tail -F rides the
# kernel inotify: zero CPU wakeups while idle) and raises desktop
# notifications. The root daemon never touches D-Bus; it only appends
# STATE|MSG|CHANNEL|TS records.
watch_events() {
    local watch_lock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fiero-prompt.watch.lock"
    local event_file="/run/fiero-hotspot/events"
    local state msg urgency

    exec 8>"$watch_lock"
    flock -n 8 || exit 0

    # The daemon's RuntimeDirectory owns this path; create only best-effort
    # (foreground runs, fresh installs) - tail -F picks the file up whenever
    # it appears.
    mkdir -p "$(dirname "$event_file")" 2>/dev/null || true
    touch "$event_file" 2>/dev/null || true

    # ponytail: if the D-Bus socket vanishes mid-run, only the reader exits;
    # tail lingers until the next event's SIGPIPE closes it.
    tail -n0 -F "$event_file" 8>&- 2>/dev/null | while IFS='|' read -r state msg _; do
        [ -n "$state" ] || continue
        if [ ! -S "${USER_BUS:-}" ]; then
            exit 0
        fi
        urgency="normal"
        case "$state" in
        CHANNEL_UNSUPPORTED | DISCONNECTED | ERROR) urgency="critical" ;;
        STARTING | CHANNEL_DRIFT) urgency="low" ;;
        esac
        /usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "$msg" \
            --icon=network-wireless \
            --urgency="$urgency" 2>/dev/null || true
    done
}

if [ "${1:-}" = "watch" ]; then
    USER_BUS="/run/user/$(id -u)/bus"
    [ -S "$USER_BUS" ] || exit 0
    watch_events
    exit 0
fi

# Serialises the debounce/supersede step below. Held only for that step, not
# while the notification is on screen, so a charger flip during an open
# prompt can still reach the code that cancels the stale prompt.
USER_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fiero-prompt.lock"

CONFIG_FILE="/etc/fiero-hotspot.conf"
if [ -r "$CONFIG_FILE" ]; then
    conf_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
    conf_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
    if [ "$conf_owner" = "root" ] && { [ "$conf_perms" = "640" ] || [ "$conf_perms" = "600" ]; }; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
fi

INTERFACE="${INTERFACE:-$(iw dev 2>/dev/null | awk '$1=="Interface" && $2 !~ /^ap[0-9]+/ {print $2; exit}')}"
SUPPORTED_CHANNELS="${SUPPORTED_CHANNELS:-1,2,3,4,5,6,7,8,9,10,11,36,40,44,48}"

freq_to_channel() {
    local f="${1%.*}" ch=""
    if [ "$f" = "2484" ]; then
        ch=14
    elif [ "$f" -ge 2407 ] 2>/dev/null && [ "$f" -le 2472 ] 2>/dev/null; then
        ch=$(((f - 2407) / 5))
    elif [ "$f" -ge 5000 ] 2>/dev/null; then
        ch=$(((f - 5000) / 5))
    fi
    printf '%s' "$ch"
}

get_channel() {
    local line
    line=$(iw dev "$1" info 2>/dev/null | grep -m1 'channel ')
    [ -n "$line" ] || return 1
    FREQ=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++){v=$i; gsub(/[()]/,"",v); if (v ~ /^[0-9][0-9][0-9][0-9](\.[0-9])?$/ &&$(i+1) ~ /MHz/) {print v; exit}}}')
    [ -n "$FREQ" ] || return 1
    CH=$(freq_to_channel "$FREQ")
    [ -n "$CH" ]
}

refresh_supported_channels() {
    local phy fresh=""
    phy=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}')
    if [ -n "$phy" ]; then
        fresh=$(iw phy "$phy" info 2>/dev/null | grep -E '\* [0-9]+(\.[0-9]+)? MHz \[[0-9]+\]' | grep -viE '(disabled|no IR|radar detection)' | awk -F'[][]' '{print $2}' | paste -sd, -)
    fi
    if [ -n "$fresh" ]; then
        SUPPORTED_CHANNELS="$fresh"
    fi
}

USER_BUS="/run/user/$(id -u)/bus"
if [ ! -S "$USER_BUS" ]; then
    echo "[WARN] D-Bus session bus not found at $USER_BUS; skipping desktop notification." >&2
    exit 0
fi
DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS"
export DBUS_SESSION_BUS_ADDRESS

# One detached watcher per user session: it survives this process and keeps
# translating daemon state events into desktop notifications (flock-guarded,
# so only the first spawn wins). Fds 8/9 are closed so it never inherits a
# held lock.
setsid --fork bash "$0" watch >/dev/null 2>&1 <&- 3>&- 8>&- 9>&- &

if [ "${AUTO_PROMPT:-true}" != "true" ]; then
    exit 0
fi
STATE_FILE="/run/user/$(id -u)/fiero-prompt.state"
COOLDOWN=11

ac_online() {
    local supply
    shopt -s nullglob
    for supply in /sys/class/power_supply/*; do
        if [ -f "$supply/type" ] && grep -qE "^(Mains|USB)$" "$supply/type" &&
            [ "$(cat "$supply/online" 2>/dev/null)" = "1" ]; then
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

# --- Timestamp cooldown debounce: udev power events fire in clusters 1-3s apart.
# The state file persists (never deleted) so duplicate events stay blocked even if
# the user clicks an action immediately after our run.
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
exec 9>"$USER_LOCK"
if ! flock -w 5 9; then
    exit 0
fi
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
            if [ -d "/proc/$old_pid" ]; then
                old_comm=$(cat "/proc/$old_pid/comm" 2>/dev/null || true)
                if [[ "$old_comm" == fiero-prompt* ]]; then
                    pkill -P "$old_pid" 2>/dev/null || true
                    kill "$old_pid" 2>/dev/null || true
                fi
            fi
        fi
    fi
fi

echo "$now:$current_state:$$" >"$STATE_FILE"
flock -u 9
exec 9>&-

# A newer charger event may have replaced this prompt while it was open.
still_current() {
    [ "$(cut -d: -f3 "$STATE_FILE" 2>/dev/null)" = "$$" ]
}

# --- Service state awareness: don't prompt when there is nothing to do.
# This runs after the state update above, so that e.g. unplugging while a
# "Start?" prompt is open still cancels that prompt even though nothing needs
# stopping.
if [ "$current_state" = "online" ] && systemctl is-active --quiet fiero-hotspot.service; then
    exit 0
fi
if [ "$current_state" = "offline" ] && ! systemctl is-active --quiet fiero-hotspot.service; then
    exit 0
fi

if [ "$current_state" = "online" ]; then
    refresh_supported_channels
    CURRENT_CHANNEL=""
    if iw dev "$INTERFACE" link 2>/dev/null | grep -q "Connected to"; then
        if get_channel "$INTERFACE"; then
            CURRENT_CHANNEL="$CH"
        fi
    fi
    if [ -z "$CURRENT_CHANNEL" ]; then
        CURRENT_FREQ=$(iw dev "$INTERFACE" link 2>/dev/null | grep -oE 'freq: [0-9]+' | awk '{print $2}')
        [ -n "$CURRENT_FREQ" ] && CURRENT_CHANNEL=$(freq_to_channel "$CURRENT_FREQ")
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
    still_current || exit 0
    # Explicit ignore -> exit. Timeout or dismissed -> start unless the user
    # opted out (AUTO_START_ON_TIMEOUT='false') and we are still on AC.
    if [ "$result" = "ignore" ]; then
        exit 0
    fi
    if [ -z "$result" ]; then
        if [ "${AUTO_START_ON_TIMEOUT:-true}" != "true" ] || ! ac_online; then
            exit 0
        fi
    fi
    # The cable can be pulled while the prompt sits on screen; re-read the
    # power state now so a manual "Start" never brings the AP up on battery.
    ac_online || exit 0
    sudo -n /usr/bin/systemctl start fiero-hotspot.service
else
    result=$(/usr/bin/notify-send -a "Fiero Hotspot" "AC disconnected. Stop Fiero Hotspot?" \
        --icon=network-wireless \
        --expire-time=10000 \
        --action="stop=Stop" \
        --action="keep=Keep Running")
    still_current || exit 0
    # Explicit keep -> exit. Timeout -> stop (the safe choice on battery)
    # unless the user opted out (AUTO_STOP_ON_TIMEOUT='false') or the charger
    # came back while the prompt was open.
    if [ "$result" = "keep" ]; then
        exit 0
    fi
    if [ -z "$result" ]; then
        if [ "${AUTO_STOP_ON_TIMEOUT:-true}" != "true" ] || ac_online; then
            exit 0
        fi
    fi
    sudo -n /usr/bin/systemctl stop fiero-hotspot.service
fi

# END OF FILE
