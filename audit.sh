#!/usr/bin/env bash
set -u

FAILURES=0

echo "=== 1. Shell Syntax Verification (bash -n) ==="
while IFS= read -r -d '' script; do
    if ! bash -n "$script"; then
        echo "[FAIL] Syntax error in $script"
        FAILURES=$((FAILURES + 1))
    fi
done < <(find . -type f -name "*.sh" -print0)

echo -e "\n=== 2. Static Analysis (shellcheck) ==="
if command -v shellcheck >/dev/null 2>&1; then
    mapfile -d '' SCRIPTS < <(find . -type f -name "*.sh" -print0)
    # Exclude intentional test idioms:
    # SC1090/SC1091: Dynamic sourcing of mocked temporary config files
    # SC2009: Using ps to snapshot CPU/memory columns during lifecycle benchmarks
    # SC2015: Inline conditionals in test summary output
    # SC2016: Checking literal expansion strings like '$HOME'
    # SC2329: Trap-invoked cleanup functions
    if ! shellcheck -x -e SC1090,SC1091,SC2009,SC2015,SC2016,SC2329 "${SCRIPTS[@]}"; then
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "[WARN] shellcheck not installed."
fi

echo -e "\n=== 3. Systemd Unit Sandboxing (systemd-analyze) ==="
while IFS= read -r -d '' unit; do
    echo "Auditing: $unit"
    score=$(systemd-analyze --offline=true security "$unit" 2>/dev/null | grep "Overall exposure level")
    echo "  -> $score"
    if [[ "$score" =~ EXPOSED ]]; then
        echo "[WARN] $unit has an EXPOSED security rating."
    fi
done < <(find . -type f -name "*.service" -print0)

echo -e "\n=== 4. Secret & Token Detection (gitleaks) ==="
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks detect --no-git --verbose || FAILURES=$((FAILURES + 1))
else
    echo "[INFO] gitleaks not installed."
fi

echo -e "\n----------------------------------------"
if [ "$FAILURES" -eq 0 ]; then
    echo "Repository audit clean. Zero defects found."
    exit 0
else
    echo "Audit finished with $FAILURES failure(s)."
    exit 1
fi
