# ADR-0001: coastty-host is the single source of truth; the GUI is a client

Status: accepted, 2026-09-17. Tracked by #7.

## Context

coastty's goal for remote access is not "a terminal you can reach" but coastty
itself, remotely: a phone (with an off-the-shelf SSH client today, a native
coastty client later) should be able to open every Space, tab and pane with the
agent status that goes with them.

Until now the daemon (coastty-host) knew only about panes - bytes, size, alive.
Spaces, tabs, membership, names, hidden state, agent status and "seen" lived
only in the running macOS app. Quit the app and that knowledge was gone, so
there was nothing a second client could render. The project's standing rule -
logic in Zig, Swift only draws - already pointed at the fix; this makes it
explicit.

## Decision

coastty-host owns the model: Spaces, tabs, pane membership and order, names,
hidden state, agent detection, seen and recency. It persists the model itself.
Every client, including the macOS GUI, reads the model from the daemon and
writes changes to it over the wire protocol. The GUI keeps only per-window
presentation (frame, which Spaces a window shows, active indices, focused
pane, split geometry). The daemon never knows windows exist.

Agent detection runs in the daemon, reusing the existing Zig module against the
terminal state the daemon already holds, so status exists whether or not the
GUI is open. Ghostty's Termio stays in the GUI: it is rendering-coupled by
design and is not what makes detection work.

Attaching to a pane is treated as logging in: clients authenticate, carry a
label, and attach as observer or controller.

## Consequences

- The GUI becomes a writer at exactly the points it marks its session dirty
  today, and a reader at launch. `session.json` shrinks to presentation only.
- Restore flips direction: the GUI fetches the model, then attaches panes under
  known Space/tab ids, instead of decoding JSON and pushing panes at the daemon.
- The daemon needs a persistent, per-daemon (dev vs prod) state directory, a
  timer, and a subscribable control channel with a versioned handshake.
- Features touching the model (e.g. hiding a Space, #11) are built on the daemon
  model, not on Swift state.
- Two detectors run per host-backed pane while the GUI is open (Termio's and
  the daemon's). Accepted for now; converging on the daemon's is a later refactor.
- Rejected: tmux control-mode compatibility; a browser tier as the foundation;
  removing windows as a GUI concept.
