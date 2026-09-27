# Fiero Hotspot

![Version](https://img.shields.io/badge/version-v1.5.0-blue)
![License](https://img.shields.io/badge/license-GPL--3.0-green)
[![CI](https://github.com/Fiero1186/Fiero-Hotspot/actions/workflows/ci.yml/badge.svg)](https://github.com/Fiero1186/Fiero-Hotspot/actions/workflows/ci.yml)

## Overview

Fiero Hotspot is an automated bash Wi-Fi repeater daemon for Linux. It shares an upstream Wi-Fi connection via NAT into a local AP using `create_ap`, orchestrated by udev power-supply events and systemd unit isolation. Concurrency is enforced via `flock` to prevent duplicate instances, and SIGTERM/EXIT traps guarantee clean child-process teardown of `hostapd` and `dnsmasq`.

## Quick Start

```bash
git clone https://github.com/Fiero1186/Fiero-Hotspot.git
cd Fiero-Hotspot
sudo ./install.sh
```

> **Note:** An active graphical desktop session with a running notification daemon is required for the interactive D-Bus prompts.

## Dependencies

| Utility | Purpose |
|---------|---------|
| `create_ap` | AP creation and lifecycle management |
| `iw` | Wi-Fi interface enumeration and channel detection |
| `util-linux` | `flock(1)` for instance-level locking |
| `systemd` | Unit management (`fiero-hotspot.service`) |
| `NetworkManager` | Upstream Wi-Fi association |
| `libnotify` | Desktop notifications via `notify-send` |
| `procps-ng` | `pgrep`/`pkill` for process management |
| `iptables` | NAT/firewall rules (required by `create_ap`) |
| `hostapd` | 802.11 AP daemon (managed by `create_ap`) |
| `dnsmasq` | DHCP/DNS server (managed by `create_ap`) |

> **Installing `create_ap`:** The original `create_ap` project is unmaintained. This project uses the maintained [lakinduakash/linux-wifi-hotspot](https://github.com/lakinduakash/linux-wifi-hotspot) fork, which provides the `create_ap` command. Install it via your package manager: **Arch** — `yay -S linux-wifi-hotspot` (or `paru`); **Debian/Ubuntu** — download the latest `.deb` from the [releases page](https://github.com/lakinduakash/linux-wifi-hotspot/releases); **other distros** — clone the repo and run `sudo make install`.

> **Note:** `nmcli` is not required at runtime. Upstream connection and frequency state are queried directly via `iw`.

## Hardware Requirements

### Wi-Fi Concurrency

Your adapter must support running a managed client and an AP simultaneously on the same physical radio. Verify with:

```
iw list
```

Locate `valid interface combinations` and confirm at least one combination allows both `#{ managed }` and `#{ AP }` with counts `>= 1`:

```
valid interface combinations:
 * #{ managed } <= 1, #{ AP } <= 1,
   total # of interfaces <= 2
```

If the only combinations show `#{ managed } <= 1, #{ monitor } <= 1`, the adapter does not support dual-mode operation and this daemon will not function.

### Channel Constraints

AP channel is inherited from the upstream connection's current channel at startup. The daemon validates the channel against `SUPPORTED_CHANNELS` (parsed from `iw phy` output). Restricted channels — those flagged as `disabled`, `no IR`, or `radar detection` — are excluded. Channels in non-DFS bands (2.4 GHz: 1-14, 5 GHz UNII-1: 36-48) are safest. DFS bands (52-144) may fail if the adapter enforces radar-detection requirements on the virtual AP interface.

### Runtime Environment

An active X11 or Wayland desktop session with a running notification daemon is required for the interactive D-Bus prompts (D-Bus session bus at `/run/user/<uid>/bus`). Without a desktop session, the installer and hotspot will still function, but the interactive action prompts (Start/Ignore/Keep Running) will not appear.

The upstream Wi-Fi connection must be managed by NetworkManager. The daemon uses `iw dev <iface> link` to monitor upstream Wi-Fi connectivity and association state.

## Tested Hardware

| Property | Detail |
|----------|--------|
| **Host Platform** | ASUS Vivobook 16 (`X1605ZA_X1605ZAC`) |
| **Wireless Chipset** | Intel Dual Band Wireless-AC 9560 160MHz (Jefferson Peak) `[8086:51f0]`, Subsystem `[8086:0034]` |
| **Driver & Subsystem** | `iwlwifi` (`mac80211` / `nl80211`) |
| **Operating System & Kernel** | Garuda Linux (Arch-based), Linux `7.2.4-zen2-1-zen` |
| **Hardware Concurrency** | Verified 1× Managed (station) + 1× AP simultaneous operation on matching channels (`#channels <= 1`) |

## System Architecture

### Lifecycle

```
udev event (AC online/offline)
  └─> 99-fiero-hotspot.rules
        └─> systemd-run --no-block -- su - <user> -c /usr/local/bin/fiero-prompt
              ├─> setsid --fork fiero-prompt watch   (detached event watcher, one per session)
              └─> sudo -n systemctl start/stop fiero-hotspot.service
                    └─> /usr/local/bin/fiero-hotspot {start|stop}
                          ├─> flock -n /run/fiero-hotspot.lock
                          ├─> create_ap --config /run/fiero-hotspot/create_ap.conf
                          └─> set_state → /run/fiero-hotspot/state + events
                                └─> fiero-prompt watch (tail -n0 -F, inotify)
                                      └─> notify-send (as the logged-in user)
```

The udev rule fires on any `power_supply` `change` event where `ATTR{type}=="Mains"` and `ATTR{online}` is `1` (plugged) or `0` (unplugged). This invokes `fiero-prompt.sh` as the logged-in user via `systemd-run` + `su` (so udev does not kill the long-running prompt), which presents a desktop notification action prompt and issues `sudo -n systemctl start|stop` accordingly. The first prompt run also spawns a detached, flock-serialized event watcher (`fiero-prompt watch`) that stays alive for the session.

### Signal Handling

Fiero only manages the `create_ap` instance it started. Its state lives in `/run/fiero-hotspot/` (mode `0755`, created by systemd's `RuntimeDirectory=`; world-readable so the unprivileged event watcher can read the IPC files): the `create_ap` PID, the `create_ap` config directory, the AP interface `create_ap` actually uses (`ap0`, or the physical card when `create_ap` falls back to `--no-virt`), the atomic state snapshot (`state`), and the append-only event stream (`events`). The temporary `create_ap.conf` holding the WPA passphrase stays protected by its own mode `0600` — the readable directory is not a secret leak.

`fiero-hotspot.sh start` traps `EXIT`, `INT`, and `TERM`. Stopping (by the trap, by `fiero-hotspot stop`, or on a channel change):

1. Sends `USR1` to Fiero's own `create_ap` (its clean-exit signal, same as `create_ap --stop`) and **waits up to 15 seconds** for it to exit. `create_ap`'s own cleanup restores `ip_forward`, removes its `iptables` rules and undoes its NetworkManager changes, so it must be allowed to finish first.
2. Only if `create_ap` hangs: kills it, stops the `hostapd`/`dnsmasq` belonging to *that* instance (matched by its config directory), and restores the saved `ip_forward` value if no other `create_ap` is running.
3. Removes a leftover virtual `apN` interface of Fiero's own instance. The physical card and other tools' interfaces are never touched.
4. Deliberately skips deleting `p2p-dev-<interface>` to prevent iwlwifi firmware crashes.

Hotspots started by other tools (for example the linux-wifi-hotspot GUI) are left alone: if a `create_ap` is already running on the interface, `start` exits with a message instead of killing it. Running `sudo fiero-hotspot stop` by hand while the systemd service is active simply runs `systemctl stop fiero-hotspot.service`.

### IPC & Prompts

The root daemon never touches the desktop. Every state transition is written by `set_state` as an atomic snapshot to `/run/fiero-hotspot/state` (`STATE`/`MSG`/`CHANNEL`/`TIMESTAMP` assignments) and appended as a pipe-delimited record (`STATE|MSG|CHANNEL|TS`) to `/run/fiero-hotspot/events` (both mode `0644`). The unprivileged `fiero-prompt watch` daemon tails the event file with `tail -n0 -F` (kernel inotify; zero CPU wakeups while idle) and raises `notify-send` notifications, with urgency mapped from the state (`ERROR`/`DISCONNECTED`/`CHANNEL_UNSUPPORTED` → critical, `STARTING`/`CHANNEL_DRIFT` → low). Interactive prompts (Start/Ignore/Keep Running) remain D-Bus-based: `fiero-prompt.sh` sets `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus` and invokes `notify-send`. A timestamp-based cooldown file (`/run/user/<uid>/fiero-prompt.state`) debounces rapid udev event clusters (11-second window). A `flock` on `/run/user/<uid>/fiero-prompt.lock` serialises that debounce step (it is not held while the notification is on screen). If the charger state flips while a prompt is still open, the stale prompt is cancelled.

If nobody answers the "Start?" prompt, **nothing is started** unless `AUTO_START_ON_TIMEOUT='true'` is set in the config: starting a Wi-Fi network should need a clear "yes". If nobody answers the "Stop?" prompt after unplugging, the hotspot is stopped (the safe choice on battery).

## Installation & Removal

### Install

```bash
sudo ./install.sh
```

The installer:

1. Audits required commands and suggests distro-specific package names (Arch/Debian/Fedora)
2. Detects the Wi-Fi interface and AC power supply via `/sys/class/power_supply/`
3. Parses supported channels from `iw phy <phyN> info`, excluding restricted frequencies
4. Prompts for SSID and password (min 8 chars, WPA2 requirement)
5. Writes configuration to `/etc/fiero-hotspot.conf` (on a re-install you can keep the existing one) (mode `640`, owned `root:<user>`; the runtime validators also accept mode `600`)
6. Installs binaries to `/usr/local/bin/fiero-hotspot` and `/usr/local/bin/fiero-prompt`
7. Installs the systemd unit to `/etc/systemd/system/fiero-hotspot.service`
8. Installs the udev rule to `/etc/udev/rules.d/99-fiero-hotspot.rules`
9. Creates a sudoers drop-in at `/etc/sudoers.d/fiero-hotspot` granting the target user passwordless `systemctl start|stop` for `fiero-hotspot.service`. The rule is validated with `visudo -c` *before* it is put in place, so a bad rule can never break `sudo`.
10. Reloads udev rules and systemd daemon

### Configuration

File: `/etc/fiero-hotspot.conf`

| Variable | Description |
|----------|-------------|
| `SSID` | Hotspot network name |
| `PASSWORD` | WPA2 passphrase, 8–63 characters (WPA2-Personal standard) |
| `INTERFACE` | Physical Wi-Fi interface (e.g. `wlan0`) |
| `POWER_SUPPLY` | AC power supply name from `/sys/class/power_supply/` |
| `SUPPORTED_CHANNELS` | Comma-separated channel whitelist (auto-detected at install) |
| `TARGET_USER` | User for notification routing |
| `TARGET_UID` | UID of `TARGET_USER` |
| `AUTO_PROMPT` | `true` for automatic D-Bus prompt on AC events, `false` for CLI-only control |
| `AUTO_START_ON_TIMEOUT` | `true` to start the hotspot when the "Start?" prompt is not answered; default `false` |

### Enable & Start

```bash
sudo systemctl enable --now fiero-hotspot.service
```

### Manual Control

```bash
sudo systemctl start fiero-hotspot.service
sudo systemctl stop fiero-hotspot.service
```

### CLI Commands

`fiero-hotspot` doubles as a user-facing CLI tool. Commands that query hardware or system state (`start`, `stop`, `status`, `clients`, `mode`) require root.

```bash
sudo fiero-hotspot start          # Start the hotspot daemon
sudo fiero-hotspot stop           # Stop the hotspot daemon
sudo fiero-hotspot status         # Show daemon state, AP interface, SSID, channel, AC power, client count
sudo fiero-hotspot clients        # List connected devices (MAC, signal dBm, DHCP IP, hostname)
sudo fiero-hotspot mode           # Toggle or set trigger mode (auto|manual)
fiero-hotspot version             # Show version (also: -v, --version) — no root required
fiero-hotspot help                # Print usage menu (also: -h, --help, or no arguments)
```

**`status` output example:**

```
=== Fiero Hotspot Status ===
  Service    : active
  Mode       : Auto (Prompt on AC)
  AP iface   : ap0
  SSID       : MyHotspot
  Channel    : 6 (2437 MHz)
  AC Power   : Connected
  Clients    : 3
```

**`clients` output example:**

```
=== Fiero Hotspot Clients ===
  MAC                Signal     IP              Hostname
  ─────────────────  ─────────  ──────────────  ──────────────
  aa:bb:cc:dd:ee:ff  -45 dBm    192.168.12.10   laptop-home
  11:22:33:44:55:66  -62 dBm    192.168.12.11   -
```

IP and hostname are resolved from the lease file of Fiero's `create_ap` instance (read through `/proc/<pid>/root`, because the service runs with a private `/tmp`) and `/var/lib/misc/dnsmasq.leases`. Fields default to `-` when unavailable.

### Uninstall

```bash
sudo ./uninstall.sh
```

Removes all installed files, stops/disables the service, and reloads udev/systemd. Use `sudo ./uninstall.sh --keep-config` to keep `/etc/fiero-hotspot.conf` for a later re-install.

## Diagnostics & Test Suite

### Automated Tests (no Wi-Fi hardware needed)

```bash
tests/run.sh
```

Runs in a throwaway Docker container, exactly like CI does on every pull request: ShellCheck on every script, a `systemd-analyze security` check (exposure must stay at or below 5.0), and bats suites that drive the real `fiero-hotspot.sh`, `fiero-prompt.sh`, `install.sh` and `uninstall.sh` against test doubles of `create_ap`, `iw`, `notify-send` and a fake charger. See [CONTRIBUTING.md](CONTRIBUTING.md).

### Running the On-Hardware Harness

```bash
sudo ./test_harness.sh
```

Requires root and a valid `/etc/fiero-hotspot.conf` with `INTERFACE`, `TARGET_USER`, and `TARGET_UID` set.

### Test Phases

The harness executes over 100 edge-case checks across all phases. Phase 9 tests the *installed* copy (`/usr/local/bin/fiero-hotspot`) and fails if it differs from the repository copy - re-run `install.sh` after changing the code.

| Phase | Tests | Description |
|-------|-------|-------------|
| **4** | 8 | `shquote()` unit tests: single-quote escaping for shell-special characters (`'`, `$`, backticks, backslash, double quotes) |
| **5a** | 3 | Dependency detection logic: all present, one missing, multiple missing |
| **5b** | 4 | Distro package name mapping: `notify-send` → `libnotify`/`libnotify-bin`, `pgrep` → `procps-ng`/`procps`, AUR create_ap |
| **5c** | 4 | Password validation: length floor, mismatch rejection, special character acceptance |
| **5d** | 2 | Interface detection: non-AP interface extraction, AP-only interface rejection |
| **5e** | 2 | RF channel parsing: full frequency listing, disabled/no-IR/radar exclusion |
| **6a** | 3 | `ac_online()` mock: Mains online=1, online=0, no Mains supply |
| **6b** | 5 | Cooldown debounce: no state file, same-state window, window expiry, state-flip process kill, malformed file |
| **6c** | 8 | Frequency-to-channel conversion: 2.4 GHz (ch 1-11), channel 14 (2484 MHz), 5 GHz (ch 36-48, 149) |
| **6d** | 2 | Channel whitelist validation against `SUPPORTED_CHANNELS` |
| **6e** | 1 | Automatic prompt setting: `AUTO_PROMPT=false` early exit validation |
| **7a** | 2 | Instance lock (`flock`): second invocation rejected, exit 0 with log message |
| **7b** | 4 | Cleanup function with mocked commands: `SKIP_CLEANUP` bypass, `ap*` interface removal, `p2p-dev-*` preservation, `/tmp/create_ap*` removal |
| **7c** | 2 | Channel validation in hotspot context: supported proceed, unsupported abort |
| **7d** | 3 | Missing config values: absent SSID, PASSWORD, or INTERFACE |
| **8a** | 3 | Config file sourcing: valid values, escaped special chars, full SSID with embedded quotes/dollar/backticks |
| **8b** | 2 | Config file permissions post-install: mode 640, root ownership |
| **8c** | 1 | Missing config file error path |
| **9a** | 13 | Unprivileged execution: exit 1 + correct error message for `start`/`stop`/`status`/`clients`/`mode` as `$TARGET_USER`; exit 0 + version output for `version`; no `Permission denied` or `flock` error leaks |
| **9b** | 17 | CLI dispatcher: no-args/`-h`/`--help`/`help` → exit 0 with usage; `version`/`-v`/`--version` → exit 0 + current version string; `mode` auto/manual toggling and aliases; unknown subcommand → exit 1 with `[ERR]` |
| **9c** | 6 | Cleanup trap isolation: `/tmp/create_ap*` marker file survives `help`, `bogus`, `status`, `clients`, `version`, `mode` (validates `SKIP_CLEANUP=1`) |
| **9d** | 4 | Status output format: root exit 0, contains `Service` and `Mode` fields, no duplicate `inactive` lines |

### Lifecycle Benchmarks (hardware-dependent)

Phases 10-12 run only when upstream Wi-Fi is on a supported channel:

- **Startup**: starts `fiero-hotspot.service`, polls for `ap*` interface and `hostapd` presence (15s timeout)
- **Resource snapshot**: captures `create_ap`/`hostapd`/`dnsmasq` process table
- **Teardown**: stops the service, polls for interface removal (10s timeout)
- **Leak audit**: checks for orphaned `create_ap`/`hostapd`/`dnsmasq` processes and uncleaned `ap*` interfaces
- **dmesg scan**: flags kernel panics or firmware crash traces

### Output

All output is logged to `./test-logs-<timestamp>/`:

```
00-environment-audit.log
01-lifecycle-execution.log
02-service-journal-full.log
03-notifications-dbus.raw
04-user-session-journal.log
05-dmesg-full.log
06-leak-audit.log
summary.txt
```

Exit code `0` = all tests passed, including a real start/stop of the hotspot. Exit code `1` = hard failure (orphan leak, interface leak, dmesg crash, edge-case failure, or lifecycle timeout). Exit code `2` = **incomplete**: no failures, but the hotspot lifecycle was skipped because upstream Wi-Fi was on an unsupported channel - connect to a supported channel and re-run.

### Reporting Issues

When filing a bug report, please include the following diagnostic artifacts:

```bash
sudo ./test_harness.sh 2>&1 | tee summary.txt
lspci | grep -i network > lspci.txt
iw list > iw_list.txt
```

Attach `summary.txt`, `lspci.txt`, and `iw_list.txt` along with your `/etc/fiero-hotspot.conf` (redact the passphrase) and the output of `journalctl -u fiero-hotspot.service -b --no-pager`.

## Known Limitations

### Runtime Credential Visibility (Process Table)

The passphrase is handed to `create_ap` through a root-only (`0600`) config file, `/run/fiero-hotspot/create_ap.conf`, which is deleted as soon as the AP is up, so it does not appear in `ps` or `/proc/<pid>/cmdline`.

`create_ap` reads that file with `read` (without `-r`), which drops backslashes and trims leading/trailing spaces. The installer therefore rejects such SSIDs/passphrases. For an older config that contains one, Fiero falls back to passing it on the command line (visible to local users) and logs a warning; mount `/proc` with `hidepid=2` if that matters on a shared machine.

The passphrase is stored in `/etc/fiero-hotspot.conf`, which the target user can read (mode `640 root:<user>`).

### Single-Radio Throughput Penalty

The upstream client and AP share the same physical radio. On a single-radio adapter, the theoretical throughput drops by approximately 50% due to half-duplex operation — the radio must time-slice between receiving upstream data and transmitting to AP clients.

### Single-Channel Lock

The AP channel is inherited from the upstream connection's current channel and cannot be changed independently (`#channels <= 1` constraint). Cross-band repeating (e.g., receiving on 5 GHz and broadcasting on 2.4 GHz) is not supported.

### Upstream Channel Drift Recovery

When the upstream Wi-Fi connection changes channel (e.g., due to roaming or AP steering), the daemon detects the drift via periodic `iw dev $INTERFACE info` polling (every 2 seconds) and restarts the AP on the new channel within an 8-second re-initialization window. The AP is cleaned up and relaunched with the updated channel via `create_ap`.

This recovery is **best-effort and structurally verified**: single-channel-lock hardware (`#channels <= 1`) cannot retune across bands (e.g., 5 GHz → 2.4 GHz). If the new channel falls outside `SUPPORTED_CHANNELS`, the daemon logs the event, notifies the user, and terminates safely rather than attempting an impossible retune.

### DFS & NO-IR Channel Safety

Channels flagged as DFS (52–144) or NO-IR by the regulatory domain are excluded from the supported channel list. If the upstream connection is on such a channel, the hotspot will refuse to start.

### NAT Routing vs. Layer-2 Broadcast Discovery

The daemon operates at Layer-3 via NAT. mDNS, AirPlay, and other Layer-2 broadcast discovery protocols will not traverse the upstream–AP boundary. Devices on the AP cannot discover services on the upstream network, and vice versa.

### System Stack Coupling

The daemon is tightly coupled to `systemd` (service unit), `udev` (power-supply events), and `NetworkManager` (upstream connection management). Running on systems without these components (e.g., OpenRC, runit, ConnMan) is not supported without significant modification.

### Bare-Metal Only (No Virtual Machine Support)

Requires a physical wireless adapter exposing an `nl80211` interface capable of simultaneous AP and Station modes. Standard virtual machine hypervisors (VirtualBox, VMware, QEMU/KVM) emulate virtualized Ethernet adapters (`virtio`, `e1000`) and cannot create `mac80211` virtual access points. Running inside a VM will fail unless the physical PCIe or USB Wi-Fi card is passed through directly to the guest.

### Headless & SSH Session Behavior

`fiero-prompt.sh` exits cleanly with a warning to stderr when `/run/user/$UID/bus` is absent; no desktop notification appears. This occurs on headless boots, SSH sessions, and non-PAM configurations where no D-Bus session bus is created. The hotspot can still be controlled manually via `sudo fiero-hotspot start/stop` — only the interactive desktop prompt is skipped.

## Systemd Hardening Rationale

The systemd service achieves a **3.0 OK** exposure rating (`systemd-analyze security fiero-hotspot.service`), down from 4.2 OK in Phase 1, 5.7 MEDIUM in v1.4.1 and 8.2 EXPOSED in v1.2.0. `PrivateTmp=true` is required: with `ProtectSystem=strict` the rest of the filesystem is read-only, and `create_ap` needs a writable `/tmp`. `ReadWritePaths=-/etc/NetworkManager` lets `create_ap` mark its virtual interface as unmanaged. One directive is intentionally omitted because it breaks essential functionality:

### ProtectKernelTunables=true (omitted)

Mounts `/proc/sys` read-only. `create_ap` writes to `net.ipv4.ip_forward` during NAT setup. A read-only `/proc/sys` causes the NAT bridge to fail silently, breaking the core hotspot functionality.

### Why Root Execution and CAP_NET_ADMIN Are Required

- **Root**: NAT routing via `iptables` requires root privileges.
- **CAP_NET_ADMIN**: Required for `iptables` rule management and `hostapd`/interface configuration. This capability cannot be replaced with user-level alternatives for NAT.
- **Privilege separation**: The daemon does not talk to the desktop at all. It only writes `state`/`events` files (mode `0644`) into `/run/fiero-hotspot` (mode `0755`); the unprivileged `fiero-prompt watch` daemon reads them and calls `notify-send` in the user's own session — no `sudo`, no PAM, no D-Bus SASL workarounds.

## Developer Notes

### Motivation & Background
So, uh, I am a hostel student, studying B.Tech Computer Science and Engineering (specalisation in networks) in an University.
My university blocks devices such as smartphones from connecting to the campus network, and hence, to the wider internet.
The hostel room I am in doesn't get that much good of a signal reception, hence, during my windows days, I used my laptop as a relay to connect to the uni's network, activate vpn and use it that way.
That all changed when I switched to Linux (specifically, Garuda Linux based on Arch Linux). I could not do the same thing easily.
I could not figure out why tools like create_ap were not working on my laptop even though I was doing things as I should've.
Then, as time went on, I kept experimenting with create_ap alot, then one day, I figured out that the virtual ap should also be created on the same channel as the one in which my laptop is connected to the uni's network.
Once I figured that out, I used AI to write up a really crude version of this project (let's call it v0.0.1) that had hardcoded values in the script, worked only on my laptop, etc.
Then one day, I thought to myself. I need to have something as "a project I have done".
And considering my recent endevaor with the crude version v0.0.1, and the course I am studying, I decided to change this project into something I could be proud of.
At first, I was using Web based AI's like Perplexity (when it's pro version was really good).
But then, after it got too bad to be worth it, I switched to Google's Gemini (still web based).
But after a while, I realised that I was doing it wrong. I was acting as a glorified human copy-paste proxy between the web based AI and the code on my computer, and a bad one at that, cause it didn't really have all the context of what was going on in the project (web based AI limitations).
Then, one day, I shelled out 5 dollars on openrouter, got DeepSeek v4 flash, set up opencode, and started going at it.
And after 3 days of going at it using OpenCode, I upgraded the project from v0.4 (something I was kinda proud of) to v1.0.0, the first stable public release (something I am proud of).
During the process, I also realsied that models like MiMo V2.5 were better than that, so I switched to it.
It is late at night now, as I am typing out this readme, 10 mins past my bedtime (as of now, I know it will cross that by at least 30 mins more).
I will do occasional updates to this project whenever I am free to do so, but please don't expect too much out of me, as this is a real niche software.

### Built with AI, Verified with Ironclad Constraints
The implementation was vibe-coded using LLMs via OpenCode, under strict systems engineering constraints:
- **Zero Blind Trust:** Every component—from root-to-user D-Bus session routing down to udev power triggers—was subjected to a strict bash test harness (`test_harness.sh`).
- **Zero Process Leakage:** Background workers, `hostapd`, and `dnsmasq` instances are tracked and reaped on `SIGTERM`/`EXIT` to prevent zombie interfaces and memory leaks.
- **Race-Condition Safety:** Concurrency is locked down via `flock` file descriptors to guarantee idempotent execution even during erratic AC power plug/unplug events.
- **Sandboxed Execution:** Hardened systemd unit isolation (`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=true`), now with `NoNewPrivileges=true`, `RestrictRealtime=true` and a capability set of `CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE` active — exposure score 3.0 OK. Desktop notifications flow through `/run/fiero-hotspot/events` instead of a root→user D-Bus hop.
- **Live USB Boot testing:** Tested in a live boot environment (Arch-Based Garuda Linux iso)

AI handled the rapid boilerplate; strict verification and ShellCheck rules kept the codebase production-grade. But the idea was fully mine.

## License

Copyright (C) 2026 Fiero.

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for the full text.
