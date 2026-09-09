#!/usr/bin/env bash
# ==============================================================================
# Fiero Hotspot - Automated Lifecycle & Resource Benchmark Test Harness
# ==============================================================================

set -euo pipefail

# Edge case test counters
EDGE_PASS=0
EDGE_FAIL=0
EDGE_SKIP=0

# ------------------------------------------------------------------------------
# 0. Root Privilege & Configuration Validation
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] test-harness.sh must be executed with root privileges." >&2
  exit 1
fi

CONFIG_FILE="/etc/fiero-hotspot.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[FATAL] Configuration file '$CONFIG_FILE' not found." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

: "${INTERFACE:?[FATAL] INTERFACE variable is not set in $CONFIG_FILE}"
: "${TARGET_USER:?[FATAL] TARGET_USER variable is not set in $CONFIG_FILE}"
: "${TARGET_UID:?[FATAL] TARGET_UID variable is not set in $CONFIG_FILE}"

# ------------------------------------------------------------------------------
# 1. Logging Initialization
# ------------------------------------------------------------------------------
LOG_DIR="./test-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# Tee all execution output to 01-lifecycle-execution.log
exec > >(tee -a "$LOG_DIR/01-lifecycle-execution.log") 2>&1

echo "======================================================================"
echo " Starting Fiero Hotspot Test Harness Benchmark"
echo " Timestamp  : $(date -Iseconds)"
echo " Log Directory: $LOG_DIR"
echo " Interface  : $INTERFACE"
echo " Target User: $TARGET_USER (UID: $TARGET_UID)"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 2. D-Bus Monitor Subsystem & Cleanup Trap
# ------------------------------------------------------------------------------
DBUS_MONITOR_PID=""
EDGE_TMP_DIRS=()

cleanup() {
  local exit_code=$?
  set +e
  if [[ -n "${DBUS_MONITOR_PID:-}" ]]; then
    echo "[INFO] Terminating background D-Bus monitor (PID: $DBUS_MONITOR_PID)..."
    pkill -P "$DBUS_MONITOR_PID" 2>/dev/null || true
    kill -TERM "$DBUS_MONITOR_PID" 2>/dev/null || true
    wait "$DBUS_MONITOR_PID" 2>/dev/null || true
  fi
  if [[ ${#EDGE_TMP_DIRS[@]} -gt 0 ]]; then
    echo "[INFO] Cleaning up edge case test temp directories..."
    rm -rf "${EDGE_TMP_DIRS[@]}" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

echo "[INFO] Launching D-Bus notification monitor..."
su - "$TARGET_USER" -c "export XDG_RUNTIME_DIR=/run/user/$TARGET_UID; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$TARGET_UID/bus; exec dbus-monitor \"interface='org.freedesktop.Notifications'\"" > "$LOG_DIR/03-notifications-dbus.raw" 2>&1 &
DBUS_MONITOR_PID=$!
sleep 0.5

# ------------------------------------------------------------------------------
# 3. Environment Audit (00-environment-audit.log)
# ------------------------------------------------------------------------------
echo "[INFO] Capturing baseline environment audit..."
{
  echo "=== UNAME ==="
  uname -a || true
  echo -e "\n=== OS-RELEASE ==="
  cat /etc/os-release 2>/dev/null || true
  echo -e "\n=== LSPCI -K ==="
  lspci -k 2>/dev/null || true
  echo -e "\n=== LSUSB ==="
  lsusb 2>/dev/null || true
  echo -e "\n=== RFKILL LIST ALL ==="
  rfkill list all 2>/dev/null || true
  echo -e "\n=== IP ADDR ==="
  ip a 2>/dev/null || true
  echo -e "\n=== IW DEV ==="
  iw dev 2>/dev/null || true
  echo -e "\n=== IW PHY ==="
  iw phy 2>/dev/null || true
  echo -e "\n=== SYS CLASS POWER SUPPLY ==="
  find /sys/class/power_supply -type f -exec grep -H . {} + 2>/dev/null || true
} > "$LOG_DIR/00-environment-audit.log"

# ==============================================================================
# 4-8. EDGE CASE & UNIT-LEVEL TESTS (no hardware required, skippable)
# ==============================================================================
EDGE_TMP_DIR=$(mktemp -d)
EDGE_TMP_DIRS+=("$EDGE_TMP_DIR")

edge_result() {
  local name="$1" result="${2:-PASS}"
  case "$result" in
    PASS) EDGE_PASS=$((EDGE_PASS + 1)); echo "[PASS] $name" ;;
    FAIL) EDGE_FAIL=$((EDGE_FAIL + 1)); echo "[FAIL] $name" ;;
    SKIP) EDGE_SKIP=$((EDGE_SKIP + 1)); echo "[SKIP] $name" ;;
  esac
}

edge_assert_equal() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    edge_result "$name" PASS
  else
    edge_result "$name" FAIL
  fi
}

# log() replicated from fiero-hotspot.sh (lines 9-17)
log() {
  local level="$1"
  shift
  if [ "$level" = "ERR" ]; then
    echo "[$level] $*" >&2
  else
    echo "[$level] $*"
  fi
}

# ------------------------------------------------------------------------------
# 4. shquote() Unit Tests (extracted from install.sh lines 136-139)
# ------------------------------------------------------------------------------
shquote() {
  local s="$1"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'\n" "$s"
}

edge_assert_equal "Phase 4.1: shquote() simple string" "$(shquote "hello")" "'hello'"
edge_assert_equal "Phase 4.2: shquote() string with spaces" "$(shquote "hello world")" "'hello world'"
edge_assert_equal "Phase 4.3: shquote() single quotes" "$(shquote "Bob's")" "'Bob'\\''s'"
edge_assert_equal "Phase 4.4: shquote() dollar sign (literal)" "$(shquote '$HOME')" "'\$HOME'"
edge_assert_equal "Phase 4.5: shquote() backticks (literal)" "$(shquote '`whoami`')" "'\`whoami\`'"
edge_assert_equal "Phase 4.6: shquote() empty string" "$(shquote "")" "''"
edge_assert_equal "Phase 4.7: shquote() backslash" "$(shquote 'C:\path')" "'C:\\path'"
edge_assert_equal "Phase 4.8: shquote() double quotes" "$(shquote 'say "hi"')" "'say \"hi\"'"

# ------------------------------------------------------------------------------
# 5. install.sh Validation Tests (replicated logic, install.sh NOT executed)
# ------------------------------------------------------------------------------
# 5a. Dependency detection logic (install.sh lines 14-21)
cmd_audit() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  printf '%s\n' "${missing[@]}"
}

FAKE_BIN_DIR="$EDGE_TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
touch "$FAKE_BIN_DIR/create_ap" "$FAKE_BIN_DIR/hostapd" "$FAKE_BIN_DIR/iw"
chmod +x "$FAKE_BIN_DIR"/*

MISSING_ALL=$(PATH="$FAKE_BIN_DIR" cmd_audit create_ap hostapd iw)
if [[ -z "$MISSING_ALL" ]]; then
  edge_result "Phase 5a.1: dependency detection - all present" PASS
else
  edge_result "Phase 5a.1: dependency detection - all present" FAIL
fi

MISSING_ONE=$(PATH="$FAKE_BIN_DIR" cmd_audit create_ap hostapd iw notify-send)
if [[ "$MISSING_ONE" == "notify-send" ]]; then
  edge_result "Phase 5a.2: dependency detection - one missing" PASS
else
  edge_result "Phase 5a.2: dependency detection - one missing" FAIL
fi

MISSING_MANY=$(PATH="$FAKE_BIN_DIR" cmd_audit create_ap hostapd iw notify-send pgrep dnsmasq)
if [[ "$MISSING_MANY" == $'notify-send\npgrep\ndnsmasq' ]]; then
  edge_result "Phase 5a.3: dependency detection - multiple missing" PASS
else
  edge_result "Phase 5a.3: dependency detection - multiple missing" FAIL
fi

# 5b. Distro package name mapping (install.sh lines 30-54)
map_pkgs() {
  local PKGS_ARCH="" PKGS_DEB="" PKGS_RPM=""
  local cmd
  for cmd in "$@"; do
    case "$cmd" in
      notify-send) PKGS_ARCH+="libnotify "; PKGS_DEB+="libnotify-bin "; PKGS_RPM+="libnotify " ;;
      pgrep)       PKGS_ARCH+="procps-ng "; PKGS_DEB+="procps ";      PKGS_RPM+="procps-ng " ;;
      *)           PKGS_ARCH+="$cmd ";      PKGS_DEB+="$cmd ";        PKGS_RPM+="$cmd " ;;
    esac
  done
  printf '%s|%s|%s' "${PKGS_ARCH% }" "${PKGS_DEB% }" "${PKGS_RPM% }"
}

edge_assert_equal "Phase 5b.1: notify-send package mapping" "$(map_pkgs notify-send)" "libnotify|libnotify-bin|libnotify"
edge_assert_equal "Phase 5b.2: pgrep package mapping" "$(map_pkgs pgrep)" "procps-ng|procps|procps-ng"
edge_assert_equal "Phase 5b.3: unknown command passes through" "$(map_pkgs some-cmd)" "some-cmd|some-cmd|some-cmd"

# 5c. Password validation (install.sh lines 107-124)
validate_password() {
  local pwd="$1" confirm="$2"
  if [ "$pwd" != "$confirm" ]; then
    return 2
  fi
  if [ "${#pwd}" -lt 8 ]; then
    return 1
  fi
  return 0
}

if ! validate_password "short" "short"; then
  edge_result "Phase 5c.1: password shorter than 8 chars rejected" PASS
else
  edge_result "Phase 5c.1: password shorter than 8 chars rejected" FAIL
fi

if ! validate_password "password1" "password2"; then
  edge_result "Phase 5c.2: password mismatch rejected" PASS
else
  edge_result "Phase 5c.2: password mismatch rejected" FAIL
fi

if validate_password "12345678" "12345678"; then
  edge_result "Phase 5c.3: password exactly 8 chars accepted" PASS
else
  edge_result "Phase 5c.3: password exactly 8 chars accepted" FAIL
fi

if validate_password 'p@ssw0rd!#$' 'p@ssw0rd!#$'; then
  edge_result "Phase 5c.4: password with special chars accepted" PASS
else
  edge_result "Phase 5c.4: password with special chars accepted" FAIL
fi

# 5d. Interface detection (install.sh line 61)
detect_interface() {
  local output="$1"
  printf '%s' "$output" | awk '$1=="Interface" && $2 !~ /^ap[0-9]+/ {print $2; exit}'
}

edge_assert_equal "Phase 5d.1: non-ap interface detected" "$(detect_interface $'Interface ap0\nInterface wlan0')" "wlan0"
edge_assert_equal "Phase 5d.2: only ap interfaces -> empty" "$(detect_interface $'Interface ap0\nInterface ap1')" ""

# 5e. RF channel parsing (install.sh line 91)
parse_channels() {
  local input="$1"
  printf '%s' "$input" | grep -E '\* [0-9]+(\.[0-9]+)? MHz \[[0-9]+\]' | grep -vE '(disabled|no IR|radar detection)' | awk -F'[][]' '{print $2}' | paste -sd, -
}

IW_PHY_FULL=$(cat <<'PHYEOF'
* 2412.000 MHz [1] (30.0 dBm)
* 2417.000 MHz [2] (30.0 dBm)
* 2422.000 MHz [3] (30.0 dBm)
* 2427.000 MHz [4] (30.0 dBm)
* 2432.000 MHz [5] (30.0 dBm)
* 2437.000 MHz [6] (30.0 dBm)
* 2442.000 MHz [7] (30.0 dBm)
* 2447.000 MHz [8] (30.0 dBm)
* 2452.000 MHz [9] (30.0 dBm)
* 2457.000 MHz [10] (30.0 dBm)
* 2462.000 MHz [11] (30.0 dBm)
* 5180.000 MHz [36] (23.0 dBm)
* 5200.000 MHz [40] (23.0 dBm)
* 5220.000 MHz [44] (23.0 dBm)
* 5240.000 MHz [48] (23.0 dBm)
PHYEOF
)

IW_PHY_RESTRICTED=$(cat <<'PHYEOF'
* 2412.000 MHz [1] (30.0 dBm)
* 2417.000 MHz [2] (0.0 dBm) (disabled)
* 2422.000 MHz [3] (0.0 dBm) (no IR)
* 2427.000 MHz [4] (0.0 dBm) (radar detection)
* 5180.000 MHz [36] (23.0 dBm)
PHYEOF
)

edge_assert_equal "Phase 5e.1: parse channels 1-11 and 36-48" "$(parse_channels "$IW_PHY_FULL")" "1,2,3,4,5,6,7,8,9,10,11,36,40,44,48"
edge_assert_equal "Phase 5e.2: disabled/no IR/radar channels excluded" "$(parse_channels "$IW_PHY_RESTRICTED")" "1,36"

# ------------------------------------------------------------------------------
# 6. fiero-prompt.sh Unit Tests (replicated logic, file NOT sourced)
# ------------------------------------------------------------------------------
# 6a. ac_online() (fiero-prompt.sh lines 23-32) - power supply base override
ac_online() {
  local supply
  local base="${POWER_SUPPLY_BASE:-/sys/class/power_supply}"
  for supply in "$base"/*; do
    if [ -f "$supply/type" ] && grep -q "^Mains$" "$supply/type" \
      && [ "$(cat "$supply/online" 2>/dev/null)" = "1" ]; then
      return 0
    fi
  done
  return 1
}

PSU_MOCK="$EDGE_TMP_DIR/psu"
mkdir -p "$PSU_MOCK/Mains"
printf 'Mains\n' > "$PSU_MOCK/Mains/type"
printf '1\n' > "$PSU_MOCK/Mains/online"

if POWER_SUPPLY_BASE="$PSU_MOCK" ac_online; then
  edge_result "Phase 6a.1: ac_online() - Mains online=1" PASS
else
  edge_result "Phase 6a.1: ac_online() - Mains online=1" FAIL
fi

printf '0\n' > "$PSU_MOCK/Mains/online"
if POWER_SUPPLY_BASE="$PSU_MOCK" ac_online; then
  edge_result "Phase 6a.2: ac_online() - Mains online=0" FAIL
else
  edge_result "Phase 6a.2: ac_online() - Mains online=0" PASS
fi

rm -rf "$PSU_MOCK/Mains"
if POWER_SUPPLY_BASE="$PSU_MOCK" ac_online; then
  edge_result "Phase 6a.3: ac_online() - no Mains supply" FAIL
else
  edge_result "Phase 6a.3: ac_online() - no Mains supply" PASS
fi
unset POWER_SUPPLY_BASE

# 6b. Cooldown debounce logic (fiero-prompt.sh lines 54-69)
STATE_COOLDOWN=11
cooldown_check() {
  local state_file="$1" current_state="$2" now="$3"
  local old_ts old_state old_pid
  if [ -f "$state_file" ]; then
    old_ts=$(cut -d: -f1 "$state_file")
    old_state=$(cut -d: -f2 "$state_file")
    old_pid=$(cut -d: -f3 "$state_file")
    if [[ "$old_ts" =~ ^[0-9]+$ ]] && [ "$old_state" = "$current_state" ] \
      && [ $((now - old_ts)) -lt "$STATE_COOLDOWN" ]; then
      return 1
    fi
    if [ "$old_state" != "$current_state" ]; then
      pkill -P "$old_pid" 2>/dev/null || true
      kill "$old_pid" 2>/dev/null || true
    fi
  fi
  return 0
}

CD_SF="$EDGE_TMP_DIR/6b.state"
rm -f "$CD_SF"
if cooldown_check "$CD_SF" online 100; then
  edge_result "Phase 6b.1: cooldown - no state file -> proceed" PASS
else
  edge_result "Phase 6b.1: cooldown - no state file -> proceed" FAIL
fi

printf '95:online:12345\n' > "$CD_SF"
if cooldown_check "$CD_SF" online 100; then
  edge_result "Phase 6b.2: cooldown - same state within window -> debounced" FAIL
else
  edge_result "Phase 6b.2: cooldown - same state within window -> debounced" PASS
fi

printf '10:online:12345\n' > "$CD_SF"
if cooldown_check "$CD_SF" online 100; then
  edge_result "Phase 6b.3: cooldown - window expired -> proceed" PASS
else
  edge_result "Phase 6b.3: cooldown - window expired -> proceed" FAIL
fi

sleep 30 &
CD_SLEEPER=$!
printf '95:online:%s\n' "$CD_SLEEPER" > "$CD_SF"
if cooldown_check "$CD_SF" offline 100; then
  wait "$CD_SLEEPER" 2>/dev/null || true
  if ! kill -0 "$CD_SLEEPER" 2>/dev/null; then
    edge_result "Phase 6b.4: cooldown - different state kills old process" PASS
  else
    edge_result "Phase 6b.4: cooldown - different state kills old process" FAIL
  fi
else
  edge_result "Phase 6b.4: cooldown - different state kills old process" FAIL
fi

printf '100\n' > "$CD_SF"
if cooldown_check "$CD_SF" online 110; then
  edge_result "Phase 6b.5: cooldown - malformed state file -> no crash" PASS
else
  edge_result "Phase 6b.5: cooldown - malformed state file -> no crash" FAIL
fi

# 6c. Frequency-to-channel conversion (fiero-prompt.sh lines 77-83)
freq_to_channel() {
  local freq="$1"
  if [ -n "$freq" ]; then
    if [ "$freq" -ge 2412 ] && [ "$freq" -le 2472 ]; then
      echo $(( (freq - 2407) / 5 ))
    elif [ "$freq" -eq 2484 ]; then
      echo 14
    elif [ "$freq" -ge 5000 ]; then
      echo $(( (freq - 5000) / 5 ))
    fi
  fi
}

edge_assert_equal "Phase 6c.1: freq 2412 -> channel 1" "$(freq_to_channel 2412)" "1"
edge_assert_equal "Phase 6c.2: freq 2437 -> channel 6" "$(freq_to_channel 2437)" "6"
edge_assert_equal "Phase 6c.3: freq 2462 -> channel 11" "$(freq_to_channel 2462)" "11"
edge_assert_equal "Phase 6c.4: freq 2484 -> channel 14" "$(freq_to_channel 2484)" "14"
edge_assert_equal "Phase 6c.5: freq 5180 -> channel 36" "$(freq_to_channel 5180)" "36"
edge_assert_equal "Phase 6c.6: freq 5240 -> channel 48" "$(freq_to_channel 5240)" "48"
edge_assert_equal "Phase 6c.7: freq 5745 -> channel 149" "$(freq_to_channel 5745)" "149"
edge_assert_equal "Phase 6c.8: no freq -> empty (iw info fallback)" "$(freq_to_channel "")" ""

# 6d. Channel validation against SUPPORTED_CHANNELS (fiero-prompt.sh lines 95-99)
channel_supported() {
  local channel="$1" supported="$2"
  [[ ",$supported," == *",$channel,"* ]]
}

SUPPORTED_DEFAULT="1,2,3,4,5,6,7,8,9,10,11,36,40,44,48"
if channel_supported 6 "$SUPPORTED_DEFAULT"; then
  edge_result "Phase 6d.1: channel in supported list -> proceeds" PASS
else
  edge_result "Phase 6d.1: channel in supported list -> proceeds" FAIL
fi

if channel_supported 13 "$SUPPORTED_DEFAULT"; then
  edge_result "Phase 6d.2: unsupported channel rejected" FAIL
else
  edge_result "Phase 6d.2: unsupported channel rejected" PASS
fi

# ------------------------------------------------------------------------------
# 7. fiero-hotspot.sh Edge Cases (replicated logic, file NOT sourced)
# ------------------------------------------------------------------------------
# 7a. Instance lock (flock) (fiero-hotspot.sh lines 80-81)
PH7A_LOCK="$EDGE_TMP_DIR/7a-instance.lock"
( exec 9>"$PH7A_LOCK"; flock -n 9 || exit 1; sleep 3 ) &
PH7A_HOLDER=$!
PH7A_RESULT=""
for _ in $(seq 1 20); do
  PH7A_RESULT=$( ( exec 9>"$PH7A_LOCK"; if flock -n 9; then echo ACQUIRED; else echo REJECTED; fi ) 2>/dev/null )
  [[ "$PH7A_RESULT" == "REJECTED" ]] && break
  sleep 0.05
done
wait "$PH7A_HOLDER" 2>/dev/null || true
if [[ "$PH7A_RESULT" == "REJECTED" ]]; then
  edge_result "Phase 7a.1: instance lock - second invocation rejected" PASS
else
  edge_result "Phase 7a.1: instance lock - second invocation rejected" FAIL
fi

( exec 9>"$PH7A_LOCK"; flock -n 9 || exit 1; sleep 3 ) &
PH7A_HOLDER=$!
PH7A_LOG="$EDGE_TMP_DIR/7a-attempt.log"
PH7A_RC=""
for _ in $(seq 1 20); do
  set +e
  ( exec 9>"$PH7A_LOCK"
    if ! flock -n 9; then
      echo "[INFO] Another instance is running. Exiting." >> "$PH7A_LOG"
      exit 0
    fi
    echo "LOCKED" >> "$PH7A_LOG"
    exit 1 )
  PH7A_RC=$?
  set -e
  [[ "$PH7A_RC" -eq 0 ]] && break
  sleep 0.05
done
wait "$PH7A_HOLDER" 2>/dev/null || true
if [[ "$PH7A_RC" -eq 0 ]] && grep -q "Another instance is running" "$PH7A_LOG"; then
  edge_result "Phase 7a.2: instance lock - exit 0 with log message" PASS
else
  edge_result "Phase 7a.2: instance lock - exit 0 with log message" FAIL
fi

# 7b. Cleanup function (fiero-hotspot.sh lines 52-68) with mocked system commands
MOCK_CALLS="$EDGE_TMP_DIR/7b-calls.log"
MOCK_IW_DEV_OUTPUT=""

create_ap() { echo "create_ap:$*" >> "$MOCK_CALLS"; }
iw() {
  echo "iw:$*" >> "$MOCK_CALLS"
  if [[ "$*" == "dev" ]]; then
    printf '%s\n' "$MOCK_IW_DEV_OUTPUT"
  fi
}
ip() { echo "ip:$*" >> "$MOCK_CALLS"; }
pkill() { echo "pkill:$*" >> "$MOCK_CALLS"; }

edge_cleanup() {
  if [ "${SKIP_CLEANUP:-0}" = "1" ]; then
    return 0
  fi
  create_ap --stop "$INTERFACE" 2>/dev/null || true
  if [ -n "${CREATE_AP_PID:-}" ]; then
    kill "$CREATE_AP_PID" 2>/dev/null || true
  fi
  pkill -f "create_ap.*$INTERFACE" 2>/dev/null || true
  for dev in $(iw dev 2>/dev/null | awk '$1=="Interface" && $2 ~ /^ap[0-9]+/ {print $2}'); do
    ip link set dev "$dev" down 2>/dev/null || true
    iw dev "$dev" del 2>/dev/null || true
    ip link delete "$dev" 2>/dev/null || true
  done
  find /tmp -maxdepth 1 -name "create_ap*" ! -type l -exec rm -rf {} + 2>/dev/null || true
}

_SAVE_INTERFACE="$INTERFACE"
INTERFACE=wlan0
CREATE_AP_PID=""

: > "$MOCK_CALLS"
SKIP_CLEANUP=1
edge_cleanup
SKIP_CLEANUP=0
if [[ ! -s "$MOCK_CALLS" ]]; then
  edge_result "Phase 7b.1: SKIP_CLEANUP=1 -> returns immediately" PASS
else
  edge_result "Phase 7b.1: SKIP_CLEANUP=1 -> returns immediately" FAIL
fi

MOCK_IW_DEV_OUTPUT=$'Interface ap0\nInterface ap1\nInterface p2p-dev-wlan0'
: > "$MOCK_CALLS"
edge_cleanup
if grep -q "iw:dev ap0 del" "$MOCK_CALLS" && grep -q "iw:dev ap1 del" "$MOCK_CALLS"; then
  edge_result "Phase 7b.2: cleanup removes ap* interfaces" PASS
else
  edge_result "Phase 7b.2: cleanup removes ap* interfaces" FAIL
fi
if ! grep -q "p2p" "$MOCK_CALLS"; then
  edge_result "Phase 7b.3: cleanup preserves p2p-dev-* interfaces" PASS
else
  edge_result "Phase 7b.3: cleanup preserves p2p-dev-* interfaces" FAIL
fi

CREATE_AP_TMP="/tmp/create_ap-7b-test-$$"
touch "$CREATE_AP_TMP"
: > "$MOCK_CALLS"
MOCK_IW_DEV_OUTPUT=""
edge_cleanup
if [[ ! -e "$CREATE_AP_TMP" ]]; then
  edge_result "Phase 7b.4: cleanup removes /tmp/create_ap* temp files" PASS
else
  edge_result "Phase 7b.4: cleanup removes /tmp/create_ap* temp files" FAIL
fi

unset -f create_ap iw ip pkill
unset MOCK_CALLS MOCK_IW_DEV_OUTPUT
INTERFACE="$_SAVE_INTERFACE"
unset _SAVE_INTERFACE

# 7c. Channel validation (fiero-hotspot.sh lines 96-99)
validate_hotspot_channel() {
  local channel="$1" supported="$2"
  if [[ ",$supported," != *",$channel,"* ]]; then
    log "ERR" "Channel $channel is not supported for AP broadcast on this hardware. Aborting."
    return 1
  fi
  return 0
}

if validate_hotspot_channel 6 "$SUPPORTED_DEFAULT"; then
  edge_result "Phase 7c.1: channel in supported list -> proceeds" PASS
else
  edge_result "Phase 7c.1: channel in supported list -> proceeds" FAIL
fi

set +e
validate_hotspot_channel 12 "$SUPPORTED_DEFAULT" 2> "$EDGE_TMP_DIR/7c-err.log"
CH_RC=$?
set -e
if [[ "$CH_RC" -ne 0 ]] && grep -q "not supported" "$EDGE_TMP_DIR/7c-err.log"; then
  edge_result "Phase 7c.2: unsupported channel -> error + exit" PASS
else
  edge_result "Phase 7c.2: unsupported channel -> error + exit" FAIL
fi

# 7d. Config file missing required values (fiero-hotspot.sh lines 39-42)
validate_config_values() {
  source "$1"
  if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ] || [ -z "${INTERFACE:-}" ]; then
    log "ERR" "Config file is missing required values (SSID, PASSWORD, INTERFACE)."
    return 1
  fi
  return 0
}

printf 'PASSWORD=pw\nINTERFACE=wlan0\n' > "$EDGE_TMP_DIR/7d-no-ssid"
printf 'SSID=Fiero\nINTERFACE=wlan0\n' > "$EDGE_TMP_DIR/7d-no-pass"
printf 'SSID=Fiero\nPASSWORD=pw\n' > "$EDGE_TMP_DIR/7d-no-iface"

set +e
( unset SSID PASSWORD INTERFACE; validate_config_values "$EDGE_TMP_DIR/7d-no-ssid" ) >/dev/null 2>&1
R_NO_SSID=$?
( unset SSID PASSWORD INTERFACE; validate_config_values "$EDGE_TMP_DIR/7d-no-pass" ) >/dev/null 2>&1
R_NO_PASS=$?
( unset SSID PASSWORD INTERFACE; validate_config_values "$EDGE_TMP_DIR/7d-no-iface" ) >/dev/null 2>&1
R_NO_IFACE=$?
set -e

if [[ "$R_NO_SSID" -eq 1 ]]; then
  edge_result "Phase 7d.1: missing SSID -> exit 1" PASS
else
  edge_result "Phase 7d.1: missing SSID -> exit 1" FAIL
fi
if [[ "$R_NO_PASS" -eq 1 ]]; then
  edge_result "Phase 7d.2: missing PASSWORD -> exit 1" PASS
else
  edge_result "Phase 7d.2: missing PASSWORD -> exit 1" FAIL
fi
if [[ "$R_NO_IFACE" -eq 1 ]]; then
  edge_result "Phase 7d.3: missing INTERFACE -> exit 1" PASS
else
  edge_result "Phase 7d.3: missing INTERFACE -> exit 1" FAIL
fi

# ------------------------------------------------------------------------------
# 8. Config File Edge Cases
# ------------------------------------------------------------------------------
write_config() {
  local f="$1" ssid="$2" pass="$3" iface="$4"
  {
    printf 'SSID=%s\n' "$(shquote "$ssid")"
    printf 'PASSWORD=%s\n' "$(shquote "$pass")"
    printf 'INTERFACE=%s\n' "$(shquote "$iface")"
    printf 'SUPPORTED_CHANNELS=%s\n' "$(shquote "$SUPPORTED_DEFAULT")"
  } > "$f"
}

write_config "$EDGE_TMP_DIR/8a-ok" "Fiero Home" "fieropass123" "wlan0"
OK_OUT=$( source "$EDGE_TMP_DIR/8a-ok" && printf '%s|%s|%s' "${SSID:-}" "${PASSWORD:-}" "${INTERFACE:-}" ) || true
edge_assert_equal "Phase 8a.1: valid config sources without error" "$OK_OUT" "Fiero Home|fieropass123|wlan0"

write_config "$EDGE_TMP_DIR/8a-escaped" "Bob's" "p@ssw0rd" "wlan0"
ESC_OUT=$( source "$EDGE_TMP_DIR/8a-escaped" && printf '%s|%s|%s' "${SSID:-}" "${PASSWORD:-}" "${INTERFACE:-}" ) || true
edge_assert_equal "Phase 8a.2: shquoted config values expand correctly" "$ESC_OUT" "Bob's|p@ssw0rd|wlan0"

SSID_SPECIAL='O'"'"'Reilly $HOME `id` hotspot'
write_config "$EDGE_TMP_DIR/8a-special" "$SSID_SPECIAL" 'p@ss w0rd' 'wlan0'
SPECIAL_OUT=$( source "$EDGE_TMP_DIR/8a-special" && printf '%s' "${SSID:-}" ) || true
edge_assert_equal "Phase 8a.3: special chars in SSID source correctly" "$SPECIAL_OUT" "$SSID_SPECIAL"

# 8b. Config file permissions after a mock install (install.sh lines 152-153)
MOCK_CFG="$EDGE_TMP_DIR/mock-install.conf"
write_config "$MOCK_CFG" "Fiero" "hotspotpass" "wlan0"
chown root:"$TARGET_USER" "$MOCK_CFG"
chmod 640 "$MOCK_CFG"
if [[ "$(stat -c %a "$MOCK_CFG")" == "640" ]]; then
  edge_result "Phase 8b.1: config file mode 640" PASS
else
  edge_result "Phase 8b.1: config file mode 640" FAIL
fi
if [[ "$(stat -c %U "$MOCK_CFG")" == "root" ]]; then
  edge_result "Phase 8b.2: config file owned by root" PASS
else
  edge_result "Phase 8b.2: config file owned by root" FAIL
fi

# 8c. Missing config file (fiero-hotspot.sh lines 32-37)
load_config() {
  local cfg="$1"
  if [ -f "$cfg" ]; then
    source "$cfg"
  else
    log "ERR" "Config file not found at $cfg. Run install.sh first."
    return 1
  fi
}

set +e
load_config "$EDGE_TMP_DIR/nonexistent.conf" 2> "$EDGE_TMP_DIR/8c-err.log"
RC_8C=$?
set -e
if [[ "$RC_8C" -ne 0 ]] && grep -q "Config file not found" "$EDGE_TMP_DIR/8c-err.log"; then
  edge_result "Phase 8c.1: missing config file -> error" PASS
else
  edge_result "Phase 8c.1: missing config file -> error" FAIL
fi

# ==============================================================================
# 9. Lifecycle Startup Benchmark
# ==============================================================================
STARTUP_SUCCESS=false
STARTUP_TIME_MS=0
VIRTUAL_IFACE=""
STARTUP_SKIPPED=false

SUPPORTED_CHANNELS="${SUPPORTED_CHANNELS:-1,2,3,4,5,6,7,8,9,10,11,36,40,44,48,149,153,157,161,165}"

CURRENT_FREQ=$(iw dev "$INTERFACE" link 2>/dev/null | grep -oE 'freq: [0-9]+' | awk '{print $2}' || true)
CURRENT_CHANNEL=""
if [[ -n "$CURRENT_FREQ" ]]; then
  if [[ "$CURRENT_FREQ" -ge 2412 && "$CURRENT_FREQ" -le 2472 ]]; then
    CURRENT_CHANNEL=$(( (CURRENT_FREQ - 2407) / 5 ))
  elif [[ "$CURRENT_FREQ" -eq 2484 ]]; then
    CURRENT_CHANNEL=14
  elif [[ "$CURRENT_FREQ" -ge 5000 ]]; then
    CURRENT_CHANNEL=$(( (CURRENT_FREQ - 5000) / 5 ))
  fi
fi
if [[ -z "$CURRENT_CHANNEL" ]]; then
  CURRENT_CHANNEL=$(iw dev "$INTERFACE" info 2>/dev/null | awk '/channel/{print $2; exit}')
fi

if [[ -z "$CURRENT_CHANNEL" ]] || [[ ",$SUPPORTED_CHANNELS," != *",$CURRENT_CHANNEL,"* ]]; then
  echo "[WARN] Upstream Wi-Fi on unsupported channel ${CURRENT_CHANNEL:-none}. Lifecycle startup skipped."
  STARTUP_SKIPPED=true
else
  echo "[INFO] Starting fiero-hotspot.service..."
  START_TS=$(date +%s%N)
  systemctl start fiero-hotspot.service

  # Poll every 0.5s for up to 15s
  for i in $(seq 1 30); do
    AP_IFACE=$(iw dev | awk '$1=="Interface" && $2~/^ap[0-9]+/ {print $2}' | head -n1)
    if [[ -n "$AP_IFACE" ]] && pgrep -f "hostapd.*/tmp/create_ap" >/dev/null 2>&1; then
      END_TS=$(date +%s%N)
      STARTUP_TIME_MS=$(( (END_TS - START_TS) / 1000000 ))
      STARTUP_SUCCESS=true
      VIRTUAL_IFACE="$AP_IFACE"
      echo "[PASS] Service reached operational state in ${STARTUP_TIME_MS} ms (Interface: $VIRTUAL_IFACE)"
      break
    fi
    sleep 0.5
  done

  if [[ "$STARTUP_SUCCESS" != "true" ]]; then
    echo "[FAIL] Service startup timed out (15s threshold exceeded)."
  fi
fi

# ------------------------------------------------------------------------------
# 10. Resource Footprint Snapshot
# ------------------------------------------------------------------------------
RESOURCE_SNAPSHOT=""
if [[ "$STARTUP_SUCCESS" == "true" ]]; then
  echo "[INFO] Capturing resource footprint..."
  RESOURCE_SNAPSHOT=$(ps -eo pid,ppid,cmd,%cpu,rss | grep -E "create_ap|hostapd|dnsmasq" | grep -v grep || true)
  echo "$RESOURCE_SNAPSHOT"
  echo "[INFO] Holding active state for 5 seconds..."
  sleep 5
fi

# ------------------------------------------------------------------------------
# 11. Lifecycle Teardown Benchmark
# ------------------------------------------------------------------------------
TEARDOWN_SUCCESS=false
TEARDOWN_TIME_MS=0

if [[ "$STARTUP_SKIPPED" == "true" ]]; then
  echo "[INFO] Lifecycle teardown skipped because startup was skipped."
  TEARDOWN_SUCCESS=true
else
  echo "[INFO] Stopping fiero-hotspot.service..."
  STOP_TS=$(date +%s%N)
  systemctl stop fiero-hotspot.service

  # Poll every 0.5s for up to 10s
  for i in $(seq 1 20); do
    REMAINING_IFACE=$(iw dev | awk '$1=="Interface" && $2~/^ap[0-9]+/ {print $2}' | head -n1)
    if [[ -z "$REMAINING_IFACE" ]]; then
      STOP_END_TS=$(date +%s%N)
      TEARDOWN_TIME_MS=$(( (STOP_END_TS - STOP_TS) / 1000000 ))
      TEARDOWN_SUCCESS=true
      echo "[PASS] Service teardown completed in ${TEARDOWN_TIME_MS} ms"
      break
    fi
    sleep 0.5
  done

  if [[ "$TEARDOWN_SUCCESS" != "true" ]]; then
    echo "[FAIL] Service teardown timed out (10s threshold exceeded)."
  fi
fi

# ------------------------------------------------------------------------------
# 12. Post-Execution Logs Harvesting
# ------------------------------------------------------------------------------
echo "[INFO] Collecting system journals, dmesg, and leak audit logs..."

journalctl -u fiero-hotspot.service --no-pager -o short-precise > "$LOG_DIR/02-service-journal-full.log" 2>&1 || true

su - "$TARGET_USER" -c "journalctl --user -b --no-pager -o short-precise" > "$LOG_DIR/04-user-session-journal.log" 2>&1 || \
journalctl _UID="$TARGET_UID" -b --no-pager -o short-precise > "$LOG_DIR/04-user-session-journal.log" 2>&1 || true

dmesg -T --color=never > "$LOG_DIR/05-dmesg-full.log" 2>&1 || true

{
  echo "=== ACTIVE PROCESS AUDIT ==="
  ps aux | grep -E "create_ap|hostapd|dnsmasq" | grep -v grep || true
  echo -e "\n=== WIRELESS INTERFACES ==="
  iw dev || true
  echo -e "\n=== IP LINKS ==="
  ip link || true
  echo -e "\n=== TEMPORARY DIRECTORY AUDIT ==="
  ls -la /tmp/create_ap* /tmp/fiero* 2>&1 || true
} > "$LOG_DIR/06-leak-audit.log"

# ------------------------------------------------------------------------------
# 13. Leak Audit & Exit Matrix Evaluation
# ------------------------------------------------------------------------------
HARD_FAIL=0
WARNINGS=0

# Check lingering orphan processes
LINGERING_PIDS=$(pgrep -f "hostapd.*/tmp/create_ap|create_ap|dnsmasq.*/tmp/create_ap" || true)
if [[ -n "$LINGERING_PIDS" ]]; then
  echo "[HARD FAIL] Lingering orphan processes detected: $LINGERING_PIDS"
  HARD_FAIL=1
fi

# Check uncleaned virtual interfaces
LINGERING_IFACES=$(iw dev | awk '$1=="Interface" && $2~/^ap[0-9]+/ {print $2}' || true)
if [[ -n "$LINGERING_IFACES" ]]; then
  echo "[HARD FAIL] Uncleaned virtual interface detected: $LINGERING_IFACES"
  HARD_FAIL=1
fi

# Check lifecycle timeouts
if [[ "$STARTUP_SKIPPED" != "true" ]]; then
  if [[ "$STARTUP_SUCCESS" != "true" ]] || [[ "$TEARDOWN_SUCCESS" != "true" ]]; then
    HARD_FAIL=1
  fi
fi

# Check dmesg for kernel panic or firmware crash traces
DMESG_FAILS=$(grep -Ei "kernel panic|firmware.*fail|call trace" "$LOG_DIR/05-dmesg-full.log" || true)
if [[ -n "$DMESG_FAILS" ]]; then
  echo "[HARD FAIL] Kernel panic or firmware error traces detected in dmesg."
  HARD_FAIL=1
fi

# Notification check (Warning only)
NOTIFICATION_COUNT=$(grep -c "member=Notify" "$LOG_DIR/03-notifications-dbus.raw" 2>/dev/null || true)
if [[ "$NOTIFICATION_COUNT" -eq 0 ]]; then
  echo "[WARNING] No notification signals captured on D-Bus session bus."
  WARNINGS=$((WARNINGS + 1))
fi

# Edge case suite results roll into the exit matrix
if [[ "$EDGE_FAIL" -gt 0 ]]; then
  echo "[HARD FAIL] Edge case tests failed: $EDGE_FAIL failed, $EDGE_PASS passed, $EDGE_SKIP skipped."
  HARD_FAIL=1
fi

# ------------------------------------------------------------------------------
# 14. Summary Report Generation
# ------------------------------------------------------------------------------
{
  echo "======================================================================"
  echo "                     FIERO HOTSPOT TEST SUMMARY                       "
  echo "======================================================================"
  echo "Execution Timestamp : $(date -Iseconds)"
  echo "Log Directory       : $LOG_DIR"
  echo "Interface           : $INTERFACE"
  echo "Target User (UID)   : $TARGET_USER ($TARGET_UID)"
  echo "----------------------------------------------------------------------"
  echo "Startup Status      : $( [[ "$STARTUP_SKIPPED" == "true" ]] && echo "SKIPPED (Unsupported Channel: ${CURRENT_CHANNEL:-none})" || ( [[ "$STARTUP_SUCCESS" == "true" ]] && echo "PASS (${STARTUP_TIME_MS} ms)" || echo "FAIL (Timeout)" ) )"
  echo "Teardown Status     : $( [[ "$STARTUP_SKIPPED" == "true" ]] && echo "SKIPPED" || ( [[ "$TEARDOWN_SUCCESS" == "true" ]] && echo "PASS (${TEARDOWN_TIME_MS} ms)" || echo "FAIL (Timeout)" ) )"
  echo "Process Leak Audit  : $( [[ -z "$LINGERING_PIDS" ]] && echo "PASS (0 orphans)" || echo "FAIL (Lingering PIDs: $LINGERING_PIDS)" )"
  echo "Interface Leak Audit: $( [[ -z "$LINGERING_IFACES" ]] && echo "PASS (Clean)" || echo "FAIL (Lingering: $LINGERING_IFACES)" )"
  echo "Kernel/Firmware Dmesg: $( [[ -z "$DMESG_FAILS" ]] && echo "PASS (No crashes)" || echo "FAIL (Traces found)" )"
  echo "D-Bus Notifications : $( [[ "$NOTIFICATION_COUNT" -gt 0 ]] && echo "PASS ($NOTIFICATION_COUNT captured)" || echo "WARNING (0 captured / headless session)" )"
  echo "Edge Case Tests     : $EDGE_PASS passed / $EDGE_FAIL failed / $EDGE_SKIP skipped"
  echo "----------------------------------------------------------------------"
  if [[ -n "$RESOURCE_SNAPSHOT" ]]; then
    echo "Active Resource Footprint:"
    echo "$RESOURCE_SNAPSHOT"
    echo "----------------------------------------------------------------------"
  fi
  echo "Final Test Result   : $( [[ "$HARD_FAIL" -eq 0 ]] && echo "PASS (Exit 0)" || echo "HARD FAIL (Exit 1)" )"
  echo "======================================================================"
} > "$LOG_DIR/summary.txt"

cat "$LOG_DIR/summary.txt"

if [[ "$HARD_FAIL" -ne 0 ]]; then
  exit 1
fi

exit 0

# END OF FILE
