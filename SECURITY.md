# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.2.x   | Yes       |
| 2.1.x   | Yes       |
| 2.0.x   | Yes       |
| 1.5.x   | No        |
| < 1.5   | No        |

## Reporting a Vulnerability

Use [GitHub Private Vulnerability Reporting](https://github.com/Fiero1186/Fiero-Hotspot/security/advisories/new) to report vulnerabilities privately. Do not open public issues for security reports.

## Known Architectural Properties

The following are documented security-relevant design decisions, not bugs:

### WPA2 Passphrase Handling

The passphrase is stored in `/etc/fiero-hotspot.conf` (mode `640 root:<target_user>`), so the target user can read it.

At runtime it is handed to `create_ap` through `/run/fiero-hotspot/create_ap.conf` (mode `0600`, root only), which is deleted as soon as the AP is up. It does not appear in the process table.

`/run/fiero-hotspot/` itself is mode `0755` so the unprivileged event watcher can read the `state`/`events` IPC files. This is safe only because the sensitive children carry their own modes: `create_ap.conf` is written under `umask 077` and is `0600` root-only, and the `snapshot/` subdirectory is installed `0700` (`install -d -m 0700`) so the target user cannot read the saved `ip_forward` value, the `iptables-save` ruleset, or the NetworkManager configuration backup. A world-readable parent directory does not weaken a `0600`/`0700` child.

**Exception**: `create_ap` parses its config file with `read` without `-r`, which drops backslashes and trims surrounding spaces. The installer rejects such passphrases. If an older config contains one, Fiero-Hotspot falls back to passing it as a command-line argument (visible in `/proc/$PID/cmdline` to local users while the hotspot is active) and logs a warning. Mitigation: re-run `install.sh` with a different passphrase, or mount `/proc` with `hidepid=2`.

### Root Daemon Requirement

The service runs as root to perform NAT routing via `iptables` and network configuration. With the systemd sandboxing in `fiero-hotspot.service` it has an exposure score of **3.4 OK** (previously 4.2; `systemd-analyze security fiero-hotspot.service`), now with `NoNewPrivileges=true` and `RestrictRealtime=true` active. Capabilities are bounded to `CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID`. `CAP_SETGID`/`CAP_SETUID` are retained **solely** because `dnsmasq` drops to the `nobody` group/user — without them it aborts with `failed to change group-id to nobody: Operation not permitted` and `create_ap` tears the AP down. Nothing in Fiero-Hotspot itself uses them. `CAP_KILL`, `CAP_DAC_OVERRIDE`, `CAP_SYS_RESOURCE`, `CAP_CHOWN` and `CAP_AUDIT_WRITE` remain fully dropped. The daemon no longer switches users or opens PAM sessions: user-facing desktop notifications are emitted by the unprivileged `fiero-prompt watch` daemon, which reads the world-readable IPC files (`/run/fiero-hotspot/state`, `/run/fiero-hotspot/events`, mode `0644` in a mode `0755` directory) and calls `notify-send` from the user's own session.

### Instance Lock Isolation

Three non-blocking `flock` locks serialise the long-running components, each on a distinct file descriptor:

| FD | Path | Held by | Protects |
|----|------|---------|----------|
| `9` | `/run/fiero-hotspot.lock` | daemon, entire lifetime | two daemons racing on one interface. Only `start` takes it; `stop`, `status`, `clients`, `mode` do not |
| `8` | `$XDG_RUNTIME_DIR/fiero-prompt.watch.lock` | watcher, entire lifetime | exactly one event watcher per user session |
| `9` | `$XDG_RUNTIME_DIR/fiero-prompt.lock` | prompt, debounce step only | the AC-state read/compare/write. Deliberately **not** held while a notification is on screen |

All three use `flock -n`, so a duplicate invocation exits `0` immediately rather than blocking. `stop` deliberately does not take the instance lock, so a manual stop can overlap a starting daemon; that case is coordinated by the `stopping` flag file and the PID file instead.

**Descriptor scoping is load-bearing.** Both `create_ap` launch paths pass `9>&-`, closing the lock descriptor in the child. Without it, a surviving `create_ap` keeps the lock held after the daemon dies and every later `start` falsely reports "Another instance is running". The watcher's `tail` coprocess is spawned with `8>&-` for the same reason.

The watcher runs `tail -n0 -F` as a **coprocess** rather than the left side of a pipeline specifically so it can be killed. With `tail | while`, a vanished D-Bus socket only ends the reader: `tail` keeps blocking on the idle event file, the shell stays in the pipeline `wait` holding fd `8`, and the lock is never released — so no new watcher could ever start.

### PID Verification

A PID read from a file is never trusted on its own. `is_create_ap_pid` applies four gates before the daemon will signal, snapshot, or tear down a process:

1. the value is numeric;
2. `/proc/$1` exists;
3. `/proc/$1/stat` state is not `Z` (a zombie is dead — signalling it does nothing and treating it as live would hang the teardown);
4. `/proc/$1/cmdline` matches `(^|/)create_ap( |$)`, anchoring both ends.

The final gate is what defeats PID reuse: a recycled PID now owned by some unrelated process fails the `create_ap` match and is ignored entirely. The same predicate guards the pre-launch snapshot, so a stale `create_ap.pid` can never cause the daemon to snapshot the wrong process's state. Command-line matching is deliberately anchored rather than a bare substring, so a process merely *mentioning* `create_ap` — such as the daemon's own `pgrep -f "create_ap..."` probe — is not mistaken for the AP.

### Process Tree Cleanup

`create_ap` runs `hostapd` and `dnsmasq` as children. Teardown must reap those children without touching anything else on the machine, and it does so by process tree, not by command line.

`descendant_pids` performs a breadth-first walk over `/proc` parent-child edges (`pgrep -P`) from the `create_ap` PID. Two properties make it safe:

- **The tree is collected while the parent is still alive.** Once `create_ap` dies its children are reparented to init and become unreachable by parent, so collecting afterwards would find nothing and leak `hostapd`/`dnsmasq`. Capture happens before the `USR1`.
- **It matches PIDs, not command lines.** Walking `/proc` can only ever reach processes that are genuinely descendants in our own tree and namespace. It cannot reach a `hostapd` belonging to another `create_ap` instance, nor a process in another mount namespace — both of which a `pkill -f hostapd` would happily destroy.

The collected tree is reaped with `TERM`, a 1 second pause, then `KILL`. When nothing in the tree is alive — the common clean-exit case — the function returns without adding any latency.

### Input Sanitization

- **Config generation** uses `shquote()` in `install.sh` for all ten written values, single-quote escaping so that `$`, backticks, backslashes and embedded quotes in an SSID cannot execute at source time.
- **Event messages** are sanitised with `tr '\n|' '  '` before being appended, replacing newlines and pipes with spaces. This keeps every `events` record at exactly four pipe-delimited fields regardless of the message text, so a hostile or merely unusual message can never desynchronise the stream.
- **The watcher reads defensively**: `while IFS='|' read -r state msg _` binds the first two fields and discards the rest, and the state string is matched against a fixed `case` list. An unrecognised state simply falls through to default urgency rather than being interpolated into a command.
- **`tail` is not used in a pipeline** by the watcher (see above), and the unprivileged script uses `nullglob` so an absent power-supply glob expands to nothing rather than a literal pattern.

### Config File Sourcing

`/etc/fiero-hotspot.conf` is sourced as root by `fiero-hotspot.sh` and as the target user by `fiero-prompt.sh`. Both refuse to source it unless it is owned by root with mode `640` or `600`. It must never be world-readable or writable by anyone but root.

### sudoers Drop-in

`/etc/sudoers.d/fiero-hotspot` lets the target user run exactly `systemctl start fiero-hotspot.service` and `systemctl stop fiero-hotspot.service` without a password. The installer validates the rule with `visudo -c` before putting it in place.
