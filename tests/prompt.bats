#!/usr/bin/env bats
# End-to-end tests of the real fiero-prompt.sh with a fake charger, D-Bus
# socket, notify-send, systemctl and sudo.

load helpers

PROMPT=/usr/local/bin/fiero-prompt
AC=/sys/class/power_supply/AC

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

plug() { echo "$1" >"$AC/online"; }

@test "plugged in and nobody answers: nothing is started by default" {
    plug 1
    "$PROMPT"
    grep -q "Start Fiero Hotspot" "$M/notify"
    [ ! -f "$M/sudo" ]
}

@test "plugged in and user clicks Start: hotspot is started" {
    plug 1
    echo start >"$M/notify-answer"
    "$PROMPT"
    grep -q "systemctl start fiero-hotspot.service" "$M/sudo"
}

@test "AUTO_START_ON_TIMEOUT=true restores start-on-timeout" {
    write_config "AUTO_START_ON_TIMEOUT='true'"
    plug 1
    "$PROMPT"
    grep -q "systemctl start fiero-hotspot.service" "$M/sudo"
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

@test "AUTO_PROMPT=false never prompts" {
    write_config "AUTO_PROMPT='false'"
    plug 1
    "$PROMPT"
    [ ! -f "$M/notify" ]
}
