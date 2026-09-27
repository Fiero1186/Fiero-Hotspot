# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **The hotspot could not start in v1.5.0.** `PrivateTmp=false` together with
  `ProtectSystem=strict` made `/tmp` read-only, so `create_ap` could not create its
  working directory. `PrivateTmp=true` is back.
- Restored the `CAP_CHOWN` and `CAP_SYS_RESOURCE` capabilities (dnsmasq, and the PAM
  session used for desktop notifications) and dropped `RestrictRealtime=true`.
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

### Changed
- If nobody answers the "Start?" prompt, the hotspot is **not** started anymore. Set
  `AUTO_START_ON_TIMEOUT='true'` in `/etc/fiero-hotspot.conf` for the old behaviour.
- The installer refuses to run from a root shell, offers to keep an existing config,
  asks which interface to use when there are several, and rejects SSIDs/passphrases
  that `create_ap`'s config parser would change (backslashes, surrounding spaces).
- `uninstall.sh --keep-config` keeps `/etc/fiero-hotspot.conf`.

### Added
- `.gitattributes` (LF line endings on every platform) and `.editorconfig`.
- This changelog.

## [1.5.0] - 2026-09-23 (not tagged)
- systemd sandbox changes (`PrivateTmp=false`, `RestrictRealtime`, fewer capabilities)
  and client lease visibility.

## [1.4.1] - 2026-09-23
- See the [GitHub release](https://github.com/Fiero1186/Fiero-Hotspot/releases/tag/v1.4.1).
