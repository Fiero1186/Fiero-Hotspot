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

VERSION="2.1.0"

CONFIG_FILE="/etc/fiero-hotspot.conf"
LOCK_FILE="/run/fiero-hotspot.lock"

# Per-instance state. Created by systemd (RuntimeDirectory=) or by us when
# running in the foreground. The directory is world-readable (0755) so the
# unprivileged event watcher (fiero-prompt.sh) can read state/events; secrets
# (the create_ap passphrase) are protected by their own 0600 file modes.
RUN_DIR="/run/fiero-hotspot"
PID_FILE="$RUN_DIR/create_ap.pid"
CONFDIR_FILE="$RUN_DIR/confdir"
IFACE_FILE="$RUN_DIR/ap_iface"
STOP_FLAG="$RUN_DIR/stopping"
AP_CONF="$RUN_DIR/create_ap.conf"
STATE_FILE="$RUN_DIR/state"
EVENTS_FILE="$RUN_DIR/events"

UPSTREAM_GRACE=15
AP_START_TIMEOUT=8
AP_STOP_TIMEOUT=15

# --- Utility Functions ---
escape_regex() {
    # shellcheck disable=SC2016 # the sed expression is meant to be literal
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
    local line
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

# State/event IPC: the root daemon never touches the desktop. It publishes an
# atomic state snapshot ($STATE_FILE) and an append-only event stream
# ($EVENTS_FILE, STATE|MSG|CHANNEL|TS) that the unprivileged watcher in
# fiero-prompt.sh reads via inotify (tail -F).
# ponytail: a "|" or newline in MSG would shift trailing fields, so both are
# flattened; upgrade to length-prefixed records if messages ever need pipes.
set_state() {
    local state="$1" msg="${2:-}" ts tmp
    ts=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
    msg=$(printf '%s' "$msg" | tr '\n|' '  ')
    mkdir -p "$RUN_DIR" 2>/dev/null || true
    chmod 755 "$RUN_DIR" 2>/dev/null || true

    # 1. Atomic state snapshot for CLI / inspection
    tmp="$RUN_DIR/.state.tmp.$$"
    {
        printf 'STATE="%s"\nMSG="%s"\nCHANNEL="%s"\nTIMESTAMP="%s"\n' \
            "$state" "$msg" "${CHANNEL:-}" "$ts"
    } >"$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"

    # 2. Append to the event stream (tail -F watchers wake on write)
    printf '%s|%s|%s|%s\n' "$state" "$msg" "${CHANNEL:-}" "$ts" >>"$EVENTS_FILE" 2>/dev/null || true
    chmod 644 "$EVENTS_FILE" 2>/dev/null || true
}

# --- Configuration ---
# Only commands that touch the hotspot load the config; help and version work
# for any user, even before create_ap is installed.
load_config() {
    local cmd conf_owner conf_perms
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
        # shellcheck disable=SC1090
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
}

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

# --- create_ap Instance Tracking ---
# Fiero only ever touches the create_ap process it started (recorded in
# $PID_FILE). Other hotspots on the system - the linux-wifi-hotspot GUI,
# another create_ap - are left alone.
CREATE_AP_PID=""

ensure_run_dir() {
    install -d -m 0755 "$RUN_DIR"
}

read_state() {
    [ -f "$1" ] && head -n1 "$1" 2>/dev/null
}

is_create_ap_pid() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -q 'create_ap'
}

current_pid() {
    local pid="${CREATE_AP_PID:-}"
    [ -n "$pid" ] || pid=$(read_state "$PID_FILE")
    is_create_ap_pid "$pid" && printf '%s' "$pid"
}

# create_ap writes its own PID to <confdir>/pid, and the AP interface it
# actually uses (ap0, or the physical card with --no-virt) to
# <confdir>/wifi_iface.
find_confdir() {
    local d
    for d in /tmp/create_ap.*.conf.*; do
        [ -f "$d/pid" ] || continue
        if [ "$(cat "$d/pid" 2>/dev/null)" = "$1" ]; then
            printf '%s' "$d"
            return 0
        fi
    done
    return 1
}

is_confdir_path() {
    [[ "${1:-}" =~ ^/tmp/create_ap\.[A-Za-z0-9_.-]+\.conf\.[A-Za-z0-9]+$ ]]
}

# create_ap parses --config files with a plain `read` (no -r): backslashes
# are dropped and leading/trailing whitespace is trimmed. Only values that
# survive that unchanged can go through the file.
config_safe_value() {
    case "$1" in *\\*) return 1 ;; esac
    [ "$1" = "${1#[[:space:]]}" ] && [ "$1" = "${1%[[:space:]]}" ]
}

# Write a root-only (0600) create_ap config so the passphrase never appears
# on a command line, where any local user could read it via ps or
# /proc/<pid>/cmdline.
write_create_ap_config() {
    local ch="$1"
    config_safe_value "$SSID" && config_safe_value "$PASSWORD" || return 1
    (
        umask 077
        {
            printf 'WIFI_IFACE=%s\n' "$INTERFACE"
            printf 'INTERNET_IFACE=%s\n' "$INTERFACE"
            printf 'SSID=%s\n' "$SSID"
            printf 'PASSPHRASE=%s\n' "$PASSWORD"
            printf 'CHANNEL=%s\n' "$ch"
        } >"$AP_CONF"
    )
}

launch_create_ap() {
    local ch="$1"
    ensure_run_dir
    rm -f "$CONFDIR_FILE" "$IFACE_FILE"
    if write_create_ap_config "$ch"; then
        create_ap --config "$AP_CONF" 9>&- &
    else
        log "WARN" "SSID or password contains a backslash or leading/trailing spaces, which create_ap's config file cannot hold. Passing them on the command line instead (visible to local users via ps)."
        create_ap "$INTERFACE" "$INTERFACE" "$SSID" "$PASSWORD" -c "$ch" 9>&- &
    fi
    CREATE_AP_PID=$!
    printf '%s\n' "$CREATE_AP_PID" >"$PID_FILE"
}

# Wait until our create_ap has a running hostapd and an AP interface.
wait_for_ap() {
    local attempt confdir ap_iface
    sleep 0.5
    for ((attempt = 1; attempt <= AP_START_TIMEOUT; attempt++)); do
        kill -0 "$CREATE_AP_PID" 2>/dev/null || return 1
        confdir=$(find_confdir "$CREATE_AP_PID") || confdir=""
        if [ -n "$confdir" ] && [ -f "$confdir/wifi_iface" ]; then
            ap_iface=$(cat "$confdir/wifi_iface" 2>/dev/null)
            if [ -n "$ap_iface" ] && iw dev "$ap_iface" info >/dev/null 2>&1 &&
                pgrep -f "hostapd.*$(escape_regex "$confdir")/hostapd.conf" >/dev/null; then
                printf '%s\n' "$confdir" >"$CONFDIR_FILE"
                printf '%s\n' "$ap_iface" >"$IFACE_FILE"
                # create_ap has read its config; don't keep the passphrase around
                rm -f "$AP_CONF"
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# create_ap saves the original forwarding values before enabling NAT and puts
# them back in its own cleanup. If we had to kill it, do that for it - unless
# another create_ap instance still needs forwarding.
restore_ip_forward() {
    local common="/tmp/create_ap.common.conf"
    if pgrep -f '(^|/)create_ap( |$)' >/dev/null; then
        return 0
    fi
    if [ -f "$common/ip_forward" ]; then
        cat "$common/ip_forward" >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        log "WARN" "Restored net.ipv4.ip_forward to $(cat "$common/ip_forward" 2>/dev/null)."
    fi
    if [ -f "$common/${INTERFACE}_forwarding" ]; then
        cat "$common/${INTERFACE}_forwarding" >"/proc/sys/net/ipv4/conf/$INTERFACE/forwarding" 2>/dev/null || true
    fi
}

# Ask our create_ap to stop and wait for it. create_ap's own cleanup restores
# ip_forward, iptables and NetworkManager, so it must be allowed to finish
# before anything else is removed.
stop_create_ap() {
    local pid ap_iface confdir forced=0 i
    pid=$(current_pid) || pid=""
    ap_iface=$(read_state "$IFACE_FILE")
    confdir=$(read_state "$CONFDIR_FILE")

    if [ -n "$pid" ]; then
        # USR1 is create_ap's clean-exit signal (same as `create_ap --stop`)
        kill -USR1 "$pid" 2>/dev/null || true
        for ((i = 0; i < AP_STOP_TIMEOUT * 2; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "WARN" "create_ap (pid $pid) did not exit within ${AP_STOP_TIMEOUT}s; forcing it."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
            forced=1
        fi
    fi

    if [ "$forced" -eq 1 ] && is_confdir_path "$confdir"; then
        # hostapd and dnsmasq of *this* instance carry the confdir in their
        # command line
        pkill -f "$(escape_regex "$confdir")/" 2>/dev/null || true
        restore_ip_forward
        rm -rf -- "$confdir"
    fi

    # Only a leftover virtual interface is removed, never the physical card.
    # Deliberately never touches p2p-dev-* to prevent iwlwifi firmware crashes.
    if [ -n "$ap_iface" ] && [ "$ap_iface" != "${INTERFACE:-}" ] &&
        [[ "$ap_iface" =~ ^ap[0-9]+$ ]] && iw dev "$ap_iface" info >/dev/null 2>&1; then
        log "WARN" "Removing leftover AP interface $ap_iface."
        ip link set dev "$ap_iface" down 2>/dev/null || true
        iw dev "$ap_iface" del 2>/dev/null || true
    fi

    CREATE_AP_PID=""
    rm -f "$PID_FILE" "$CONFDIR_FILE" "$IFACE_FILE" "$AP_CONF"
}

cleanup() {
    stop_create_ap
    rm -f "$STOP_FLAG"
}

detect_channel() {
    get_channel "$INTERFACE" && CHANNEL="$CH"
}

# Watch the upstream link while the AP runs: follow channel changes, stop when
# upstream is gone for good, stop when create_ap dies.
monitor_hotspot() {
    local last_channel="$CHANNEL" down_since="" poll_int=2
    local now link_out link_rc current_ch

    while true; do
        if ! kill -0 "$CREATE_AP_PID" 2>/dev/null; then
            if [ -f "$STOP_FLAG" ]; then
                log "INFO" "create_ap stopped on request."
            else
                log "ERR" "create_ap process exited unexpectedly. Shutting down hotspot."
                set_state "ERROR" "Hotspot stopped: create_ap process exited"
            fi
            break
        fi

        now=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
        link_out=$(iw dev "$INTERFACE" link 2>/dev/null)
        link_rc=$?

        if [ "$link_rc" -eq 0 ] && printf '%s' "$link_out" | grep -q "Connected to"; then
            down_since=""
            poll_int=2

            current_ch=""
            if get_channel "$INTERFACE"; then current_ch="$CH"; fi
            if [ -n "$current_ch" ] && [ "$current_ch" != "$last_channel" ]; then
                log "WARN" "Upstream channel changed ($last_channel -> $current_ch). Re-evaluating AP..."
                if [[ ",$SUPPORTED_CHANNELS," != *",$current_ch,"* ]]; then
                    log "ERR" "New channel $current_ch is unsupported for AP broadcast. Shutting down."
                    set_state "CHANNEL_UNSUPPORTED" "Hotspot stopped: channel $current_ch unsupported"
                    break
                fi

                set_state "CHANNEL_DRIFT" "Hotspot restarting: channel changed to $current_ch"
                stop_create_ap
                CHANNEL="$current_ch"
                last_channel="$current_ch"

                launch_create_ap "$CHANNEL"
                if ! wait_for_ap; then
                    log "ERR" "Failed to bring up AP on channel $CHANNEL within ${AP_START_TIMEOUT}s."
                    set_state "ERROR" "Hotspot stopped: AP re-init failed"
                    break
                fi
                log "INFO" "create_ap successfully restarted on channel $CHANNEL (pid $CREATE_AP_PID)."
                set_state "LIVE" "Hotspot is live on channel $CHANNEL!"
            fi
        else
            # "Not connected", or iw itself failed (driver reset, card removed)
            poll_int=1
            if [ -z "$down_since" ]; then
                down_since="$now"
            fi
            if [ $((now - down_since)) -ge "$UPSTREAM_GRACE" ]; then
                sleep 2
                if ! iw dev "$INTERFACE" link 2>/dev/null | grep -q "Connected to"; then
                    log "ERR" "Upstream Wi-Fi disconnected permanently. Shutting down hotspot."
                    set_state "DISCONNECTED" "Hotspot stopped: upstream Wi-Fi disconnected"
                    break
                fi
                down_since=""
            fi
        fi

        sleep "$poll_int"
    done
}

start_hotspot() {
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Starting the hotspot requires root. Run: sudo fiero-hotspot start"
        exit 1
    fi
    load_config

    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        log "INFO" "Another instance is running. Exiting."
        exit 0
    }

    # Leftover from an earlier run of ours (e.g. a killed foreground session)
    if [ -n "$(current_pid)" ]; then
        log "WARN" "Stopping stale create_ap from a previous run..."
        stop_create_ap
    fi

    local escaped_if
    escaped_if=$(escape_regex "$INTERFACE")
    if pgrep -f "create_ap.*$escaped_if" >/dev/null; then
        log "WARN" "create_ap is already running on $INTERFACE (started outside Fiero?). Not touching it."
        log "WARN" "Stop it first, e.g.: sudo create_ap --stop $INTERFACE"
        set_state "ERROR" "Hotspot not started: another hotspot is already running on $INTERFACE"
        exit 0
    fi

    ensure_run_dir
    rm -f "$STOP_FLAG"

    # trap fires on normal exit and on SIGINT/SIGTERM; cleanup is idempotent
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 0' TERM

    log "INFO" "Starting hotspot process..."

    refresh_supported_channels

    if ! detect_channel; then
        log "ERR" "Could not detect WiFi channel on $INTERFACE. Aborting."
        set_state "DISCONNECTED" "Hotspot could not start: no upstream Wi-Fi detected"
        exit 0
    fi

    if [[ ",$SUPPORTED_CHANNELS," != *",$CHANNEL,"* ]]; then
        log "ERR" "Channel $CHANNEL is not supported for AP broadcast on this hardware. Aborting."
        set_state "CHANNEL_UNSUPPORTED" "Hotspot could not start: Channel $CHANNEL is unsupported"
        exit 0
    fi

    set_state "STARTING" "Starting hotspot on channel $CHANNEL..."

    log "INFO" "Launching create_ap in background..."
    launch_create_ap "$CHANNEL"

    if ! wait_for_ap; then
        if kill -0 "$CREATE_AP_PID" 2>/dev/null; then
            log "ERR" "create_ap failed to start (pid $CREATE_AP_PID, no AP within ${AP_START_TIMEOUT}s)."
        else
            log "ERR" "create_ap exited during startup."
        fi
        set_state "ERROR" "Hotspot could not start (see: journalctl -u fiero-hotspot)"
        exit 1
    fi

    log "INFO" "create_ap is live (pid $CREATE_AP_PID, AP interface $(read_state "$IFACE_FILE"))."
    set_state "LIVE" "Hotspot is live! SSID: $SSID"

    monitor_hotspot
    exit 0
}

stop_hotspot() {
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Stopping the hotspot requires root. Run: sudo fiero-hotspot stop"
        exit 1
    fi
    load_config

    # Run by hand while systemd owns the hotspot: let systemd stop it, so
    # the service state stays correct. (INVOCATION_ID is set for processes
    # started by systemd, including ExecStop=.)
    if [ -z "${INVOCATION_ID:-}" ] && systemctl is-active --quiet fiero-hotspot.service 2>/dev/null; then
        log "INFO" "Stopping fiero-hotspot.service..."
        exec systemctl stop fiero-hotspot.service
    fi

    ensure_run_dir
    touch "$STOP_FLAG"
    log "INFO" "Stopping hotspot..."
    stop_create_ap

    if ac_online; then
        set_state "STOPPED" "Hotspot stopped manually"
    else
        set_state "STOPPED" "Hotspot stopped (charger unplugged)"
    fi
}

status_hotspot() {
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Status requires root. Run: sudo fiero-hotspot status"
        exit 1
    fi
    load_config

    local svc_state pid ap_iface ap_channel ap_freq client_count ac_status

    svc_state=$(systemctl is-active fiero-hotspot.service 2>/dev/null || true)
    svc_state="${svc_state:-inactive}"

    pid=$(current_pid) || pid=""
    if [ "$svc_state" != "active" ] && [ -n "$pid" ]; then
        svc_state="running in foreground (pid $pid)"
    fi

    ap_iface=""
    [ -n "$pid" ] && ap_iface=$(read_state "$IFACE_FILE")
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
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Client listing requires root. Run: sudo fiero-hotspot clients"
        exit 1
    fi
    load_config

    local pid ap_iface confdir
    pid=$(current_pid) || pid=""
    ap_iface=""
    [ -n "$pid" ] && ap_iface=$(read_state "$IFACE_FILE")

    if [ -z "$ap_iface" ]; then
        log "INFO" "Hotspot is not running. No AP interface found."
        exit 0
    fi

    # The service runs with a private /tmp; /proc/<pid>/root reaches the
    # create_ap process's own view of it from outside the sandbox.
    local -A mac_to_ip mac_to_host
    local lease_file
    confdir=$(read_state "$CONFDIR_FILE")
    for lease_file in /var/lib/misc/dnsmasq.leases "/proc/$pid/root$confdir/dnsmasq.leases"; do
        if [ "$lease_file" != "/var/lib/misc/dnsmasq.leases" ] && ! is_confdir_path "$confdir"; then
            continue
        fi
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

    # iw prints "\tsignal:  \t-45 [-47, -46] dBm" (two spaces, a tab, and an
    # optional per-chain list), so match any whitespace and stop at the number.
    local current_mac="" line
    local station_re='^Station ([0-9a-fA-F:]+)'
    local signal_re='^[[:space:]]*signal:[[:space:]]+(-?[0-9]+)'
    while IFS= read -r line; do
        if [[ "$line" =~ $station_re ]]; then
            current_mac="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $signal_re ]]; then
            local signal="${BASH_REMATCH[1]}"
            local ip="${mac_to_ip[$current_mac]:--}"
            local host="${mac_to_host[$current_mac]:--}"
            printf "  %-17s %-10s %-15s %s\n" "$current_mac" "${signal} dBm" "$ip" "$host"
        fi
    done <<<"$station_output"
}

update_auto_prompt() {
    local val="$1"
    if grep -q '^AUTO_PROMPT=' "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^AUTO_PROMPT=.*/AUTO_PROMPT='${val}'/" "$CONFIG_FILE"
    else
        echo "AUTO_PROMPT='${val}'" >>"$CONFIG_FILE"
    fi
    chown root:"$TARGET_USER" "$CONFIG_FILE" 2>/dev/null || true
    chmod 640 "$CONFIG_FILE" 2>/dev/null || true
}

mode_hotspot() {
    if [ "$EUID" -ne 0 ]; then
        log "ERR" "Mode toggle requires root. Run: sudo fiero-hotspot mode"
        exit 1
    fi
    load_config

    local current="${AUTO_PROMPT:-true}" ans
    case "${1:-}" in
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
        log "ERR" "Unknown mode: '$1'. Use 'auto' or 'manual'."
        exit 1
        ;;
    esac
}

usage() {
    printf "Usage: fiero-hotspot {start|stop|status|clients|mode|version|help}\n"
    printf "\n"
    printf "  start    Start the hotspot daemon\n"
    printf "  stop     Stop the hotspot daemon\n"
    printf "  status   Show hotspot status dashboard\n"
    printf "  clients  List connected clients\n"
    printf "  mode     Toggle or set trigger mode (auto|manual)\n"
    printf "  version  Show version information (also: -v, --version)\n"
    printf "  help     Show this help message\n"
}

case "${1:-}" in
start) start_hotspot ;;
stop) stop_hotspot ;;
status) status_hotspot ;;
clients) clients_hotspot ;;
mode | toggle) mode_hotspot "${2:-}" ;;
version | -v | --version)
    printf "fiero-hotspot v%s\n" "$VERSION"
    ;;
help | -h | --help | "")
    usage
    ;;
*)
    log "ERR" "Unknown action: '$1'. Run 'fiero-hotspot help' for usage."
    exit 1
    ;;
esac

# END OF FILE
