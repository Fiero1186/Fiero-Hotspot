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

# /sys/class/power_supply is replaced by a tmpfs so the tests can fake a charger.
docker run --rm "${tty_flag[@]}" \
    --tmpfs /sys/class/power_supply \
    --volume "$src:/src:ro" \
    "$IMAGE" bash /src/tests/in-container.sh "$@"
