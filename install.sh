#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run this installer with sudo."
    exit 1
fi

# Secret-bearing files (config with WPA passphrase, sudoers drop-in) must never
# be world-readable, even for the instant between creation and chmod.
umask 077

echo "=== Fiero Hotspot Installer ==="

# ---------------------------------------------------------
# 1. DEPENDENCY AUDIT (Distro-Aware)
# ---------------------------------------------------------
REQUIRED_CMDS=("create_ap" "hostapd" "dnsmasq" "iw" "iptables" "notify-send" "pgrep" "pkill" "flock")
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
    NEED_AUR_CREATE_AP=0
    for cmd in "${MISSING_CMDS[@]}"; do
        case "$cmd" in
            notify-send) PKGS_ARCH+="libnotify "; PKGS_DEB+="libnotify-bin "; PKGS_RPM+="libnotify " ;;
            pgrep|pkill)  PKGS_ARCH+="procps-ng "; PKGS_DEB+="procps ";      PKGS_RPM+="procps-ng " ;;
            flock)        PKGS_ARCH+="util-linux "; PKGS_DEB+="util-linux ";  PKGS_RPM+="util-linux " ;;
            create_ap)   NEED_AUR_CREATE_AP=1 ;;
            *)           PKGS_ARCH+="$cmd ";      PKGS_DEB+="$cmd ";        PKGS_RPM+="$cmd " ;;
        esac
    done

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "To install missing packages, run:"
        # Use ID_LIKE as a fallback if ID is too specific (e.g., garuda -> arch)
        case "${ID_LIKE:-$ID}" in
            *arch*)
                if [ -n "$PKGS_ARCH" ]; then
                    echo "  Official repos: sudo pacman -S $PKGS_ARCH"
                fi
                if [ "$NEED_AUR_CREATE_AP" -eq 1 ]; then
                    echo "  AUR (required): yay -S linux-wifi-hotspot (or paru -S linux-wifi-hotspot)"
                fi
                ;;
            *debian*) if [ -n "$PKGS_DEB" ]; then echo "  sudo apt install $PKGS_DEB"; fi ;;
            *fedora*) if [ -n "$PKGS_RPM" ]; then echo "  sudo dnf install $PKGS_RPM"; fi ;;
            *)        if [ -n "$PKGS_ARCH" ]; then echo "  Please use your package manager to install: $PKGS_ARCH"; fi ;;
        esac
    else
        if [ -n "$PKGS_ARCH" ]; then
            echo "Please use your package manager to install: $PKGS_ARCH"
        fi
    fi

    if [ "$NEED_AUR_CREATE_AP" -eq 1 ] && [[ "${ID_LIKE:-$ID}" != *arch* ]]; then
        echo ""
        echo "  NOTE: 'create_ap' is dead upstream and is not packaged for this distro."
        echo "  Install the maintained fork (provides create_ap):"
        echo "    Debian/Ubuntu: .deb from https://github.com/lakinduakash/linux-wifi-hotspot/releases"
        echo "    Other distros: git clone https://github.com/lakinduakash/linux-wifi-hotspot && sudo make install"
    fi
    exit 1
fi


SRC_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_PATH="/etc/fiero-hotspot.conf"
SUDOERS_FILE="/etc/sudoers.d/fiero-hotspot"
# sudo ignores sudoers.d files whose name contains a dot, so this temp file
# stays inert until it has been validated and renamed into place.
SUDOERS_TMP="/etc/sudoers.d/.fiero-hotspot.tmp"
CONFIG_TMP="${CONFIG_PATH}.tmp.$$"
trap 'rm -f "$SUDOERS_TMP" "$CONFIG_TMP"' EXIT

# Read one value from an existing config without polluting this shell.
conf_get() {
    (
        # shellcheck disable=SC1090
        . "$CONFIG_PATH" >/dev/null 2>&1
        printf '%s' "${!1:-}"
    )
}

# create_ap reads its config file with a plain `read`, which drops
# backslashes and trims surrounding spaces (see fiero-hotspot.sh).
has_config_unsafe_chars() {
    case "$1" in *\\* | [[:space:]]* | *[[:space:]]) return 0 ;; esac
    return 1
}

has_non_printable_ascii() {
    printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'
}

# ---------------------------------------------------------
# 2. TARGET USER & EXISTING CONFIGURATION
# ---------------------------------------------------------
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Error: run the installer with sudo from the desktop user who should get the hotspot prompts,"
    echo "       e.g. 'sudo ./install.sh' - not from a root shell."
    exit 1
fi

KEEP_CONFIG=0
if [ -f "$CONFIG_PATH" ]; then
    read -rp "Existing configuration found at $CONFIG_PATH. Keep it? [Y/n]: " KEEP_INPUT
    case "${KEEP_INPUT:-Y}" in
        [nN] | [nN][oO]) ;;
        *) KEEP_CONFIG=1 ;;
    esac
fi

if [ "$KEEP_CONFIG" -eq 1 ]; then
    existing_user=$(conf_get TARGET_USER)
    if [ -n "$existing_user" ] && id -u "$existing_user" >/dev/null 2>&1; then
        TARGET_USER="$existing_user"
    fi
    AUTO_PROMPT=$(conf_get AUTO_PROMPT)
    AUTO_PROMPT="${AUTO_PROMPT:-true}"
    echo "Keeping existing configuration (target user: $TARGET_USER)."
fi
TARGET_UID=$(id -u "$TARGET_USER")

if [ "$KEEP_CONFIG" -eq 0 ]; then
    # ---------------------------------------------------------
    # 3. INTERFACE & HARDWARE DISCOVERY
    # ---------------------------------------------------------
    mapfile -t WIFI_IFACES < <(iw dev | awk '$1=="Interface" && $2 !~ /^ap[0-9]+/ {print $2}')
    if [ "${#WIFI_IFACES[@]}" -eq 0 ]; then
        echo "Could not detect a Wi-Fi interface."
        exit 1
    elif [ "${#WIFI_IFACES[@]}" -eq 1 ]; then
        INTERFACE="${WIFI_IFACES[0]}"
    else
        echo "Multiple Wi-Fi interfaces found:"
        for i in "${!WIFI_IFACES[@]}"; do
            echo "  $((i + 1))) ${WIFI_IFACES[$i]}"
        done
        while true; do
            read -rp "Which one is connected to the upstream Wi-Fi? [1]: " IFACE_CHOICE
            IFACE_CHOICE="${IFACE_CHOICE:-1}"
            if [[ "$IFACE_CHOICE" =~ ^[0-9]+$ ]] && [ "$IFACE_CHOICE" -ge 1 ] && [ "$IFACE_CHOICE" -le "${#WIFI_IFACES[@]}" ]; then
                INTERFACE="${WIFI_IFACES[$((IFACE_CHOICE - 1))]}"
                break
            fi
            echo "Please enter a number between 1 and ${#WIFI_IFACES[@]}."
        done
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
    # 4. RF SPECTRUM DISCOVERY
    # ---------------------------------------------------------
    echo "Discovering supported RF channels for $INTERFACE..."
    PHY=$(iw dev "$INTERFACE" info | awk '/wiphy/{print "phy"$2}')
    SUPPORTED_CHANNELS=""

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
    # 5. SSID & PASSPHRASE VALIDATION
    # ---------------------------------------------------------
    echo ""
    read -rp "Enter SSID for the hotspot: " SSID

    if [ -z "$SSID" ]; then
        echo "Error: SSID cannot be empty."
        exit 1
    fi
    if [ "${#SSID}" -gt 32 ]; then
        echo "Error: SSID must be 32 characters or fewer (802.11 limit)."
        exit 1
    fi
    if has_non_printable_ascii "$SSID"; then
        echo "Error: SSID contains non-printable characters."
        exit 1
    fi
    if has_config_unsafe_chars "$SSID"; then
        echo "Error: SSID must not contain a backslash or start/end with a space."
        exit 1
    fi

    while true; do
        read -rsp "Enter password for the hotspot (8-63 chars): " PASSWORD
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

        if [ "${#PASSWORD}" -gt 63 ]; then
            echo "Error: Password must be 63 characters or fewer (WPA2 limit). Please try again."
            continue
        fi

        if has_non_printable_ascii "$PASSWORD"; then
            echo "Error: Password may only use printable ASCII characters (WPA2 requirement). Please try again."
            continue
        fi

        if has_config_unsafe_chars "$PASSWORD"; then
            echo "Error: Password must not contain a backslash or start/end with a space (it could not be kept out of the process list). Please try again."
            continue
        fi

        break
    done
    echo

    # ---------------------------------------------------------
    # 5b. AUTO_PROMPT SELECTION
    # ---------------------------------------------------------
    read -rp "Enable automatic hotspot prompt on charger connection? [Y/n]: " AUTO_PROMPT_INPUT
    case "${AUTO_PROMPT_INPUT:-Y}" in
        [nN] | [nN][oO]) AUTO_PROMPT="false" ;;
        *) AUTO_PROMPT="true" ;;
    esac

    # ---------------------------------------------------------
    # 6. CONFIGURATION
    # ---------------------------------------------------------
    # Single-quote a value so the config can be sourced safely even if it
    # contains quotes, $, backticks, or backslashes (e.g. an SSID like "Bob's 5G").
    shquote() {
        local s="$1"
        s="${s//\'/\'\\\'\'}"
        printf "'%s'\n" "$s"
    }

    cat >"$CONFIG_TMP" <<EOF
SSID=$(shquote "$SSID")
PASSWORD=$(shquote "$PASSWORD")
INTERFACE=$(shquote "$INTERFACE")
POWER_SUPPLY=$(shquote "$POWER_SUPPLY")
SUPPORTED_CHANNELS=$(shquote "$SUPPORTED_CHANNELS")
TARGET_USER=$(shquote "$TARGET_USER")
TARGET_UID=$(shquote "$TARGET_UID")
AUTO_PROMPT=$(shquote "$AUTO_PROMPT")
AUTO_START_ON_TIMEOUT='false'
EOF

    chown root:"$TARGET_USER" "$CONFIG_TMP"
    chmod 640 "$CONFIG_TMP"
    mv "$CONFIG_TMP" "$CONFIG_PATH"
    echo "Config written to $CONFIG_PATH (permissions 640)."
fi

# ---------------------------------------------------------
# 7. DEPLOYMENT
# ---------------------------------------------------------
install -m 755 -o root -g root "$SRC_DIR/fiero-hotspot.sh" /usr/local/bin/fiero-hotspot
echo "Installed script to /usr/local/bin/fiero-hotspot (permissions 755)."

install -m 755 -o root -g root "$SRC_DIR/fiero-prompt.sh" /usr/local/bin/fiero-prompt
echo "Installed script to /usr/local/bin/fiero-prompt (permissions 755)."

install -m 644 -o root -g root "$SRC_DIR/fiero-hotspot.service" /etc/systemd/system/fiero-hotspot.service
echo "Installed systemd unit to /etc/systemd/system/fiero-hotspot.service"

install -m 644 -o root -g root "$SRC_DIR/99-fiero-hotspot.rules" /etc/udev/rules.d/99-fiero-hotspot.rules
escaped_target=$(printf '%s' "$TARGET_USER" | sed 's/[&/\]/\\&/g')
sed -i "s/@TARGET_USER@/${escaped_target}/g" /etc/udev/rules.d/99-fiero-hotspot.rules
echo "Installed udev rule to /etc/udev/rules.d/99-fiero-hotspot.rules"

# Validate before installing: a broken file in /etc/sudoers.d breaks sudo
# for the whole system.
printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl start fiero-hotspot.service, /usr/bin/systemctl stop fiero-hotspot.service\n' "$TARGET_USER" >"$SUDOERS_TMP"
chmod 440 "$SUDOERS_TMP"
chown root:root "$SUDOERS_TMP"
if ! visudo -cf "$SUDOERS_TMP" >/dev/null; then
    echo "Error: generated sudoers rule failed validation; not installing it."
    exit 1
fi
mv -f "$SUDOERS_TMP" "$SUDOERS_FILE"
echo "Installed sudoers drop-in to $SUDOERS_FILE (permissions 440)."

udevadm control --reload-rules
udevadm trigger --subsystem-match=power_supply --action=change
systemctl daemon-reload

echo
echo "Installation complete."
if [ "$AUTO_PROMPT" = "true" ]; then
    echo "When the charger is connected/disconnected, a desktop prompt will ask"
    echo "whether to start/stop the hotspot. If you don't answer, nothing is started"
    echo "(set AUTO_START_ON_TIMEOUT='true' in $CONFIG_PATH to change that)."
    TEST_CMD="sudo systemctl start fiero-hotspot.service"
else
    echo "Manual mode: use 'sudo fiero-hotspot start' to start and 'sudo fiero-hotspot stop' to stop."
    TEST_CMD="sudo fiero-hotspot start"
fi
echo "You can manually test it with: $TEST_CMD"
echo ""
echo "Hardened systemd unit installed. Inspect exposure with: systemd-analyze security fiero-hotspot.service"

# END OF FILE
