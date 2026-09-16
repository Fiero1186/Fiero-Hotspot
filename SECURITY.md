# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.3.x   | Yes       |
| < 1.3   | No        |

## Reporting a Vulnerability

Use [GitHub Private Vulnerability Reporting](https://github.com/Fiero1186/Fiero-Hotspot/security/advisories/new) to report vulnerabilities privately. Do not open public issues for security reports.

## Known Architectural Properties

The following are documented security-relevant design decisions, not bugs:

### Plaintext WPA2 Passphrase in Process Table

`create_ap` receives the WPA2 passphrase as a command-line argument. On standard multi-user systems (without `procfs` mounted with `hidepid=2`), the cleartext passphrase is visible in `/proc/$PID/cmdline` to any local user while the hotspot is active.

**Mitigation**: Mount `/proc` with `hidepid=2` and grant access only to specific UIDs, or use single-user setups where no untrusted users have local access.

### Root Daemon Requirement

The service runs as root to perform NAT routing via `iptables` and network configuration. This results in a systemd exposure score of **5.7 MEDIUM**. The daemon uses `sudo -u $TARGET_USER` for user-facing operations (desktop notifications) and drops capabilities where possible via `CapabilityBoundingSet`.

### Config File Sourcing

`/etc/fiero-hotspot.conf` contains the WPA2 passphrase and is sourced as root by both `fiero-hotspot.sh` and `fiero-prompt.sh`. File permissions are enforced at `640 root:<target_user>`. The runtime validators also accept mode `600`. The file must never be world-readable.
