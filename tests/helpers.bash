# Shared helpers for the bats suites.
#
# These tests replace system commands (iw, create_ap, systemctl, sudo, ...)
# with test doubles and write /etc/fiero-hotspot.conf, so they must only ever
# run inside the throwaway container started by tests/run.sh.

REPO="${REPO:-/src}"
M=/tmp/mock-state
FH="$REPO/fiero-hotspot.sh"

# refute <command...>: fail when the command succeeds. (A bare `! cmd` never
# fails a bats test: bash ignores negated commands under set -e.)
refute() {
    if "$@"; then
        echo "expected to fail: $*" >&2
        return 1
    fi
}

require_container() {
    if [ "${FIERO_TEST_CONTAINER:-}" != "1" ]; then
        echo "Refusing to run: these tests modify the system. Use tests/run.sh." >&2
        return 1
    fi
    # tests/run.sh mounts one scratch volume at both paths (fake charger).
    if [ ! -d /fake-power ] || ! mountpoint -q /sys/class/power_supply; then
        echo "Fake charger volume missing: start the tests with tests/run.sh." >&2
        return 1
    fi
}

install_mocks() {
    local m
    for m in create_ap iw ip systemctl sudo udevadm; do
        install -m 755 "$REPO/tests/mocks/$m" "/usr/local/bin/$m"
    done
    for m in hostapd dnsmasq iptables; do
        install -m 755 "$REPO/tests/mocks/stub" "/usr/local/bin/$m"
    done
    install -m 755 "$REPO/tests/mocks/notify-send" /usr/bin/notify-send
}

# Match only the test doubles. A broad `pkill -f hostapd` would also kill
# bats itself: bats-exec-test's command line contains the test's name.
kill_doubles() {
    pkill -f '^(/bin/bash /usr/local/bin/create_ap|create_ap |hostapd /tmp/)' 2>/dev/null || true
    pkill -f 'fiero-prompt watch' 2>/dev/null || true
}

reset_state() {
    kill_doubles
    sleep 0.3
    rm -rf "$M" /tmp/create_ap.* /run/fiero-hotspot /run/fiero-hotspot.lock
    mkdir -p "$M"
}

# write_config [extra lines...]
write_config() {
    {
        echo "SSID='Fiero Test'"
        echo "PASSWORD='s3cret-pass'"
        echo "INTERFACE='wlan0'"
        echo "SUPPORTED_CHANNELS='1,2,3,4,5,6,7,8,9,10,11'"
        local line
        for line in "$@"; do echo "$line"; done
    } >/etc/fiero-hotspot.conf
    chmod 600 /etc/fiero-hotspot.conf
}

# Start the daemon in the background and wait until it reports the AP live.
# fd 3 is closed so bats does not wait for the background process.
start_daemon() {
    bash "$FH" start >"$M/start.log" 2>&1 3>&- &
    echo $! >"$M/main.pid"
    wait_for_log "is live" "$M/start.log" 10
}

stop_daemon() {
    bash "$FH" stop >"$M/stop.log" 2>&1
    local pid
    pid=$(cat "$M/main.pid" 2>/dev/null) || return 0
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
    done
    return 1
}

# wait_for_log <text> <file> <seconds>
wait_for_log() {
    local i
    for ((i = 0; i < $3 * 4; i++)); do
        grep -q -- "$1" "$2" 2>/dev/null && return 0
        sleep 0.25
    done
    echo "timed out waiting for '$1' in $2:" >&2
    cat "$2" >&2 2>/dev/null
    return 1
}
