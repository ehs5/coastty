# coastty: domain glossary

The words this project uses, and what they mean here. Skills and agents working
in this repo should use these terms as defined and avoid the synonyms noted.
Decisions that are hard to reverse live in `docs/adr/`.

## The pieces

- **coastty** - a macOS terminal forked from Ghostty. Ghostty plus a sidebar and
  real session persistence; everything else should look and behave like Ghostty.
- **coastty-host** (the **daemon**) - a headless process, one per user, that owns
  every pane's pty and terminal state and outlives the GUI. It is the single
  source of truth for the model (ADR-0001). Reached over a Unix socket speaking
  the **wire protocol** (`src/host/wire.zig`). Only processes running as the
  user can connect.
- **the app's token** - a secret the daemon makes on every start and writes
  beside its socket (`<socket>.token`, owner-only). The app sends it with every
  request that reaches inside a pane (`CREATE`, `ATTACH`, `KILL`, `SWEEP`) and
  when it subscribes as the app; without it those are refused. Reading the
  model and asking for layout changes need no token. Never placed in a pane's
  environment or on a command line.
- **protocol version** - `wire.protocol_version`, the version of the wire
  protocol. Bumped only when the app and the daemon can no longer talk.
- **daemon version** - `wire.daemon_version`, the version of the daemon's
  own code, which the daemon reports in answer to `VERSION` along with the
  protocol version. Bumped when the daemon changes in a way users should get.
  An app that finds a daemon with either number different from its own, older
  or newer, restarts it and tells the user afterwards (ADR-0003). Not the
  app's version: an app-only release changes neither number.
- **the GUI** (the Mac app) - one client of the daemon. It draws; it does not own
  the model.
- **client** - anything speaking the wire protocol: the GUI, `coastty attach`,
  a future native phone app. All clients are peers to the daemon.
- **`coastty attach`** - the terminal-mode client: a picker of Spaces/tabs/panes,
  then a raw-mode attachment to one pane. The first non-GUI client; what a phone
  reaches over SSH or mosh.

## The model (owned by the daemon)

- **pane** - one terminal: a pty, a running process, a parsed screen. Identified
  by `surface:<uuid>`, the GUI surface's persisted id. *Avoid:* "session" or
  "terminal" for a single pane.
- **tab** - an ordered list of panes (the panes of one split). Has an optional
  user-set title.
- **Space** - an ordered list of tabs. Has an optional user-set name; its default
  name is derived from its starter pane's directory. *Avoid:* "workspace".
- **hidden Space** - a Space tucked out of the normal Space order but fully
  alive. Hidden Spaces form their own ring for cycling; a hide/unhide toggle and
  a browse-hidden toggle are the only bridges (#11).
- **attention state** - the four user-facing states of an agent pane:
  **Working**, **Done** (finished, not yet seen), **Idle** (finished and seen),
  **Blocked** (waiting on a permission prompt). Derived from the detector's
  state (idle / working / blocked / unknown) plus **seen**.
- **seen** - a fact about a pane: some client has looked at it since it last
  finished. Any client viewing a pane marks it seen for every client.
- **recency** - a monotonically increasing counter bumped on every genuine
  attention-state change; orders the sidebar's Agents section.
- **agent detection** - the Zig module (`src/agent-detection/`) that reads a
  pane's screen, title, progress report and foreground process to decide the
  detector state. Runs in the daemon (and, for now, also in the GUI's Termio).
- **revision** - a counter on the whole model, bumped on every change. Paired
  with the **run id** (this run of the daemon) it tells a client whether the
  copy it is holding is still current.
- **model.json** - the daemon's own file (`src/host/Model.zig`), under
  `~/.local/state/coastty-host/<socket>/`, namespaced by the socket the daemon
  serves so a dev daemon and the production one never share one. Holds what
  exists, never what is running: a restart brings the Spaces, tabs and
  directories back as fresh shells, not the processes that were in them.

## Presentation (owned by each GUI window)

- **window** - a Mac window showing some Spaces. Frame, which Spaces it shows,
  active Space and tab, focused pane per tab, split geometry (directions,
  ratios, zoom), tab color, sidebar width. Has a **window id** that survives
  app restarts. The daemon owns nothing about windows; it holds what the app
  reports about them (each window's id, its Spaces and its active Space)
  while the app is connected, in memory only.
- **session.json** - the GUI's per-window presentation file, namespaced by
  bundle id. Historically it also held the model; after ADR-0001 it does not.

## Attachment

- **attach** - a client opening a live, two-way stream to one pane. Equivalent
  to logging in: treat it with the same care.
- **observer** / **controller** - the two attachment roles. Observers receive
  output and status; only a controller may send input or resize. Attaching
  defaults to observer.
- **resize policy** - while a GUI client is attached to a pane, only the GUI's
  size is honoured; a phone never reflows the desktop.
- **client label** - the name a client attaches under, so the GUI can show and
  revoke attachments.

## Controlling coastty

- **layout commands** - the `coastty space`, `coastty tab`, `coastty pane` and `coastty window` commands
  that create, close, rename and reorder Spaces and tabs, split and close panes,
  bring any of them to the front, and list windows and move Spaces between them.
  Usable alike by people, scripts and agents. They change layout only: they never
  type into a pane or read one.
  *Avoid:* "workspace commands".

## Lifecycle words

- **close** - ends the process(es) in a tab, Space or window. Destructive,
  confirmed when something is running, no undo.
- **quit** - the GUI exits; nothing is killed. Panes keep running in the daemon.
- **hide** - a Space leaves the normal ring; nothing is killed; no confirmation.
- **sweep** - at launch the GUI names every pane it still wants; the daemon ends
  the rest.
- **session ended** - a pane whose process died while the GUI was closed; on
  reattach it becomes a fresh shell with a visible notice.
- **daemon restart** - the daemon is stopped with SIGTERM, which writes the
  model out, and a new one started. Every pane's process ends and comes back
  as a fresh shell in its directory; Spaces and tabs survive. The app causes
  one only when the running daemon's protocol or daemon version differs from
  its own, and a dialog always says so afterwards.

## Ghostty terms that matter here

- **Surface** - Ghostty's per-pane object in the GUI process.
- **Termio** - Ghostty's per-surface I/O object: reads the pty (or, for a
  host-backed pane, the daemon's stream), parses it into terminal state, and
  drives the renderer. Lives in the GUI only; it is rendering-coupled by design.
- **apprt** - Ghostty's platform runtime layer (`src/apprt/embedded.zig` for
  macOS): the C ABI Swift calls.
