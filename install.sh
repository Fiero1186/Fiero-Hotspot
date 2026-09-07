#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run this installer with sudo."
    exit 1
fi

echo "=== Fiero Hotspot Installer ==="

# ---------------------------------------------------------
# 1. DEPENDENCY AUDIT (Distro-Aware)
# ---------------------------------------------------------
REQUIRED_CMDS=("create_ap" "hostapd" "dnsmasq" "iw" "iptables" "notify-send" "pgrep")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -ne 0 ]; then
    echo "Error: Missing required dependencies:"
    for cmd in "${MISSING_CMDS[@]}"; do
        echo "  - $cmd"
    done
    echo ""

    # Map generic binaries to distro-specific package names
    PKGS_ARCH=""
    PKGS_DEB=""
    PKGS_RPM=""
    for cmd in "${MISSING_CMDS[@]}"; do
        case "$cmd" in
            notify-send) PKGS_ARCH+="libnotify "; PKGS_DEB+="libnotify-bin "; PKGS_RPM+="libnotify " ;;
            pgrep)       PKGS_ARCH+="procps-ng "; PKGS_DEB+="procps ";      PKGS_RPM+="procps-ng " ;;
            *)           PKGS_ARCH+="$cmd ";      PKGS_DEB+="$cmd ";        PKGS_RPM+="$cmd " ;;
        esac
    done

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "To install missing packages, run:"
        # Use ID_LIKE as a fallback if ID is too specific (e.g., garuda -> arch)
        case "${ID_LIKE:-$ID}" in
            *arch*)   echo "  sudo pacman -S $PKGS_ARCH" ;;
            *debian*) echo "  sudo apt install $PKGS_DEB" ;;
            *fedora*) echo "  sudo dnf install $PKGS_RPM" ;;
            *)        echo "  Please use your package manager to install: $PKGS_ARCH" ;;
        esac
    else
        echo "Please use your package manager to install: $PKGS_ARCH"
    fi
    exit 1
fi

# ---------------------------------------------------------
# 2. INTERFACE & HARDWARE DISCOVERY
# ---------------------------------------------------------
INTERFACE=$(iw dev | awk '$1=="Interface"{print $2; exit}')
if [ -z "$INTERFACE" ]; then
    echo "Could not detect a Wi-Fi interface."
    exit 1
fi

POWER_SUPPLY=""
for supply in /sys/class/power_supply/*; do
    if [ -f "$supply/type" ] && grep -q "^Mains$" "$supply/type"; then
        POWER_SUPPLY=$(basename "$supply")
        break
    fi
done

if [ -z "$POWER_SUPPLY" ]; then
    echo "Could not detect the AC power supply name."
    exit 1
fi

echo "Detected Wi-Fi interface: $INTERFACE"
echo "Detected power supply: $POWER_SUPPLY"

# ---------------------------------------------------------
# 3. RF SPECTRUM DISCOVERY
# ---------------------------------------------------------
echo "Discovering supported RF channels for $INTERFACE..."
PHY=$(iw dev "$INTERFACE" info | awk '/wiphy/{print "phy"$2}')

if [ -n "$PHY" ]; then
    # Grab all channel lines, allow for decimal outputs (.0 MHz), exclude restricted flags, extract the channel number, and join with commas
    SUPPORTED_CHANNELS=$(iw phy "$PHY" info | grep -E '\* [0-9]+(\.[0-9]+)? MHz \[[0-9]+\]' | grep -vE '(disabled|no IR|radar detection)' | awk -F'[][]' '{print $2}' | paste -sd, -)
fi

if [ -z "$SUPPORTED_CHANNELS" ]; then
    SUPPORTED_CHANNELS="1,2,3,4,5,6,7,8,9,10,11,36,40,44,48"
    echo "Warning: Could not parse PHY dynamically. Defaulting to safe fallback channels."
else
    echo "Safe broadcast channels detected: $SUPPORTED_CHANNELS"
fi

# ---------------------------------------------------------
# 4. PASSPHRASE VALIDATION
# ---------------------------------------------------------
echo ""
read -rp "Enter SSID for the hotspot: " SSID

while true; do
    read -rsp "Enter password for the hotspot (min 8 chars): " PASSWORD
    echo
    read -rsp "Confirm password: " PASSWORD_CONFIRM
    echo

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match. Please try again."
        continue
    fi

    if [ "${#PASSWORD}" -lt 8 ]; then
        echo "Error: Password must be at least 8 characters long (WPA2 requirement). Please try again."
        continue
    fi

    break
done
echo

# ---------------------------------------------------------
# 5. CONFIGURATION & DEPLOYMENT
# ---------------------------------------------------------
CONFIG_PATH="/etc/fiero-hotspot.conf"

# Single-quote a value so the config can be sourced safely even if it
# contains quotes, $, backticks, or backslashes (e.g. an SSID like "Bob's 5G").
shquote() {
    local s="$1"
    s="${s//\'/\'\\\'\'}"
    printf "'%s'\n" "$s"
}

cat > "$CONFIG_PATH" <<EOF
SSID=$(shquote "$SSID")
PASSWORD=$(shquote "$PASSWORD")
INTERFACE=$(shquote "$INTERFACE")
POWER_SUPPLY=$(shquote "$POWER_SUPPLY")
SUPPORTED_CHANNELS=$(shquote "$SUPPORTED_CHANNELS")
EOF

chmod 600 "$CONFIG_PATH"
chown root:root "$CONFIG_PATH"
echo "Config written to $CONFIG_PATH (permissions 600)."

install -m 755 -o root -g root fiero-hotspot.sh /usr/local/bin/fiero-hotspot
echo "Installed script to /usr/local/bin/fiero-hotspot (permissions 755)."

install -m 644 -o root -g root fiero-hotspot.service /etc/systemd/system/fiero-hotspot.service
echo "Installed systemd unit to /etc/systemd/system/fiero-hotspot.service"

install -m 644 -o root -g root 99-fiero-hotspot.rules /etc/udev/rules.d/99-fiero-hotspot.rules
echo "Installed udev rule to /etc/udev/rules.d/99-fiero-hotspot.rules"

udevadm control --reload-rules
systemctl daemon-reload
systemctl enable fiero-hotspot.service

echo
echo "Installation complete."
echo "The hotspot will now auto-start when the charger is connected."
echo "You can manually test it with: sudo systemctl start fiero-hotspot.service"
