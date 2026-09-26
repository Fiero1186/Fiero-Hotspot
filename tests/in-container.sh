#!/usr/bin/env bash
# Entry point inside the test container (see tests/run.sh).
set -uo pipefail

if [ "${FIERO_TEST_CONTAINER:-}" != "1" ]; then
    echo "Refusing to run outside the test container. Use tests/run.sh." >&2
    exit 1
fi

cd /src || exit 1
rc=0

if [ "$#" -eq 0 ]; then
    echo "=== ShellCheck ==="
    # Same exclusions as audit.sh (intentional idioms in test_harness.sh).
    if shellcheck -x -e SC1090,SC1091,SC2009,SC2015,SC2016,SC2329 \
        ./*.sh tests/*.sh tests/mocks/*; then
        echo "clean"
    else
        rc=1
    fi

    echo
    echo "=== systemd-analyze security (must stay at or below 5.0; --threshold is x10) ==="
    systemd-analyze --offline=true security fiero-hotspot.service 2>/dev/null | grep "Overall exposure level"
    if ! systemd-analyze --offline=true --threshold=50 security fiero-hotspot.service >/dev/null 2>&1; then
        echo "FAIL: exposure score went above 5.0"
        rc=1
    fi

    suites=(tests/daemon.bats tests/prompt.bats tests/install.bats)
else
    suites=()
    for name in "$@"; do suites+=("tests/$name.bats"); done
fi

echo
echo "=== bats ==="
bats --print-output-on-failure "${suites[@]}" || rc=1

exit "$rc"
