#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run this uninstaller with sudo."
    exit 1
fi

KEEP_CONFIG=0
case "${1:-}" in
    --keep-config) KEEP_CONFIG=1 ;;
    "") ;;
    *)
        echo "Usage: sudo ./uninstall.sh [--keep-config]"
        exit 1
        ;;
esac

echo "=== Fiero Hotspot Uninstaller ==="

if systemctl list-unit-files | grep -q "^fiero-hotspot.service"; then
    systemctl stop fiero-hotspot.service >/dev/null 2>&1 || true
    systemctl disable fiero-hotspot.service >/dev/null 2>&1 || true
    echo "Stopped and disabled fiero-hotspot.service"
fi

# A hotspot started by hand (sudo fiero-hotspot start) is not a systemd unit;
# stop it cleanly so create_ap can restore ip_forward and NetworkManager.
if [ -x /usr/local/bin/fiero-hotspot ]; then
    /usr/local/bin/fiero-hotspot stop >/dev/null 2>&1 || true
fi

rm -f /usr/local/bin/fiero-hotspot
echo "Removed /usr/local/bin/fiero-hotspot"

rm -f /usr/local/bin/fiero-prompt
echo "Removed /usr/local/bin/fiero-prompt"
pkill -f 'fiero-prompt watch' 2>/dev/null || true

rm -f /etc/sudoers.d/fiero-hotspot /etc/sudoers.d/.fiero-hotspot.tmp
echo "Removed /etc/sudoers.d/fiero-hotspot"

if [ "$KEEP_CONFIG" -eq 1 ]; then
    echo "Kept /etc/fiero-hotspot.conf (--keep-config)"
else
    rm -f /etc/fiero-hotspot.conf
    echo "Removed /etc/fiero-hotspot.conf"
fi

rm -f /etc/systemd/system/fiero-hotspot.service
echo "Removed /etc/systemd/system/fiero-hotspot.service"

rm -f /etc/udev/rules.d/99-fiero-hotspot.rules
echo "Removed /etc/udev/rules.d/99-fiero-hotspot.rules"

rm -rf /run/fiero-hotspot
rm -f /run/fiero-hotspot.lock /run/fiero-shutting-down.lock
rm -f /run/user/*/fiero-prompt.lock /run/user/*/fiero-prompt.state 2>/dev/null || true
# /tmp/create_ap.* is left alone: create_ap removes its own directories, the
# service's are in its private /tmp, and others may belong to another tool.
echo "Cleaned runtime state and lock files"

udevadm control --reload-rules
systemctl daemon-reload

echo
echo "Uninstallation complete."
