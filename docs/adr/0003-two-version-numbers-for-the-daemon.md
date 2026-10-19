# ADR-0003: Two version numbers decide what an upgrade does to the daemon, and the user is always told

Status: accepted, 2026-10-19.

## Context

`coastty-host` owns every pane's process and outlives the app (ADR-0001).
That is coastty's core promise: quitting or upgrading the app ends nothing.
But after an upgrade the daemon still running is the old build, and only
restarting it puts the new daemon code in place. Restarting it ends every
shell and agent in every pane. Spaces and tabs survive, because the daemon
writes its model out on SIGTERM, but each pane comes back as a fresh shell.

An earlier change stopped any daemon built as another coastty version
whenever the app started. Every upgrade then restarted every pane without
asking, including releases that changed nothing in the daemon. It was
reverted.

## Decision

Two numbers, both in `src/host/wire.zig`, decide what happens when an app
meets a daemon that is already running. The daemon reports both in answer to
`VERSION`; `src/host/upgrade.zig` makes the decision.

- **Protocol version** (`protocol_version`): bumped only when the app and
  the daemon can no longer talk. A daemon speaking another protocol cannot
  serve the app at all, so the app restarts it before building its windows,
  and once they are up a dialog says what happened and why.
- **Daemon version** (`daemon_version`): bumped when the daemon's code
  changes in a way users should get. When the running daemon's is older,
  the app keeps using it and offers the update in a dialog, "Restart panes
  to update", with "Restart now" and "Later". Nothing restarts until the
  user clicks "Restart now". Restarting the Mac picks up the new daemon too.

The app's own version (`COASTTY_VERSION`) enters into neither. An app-only
release changes neither number and never restarts a pane.

Never restart the daemon without telling the user: before the restart when
they can choose, after it when it could not be avoided. The words "random"
or "crashed" must never be their best guess.

## Consequences

- Most upgrades keep every pane running. Users get daemon fixes when they
  choose to, or at their next Mac restart.
- A daemon older than the app keeps running for as long as the user says
  "Later", so the app must keep working against any daemon of its own
  protocol, whatever its daemon version.
- The release script refuses a release that changed `src/host/` since the
  last one without bumping the daemon version (or the protocol version),
  unless run with `--no-daemon-bump` for a change users need not restart
  for. A forgotten bump would leave users on the old daemon with nothing
  offering the new one.
- A daemon from before `VERSION` existed counts as daemon version 0, so the
  app asks before replacing it rather than restarting it.
- Rejected: restarting the daemon on every app version change; restarting
  silently on a protocol change; tying the daemon to the app's version.
- Keeping panes alive across a daemon replacement, by handing their ptys to
  the new daemon, would remove the restart altogether. It is a separate,
  later decision.
