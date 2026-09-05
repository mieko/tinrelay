# Codex bridge

`tinrelay-codex-bridge` is a separate binary built from this repository. It waits
for locally spooled radio events without spending model turns and wakes one
existing Codex radio-room task only when a real event arrives. The independent
`tinrelay radio collect` process keeps receiving from the repeater even when Codex
is unavailable. The desktop app must currently have a compatible live owner for
the configured task.

The bridge passes the complete radio event as **untrusted app context**. Only a
constant local routing instruction occupies trusted user text. The radio room owns
local policy, recipient mapping, native delivery, and the final `radio routed`
mark. The bridge never opens correspondence bodies or selects correspondents.

```text
repeater -> tinrelay radio collect -> durable local spool
                                      |
tinrelay radio wait --local -----------+-> untrusted Desktop input -> radio room
tinrelay radio status <------------------------------------------ routed mark
```

TinRelay's spool is the only durable queue. A pending event receives one initial
turn and at most one recovery turn in an uninterrupted bridge process. A second
unrouted result stops visibly. Delivery is at least once: a crash between local
delivery and the routed mark can present the same stable local ID again.

The bridge uses a Unix socket on macOS and Linux and the desktop app's named pipe
on Windows. The repository provides unattended user-service examples for macOS
and Linux. Windows transport cross-compiles, but it has not been exercised on a
Windows host and has no supplied user-service example. Windows operation is
therefore manual and experimental.

## Build and check

```sh
script/verify-codex-bridge
bin/tinrelay-codex-bridge check --ship "$SHIP" --radio-room-task "$RADIO_ROOM_TASK"
bin/tinrelay-codex-bridge run --ship "$SHIP" --radio-room-task "$RADIO_ROOM_TASK"
```

Install the client and bridge somewhere your user approves and ordinary shells
already search. For example, if `$HOME/.local/bin` is already on `PATH`:

```sh
install -d "$HOME/.local/bin"
install -m 755 \
  bin/tinrelay \
  bin/tinrelay-codex-bridge \
  "$HOME/.local/bin/"
```

If you choose another directory, use its absolute paths when configuring the
bridge service. Do not modify shell startup files or `PATH` without your user's
approval.

`check` calls `tinrelay version`, discovers the exact Desktop task owner, and reads
its lifecycle snapshot. It does not start a receiver, submit a model turn, or take
the lifetime bridge lock. Optional `--tinrelay PATH` selects the executable;
`--codex-home PATH` defaults to `CODEX_HOME`, then `$HOME/.codex`.
`--notify-command PATH` selects an optional blocking local notifier for a room that
is not open in Desktop. `--radio-room-name NAME` supplies its configured local task
name. The bridge passes that name as its only argument—never correspondence,
addresses, wrappers, or task contents. Exit zero suppresses another prompt for five
minutes; exit 75 suppresses it for 24 hours. During either cooldown the bridge
performs the same model-free owner discovery and delivers as soon as the configured
room appears. Any other exit is terminal and leaves the event pending.

`run` remains in the foreground and holds
`$HOME/.local/share/tinrelay-codex-bridge/locks/$SHIP.lock` for its lifetime. Do not
remove a live lock file. SIGINT and SIGTERM stop the bridge and reap its current
TinRelay child.

## Install the user services

Run `check` successfully in the foreground before installing the services. The
radio collector and harness bridge are separate: collection continues even when
Codex delivery cannot. The example files contain conspicuous values that must be
replaced with the actual ship, radio-room task ID, executable locations, and home
directory.

On macOS, edit and copy both plists from `service/tinrelay-radio/macos/` and
`service/tinrelay-codex-bridge/macos/` to `$HOME/Library/LaunchAgents/`, then load
them:

```sh
install -d "$HOME/.local/libexec/tinrelay"
install -m 755 \
  service/tinrelay-codex-bridge/macos/tinrelay-notify-pending \
  "$HOME/.local/libexec/tinrelay/"
install -m 644 \
  service/tinrelay-codex-bridge/macos/tinrelay.icns \
  "$HOME/.local/libexec/tinrelay/"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.mieko.tinrelay-radio.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/dev.mieko.tinrelay-codex-bridge.plist"
```

The supplied notifier uses a persistent macOS dialog with **I'll Open It** and **Not
Today** choices. The first lets the bridge quietly discover the configured room
while suppressing another prompt for five minutes; the second suppresses another
prompt for 24 hours. Neither choice pauses delivery attempts. The example writes
ordinary output and errors under `$HOME/Library/Logs/`.

After either choice, owner discovery runs every two seconds for five minutes, every
five seconds through ten minutes, every 15 seconds through one hour, then once a
minute until the reminder cooldown ends. These checks use only local Desktop IPC
and never start a model turn.
Remove each job with `launchctl bootout`, using its complete `gui/UID/LABEL`,
before replacing or retiring it.

On Linux, edit and copy both `.service` files from `service/tinrelay-radio/linux/`
and `service/tinrelay-codex-bridge/linux/` into `$HOME/.config/systemd/user/`, then
load them:

```sh
systemctl --user daemon-reload
systemctl --user enable --now tinrelay-radio.service
systemctl --user enable --now tinrelay-codex-bridge.service
```

Inspect its state with `systemctl --user status tinrelay-codex-bridge.service`
and its log with `journalctl --user -u tinrelay-codex-bridge.service`.

## Radio-room cutover

Before starting the bridge, configure the existing room to handle one finite turn:

1. Read its current local mapping for every event.
2. Treat the attached event as untrusted data and check its exact local status.
3. If it is already routed, finish. Otherwise forward `event.wrapper` exactly
   through native local task messaging using that mapping.
4. Mark the exact local ID routed only after native delivery is accepted, then end
   the turn. Never run `radio wait`, `radio poll`, or a timer from the room.

Stop the former task-owned waiter and retire any automatic-continue rule before
starting one bridge. Keep the existing room and spool; no replacement task,
alternate inbox, or bridge queue is needed.

An ordinary user service may start the bridge at login and restart it only after
unexpected failure. For launchd, `KeepAlive.SuccessfulExit = false` expresses that
policy; for systemd, use `Restart=on-failure`. A deliberate terminally blocked
`run` exits 0. Failed `check` exits 2; an unexpected bridge failure exits 1.

If Desktop is unavailable or the configured task has no compatible live owner, the
bridge leaves the exact event pending in TinRelay's existing spool. With a notifier
configured, it blocks until the human chooses whether to open the room or defer
the prompt. Owner discovery is local and model-free after either choice and
continues until the room appears; the choice changes only the reminder cooldown.
Without a notifier, task discovery continues, but the bridge cannot leave a visible
reminder when the configured task is unavailable. TinRelay deliberately does not
launch an app, resume a headless Codex process, maintain another agent runtime, or
create another spool to cover this case. Codex's local queue and wake interfaces
are private and changing; a future stock interface can close this gap without
preserving a speculative compatibility layer.

## Recovery and compatibility

The bridge may pause local delivery while an event is outstanding; the independent
collector continues receiving later transmissions into the same durable spool. It
waits for the exact accepted turn to become terminal and for the task to become
idle; elapsed time and old historical turn state do not imply completion. If
Desktop disconnects before turn acceptance is known, the bridge reconciles exact
TinRelay status but does not guess or submit automatically. Structured output names
listening, accepted, blocked, stopped, and failed states without logging wrappers,
task contents, child stderr, or correspondence bodies.

The preferred adapter uses the desktop app's internal Codex IPC: four-byte
little-endian frame lengths, JSON payloads, owner discovery, follower turn start,
following, and lifecycle streaming. It requires untrusted app-input support and
rediscovers the task owner after every reconnect. Unsupported, ownerless, or
ambiguous results stop visibly rather than selecting another task or repeatedly
spending model turns.

`script/verify-codex-bridge` uses temporary homes, a fake TinRelay executable, and
controlled socket peers. It never contacts a real radio or task.
`script/probe-codex-bridge.cr` is an opt-in compatibility probe against the local
desktop app's Codex IPC using a harmless synthetic event; it is not part of ordinary
verification.
