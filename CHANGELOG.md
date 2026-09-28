# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.1.0] - 2026-09-28

### Fixed
- **The hotspot could not start at all in v2.0.0.** `CAP_SETUID` and `CAP_SETGID` were
  dropped from `CapabilityBoundingSet`, but `dnsmasq` drops to the `nobody` group/user.
  It aborted with `failed to change group-id to nobody: Operation not permitted`,
  `create_ap` never brought the AP up, and the unit exited 1 after `AP_START_TIMEOUT`.
  Both capabilities are restored, scoped strictly to `dnsmasq`; nothing in Fiero uses
  them. Everything else in the v2.0.0 bounding set stays dropped.
- `test_harness.sh` now starts `fiero-prompt watch` alongside the D-Bus monitor.
  Since v2.0.0 the daemon never touches D-Bus, so a bare `dbus-monitor` could never
  observe a `Notify` signal — the harness now exercises the real inotify path.

### Security
- Exposure score rises from **3.0 OK** to **3.4 OK**, caused solely by restoring
  `CAP_SETGID`/`CAP_SETUID` to the capability bounding set. They are required for
  `dnsmasq`'s drop to `nobody` and are used by nothing in Fiero itself. The score
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
- Stopping the hotspot waits for `create_ap` to finish its own cleanup. Before, Fiero
  deleted `create_ap`'s temp files right away, which could leave `ip_forward` enabled
  after the hotspot was off.
- Fiero only manages its own `create_ap`. It no longer deletes other tools' `ap*`
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
  *(The `CAP_SETUID`/`CAP_SETGID` drop broke startup — see `[Unreleased]`.)*
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
