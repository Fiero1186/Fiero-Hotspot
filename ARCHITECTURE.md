# Architecture

Deep mechanics of Fiero-Hotspot: component boundaries, the daemon state
machine, the `/run/fiero-hotspot` file contract, the privilege boundary, and the
recovery paths.

For installation, CLI usage and troubleshooting, see [README.md](README.md).
For threat-model notes, see [SECURITY.md](SECURITY.md).

## Component Map

```
udev event (AC online/offline)
  └─> 99-fiero-hotspot.rules
        └─> systemd-run --no-block --collect --property=KillMode=process -- su <user> -c /usr/local/bin/fiero-prompt
              ├─> setsid --fork fiero-prompt watch   (detached event watcher, one per session)
              └─> sudo -n systemctl start/stop fiero-hotspot.service
                    └─> /usr/local/bin/fiero-hotspot {start|stop}
                          ├─> flock -n /run/fiero-hotspot.lock
                          ├─> create_ap --config /run/fiero-hotspot/create_ap.conf
                          └─> set_state → /run/fiero-hotspot/state + events
                                └─> fiero-prompt watch (tail -n0 -F, inotify)
                                      └─> notify-send (as the logged-in user)
```

Four processes, two privilege levels:

| Process | Runs as | Lifetime | Owns |
|---------|---------|----------|------|
| `fiero-hotspot start` | root | daemon lifetime | `create_ap` + its children, iptables, sysctl, NetworkManager |
| `create_ap` | root | AP lifetime | `hostapd`, `dnsmasq` |
| `fiero-prompt` | target user | one udev event | the interactive prompt, one AC transition |
| `fiero-prompt watch` | target user | session lifetime | `tail` of the event stream, `notify-send` |

The udev rule does not distinguish plug from unplug. It matches any
`power_supply` `change` event whose `type` is `Mains` or `USB`, and the
`ac_online()` helper reads the supply's `online` attribute at runtime to decide
which transition occurred. `USB` is in the match because USB-C Power Delivery
chargers (UCSI) register as `type=USB` rather than `Mains`.

The transient unit is spawned with `--property=KillMode=process` deliberately.
`systemd-run` creates a transient *service* unit, whose default `KillMode` is
`control-group` — which SIGTERMs every remaining process in the cgroup as soon
as `su` exits. `setsid --fork` detaches the watcher from the session but not
from the cgroup, so without this override the watcher dies before the daemon
emits `STARTING`/`LIVE` and lifecycle notifications are silently lost. The
transient unit then lingers `inactive` for as long as the watcher runs.

## State Machine

`set_state` is the only writer of daemon state. It takes a state name, a human
message, and optionally a channel, then writes two artefacts: the atomically
replaced `state` snapshot and an appended `events` record.

There are **seven** states. Note that there is no bare `DRIFT` and no `FAILED`
— the actual names are `CHANNEL_DRIFT` and `ERROR`.

```
                    ┌──────────┐
                    │ STARTING │  channel detected + validated, create_ap launched
                    └────┬─────┘
                         │ wait_for_ap ok
                    ┌────▼─────┐
              ┌────►│   LIVE   │◄──── re-init ok after drift
              │     └────┬─────┘
              │          │
   re-init ok │          │ create_ap died unexpectedly
   after      │          │  (or wait_for_ap failed on relaunch)
   drift      │          │
              │     ┌────┴──────┬─────────────┬──────────────────┐
              │     │           │             │                  │
      ┌───────┴──┐  │        ┌──▼─────┐  ┌────▼──────┐   ┌───────▼────────┐
      │ CHANNEL_ │  │        │ ERROR  │  │    ERROR  │   │  STOPPED       │
      │  DRIFT   │  │        │(crash) │  │(pre-start)│   │ (manual / AC)  │
      └──────────┘  │        └────┬───┘  └───────────┘   └────────────────┘
                    │             │ exit 1
   upstream channel │ changed to a channel outside SUPPORTED_CHANNELS
   changed, new     │
   channel is OK    │
   ─────────────────┴──► CHANNEL_UNSUPPORTED
                         (exit 0)

   no upstream Wi-Fi at all, or upstream vanished mid-session,
   or the interface disappeared from nl80211  ──►  DISCONNECTED  (exit 75)
```

| State | Meaning | Exit |
|-------|---------|------|
| `STARTING` | Channel detected and validated, `create_ap` launched, waiting for the AP to come up | — |
| `LIVE` | AP is up and serving clients | — |
| `CHANNEL_DRIFT` | Upstream moved to a supported channel; AP is being torn down and relaunched | — |
| `CHANNEL_UNSUPPORTED` | Upstream moved to a channel this PHY cannot broadcast on. Terminating rather than attempting an impossible retune | `0` |
| `DISCONNECTED` | Upstream Wi-Fi is gone, or the interface disappeared | `75` |
| `ERROR` | `create_ap` crashed, or a pre-launch check failed (foreign hotspot already on the interface, no upstream, AP did not appear) | `1` or `0` |
| `STOPPED` | `stop` was requested, or the charger was unplugged | `0` |

**Exit codes** are the daemon's contract with systemd:

| Code | Constant | Meaning | systemd reaction |
|------|----------|---------|------------------|
| `0` | — | Clean stop, or a deliberate "cannot proceed" (`CHANNEL_UNSUPPORTED`, pre-launch `ERROR`) | no restart |
| `1` | `EXIT_CRASH` | `create_ap` died unexpectedly | `Restart=on-failure` |
| `75` | `EXIT_UPSTREAM` | Upstream is dead or the device is gone | `RestartPreventExitStatus=75` — **no** restart |

`75` is chosen deliberately: it is a request, not a fault, so a dead upstream
network must not trigger a crash-restart loop. The unit additionally bounds
restarts with `StartLimitIntervalSec=300` / `StartLimitBurst=3`.

**Silent transitions.** Two paths write no state at all: a `create_ap` death
while the stop flag is already set (a normal `stop`, so the last state already
says `STOPPED`), and the removal of a stale stop flag at the top of `start`.
A consumer that watches `events` therefore sees no record of a manual stop
that was already implied by a prior state.

## File Contracts

Everything lives under `/run/fiero-hotspot/` (mode `0755`, created by systemd's
`RuntimeDirectory=`), except the instance lock.

| Path | Mode | Written by | Contents | Removed |
|------|------|------------|----------|---------|
| `/run/fiero-hotspot.lock` | umask default | `exec 9>` | empty; `flock` target | never (harmless) |
| `state` | `0644` | `set_state` | 4-line sourceable `KEY="value"` snapshot | never (overwritten) |
| `events` | `0644` | `set_state` (`>>`) | append-only `STATE\|MSG\|CHANNEL\|TS` | never |
| `.state.tmp.$$` | `0644` | `set_state` | staging file for the atomic write | renamed, or `rm -f` on failure |
| `stopping` | umask default | `stop` (`touch`) | manual-stop flag, checked by the monitor | end of `stop_create_ap`, and at the top of every `start` |
| `create_ap.pid` | umask default | `launch_create_ap` | PID of the `create_ap` we started | end of `stop_create_ap` |
| `confdir` | umask default | `launch_create_ap` poll loop, rewritten by `wait_for_ap` | `create_ap`'s own `/tmp/create_ap.*.conf.*` path | before relaunch, and on stop |
| `ap_iface` | umask default | `wait_for_ap` | the AP interface actually in use (`ap0`, or the physical card) | before relaunch, and on stop |
| `create_ap.conf` | **`0600`** | `write_create_ap_config` (`umask 077`) | SSID + WPA2 passphrase | as soon as `create_ap` has read it, and on stop |
| `snapshot/` | **`0700`** | `snapshot_system_state` (`install -d -m 0700`) | pre-launch rollback data | `rm -rf` on stop, and at the top of every `start` |
| `snapshot/ip_forward` | `0600` | `cat /proc/sys/net/ipv4/ip_forward` | previous value | with the directory |
| `snapshot/iface_forwarding` | `0600` | `cat /proc/sys/net/ipv4/conf/$IF/forwarding` | previous value | with the directory |
| `snapshot/iptables.rules` | `0600` | `iptables-save` | previous NAT ruleset | with the directory |
| `snapshot/nm.conf` | `0600` | `cp -p` of the NM config | previous contents | with the directory |
| `snapshot/nm.absent` | `0600` | `: >` marker | "NM conf did not exist before us" | with the directory |

The directory is `0755` so the unprivileged watcher can read `state` and
`events`. That is safe because the sensitive children carry their own modes:
`create_ap.conf` is `0600` and `snapshot/` is `0700`. The readable parent is
not a leak.

**Snapshot guard rails.** The snapshot is taken **once per daemon run**, before
`create_ap` is launched, and not again on a drift relaunch — otherwise a
drifted system would snapshot its own already-modified state and later "restore"
to the wrong baseline. Empty captures are discarded rather than stored, because
an empty `iptables` restore would roll back to a default. The iptables restore
is additionally gated on the file beginning with `# Generated by`, so a
truncated or foreign ruleset is never fed to `iptables-restore`. The
NetworkManager restore only rewrites the config if it actually mentions our
interface.

**Two formats, deliberately.** `state` is a sourceable snapshot with named keys
(atomic, via `mv`); `events` is an append-only positional log. They are not
interchangeable. `TIMESTAMP` in both is seconds since boot from `/proc/uptime`,
not wall-clock — the file lives in `/run`, so wall-clock is not needed and
boot-relative ordering survives a clock change. `CHANNEL` may legitimately be
empty. Messages are sanitised with `tr '\n|' '  '` so the pipe-delimited
`events` record always has exactly four fields.

## Privilege Boundary

The root daemon never talks to the desktop. That is a hard architectural line,
not an optimisation.

**Root writes files. The user session reads them.** The daemon's entire
notification-adjacent output is `state` and `events`, both `0644` in a `0755`
directory. It contains no `dbus-send`, no `gdbus`, no `busctl`, no
`systemctl --user`, and no `DBUS_SESSION_BUS_ADDRESS` anywhere in the codebase.
Conversely, `fiero-prompt watch` runs with no special privilege at all: it
tails a world-readable file, checks that the user's bus socket still exists,
and calls `notify-send`, which libnotify delivers over that session's own bus.

**Why this shape.** A root process reaching into a user's session bus is the
classic privilege-boundary bug in desktop daemons: it requires either
`machinectl`/`pkexec` gymnastics, or a root-owned `DBUS_SESSION_BUS_ADDRESS`
injection that leaks the session's identity to a privileged process. Making the
root side write a file instead reduces the whole problem to "a root process
wrote two `0644` files" — and the notification path is then testable without a
bus at all.

**The bus address is set explicitly, not inherited.** `fiero-prompt` does not
rely on `dbus-launch` or `systemctl --user import-env`. It computes
`/run/user/$(id -u)/bus` and exports
`DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_BUS"` itself. The reason is
environmental: a `udev → systemd-run → su` chain hands over a stripped
environment with no `XDG_RUNTIME_DIR`, so libnotify has nothing to fall back
on and every notification would be dropped silently. If the socket is not a
socket, the script exits `0` quietly.

**Descriptor scoping.** Both `create_ap` launch paths pass `9>&-`, closing the
instance-lock descriptor in the child. Without it a surviving `create_ap`
would keep the lock held after the daemon died, and every subsequent `start`
would falsely report "Another instance is running". The watcher's `tail`
coprocess is spawned with `8>&-` for the same reason, so the watcher lock
cannot leak into a child either.

**Two locks, different jobs.**

| Descriptor | Path | Held by | Protects |
|-----------|------|---------|----------|
| `9` | `/run/fiero-hotspot.lock` | daemon, whole lifetime | prevents two daemons from racing on one interface. `start` only — `stop`, `status`, `clients`, `mode` never take it |
| `8` | `$XDG_RUNTIME_DIR/fiero-prompt.watch.lock` | watcher, whole lifetime | one event watcher per user session |
| `9` (transient) | `$XDG_RUNTIME_DIR/fiero-prompt.lock` | prompt, debounce step only | serialises the AC-state read/compare/write. Deliberately **not** held while a notification is on screen |

`fiero-hotspot stop` does not take the instance lock, so a manual stop can
overlap a starting daemon; that case is coordinated by the `stopping` flag
file and the PID file instead.

**Validation of what the daemon acts on.** A PID read from a file is never
trusted on its own. `is_create_ap_pid` applies four gates — numeric, present
in `/proc`, not a zombie, and `cmdline` matching `(^|/)create_ap( |$)` — so a
recycled PID belonging to some unrelated process cannot be signalled, and a
defunct `create_ap` is not mistaken for a running one.

## Recovery Paths

**Channel drift.** The monitor loop polls the upstream channel every second.
On a change to a channel that is in `SUPPORTED_CHANNELS`, it writes
`CHANNEL_DRIFT`, tears the AP down, **re-reads the channel** (the link may
have moved again during the up-to-15-second teardown), and relaunches with an
8-second `wait_for_ap` budget. A change to an unsupported channel writes
`CHANNEL_UNSUPPORTED` and exits `0` rather than trying an impossible retune.

There is deliberately **no retry budget on drift recovery.** A flapping
upstream — one that oscillates faster than the teardown can complete — will
restart `create_ap` indefinitely. Only an unsupported channel or a failed
re-init terminates the attempt. This is a known ceiling: a drift-retry counter
would bound it, at the cost of giving up on a genuinely late-arriving channel
change.

**Upstream loss.** Held through a 15 second grace window, then retried at 10s,
20s and 40s (3 windows, `backoff *= 2` each time) for roughly 85 seconds of
total tolerance. Note the cap is on the *retry count*, not on the delay: the
backoff value is doubled after the last window and never used, so there is no
numeric delay ceiling. A successful re-association resets the whole ladder. On
exhaustion: `DISCONNECTED`, exit `75`, no systemd restart.

**Device loss** is a different failure. If `iw dev $INTERFACE link` stops
responding, that is a hardware or driver event, not a roam, and it gets a
single 5 second re-confirm instead of the ladder before the same
`DISCONNECTED` / exit `75` verdict. A `gone` link state is distinguished from
a `down` one precisely so the two are not confused.

**Teardown ordering.** The descendant process tree is collected **while
`create_ap` is still alive**, because once the parent dies its children are
reparented to init and become unreachable by parent. The tree is then walked
breadth-first over `/proc` parent-child edges rather than matched by command
line, so it can only ever match processes in our own tree and namespace — it
cannot reach another instance's `hostapd` or a process in another mount
namespace.

The sequence is: collect tree → `USR1` to `create_ap` (its clean-exit signal,
equivalent to `create_ap --stop`) → wait up to 15 seconds → `TERM` then 2s
then `KILL` if it hung → reap the collected tree with `TERM`, 1s, `KILL`. The
wait before forcing matters: `create_ap`'s own cleanup restores `ip_forward`,
removes its iptables rules and undoes its NetworkManager changes, and killing
it early leaves the system dirty.

Leftover AP interfaces are removed only when they match `^ap[0-9]+$` and
differ from the physical interface. `p2p-dev-*` is never touched, to avoid
crashing iwlwifi firmware.
