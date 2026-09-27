# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.5.x   | Yes       |
| < 1.5   | No        |

## Reporting a Vulnerability

Use [GitHub Private Vulnerability Reporting](https://github.com/Fiero1186/Fiero-Hotspot/security/advisories/new) to report vulnerabilities privately. Do not open public issues for security reports.

## Known Architectural Properties

The following are documented security-relevant design decisions, not bugs:

### WPA2 Passphrase Handling

The passphrase is stored in `/etc/fiero-hotspot.conf` (mode `640 root:<target_user>`), so the target user can read it.

At runtime it is handed to `create_ap` through `/run/fiero-hotspot/create_ap.conf` (mode `0600`, root only), which is deleted as soon as the AP is up. It does not appear in the process table.

**Exception**: `create_ap` parses its config file with `read` without `-r`, which drops backslashes and trims surrounding spaces. The installer rejects such passphrases. If an older config contains one, Fiero falls back to passing it as a command-line argument (visible in `/proc/$PID/cmdline` to local users while the hotspot is active) and logs a warning. Mitigation: re-run `install.sh` with a different passphrase, or mount `/proc` with `hidepid=2`.

### Root Daemon Requirement

The service runs as root to perform NAT routing via `iptables` and network configuration. With the systemd sandboxing in `fiero-hotspot.service` it has an exposure score of **4.2 OK** (`systemd-analyze security fiero-hotspot.service`). The daemon uses `sudo -u $TARGET_USER` for user-facing operations (desktop notifications) and limits capabilities via `CapabilityBoundingSet`.

### Config File Sourcing

`/etc/fiero-hotspot.conf` is sourced as root by `fiero-hotspot.sh` and as the target user by `fiero-prompt.sh`. Both refuse to source it unless it is owned by root with mode `640` or `600`. It must never be world-readable or writable by anyone but root.

### sudoers Drop-in

`/etc/sudoers.d/fiero-hotspot` lets the target user run exactly `systemctl start fiero-hotspot.service` and `systemctl stop fiero-hotspot.service` without a password. The installer validates the rule with `visudo -c` before putting it in place.
