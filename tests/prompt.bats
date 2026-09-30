#!/usr/bin/env bats
# End-to-end tests of the real fiero-prompt.sh with a fake charger, D-Bus
# socket, notify-send, systemctl and sudo.

load helpers

PROMPT=/usr/local/bin/fiero-prompt
# The scripts read /sys/class/power_supply/AC; tests write the same files via
# /fake-power (see tests/run.sh), because writes under /sys are denied.
AC=/fake-power/AC

setup_file() {
    require_container
    install_mocks
    # Installed under its real name: the stale-prompt check looks at
    # /proc/<pid>/comm == fiero-prompt.
    install -m 755 "$REPO/fiero-prompt.sh" "$PROMPT"
    mkdir -p /run/user/0 "$AC"
    echo Mains >"$AC/type"
    rm -f /run/user/0/bus
    perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "/run/user/0/bus", Listen => 1) or die $!'
}

setup() {
    reset_state
    rm -f /run/user/0/fiero-prompt.state
    write_config
}

# Every non-watch invocation spawns a detached `fiero-prompt watch` (the
# notifier), and reset_state does not clear the watcher lock. Without this,
# one test's watcher tails the next test's synthetic events and double-counts
# notifications.
teardown() {
    stop_watcher
    kill_doubles
    rm -f /run/user/0/fiero-prompt.watch.lock
}

plug() { echo "$1" >"$AC/online"; }

# --- event watcher (fiero-prompt.sh watch) ---
EVENTS=/run/fiero-hotspot/events

# start_watcher [socket]: launch `fiero-prompt watch` detached and wait for it
# to take the flock. The optional socket is created when missing.
start_watcher() {
    local sock="${1:-/run/user/0/bus}"
    [ -S "$sock" ] || perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die $!' "$sock"
    rm -f /run/user/0/fiero-prompt.watch.lock
    : >"$M/notify"
    "$PROMPT" watch >"$M/watch.log" 2>&1 3>&- &
    echo $! >"$M/watch.pid"
    sleep 0.6
}

stop_watcher() {
    local pid
    pid=$(cat "$M/watch.pid" 2>/dev/null) || return 0
    kill "$pid" 2>/dev/null || true
    rm -f "$M/watch.pid"
}

# emit <STATE> <MSG>: append one record in the daemon's pipe-delimited format
emit() { printf '%s|%s|6|1700000000\n' "$1" "$2" >>"$EVENTS"; }

@test "the watcher maps ERROR and DISCONNECTED to critical urgency" {
    start_watcher
    emit ERROR "boom happened"
    emit DISCONNECTED "link is gone"
    wait_for_log "boom happened" "$M/notify" 10
    wait_for_log "link is gone" "$M/notify" 10
    grep -q "^notify .*boom happened.*--urgency=critical" "$M/notify"
    grep -q "^notify .*link is gone.*--urgency=critical" "$M/notify"
}

@test "the watcher maps STARTING and CHANNEL_DRIFT to low urgency" {
    start_watcher
    emit STARTING "booting up"
    emit CHANNEL_DRIFT "moving to 11"
    wait_for_log "booting up" "$M/notify" 10
    wait_for_log "moving to 11" "$M/notify" 10
    grep -q "^notify .*booting up.*--urgency=low" "$M/notify"
    grep -q "^notify .*moving to 11.*--urgency=low" "$M/notify"
}

@test "a second watcher refuses to start while one holds the lock" {
    start_watcher
    "$PROMPT" watch
    emit STARTING "only once"
    wait_for_log "only once" "$M/notify" 10
    sleep 1
    [ "$(grep -c "only once" "$M/notify")" -eq 1 ]
}

@test "the watcher releases its lock when the session bus disappears" {
    start_watcher
    rm -f /run/user/0/bus
    emit ERROR "bus went away"
    for _ in $(seq 1 20); do
        kill -0 "$(cat "$M/watch.pid")" 2>/dev/null || break
        sleep 0.25
    done
    refute kill -0 "$(cat "$M/watch.pid")" 2>/dev/null
    rm -f "$M/watch.pid"
    # A fresh watcher must be able to take the lock and receive events again.
    start_watcher
    emit ERROR "back after the bus returned"
    wait_for_log "back after the bus returned" "$M/notify" 10
}

@test "a denied elevation surfaces a critical notification" {
    plug 1
    touch "$M/sudo-fails"
    "$PROMPT"
    wait_for_log "sudo permission denied" "$M/notify" 10
    grep -q -- "--urgency=critical" "$M/notify"
}

@test "plugged in and nobody answers: hotspot is started by default" {
    plug 1
    "$PROMPT"
    grep -q "Start Fiero Hotspot" "$M/notify"
    grep -q "systemctl start fiero-hotspot.service" "$M/sudo"
}

@test "a config without the timeout keys still starts on timeout" {
    plug 1
    refute grep -q AUTO_START_ON_TIMEOUT /etc/fiero-hotspot.conf
    refute grep -q AUTO_STOP_ON_TIMEOUT /etc/fiero-hotspot.conf
    "$PROMPT"
    grep -q "systemctl start fiero-hotspot.service" "$M/sudo"
}

@test "plugged in and user clicks Start: hotspot is started" {
    plug 1
    echo start >"$M/notify-answer"
    "$PROMPT"
    grep -q "systemctl start fiero-hotspot.service" "$M/sudo"
}

@test "AUTO_START_ON_TIMEOUT=false does nothing when the Start prompt times out" {
    write_config "AUTO_START_ON_TIMEOUT='false'"
    plug 1
    "$PROMPT"
    grep -q "Start Fiero Hotspot" "$M/notify"
    [ ! -f "$M/sudo" ]
}

@test "unplugging while the Start prompt is open cancels it" {
    plug 1
    echo 4 >"$M/notify-delay"
    echo start >"$M/notify-answer"
    "$PROMPT" 3>&- &
    first=$!
    sleep 1
    plug 0
    rm -f "$M/notify-delay"
    "$PROMPT"
    sleep 0.5
    refute kill -0 "$first"
    sleep 4
    [ ! -f "$M/sudo" ]
}

@test "duplicate charger events within the cooldown show one prompt" {
    plug 1
    "$PROMPT"
    "$PROMPT"
    "$PROMPT"
    [ "$(grep -c -- "--action" "$M/notify")" -eq 1 ]
}

@test "unplugged with the hotspot running and no answer: hotspot is stopped" {
    touch "$M/svc-active"
    plug 0
    "$PROMPT"
    grep -q "systemctl stop fiero-hotspot.service" "$M/sudo"
}

@test "AUTO_STOP_ON_TIMEOUT=false keeps the hotspot running on timeout" {
    write_config "AUTO_STOP_ON_TIMEOUT='false'"
    touch "$M/svc-active"
    plug 0
    "$PROMPT"
    grep -q "AC disconnected" "$M/notify"
    [ ! -f "$M/sudo" ]
}

@test "clicking Keep Running wins over AUTO_STOP_ON_TIMEOUT=true" {
    write_config "AUTO_STOP_ON_TIMEOUT='true'"
    touch "$M/svc-active"
    plug 0
    echo keep >"$M/notify-answer"
    "$PROMPT"
    [ ! -f "$M/sudo" ]
}

@test "AUTO_PROMPT=false never prompts" {
    write_config "AUTO_PROMPT='false'"
    plug 1
    "$PROMPT"
    [ ! -f "$M/notify" ]
}
