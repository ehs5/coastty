# ADR-0003: Two version numbers decide what an upgrade does to the daemon, and the user is always told

Status: accepted, 2026-10-19. Revised 2026-10-24: any version difference restarts the daemon.

## Context

`coastty-host` owns every pane's process and outlives the app (ADR-0001).
That is coastty's core promise: quitting or upgrading the app ends nothing.
But after an upgrade the daemon still running is the old build, and only
restarting it puts the new daemon code in place. Restarting it ends every
shell in every pane. Spaces and tabs survive, because the daemon writes its
model out on SIGTERM, but each pane comes back as a fresh shell.

An earlier change stopped any daemon built as another coastty version
whenever the app started. Every upgrade then restarted every pane,
including releases that changed nothing in the daemon. It was reverted.

## Decision

Two numbers, both in `src/host/wire.zig`, decide what happens when an app
meets a daemon that is already running. The daemon reports both in answer to
`VERSION`; `src/host/upgrade.zig` makes the decision.

- **Protocol version** (`protocol_version`): bumped only when the app and
  the daemon can no longer talk.
- **Daemon version** (`daemon_version`): bumped when the daemon's code
  changes in a way users should get.

When either number differs from the app's, in either direction, the app
restarts the daemon the first time it reaches for it, before any pane
connects. Once a window is up, a dialog with one OK button says what
happened: "Coastty restarted its background service". When both numbers
match, the app keeps the daemon as it is.

The app's own version (`COASTTY_VERSION`) enters into neither. An app-only
release changes neither number and never restarts a pane.

Never restart the daemon without telling the user. The words "random" or
"crashed" must never be their best guess.

## Consequences

- Most upgrades keep every pane running. A release that bumps either number
  restarts every running shell when the new app opens.
- The app only ever talks to a daemon of its own versions, so neither side
  has to cope with the other being older or newer. Going back to an older
  app restarts the daemon too.
- The release script refuses a release that changed `src/host/` since the
  last one without bumping the daemon version (or the protocol version),
  unless run with `--no-daemon-bump` for a change users need not restart
  for. A forgotten bump would leave users on the old daemon.
- A daemon from before `VERSION` existed counts as daemon version 0, so the
  app restarts it.
- If the daemon cannot be stopped, a dialog says Coastty couldn't restart
  its background service and how to stop it by hand.
- Rejected: restarting the daemon on every app version change; restarting
  silently; tying the daemon to the app's version; keeping an older daemon
  and asking before restarting it ("Restart now" / "Later"), which left the
  app and daemon mismatched for as long as the user chose "Later".
- Keeping panes alive across a daemon replacement, by handing their ptys to
  the new daemon, would remove the restart altogether. It is a separate,
  later decision.
