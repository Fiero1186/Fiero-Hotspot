#!/usr/bin/env bash
#
# Run the whole test suite in a throwaway Debian container - the same way CI
# does. Needs Docker; works from Linux, macOS and Git Bash on Windows.
#
#   tests/run.sh            ShellCheck + systemd-analyze + all bats suites
#   tests/run.sh daemon     only tests/daemon.bats (also: prompt, install)

set -euo pipefail

cd "$(dirname "$0")/.."
IMAGE="fiero-hotspot-test"

src="$PWD"
if command -v cygpath >/dev/null 2>&1; then
    # Git Bash / MSYS: hand Docker a Windows path and stop MSYS from
    # rewriting the container-side paths.
    src="$(cygpath -w "$PWD")"
    export MSYS_NO_PATHCONV=1
fi

docker build --quiet --tag "$IMAGE" tests >/dev/null

tty_flag=()
[ -t 1 ] && tty_flag=(--tty)

# Fake charger: one scratch volume is mounted twice. The scripts read it at
# /sys/class/power_supply; the tests write it at /fake-power. Docker's default
# AppArmor profile (Linux hosts, e.g. CI) denies every write under /sys, even
# to a mount placed there, so tests must never write through the /sys path.
POWER_VOLUME="fiero-test-power-$$"
docker volume create "$POWER_VOLUME" >/dev/null
trap 'docker volume rm -f "$POWER_VOLUME" >/dev/null 2>&1 || true' EXIT

docker run --rm "${tty_flag[@]}" \
    --volume "$POWER_VOLUME:/sys/class/power_supply" \
    --volume "$POWER_VOLUME:/fake-power" \
    --volume "$src:/src:ro" \
    "$IMAGE" bash /src/tests/in-container.sh "$@"
