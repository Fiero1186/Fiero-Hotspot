#!/usr/bin/env bash
# ==============================================================================
# Fiero Hotspot - Automated Lifecycle & Resource Benchmark Test Harness
# ==============================================================================

set -euo pipefail

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

cleanup() {
  local exit_code=$?
  set +e
  if [[ -n "${DBUS_MONITOR_PID:-}" ]]; then
    echo "[INFO] Terminating background D-Bus monitor (PID: $DBUS_MONITOR_PID)..."
    pkill -P "$DBUS_MONITOR_PID" 2>/dev/null || true
    kill -TERM "$DBUS_MONITOR_PID" 2>/dev/null || true
    wait "$DBUS_MONITOR_PID" 2>/dev/null || true
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

# ------------------------------------------------------------------------------
# 4. Lifecycle Startup Benchmark
# ------------------------------------------------------------------------------
STARTUP_SUCCESS=false
STARTUP_TIME_MS=0
VIRTUAL_IFACE=""
STARTUP_SKIPPED=false

SUPPORTED_CHANNELS="${SUPPORTED_CHANNELS:-1,2,3,4,5,6,7,8,9,10,11,36,40,44,48,149,153,157,161,165}"

CURRENT_FREQ=$(iw dev "$INTERFACE" link 2>/dev/null | grep -oE 'freq: [0-9]+' | awk '{print $2}')
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
# 5. Resource Footprint Snapshot
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
# 6. Lifecycle Teardown Benchmark
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
# 7. Post-Execution Logs Harvesting
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
# 8. Leak Audit & Exit Matrix Evaluation
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

# ------------------------------------------------------------------------------
# 9. Summary Report Generation
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
