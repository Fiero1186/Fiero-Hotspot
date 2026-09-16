#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run this uninstaller with sudo."
    exit 1
fi

echo "=== Fiero Hotspot Uninstaller ==="

if systemctl list-unit-files | grep -q "^fiero-hotspot.service"; then
    systemctl stop fiero-hotspot.service >/dev/null 2>&1 || true
    systemctl disable fiero-hotspot.service >/dev/null 2>&1 || true
    echo "Stopped and disabled fiero-hotspot.service"
fi

rm -f /usr/local/bin/fiero-hotspot
echo "Removed /usr/local/bin/fiero-hotspot"

rm -f /usr/local/bin/fiero-prompt
echo "Removed /usr/local/bin/fiero-prompt"

rm -f /etc/sudoers.d/fiero-hotspot
echo "Removed /etc/sudoers.d/fiero-hotspot"

rm -f /etc/fiero-hotspot.conf
echo "Removed /etc/fiero-hotspot.conf"

rm -f /etc/systemd/system/fiero-hotspot.service
echo "Removed /etc/systemd/system/fiero-hotspot.service"

rm -f /etc/udev/rules.d/99-fiero-hotspot.rules
echo "Removed /etc/udev/rules.d/99-fiero-hotspot.rules"

rm -f /run/fiero-hotspot.lock /run/fiero-shutting-down.lock
rm -f /run/user/*/fiero-prompt.lock /run/user/*/fiero-prompt.state 2>/dev/null || true
find /tmp -maxdepth 1 -name "create_ap*" -uid 0 ! -type l -exec rm -rf {} + 2>/dev/null || true
echo "Cleaned runtime state and lock files"

udevadm control --reload-rules
systemctl daemon-reload

echo
echo "Uninstallation complete."
