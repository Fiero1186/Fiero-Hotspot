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
UPSTREAM_GRACE=15

CONFIG_FILE="/etc/fiero-hotspot.conf"

VERSION="1.4.0"

# --- Utility Functions ---
escape_regex() {
    printf '%s' "$1" | sed 's/[][\.|$(){}?+*^\\-]/\\&/g'
}

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
    local line freq
    line=$(iw dev "$1" info 2>/dev/null | grep -m1 'channel ')
    [ -n "$line" ] || return 1
    FREQ=$(printf '%s\n' "$line" | awk '{for(i=1;i<NF;i++){v=$i; gsub(/[()]/,"",v); if (v ~ /^[0-9]{4,5}(\.[0-9])?$/ &&$(i+1) ~ /MHz/) {print v; exit}}}')
    [ -n "$FREQ" ] || return 1
    CH=$(freq_to_channel "$FREQ")
    [ -n "$CH" ]
}

refresh_supported_channels() {
    local phy fresh=""
    phy=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}')
    if [ -n "$phy" ]; then
        fresh=$(iw phy "$phy" info 2>/dev/null | grep -E '\* [0-9]+(\.[0-9]+)? MHz \[[0-9]+\]' | grep -vE '(disabled|no IR|radar detection)' | awk -F'[][]' '{print $2}' | paste -sd, -)
    fi
    if [ -n "$fresh" ]; then
        SUPPORTED_CHANNELS="$fresh"
        log "INFO" "Using live channel list: $SUPPORTED_CHANNELS"
    fi
}

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
        log "WARN" "TARGET_USER/TARGET_UID not set; skipping desktop notification."
        return 0
    fi
    sudo -u "$TARGET_USER" env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
        /usr/bin/notify-send -a "Fiero Hotspot" "Hotspot" "$msg" --icon=network-wireless 2>/dev/null || true
}

for cmd in iw pgrep pkill create_ap; do
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

ac_online() {
    if [ -n "${POWER_SUPPLY:-}" ] &&
        [ -f "/sys/class/power_supply/$POWER_SUPPLY/online" ] &&
        [ "$(cat "/sys/class/power_supply/$POWER_SUPPLY/online" 2>/dev/null)" = "1" ]; then
        return 0
    fi
    local supply
    for supply in /sys/class/power_supply/*; do
        if [ -f "$supply/type" ] && grep -q "^Mains$" "$supply/type" &&
            [ "$(cat "$supply/online" 2>/dev/null)" = "1" ]; then
            return 0
        fi
    done
    return 1
}

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
    escaped_if=$(escape_regex "$INTERFACE")
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
    get_channel "$INTERFACE" && CHANNEL="$CH"
}

start_hotspot() {
    if [ "$EUID" -ne 0 ]; then
        SKIP_CLEANUP=1
        log "ERR" "Starting the hotspot requires root. Run: sudo fiero-hotspot start"
        exit 1
    fi
    exec 9>/run/fiero-hotspot.lock
    flock -n 9 || {
        log "INFO" "Another instance is running. Exiting."
        SKIP_CLEANUP=1
        exit 0
    }

    local escaped_if
    escaped_if=$(escape_regex "$INTERFACE")
    if pgrep -f "create_ap.*$escaped_if" >/dev/null && iw dev | grep -qE '^\s*Interface ap[0-9]'; then
        log "INFO" "Hotspot already running. Skipping."
        SKIP_CLEANUP=1
        exit 0
    fi

    log "INFO" "Starting hotspot process..."

    refresh_supported_channels

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
    create_ap "$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD" -c "$CHANNEL" 9>&- &
    CREATE_AP_PID=$!

    sleep 0.5
    if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
        log "ERR" "create_ap process exited immediately after launch."
        cleanup
        exit 1
    fi

    for ((attempt = 1; attempt <= 8; attempt++)); do
        if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
            break
        fi
        if iw dev 2>/dev/null | grep -qE '^\s*Interface ap[0-9]+' && pgrep -f "hostapd.*/tmp/create_ap" >/dev/null; then
            log "INFO" "create_ap is live (pid $CREATE_AP_PID, AP interface up)."
            notify "Hotspot is live! SSID: $SSID"
            local last_channel="$CHANNEL"
            local down_since=""
            local poll_int=2
            rm -f "$SHUTDOWN_LOCK"
            while true; do
                if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
                    if [ -f "$SHUTDOWN_LOCK" ]; then
                        rm -f "$SHUTDOWN_LOCK"
                        log "WARN" "create_ap exited during manual stop; treating as clean stop."
                        break
                    fi
                    log "ERR" "create_ap process exited unexpectedly. Shutting down hotspot."
                    notify "Hotspot stopped: create_ap process exited"
                    break
                fi

                local up_uptime link_out link_rc
                up_uptime=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
                link_out=$(iw dev "$INTERFACE" link 2>/dev/null)
                link_rc=$?

                if [ "$link_rc" -eq 0 ] && printf '%s' "$link_out" | grep -q "Connected to"; then
                    down_since=""
                    poll_int=2

                    local current_ch=""
                    if get_channel "$INTERFACE"; then current_ch="$CH"; fi
                    if [ -n "$current_ch" ] && [ "$current_ch" != "$last_channel" ]; then
                        log "WARN" "Upstream channel changed ($last_channel -> $current_ch). Re-evaluating AP..."
                        if [[ ",$SUPPORTED_CHANNELS," != *",$current_ch,"* ]]; then
                            log "ERR" "New channel $current_ch is unsupported for AP broadcast. Shutting down."
                            notify "Hotspot stopped: channel $current_ch unsupported"
                            break
                        fi

                        notify "Hotspot restarting: channel changed to $current_ch"
                        cleanup
                        CHANNEL="$current_ch"
                        last_channel="$current_ch"

                        create_ap "$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD" -c "$CHANNEL" 9>&- &
                        CREATE_AP_PID=$!

                        sleep 0.5
                        if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
                            log "ERR" "create_ap failed to restart on channel $CHANNEL."
                            notify "Hotspot stopped: create_ap restart failed"
                            break
                        fi

                        local reinit_ok=0
                        for ((reinit_attempt = 1; reinit_attempt <= 8; reinit_attempt++)); do
                            if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
                                break
                            fi
                            if iw dev 2>/dev/null | grep -qE '^\s*Interface ap[0-9]+' && pgrep -f "hostapd.*/tmp/create_ap" >/dev/null; then
                                reinit_ok=1
                                log "INFO" "create_ap successfully restarted on channel $CHANNEL (pid $CREATE_AP_PID)."
                                notify "Hotspot is live on channel $CHANNEL!"
                                break
                            fi
                            sleep 1
                        done

                        if [ "$reinit_ok" -ne 1 ]; then
                            log "ERR" "Failed to bring up AP on channel $CHANNEL within 8s."
                            notify "Hotspot stopped: AP re-init failed"
                            break
                        fi
                    fi
                elif [ "$link_rc" -eq 0 ] && printf '%s' "$link_out" | grep -q "Not connected"; then
                    poll_int=1
                    if [ -z "$down_since" ]; then
                        down_since="$up_uptime"
                    fi
                    if [ $((up_uptime - down_since)) -ge "$UPSTREAM_GRACE" ]; then
                        sleep 2
                        link_out=$(iw dev "$INTERFACE" link 2>/dev/null)
                        if ! printf '%s' "$link_out" | grep -q "Connected to"; then
                            log "ERR" "Upstream Wi-Fi disconnected permanently. Shutting down hotspot."
                            notify "Hotspot stopped: upstream Wi-Fi disconnected"
                            break
                        fi
                        down_since=""
                    fi
                fi

                sleep "$poll_int"
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
    if [ "$EUID" -ne 0 ]; then
        SKIP_CLEANUP=1
        log "ERR" "Stopping the hotspot requires root. Run: sudo fiero-hotspot stop"
        exit 1
    fi
    touch "$SHUTDOWN_LOCK"
    log "INFO" "Stopping hotspot..."
    if ac_online; then
        notify "Hotspot stopped manually"
    else
        notify "Hotspot stopped (charger unplugged)"
    fi
    # Teardown is handled automatically by the EXIT trap
}

status_hotspot() {
    SKIP_CLEANUP=1
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Status requires root. Run: sudo fiero-hotspot status"
        exit 1
    fi

    local svc_state ap_iface ap_channel ap_freq client_count ac_status

    svc_state=$(systemctl is-active fiero-hotspot.service 2>/dev/null || true)
    svc_state="${svc_state:-inactive}"

    ap_iface=$(iw dev 2>/dev/null | awk '$1=="Interface" && $2 ~ /^ap[0-9]+/ {print $2; exit}')
    ap_iface="${ap_iface:-none}"

    if [ "$ap_iface" != "none" ]; then
        ap_channel=""
        ap_freq=""
        if get_channel "$ap_iface"; then
            ap_channel="$CH"
            ap_freq="$FREQ"
        fi
        client_count=$(iw dev "$ap_iface" station dump 2>/dev/null | grep -c "^Station ")
    else
        ap_channel="-"
        ap_freq="-"
        client_count=0
    fi

    if ac_online; then
        ac_status="Connected"
    else
        ac_status="Battery"
    fi

    local freq_display="-"
    if [ -n "$ap_freq" ] && [ "$ap_freq" != "-" ]; then
        freq_display="${ap_freq} MHz"
    fi

    local channel_display="-"
    if [ -n "$ap_channel" ] && [ "$ap_channel" != "-" ]; then
        channel_display="${ap_channel} (${freq_display})"
    fi

    printf "=== Fiero Hotspot Status ===\n"
    printf "  Service    : %s\n" "$svc_state"
    if [ "${AUTO_PROMPT:-true}" = "true" ]; then
        printf "  Mode       : Auto (Prompt on AC)\n"
    else
        printf "  Mode       : Manual (CLI only)\n"
    fi
    printf "  AP iface   : %s\n" "$ap_iface"
    printf "  SSID       : %s\n" "$SSID"
    printf "  Channel    : %s\n" "$channel_display"
    printf "  AC Power   : %s\n" "$ac_status"
    printf "  Clients    : %s\n" "$client_count"
}

clients_hotspot() {
    SKIP_CLEANUP=1
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Client listing requires root. Run: sudo fiero-hotspot clients"
        exit 1
    fi

    local ap_iface
    ap_iface=$(iw dev 2>/dev/null | awk '$1=="Interface" && $2 ~ /^ap[0-9]+/ {print $2; exit}')

    if [ -z "$ap_iface" ]; then
        log "INFO" "Hotspot is not running. No AP interface found."
        exit 0
    fi

    local -A mac_to_ip mac_to_host
    local lease_file
    for lease_file in /var/lib/misc/dnsmasq.leases /tmp/create_ap.*/dnsmasq.leases; do
        [ -f "$lease_file" ] || continue
        while IFS=' ' read -r _expiry mac ip hostname _rest; do
            mac_to_ip["$mac"]="$ip"
            if [ -n "$hostname" ] && [ "$hostname" != "*" ]; then
                mac_to_host["$mac"]="$hostname"
            fi
        done <"$lease_file"
    done

    local station_output
    station_output=$(iw dev "$ap_iface" station dump 2>/dev/null)

    if [ -z "$station_output" ]; then
        log "INFO" "No clients connected."
        exit 0
    fi

    printf "=== Fiero Hotspot Clients ===\n"
    printf "  %-17s %-10s %-15s %s\n" "MAC" "Signal" "IP" "Hostname"
    printf "  %-17s %-10s %-15s %s\n" "─────────────────" "──────────" "───────────────" "─────────────"

    local current_mac=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^Station\ ([0-9a-fA-F:]+) ]]; then
            current_mac="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ signal:\ (-?[0-9]+)\ dBm ]]; then
            local signal="${BASH_REMATCH[1]}"
            local ip="${mac_to_ip[$current_mac]:--}"
            local host="${mac_to_host[$current_mac]:--}"
            printf "  %-17s %-10s %-15s %s\n" "$current_mac" "${signal} dBm" "$ip" "$host"
        fi
    done <<<"$station_output"
}

case "${1:-}" in
start) start_hotspot ;;
stop) stop_hotspot ;;
status) status_hotspot ;;
clients) clients_hotspot ;;
mode | toggle)
    SKIP_CLEANUP=1
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Mode toggle requires root. Run: sudo fiero-hotspot mode"
        exit 1
    fi
    cfg="/etc/fiero-hotspot.conf"
    current="${AUTO_PROMPT:-true}"
    update_auto_prompt() {
        local val="$1"
        if grep -q '^AUTO_PROMPT=' "$cfg" 2>/dev/null; then
            sed -i "s/^AUTO_PROMPT=.*/AUTO_PROMPT='${val}'/" "$cfg"
        else
            echo "AUTO_PROMPT='${val}'" >>"$cfg"
        fi
        chown root:"$TARGET_USER" "$cfg" 2>/dev/null || true
        chmod 640 "$cfg" 2>/dev/null || true
    }
    case "${2:-}" in
    auto | enable | on)
        update_auto_prompt 'true'
        log "INFO" "Auto-prompt enabled."
        ;;
    manual | disable | off)
        update_auto_prompt 'false'
        log "INFO" "Auto-prompt disabled (manual mode)."
        ;;
    "")
        if [ "$current" = "true" ]; then
            printf "Current mode: Auto (Prompt on AC)\n"
            read -rp "Switch to Manual? [y/N]: " ans
        else
            printf "Current mode: Manual (CLI only)\n"
            read -rp "Switch to Auto? [y/N]: " ans
        fi
        case "${ans}" in
        [yY] | [yY][eE][sS])
            if [ "$current" = "true" ]; then
                update_auto_prompt 'false'
                log "INFO" "Switched to manual mode."
            else
                update_auto_prompt 'true'
                log "INFO" "Switched to auto mode."
            fi
            ;;
        *)
            log "INFO" "No change."
            ;;
        esac
        ;;
    *)
        log "ERR" "Unknown mode: '$2'. Use 'auto' or 'manual'."
        exit 1
        ;;
    esac
    ;;
version | -v | --version)
    SKIP_CLEANUP=1
    printf "fiero-hotspot v%s\n" "$VERSION"
    ;;
help | -h | --help | "")
    SKIP_CLEANUP=1
    printf "Usage: fiero-hotspot {start|stop|status|clients|mode|version|help}\n"
    printf "\n"
    printf "  start    Start the hotspot daemon\n"
    printf "  stop     Stop the hotspot daemon\n"
    printf "  status   Show hotspot status dashboard\n"
    printf "  clients  List connected clients\n"
    printf "  mode     Toggle or set trigger mode (auto|manual)\n"
    printf "  version  Show version information (also: -v, --version)\n"
    printf "  help     Show this help message\n"
    ;;
*)
    SKIP_CLEANUP=1
    log "ERR" "Unknown action: '$1'. Run 'fiero-hotspot help' for usage."
    exit 1
    ;;
esac

# END OF FILE
