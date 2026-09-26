#!/usr/bin/env bats
# End-to-end tests of the real fiero-hotspot.sh against create_ap/iw doubles.

load helpers

setup_file() {
    require_container
    install_mocks
}

setup() {
    reset_state
    write_config
}

teardown() {
    stop_daemon >/dev/null 2>&1 || true
    kill_doubles
}

@test "start brings the AP up and records our own instance" {
    start_daemon
    pid=$(cat /run/fiero-hotspot/create_ap.pid)
    tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q create_ap
    [ "$(cat /run/fiero-hotspot/ap_iface)" = ap0 ]
    [[ "$(cat /run/fiero-hotspot/confdir)" == /tmp/create_ap.wlan0.conf.* ]]
}

@test "status and clients report the running hotspot" {
    start_daemon
    run bash "$FH" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"AP iface   : ap0"* ]]
    [[ "$output" == *"Clients    : 1"* ]]

    run bash "$FH" clients
    [ "$status" -eq 0 ]
    [[ "$output" == *"aa:bb:cc:dd:ee:ff -45 dBm    192.168.12.10   phone"* ]]
}

@test "stop waits for create_ap's own cleanup and leaves nothing behind" {
    echo 3 >"$M/stop-delay"
    start_daemon
    t0=$(date +%s)
    stop_daemon
    [ $(($(date +%s) - t0)) -ge 3 ]
    grep -q clean-exit "$M/events"
    grep -q "stopped on request" "$M/start.log"
    refute grep -q unexpectedly "$M/start.log"
    refute sh -c 'ls -d /tmp/create_ap.* 2>/dev/null'
    refute pgrep -f "^hostapd"
    [ ! -e /run/fiero-hotspot/create_ap.pid ]
}

@test "passphrase never appears on a command line" {
    start_daemon
    refute grep -q "s3cret-pass" "$M/argv"
    grep -q "^--config /run/fiero-hotspot/create_ap.conf" "$M/argv"
    grep -qx "PASSPHRASE=s3cret-pass" "$M/last-config"
    grep -qx "CHANNEL=6" "$M/last-config"
    [ "$(cat "$M/conf-mode")" = 600 ]
    [ ! -e /run/fiero-hotspot/create_ap.conf ]
    refute sh -c 'ps -eo args | grep -v grep | grep -q "s3cret-pass"'
}

@test "a passphrase create_ap's config parser would mangle falls back to argv with a warning" {
    write_config
    sed -i "s/^PASSWORD=.*/PASSWORD='back\\\\slash-pass'/" /etc/fiero-hotspot.conf
    start_daemon
    grep -q "Passing them on the command line" "$M/start.log"
    grep -qF 'back\slash-pass' "$M/argv"
}

@test "another tool's create_ap on the interface is left alone" {
    bash -c "exec -a 'create_ap wlan0 wlan0 Other pass' sleep 1000" 3>&- &
    foreign=$!
    run bash "$FH" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not touching it"* ]]
    kill -0 "$foreign"
    kill "$foreign"
}

@test "--no-virt fallback (AP on the physical card) is detected and never deleted" {
    touch "$M/no-virt"
    start_daemon
    [ "$(cat /run/fiero-hotspot/ap_iface)" = wlan0 ]
    stop_daemon
    refute grep -q "del" "$M/events"
}

@test "AP follows the upstream to a new channel" {
    start_daemon
    first=$(cat /run/fiero-hotspot/create_ap.pid)
    echo 11 >"$M/channel"
    wait_for_log "restarted on channel 11" "$M/start.log" 15
    grep -q "clean-exit $first" "$M/events"
    [ "$(cat /run/fiero-hotspot/create_ap.pid)" != "$first" ]
}

@test "hung create_ap is forced down; only its own hostapd is killed" {
    touch "$M/ignore-usr1"
    bash -c "exec -a 'hostapd /tmp/other/hostapd.conf' sleep 1000" 3>&- &
    other=$!
    start_daemon
    stop_daemon
    grep -q "forcing it" "$M/stop.log"
    refute pgrep -f "hostapd /tmp/create_ap"
    kill -0 "$other"
    kill "$other"
}

@test "a failing 'iw dev link' counts as upstream lost and shuts down" {
    start_daemon
    touch "$M/link-fails"
    wait_for_log "disconnected permanently" "$M/start.log" 25
}

@test "unsupported upstream channel aborts without starting create_ap" {
    echo 36 >"$M/channel"
    run bash "$FH" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Channel 36 is not supported"* ]]
    [ ! -s "$M/argv" ]
}

@test "help and version need no root, config or create_ap" {
    rm -f /etc/fiero-hotspot.conf
    run su nobody -s /bin/bash -c "bash $FH version"
    [ "$status" -eq 0 ]
    [[ "$output" == "fiero-hotspot v"* ]]
    run su nobody -s /bin/bash -c "bash $FH help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: fiero-hotspot"* ]]
}

@test "root-only commands explain themselves to normal users" {
    for cmd in start stop status clients mode; do
        run su nobody -s /bin/bash -c "bash $FH $cmd"
        [ "$status" -eq 1 ]
        [[ "$output" == *"requires root"* ]]
    done
}
