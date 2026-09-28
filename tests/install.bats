#!/usr/bin/env bats
# Tests of the real install.sh / uninstall.sh with fake hardware tools and
# the real visudo.

load helpers

WORK=/tmp/fiero-src
ANSWERS='My Hotspot\ngoodpass123\ngoodpass123\n\n\n\n'

setup_file() {
    require_container
    install_mocks
    id tester >/dev/null 2>&1 || useradd -m tester
    # Written via /fake-power, read by install.sh at /sys/class/power_supply
    # (see tests/run.sh).
    mkdir -p /fake-power/AC /etc/udev/rules.d /etc/systemd/system
    echo Mains >/fake-power/AC/type
    rm -rf "$WORK"
    cp -r "$REPO" "$WORK"
}

setup() {
    reset_state
    rm -f /etc/fiero-hotspot.conf /etc/sudoers.d/fiero-hotspot /etc/sudoers.d/.fiero-hotspot.tmp \
        /usr/local/bin/fiero-hotspot /usr/local/bin/fiero-prompt
}

install_as_tester() {
    printf "$1" | SUDO_USER=tester bash "$WORK/install.sh"
}

@test "fresh install writes a protected config and a valid sudoers rule" {
    run install_as_tester "$ANSWERS"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a %U %G' /etc/fiero-hotspot.conf)" = "640 root tester" ]
    grep -qx "AUTO_START_ON_TIMEOUT='true'" /etc/fiero-hotspot.conf
    grep -qx "AUTO_STOP_ON_TIMEOUT='true'" /etc/fiero-hotspot.conf
    visudo -cf /etc/sudoers.d/fiero-hotspot
    [ ! -e /etc/sudoers.d/.fiero-hotspot.tmp ]
    [ -x /usr/local/bin/fiero-hotspot ]
}

@test "answering no to both timeout questions disables both fallbacks" {
    run install_as_tester 'My Hotspot\ngoodpass123\ngoodpass123\n\nn\nn\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start on plug-in timeout : false"* ]]
    [[ "$output" == *"stop on unplug timeout   : false"* ]]
    grep -qx "AUTO_START_ON_TIMEOUT='false'" /etc/fiero-hotspot.conf
    grep -qx "AUTO_STOP_ON_TIMEOUT='false'" /etc/fiero-hotspot.conf
}

@test "installer refuses to run from a root shell" {
    run bash -c "printf 'x\n' | env -u SUDO_USER bash $WORK/install.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not from a root shell"* ]]
    [ ! -e /etc/fiero-hotspot.conf ]
}

@test "a sudoers rule that fails validation is never installed" {
    mv /usr/sbin/visudo /usr/sbin/visudo.real
    printf '#!/bin/sh\nexit 1\n' >/usr/sbin/visudo
    chmod +x /usr/sbin/visudo
    run install_as_tester "$ANSWERS"
    mv -f /usr/sbin/visudo.real /usr/sbin/visudo
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed validation"* ]]
    [ ! -e /etc/sudoers.d/fiero-hotspot ]
    [ ! -e /etc/sudoers.d/.fiero-hotspot.tmp ]
    visudo -c
}

@test "re-install keeps the existing config byte for byte" {
    install_as_tester "$ANSWERS"
    before=$(sha256sum /etc/fiero-hotspot.conf)
    rm -f /usr/local/bin/fiero-hotspot
    run install_as_tester '\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Keeping existing configuration"* ]]
    [ "$(sha256sum /etc/fiero-hotspot.conf)" = "$before" ]
    [ -x /usr/local/bin/fiero-hotspot ]
}

@test "passwords create_ap's config parser would change are rejected" {
    run install_as_tester 'My Hotspot\nbad\\\\pass123\nbad\\\\pass123\ngoodpass123\ngoodpass123\n\n\n\n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"must not contain a backslash"* ]]
    grep -qx "PASSWORD='goodpass123'" /etc/fiero-hotspot.conf
}

@test "with two Wi-Fi cards the user picks the upstream one" {
    touch "$M/multi"
    run install_as_tester "2\\n$ANSWERS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2) wlan1"* ]]
    grep -qx "INTERFACE='wlan1'" /etc/fiero-hotspot.conf
}

@test "uninstall --keep-config keeps the config, plain uninstall removes it" {
    install_as_tester "$ANSWERS"
    run bash "$WORK/uninstall.sh" --keep-config
    [ "$status" -eq 0 ]
    [ -f /etc/fiero-hotspot.conf ]
    [ ! -e /etc/sudoers.d/fiero-hotspot ]
    run bash "$WORK/uninstall.sh"
    [ "$status" -eq 0 ]
    [ ! -e /etc/fiero-hotspot.conf ]
}
