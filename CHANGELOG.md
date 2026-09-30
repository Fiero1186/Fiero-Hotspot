# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.2.0] - 2026-09-30

### Added
- **Upstream link state is now classified before acting.** `monitor_hotspot`
  distinguishes a `gone` interface (device removed from `nl80211`) from a
  `down` one (a roam or a dropped association). A vanished device gets a single
  5s re-confirm instead of being treated as a transient disconnect, so a driver
  or hardware event is no longer confused with ordinary Wi-Fi loss.
- **Exponential backoff on upstream loss.** A dropped upstream connection is
  now held through a 15s grace window and then retried at 10s, 20s and 40s
  (3 windows) before the hotspot is torn down — roughly 85s of tolerance, up
  from tearing down on the first missed poll. A successful re-association resets
  the ladder.
- **Pre-launch system-state snapshots.** `snapshot_system_state` records
  `ip_forward`, the interface's `forwarding` flag, the full `iptables-save`
  ruleset and the NetworkManager config into a `0700` `snapshot/` directory
  before `create_ap` launches, and restores them on teardown. The snapshot is
  taken once per daemon run, not per relaunch, so a drifted system can never
  become its own rollback baseline.
- **Parent-scoped process-tree teardown.** `descendant_pids` collects the
  `create_ap` process tree breadth-first over `/proc` parent-child edges while
  the parent is still alive, then reaps it with TERM/1s/KILL. Matching PIDs
  rather than command lines means a `hostapd` from another instance, or from
  another mount namespace, can never be killed.
- **Bounded crash recovery.** The service gained `Restart=on-failure`,
  `RestartSec=10`, `RestartPreventExitStatus=75` and
  `StartLimitIntervalSec=300`/`StartLimitBurst=3`. A crashed `create_ap` is
  now retried; a dead upstream (exit 75) is not, and a persistent fault can no
  longer loop indefinitely.
- **New documentation: [ARCHITECTURE.md](ARCHITECTURE.md).** Component map, the
  seven-state state machine, the complete `/run/fiero-hotspot` file contract,
  the privilege boundary, and the drift/backoff recovery paths.

### Changed
- **PID validation hardened.** `is_create_ap_pid` now rejects zombies and
  anchors its `create_ap` command-line match on both ends (`(^|/)create_ap( |$)`),
  so PID reuse, a defunct child, and a process that merely mentions `create_ap`
  can no longer be mistaken for the AP.
- **Config validation is now a hard dependency check.** `load_config` verifies
  `iw pgrep pkill create_ap flock ip systemctl stat cut sed awk` are present
  before sourcing the config, and refuses to run against a config that is not
  root-owned with mode exactly `640` or `600`.
- **Channel-drift recovery re-reads the upstream after teardown.** The link can
  move again during the up-to-15s AP shutdown, so the channel is sampled again
  before relaunching. Worst-case drift recovery is therefore ~23s (15s teardown
  + 8s `wait_for_ap`), not 8s.
- **Instance lock descriptors are scoped to the parent.** Both `create_ap`
  launch paths pass `9>&-`, and the watcher's `tail` coprocess is spawned with
  `8>&-`, so a surviving child cannot keep the lock held and make every later
  `start` falsely report "Another instance is running".
- **`fiero-prompt watch` sets the D-Bus address explicitly.** It exports
  `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` instead of
  relying on `dbus-launch` or `systemctl --user import-env`. The
  `udev → systemd-run → su` chain hands over a stripped environment with no
  `XDG_RUNTIME_DIR`, which previously caused every notification to be dropped
  silently.
- **The watcher now runs `tail -n0 -F` as a coprocess**, not as the left side
  of a pipeline, so it can be killed on teardown. Previously a vanished D-Bus
  socket left the reader blocked on the idle event file while holding fd 8, so
  the `flock` was never released and no new watcher could ever start.
- **`restore_system_state` no longer matches its own process.** A `pgrep -f`
  self-match was fixed with an exact-PID exclusion (`grep -vxF`), so a running
  harness or the daemon itself is never counted as a leaked child.
- **Detection regexes are anchored and case-insensitive where appropriate.**
  Frequency parsing uses explicit digit classes; channel filtering and
  interface matching are anchored (`[[:space:]]$IF([[:space:]]|$)`) so
  `wlan1` cannot match `wlan10`.
- **`install.sh` guards against empty MACs** when building the client list, and
  both scripts `shopt -s nullglob` so an absent power-supply glob cannot be
  iterated literally.
- **`TimeoutStopSec` raised to 60s** in the unit, matching the 15s `create_ap`
  teardown plus the 2s force-kill plus descendant reaping.
- **Documentation corrections.** The udev rule matches `Mains|USB` and never
  matches on `ATTR{online}` — presence is read at runtime by `ac_online()`;
  drift polling is 1s while healthy (2s only during backoff); `TARGET_USER` and
  `TARGET_UID` consumer boundaries are now stated explicitly. See
  [ARCHITECTURE.md](ARCHITECTURE.md) and [SECURITY.md](SECURITY.md).

### Fixed
- **`fiero-prompt`'s `ac_online()` now honours `POWER_SUPPLY`.** The configured
  supply name was read but not actually used, so the configured value and the
  auto-detected fallback could disagree.
- **`${TARGET_USER:-...}` fallback applied** everywhere it is used, so an
  unset `TARGET_USER` can no longer produce an unquoted `chown root:`.
- **Phase 9c harness false failure and hang fixed.** The `/run/fiero-hotspot`
  fingerprint was missing size and mtime, so `stop` — which creates no new
  filenames on a repeat run — produced an identical fingerprint and the 9c.2
  positive control failed on every run after the first. The fingerprint now
  uses `find -printf '%p %s %T@\n'`, and a missing directory no longer aborts
  the harness under `set -euo pipefail`. The read-only subcommand probe also
  redirects stdin from `/dev/null`, since bare `mode` prompts interactively and
  blocked forever on the harness's inherited stdin.
- **Test coverage extended** across `test_harness.sh` and the bats suites:
  new daemon, prompt and CLI coverage for the link-state classifier, the
  snapshot/restore path, process-tree teardown, `is_create_ap_pid` rejection
  cases, watcher bus-loss recovery, and the phase 9 CLI dispatcher.

## [2.1.3] - 2026-09-28

### Fixed
- Fixed missing `STARTING` and `LIVE` desktop notifications by adding `--property=KillMode=process` to the udev `systemd-run` rule. Prevents systemd control-group teardown from terminating the detached `fiero-prompt watch` process when the prompt script exits.

## [2.1.2] - 2026-09-28

### Changed
- Documentation and template naming pass: prose references to the project now use
  `Fiero-Hotspot` consistently across `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`,
  `SECURITY.md` and the issue templates. The author copyright line, GitHub URLs and
  all command/path/flag strings are unchanged.

## [2.1.1] - 2026-09-28

### Fixed
- Added USB-C Power Delivery detection (`type=USB`) fallback across `install.sh`, `fiero-hotspot.sh`, and `fiero-prompt.sh` for laptops without dedicated `Mains` power nodes.
- Updated `99-fiero-hotspot.rules` to match `Mains|USB` power supplies and dropped the login-shell `-` from `su` to eliminate `.profile` execution overhead on power state changes.
- Added an immediate `ac_online` re-check prior to starting the systemd service in `fiero-prompt.sh` to prevent starting on battery when a prompt is answered after unplugging.

## [2.1.0] - 2026-09-28

### Fixed
- **The hotspot could not start at all in v2.0.0.** `CAP_SETUID` and `CAP_SETGID` were
  dropped from `CapabilityBoundingSet`, but `dnsmasq` drops to the `nobody` group/user.
  It aborted with `failed to change group-id to nobody: Operation not permitted`,
  `create_ap` never brought the AP up, and the unit exited 1 after `AP_START_TIMEOUT`.
  Both capabilities are restored, scoped strictly to `dnsmasq`; nothing in Fiero-Hotspot
  uses them. Everything else in the v2.0.0 bounding set stays dropped.
- `test_harness.sh` now starts `fiero-prompt watch` alongside the D-Bus monitor.
  Since v2.0.0 the daemon never touches D-Bus, so a bare `dbus-monitor` could never
  observe a `Notify` signal — the harness now exercises the real inotify path.

### Security
- Exposure score rises from **3.0 OK** to **3.4 OK**, caused solely by restoring
  `CAP_SETGID`/`CAP_SETUID` to the capability bounding set. They are required for
  `dnsmasq`'s drop to `nobody` and are used by nothing in Fiero-Hotspot itself. The score
  stays well inside the 5.0 ceiling enforced by `tests/in-container.sh`.

### Changed
- The plug-in and unplug timeout fallbacks are now symmetrical and configurable.
  `AUTO_START_ON_TIMEOUT` and `AUTO_STOP_ON_TIMEOUT` both default to `'true'`, and the
  installer asks for both (right after `AUTO_PROMPT`) instead of hardcoding the
  start behaviour to `'false'`. Configs written before this key existed keep the
  v1.5.0 behaviour (act on timeout) rather than silently going quiet.
- Only the unplug fallback can be disabled without a prompt: answering `n` to both
  installer questions writes `'false'` for both keys.

## [2.0.0] - 2026-09-27

### Fixed
- **The hotspot could not start in v1.5.0.** `PrivateTmp=false` together with
  `ProtectSystem=strict` made `/tmp` read-only, so `create_ap` could not create its
  working directory. `PrivateTmp=true` is back.
- Restored the `CAP_CHOWN` and `CAP_SYS_RESOURCE` capabilities (dnsmasq, and the PAM
  session used for desktop notifications) and dropped `RestrictRealtime=true`.
  *(Temporary Phase 1 measure — fully superseded by the decoupled IPC architecture
  below: those capabilities are dropped permanently and `RestrictRealtime=true` is
  restored.)*
- `create_ap` can write NetworkManager's `unmanaged-devices` setting again
  (`ReadWritePaths=-/etc/NetworkManager`).
- Stopping the hotspot waits for `create_ap` to finish its own cleanup. Before,
  Fiero-Hotspot deleted `create_ap`'s temp files right away, which could leave
  `ip_forward` enabled after the hotspot was off.
- Fiero-Hotspot only manages its own `create_ap`. It no longer deletes other tools' `ap*`
  interfaces or `/tmp/create_ap*` directories, and refuses to start when another
  `create_ap` already runs on the interface.
- A hotspot that `create_ap` started with `--no-virt` (no `ap*` interface) is no longer
  torn down as "failed to start".
- `clients` never listed any device: `iw` prints `signal:  <tab>-45 [...] dBm`, which the
  old pattern did not match. It now also works with the service's private `/tmp`.
- Unplugging the charger while the "Start?" prompt is open now cancels that prompt.
- A failing `iw dev <iface> link` (driver reset, card removed) counts as disconnected
  instead of looping forever.
- `sudo fiero-hotspot stop` while the service is running now goes through
  `systemctl stop`, so the unit state stays correct.
- `help` and `version` work without root, a config file, or `create_ap` installed.
- The installer validates the sudoers rule *before* putting it in place, so a bad rule
  can no longer break `sudo` for the whole system.
- The test harness no longer reports PASS when the hotspot start/stop was skipped (it
  now exits 2, "incomplete"), and warns when the installed copy differs from the
  repository. `audit.sh` no longer says "Zero defects" when checks were skipped.

### Security
- The WPA passphrase is passed to `create_ap` through a root-only config file instead
  of the command line, so local users can no longer read it with `ps`.
- **Complete removal of PAM session jumping from the root daemon.** The daemon no
  longer runs `sudo -u $TARGET_USER notify-send`; desktop notifications are emitted
  by an unprivileged event watcher reading `/run/fiero-hotspot/events`.
- Re-enabled `NoNewPrivileges=true` and `RestrictRealtime=true` in
  `fiero-hotspot.service` (both previously omitted for the PAM hop).
- Reduced `CapabilityBoundingSet` to the network essentials
  (`CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE`), dropping `CAP_SETUID`,
  `CAP_SETGID`, `CAP_KILL`, `CAP_DAC_OVERRIDE`, `CAP_SYS_RESOURCE`, `CAP_CHOWN` and
  `CAP_AUDIT_WRITE`.
  *(The `CAP_SETUID`/`CAP_SETGID` drop broke startup — fixed in `[2.1.0]`.)*
- Exposure score improves from **4.2 OK** to **3.0 OK**
  (`systemd-analyze security`).

### Changed
- If nobody answers the "Start?" prompt, the hotspot is **not** started anymore. Set
  `AUTO_START_ON_TIMEOUT='true'` in `/etc/fiero-hotspot.conf` for the old behaviour.
- The installer refuses to run from a root shell, offers to keep an existing config,
  asks which interface to use when there are several, and rejects SSIDs/passphrases
  that `create_ap`'s config parser would change (backslashes, surrounding spaces).
- `uninstall.sh --keep-config` keeps `/etc/fiero-hotspot.conf`.
- Replaced the synchronous `notify()` in the root daemon with an atomic state snapshot
  (`/run/fiero-hotspot/state`) and a kernel-inotify event stream
  (`/run/fiero-hotspot/events`, `STATE|MSG|CHANNEL|TS` records). `/run/fiero-hotspot`
  is now mode `0755` (IPC files `0644`); the passphrase file stays `0600`.

### Added
- `.gitattributes` (LF line endings on every platform) and `.editorconfig`.
- This changelog.
- Detached unprivileged event watcher mode in `fiero-prompt.sh` (`fiero-prompt watch`):
  tails the daemon's event stream via `tail -n0 -F` and raises desktop notifications
  with state-based urgency; one flock-guarded instance per user session, spawned
  automatically by the first prompt run.

## [1.5.0] - 2026-09-23 (not tagged)
- systemd sandbox changes (`PrivateTmp=false`, `RestrictRealtime`, fewer capabilities)
  and client lease visibility.

## [1.4.1] - 2026-09-23
- See the [GitHub release](https://github.com/Fiero1186/Fiero-Hotspot/releases/tag/v1.4.1).
