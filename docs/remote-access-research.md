# Remote access to coastty-host panes: research and architecture assessment

Status: research only. No code, no implementation plan. Written against the
`coastty-host` daemon as of 14 September 2026, the v0.1 spec, the session
persistence work, issue #7,
and the public documentation of Moshi, dotMux, ttyd, mosh and Tailscale
(sources at the end).

## Summary

- **The tmux door is closed, and that is fine.** Moshi does not need tmux at
  all; dotMux is built entirely on tmux's control-mode protocol and cannot be
  made to talk to `coastty-host` short of emulating tmux, which is not worth
  doing. What both apps actually need is an SSH server on the Mac. coastty
  should stop thinking of pillar 3 as "be tmux-compatible" and think of it as
  "be a good citizen of an SSH session".
- **"Every tab automatically remote-accessible with zero setup" is half right.**
  Zero *per-tab* setup is right: once the machine is reachable, every pane
  should be listed and attachable with no per-tab toggles. *Automatic* exposure
  of the machine is wrong: coastty must never open a network path on its own.
  The recommended shape is one explicit, visible, revocable machine-level
  enrolment, after which every pane is reachable. Not per-tab opt-in, not
  silent.
- **Recommended architecture: SSH-native first.** Ship a real `coastty attach`
  terminal client (picker + raw-mode attach) that speaks the existing wire
  protocol, reachable through macOS's own Remote Login (`sshd`) and therefore
  through plain `ssh`, `mosh host -- coastty`, Moshi, dotMux (plain-terminal
  mode), Blink, Termius, or anything else. Tailscale is the recommended
  *network* layer, exactly as Moshi's own docs recommend; it is not required.
  This reuses `sshd`'s authentication, mosh's roaming, and every mobile
  client's key handling (Secure Enclave keys in both Moshi and dotMux) instead
  of rebuilding them.
- **The web-terminal-over-Tailscale candidate is sound but second.** The
  ATTACH-to-WebSocket bridge itself is small and `ATTACH` is already
  bidirectional, so feasibility is not the problem. The problems are that
  coastty would own an HTTP/TLS/WebSocket/auth surface it does not own today,
  xterm.js is a poor terminal on iOS Safari, and the design has to depend on
  which of the three Tailscale macOS variants the user runs. Worth doing later
  as a "glance and approve from a browser" tier, not as the foundation.
- **Security is where the premise needs the most correction.** A pane is a
  shell running as the user, and an agent pane is a shell that will execute
  whatever it is told to approve. Whatever transport is chosen must treat
  "attach with input" as equivalent to "log in", and the local socket's
  current no-auth model (any same-uid process, including a process inside an
  agent pane, can `ATTACH` and `INPUT` to any other pane) needs to be fixed
  before any of it goes near a network.

## 1. What coastty-host is today (facts from the code)

Everything below is from `src/host/*.zig` and `src/termio/HostBackend.zig`.

**Shape.** A headless daemon, started by the GUI on demand (`coastty-host
start` forks, `setsid`s, and serves forever; `HostBackend.connectOrStartHost`
spawns it from `Contents/MacOS/` and polls for the socket, macOS only). It
holds an in-memory registry of panes; nothing is persisted, so it survives a
GUI quit or crash but not a reboot. Each pane is a pty-owned child plus a real
Ghostty `Terminal` fed by a reader thread, so the daemon always has an
authoritative, parsed screen even with nobody attached.

**Protocol** (`wire.zig`). Plain text headers, length-prefixed binary bodies,
one connection per request, over a Unix socket at `$TMPDIR/coastty-host-<uid>.sock`.
Commands: `CREATE` (spawn, or reuse a live pane by id and resize it), `LIST`
(id, cols, rows, alive - nothing else), `ATTACH <id>`.

**`ATTACH` is already a full duplex terminal session, not an observer feed.**
This is the single most important feasibility fact. After `OK`, `META`, and a
`SNAPSHOT` (a genuine VT byte stream that reconstructs cursor position, styles,
modes, scroll region, tabstops, palette and title, not a text dump), the
connection carries `DATA` frames out and accepts `INPUT <len>` and
`RESIZE <cols> <rows>` in (`Host.zig`, `handleAttach` loop; `Pane.writeInput`,
`Pane.resize`). Multiple subscribers per pane are supported: `Pane.subscribers`
is a list and every pty chunk is broadcast to all of them under one lock, so a
GUI tab and a remote client can watch the same pane simultaneously today. The
`coastty-host attach` debug CLI is print-only, but that is a limitation of the
CLI, not of the daemon.

**What the daemon does not know.** It has no names. `LIST` cannot tell a
remote client which pane is "backend · claude" in Space "plainkey"; tab names,
Space membership, and the four attention states all live GUI-side. Agent
detection runs in the GUI using the `META <pgid> <child_pid>` frames, so a
remote client would either need the GUI running and publishing state, or the
daemon would need to run detection itself. There is no `FORGET`/kill command
(noted as future in `Pane.deinit`'s comment). Pane identity is derived from the
working directory plus an in-process counter (`HostBackend.stableId`), a
documented limitation that already makes reattach unreliable beyond the first
tab per directory; a remote picker would inherit that ambiguity.

**No authentication or authorization of any kind.** The only access control is
that `$TMPDIR` is a per-user 0700 directory on macOS. Any process running as
the user can `LIST` every pane and `ATTACH`+`INPUT` to it. That includes every
process running *inside* a pane, i.e. an agent can type into a sibling agent's
session. Acceptable-ish for a local-only daemon whose only client was meant to
be the GUI; not acceptable the moment a network client exists, because a
compromised remote client gets the same unrestricted socket.

**Resize has no policy.** Any client's `RESIZE` changes the one pty's size for
everyone. tmux has a `window-size` option (smallest/largest/latest) precisely
because this is the first thing that hurts when a phone attaches to a desktop
session. A phone attaching at 45 columns would reflow the Mac's tab.

**Related dormant asset.** `src/terminal/tmux/{control,layout,output,viewer}.zig`
is Ghostty's tmux control-mode *client* (it consumes `%output`, `%layout-change`
etc.). It is not a server and does not help make coastty look like tmux to
anyone.

## 2. What Moshi and dotMux actually require

### Moshi

Moshi ("Moshi: herdr/tmux on SSH/MOSH" on the App Store) is an iOS terminal
client with three transports: SSH, mosh (bootstrapped over SSH, then UDP), and
Eternal Terminal. Its docs are explicit that the host needs nothing beyond an
SSH server: "Without it, Moshi works via SSH/Mosh alone." tmux is recommended
("the strongest setup is mosh for transport plus tmux for process lifetime")
but optional.

Multiplexer support is first-class but hardcoded. On connect Moshi runs an SSH
preflight that probes `command -v herdr`, `command -v tmux`, and
`command -v zellij`, lists sessions per multiplexer (for herdr: `herdr session
list --json`), and shows them under separate tabs in a session picker with a
per-multiplexer shortcut panel. There is no documented way to register a
fourth multiplexer or a custom attach command. The herdr integration is the
useful precedent: herdr is not tmux, has its own session model, and Moshi
added it as "a peer to tmux and Zellij" - detection, picker, shortcuts, hook
context. coastty's path to first-class Moshi support is therefore the same as
herdr's: a `coastty session list --json`-style command and a pitch to Moshi's
developer, not protocol compatibility.

Two host-side hooks matter for design:

- The Mosh connection type has a per-connection "Mosh path" setting (custom
  path to `mosh-server`, e.g. `/opt/homebrew/bin/mosh-server`). mosh-server
  accepts a trailing `-- COMMAND`, so a wrapper at that path that execs the
  real `mosh-server` with `-- coastty attach` appended would drop a Moshi mosh
  session straight into coastty's picker. One-time per-connection setup, no
  `sshd` changes.
- Moshi's optional `moshi-hook` host daemon delivers agent approvals and a
  chat view by consuming the *agent's own* hooks (Claude Code hooks), not by
  talking to the multiplexer. That is orthogonal to coastty and would work
  alongside it unchanged.

Moshi's Tailscale page is essentially the architecture this document
recommends: ordinary `sshd` (macOS "Remote Login") reached over the Tailscale
tunnel by 100.x address or MagicDNS name, mosh-server from Homebrew, and an
explicit warning to *disable* Tailscale SSH because it bypasses `sshd` and
`authorized_keys`.

### dotMux

dotMux is a native iOS SSH client whose whole feature set (windows as native
tabs, panes as native views, session picker, touch split/resize) comes from
speaking tmux control mode: "dotMux talks to tmux over its control-mode
protocol (tmux -CC), so it owns the rendering." Auth is ed25519 or Secure
Enclave P-256 keys, or password; connections are direct, no relay. With no
tmux on the host it "falls back to a plain terminal, gracefully."

So dotMux against coastty is a plain SSH terminal - which is enough for `ssh`
+ `coastty attach`, but none of dotMux's native chrome. Making it more than
that would mean coastty-host impersonating `tmux -CC`: implementing
`list-sessions`/`list-windows`/`list-panes` with `-F` format strings,
`%begin`/`%end`/`%error` guards, `%output` with octal escaping,
`%layout-change`, `refresh-client` sizing and flow control, `send-keys`, and
matching undocumented notification ordering that Ghostty's own viewer notes is
"based on reading the tmux source code as of Dec 2025." That is a large,
fragile compatibility surface for one client, and it would drag coastty back
toward the tmux session/window/pane model it deliberately left. Not
recommended; the door is closed and should stay closed.

### Net effect on pillar 3

The original bet - "real tmux underneath so Moshi/dotMux/SSH work for free" -
was mostly a bet about *SSH*. Moshi never required tmux; dotMux is the only
tool for which tmux was load-bearing, and only for its native-tabs mode. What
actually made "free" possible was that tmux is a terminal program you can run
inside any SSH session. coastty-host can have the same property by shipping a
terminal client for its own protocol.

## 3. Is "every tab automatically remote-accessible, zero setup" good DX?

Short answer: the *reachability* half is right, the *automatic* half is
wrong, and the two get conflated because tmux blurred them.

### What holds up

**Zero per-tab setup.** A remote client's first screen is necessarily a list
("which of my panes do I want?"), and that list is the discoverability
mechanism. Once a list exists, forcing the user to pre-flag tabs as "remote
enabled" on the Mac is pure friction: the moment you need something you did
not flag, you are back at the Mac. The user's actual mental model - "my
coastty, from my phone" - is machine-level, not tab-level. Every pane should
appear in the picker. An *exclusion* ("mark this pane private") is a
reasonable refinement; an inclusion list is not.

**Resource cost is a non-issue if modelled correctly.** "N remote-reachable
endpoints" is the wrong picture. There is one daemon, one listener (or none:
`sshd` is already the listener), and N panes that already exist for
persistence reasons. A remote attach costs one thread and one socket in the
daemon, plus one `mosh-server` or `sshd` child per *client*, not per pane.
Idle cost of being reachable is zero over what persistence already costs.

### What does not hold up

**Automatic exposure fails the surprise test.** Today coastty-host is a local
Unix socket. Opening any network path - a listener, a Tailscale Serve entry, a
`sshd` toggle, an `authorized_keys` line - without an explicit user action is
not a feature, it is a vulnerability disclosure waiting to be written. A
security-conscious user's expectation is that a terminal emulator does not
listen on the network until told to. The standing design constraint ("look
and behave exactly like Ghostty, the sidebar is the only addition") cuts the
same way: Ghostty does not silently open ports.

**"Invisible" is the right bar for daily use, not for enrolment.** The tmux bundling decision
already drew this line for tmux: one-time setup may be visible, daily use must
be invisible. Remote access should follow it exactly: one explicit enrolment
(enable Remote Login, install `mosh-server`, or pair a device), then nothing to
think about afterwards. That was always the actual tmux story too - nobody
gets `sshd` enabled and keys distributed "for free"; tmux just meant there was
no *additional* coastty-specific step after that.

**Shared pty geometry is a real UX problem, not a detail.** With no resize
policy, attaching from a phone reflows the desktop tab, and Claude Code's TUI
at 45 columns is barely usable anyway. This needs a deliberate answer
(remote clients cannot `RESIZE` by default; or the desktop's size wins while
the GUI is attached; or an explicit "take over size" action). tmux hit the
same problem and grew `window-size` options for it; coastty gets to choose
once instead.

**Accidental input.** A phone in a pocket with a live, writable attach to an
agent's permission prompt is a foot-gun. ttyd is read-only by default (`-W`
to allow writes) for the same reason. The cheap fix is a role: attach as
observer, one explicit action to take control. For the agent-approval use
case this is one tap and worth it.

**Status without the GUI.** The user story is "check on my agents from my
phone." If the GUI has quit (the whole point of persistence), nobody is
computing Working/Green/Checkmark/Red, because detection is GUI-side. A picker
that lists panes without attention state is much less useful than the sidebar.
Either the daemon learns to run detection (it has the parsed `Terminal`, the
pgid, and the OSC title, so it has the inputs), or the picker is honest that
status is only available while coastty is open.

### Opinion

Design remote access as: **explicit machine enrolment, implicit pane
reachability, visible attachment.** Concretely: nothing is reachable until the
user takes a one-time action that is obviously about remote access; after
that every pane is listed and attachable with no per-tab configuration; and
while any remote client is attached, the GUI shows it (the way tmux shows
attached clients in its status), with a way to kick it. That last part is not
optional polish - the local user seeing "someone is attached to this pane" is
the main mitigation against a stolen phone or a compromised tailnet device.

Per-tab opt-in should be rejected. It optimises for a threat (the user
accidentally exposing a specific tab) that machine-level enrolment already
covers, at the cost of the property that makes remote access worth having.

## 4. Architecture

### 4.1 Foundation work every option needs

Whatever transport wins, these gaps in the daemon come first, because a
remote client is useless without them and they are transport-independent:

1. **Pane metadata in the daemon.** Tab name, Space name, cwd, and ideally
   attention state, pushed by the GUI over new control commands, so `LIST`
   (or a richer successor) can drive a picker. The GUI already has all of
   this; the daemon needs a place to hold it and a way to receive updates.
2. **Stable pane identity from the GUI.** Already flagged in `HostBackend`'s
   `ConnectOptions` comment as the intended fix for the per-directory counter;
   a remote picker makes it urgent, since "which of these three `~/dev/x`
   panes is the one with Claude in it" is exactly the question the phone asks.
3. **Client roles on `ATTACH`.** Observer vs controller, with `INPUT`/`RESIZE`
   honoured only for a controller, and a resize policy that stops a remote
   client from reflowing the desktop by default.
4. **Authentication on the socket for non-GUI clients**, and a way for the
   daemon to know *who* is attached (a label per subscriber) so the GUI can
   show and revoke attachments. See section 5.
5. **Optional: detection in the daemon**, so status is available with the GUI
   closed. Bigger, but the daemon has every input detection needs.

None of this is remote-specific; items 1-3 also improve the local story.

### 4.2 Option A (recommended): SSH-native via a real `coastty attach` client

**Mechanism.** A terminal-mode client for the existing wire protocol: puts its
own tty in raw mode, forwards keystrokes as `INPUT`, forwards `SIGWINCH` as
`RESIZE`, replays `SNAPSHOT`/`DATA` to stdout, and starts with a picker built
from the metadata in 4.1 (Spaces, tabs, status) when no pane id is given. The
debug CLI in `src/host/main.zig` is the seed of this but is print-only today.

Then reachability is whatever already gets a shell onto the Mac:

- `ssh mac` then `coastty` (or `ssh -t mac coastty attach <id>`).
- `mosh mac -- coastty` - mosh runs arbitrary commands, so roaming, packet-loss
  tolerance and sleep survival come from mosh, unchanged, exactly as they do
  for `mosh host -- tmux attach`.
- Moshi in SSH mode: connect, type one word. In Mosh mode: point "Mosh path" at
  a coastty-shipped wrapper that appends `-- coastty` to the real
  `mosh-server`. Longer term, offer Moshi a `session list --json` command in
  the herdr shape and ask for a picker tab.
- dotMux, Blink, Termius, Prompt, a laptop: plain terminal, same command.
- Optionally, a dedicated coastty SSH key with an `authorized_keys`
  `command="coastty attach"` + `restrict` line, so a phone's key lands
  directly in the picker and cannot open port forwards or scp. This has to
  special-case mosh's bootstrap (`SSH_ORIGINAL_COMMAND` beginning with
  `mosh-server new ...` must exec the real mosh-server with `-- coastty`
  appended) - a known pattern, but a real detail to get right.

**Network layer.** Tailscale, recommended not required: ordinary `sshd`
reached over the tailnet by MagicDNS name, precisely the setup Moshi's own
docs describe, with Tailscale SSH explicitly *off* (it bypasses `sshd` and
`authorized_keys`, and the Tailscale SSH server is not available on the App
Store or Standalone macOS variants anyway). Anyone without Tailscale uses
whatever they already use to reach their Mac.

**Why this is the right first tier.**

- It reuses hardened infrastructure for every hard part: `sshd` for
  authentication and transport encryption, mosh for roaming, the client apps
  for key storage (Secure Enclave in both Moshi and dotMux), Tailscale for
  reachability without port forwarding. coastty adds no listener, no TLS, no
  session cookies, no origin checks.
- It matches pillar 3's literal wording ("tools he already has, zero
  coastty-specific client software") better than any browser page does.
- Enrolment *is* the security boundary and it is Apple's own: System Settings
  > Sharing > Remote Login. There is no way to be accidentally exposed.
- It is the smallest build: one CLI client plus the 4.1 foundation.

**Real costs and gaps.**

- Remote Login must be on and, for mosh, `mosh-server` installed (Homebrew).
  One-time and visible, which section 3 argues is correct, but it is not
  "zero setup".
- No browser access. A machine with only a browser cannot reach it.
- Moshi's picker will not list coastty panes until Moshi adds support; until
  then it is "connect, type `coastty`." dotMux stays a plain terminal.
- SSH's own weaknesses apply: enable key-only auth, and note that a coastty
  attach is a shell, so a `command=`-restricted key restricts *how* you get
  a shell, not *whether*.
- The Mac has to stay awake; Moshi's "Mac as endless agent" guide covers the
  power-settings side, but coastty cannot fix it.

### 4.3 Option B: web terminal (ttyd pattern) over Tailscale

**The candidate as floated.** coastty-host (or a sidecar) runs a small HTTP
server; a page loads xterm.js; a WebSocket carries `ATTACH` frames both ways;
`tailscale serve <port>` publishes it on the tailnet at
`https://<mac>.<tailnet>.ts.net` with an automatically provisioned
certificate, tailnet-only (Funnel would make it public and must never be
used). The user opens the URL on the phone.

**What checks out.**

- The bridge is genuinely small: `ATTACH` is already duplex, `SNAPSHOT` is
  already a full VT stream, so a WebSocket client gets correct cursor and
  styling on connect and after every reconnect. ttyd's architecture
  (libwebsockets + xterm.js, one process per client, `-W` writable flag,
  `-O` origin check, `-H` auth-header for reverse-proxy identity) is a
  direct template.
- Tailscale Serve on macOS: proxying a local *port* works on the App Store
  and Standalone variants (only serving files/directories is restricted to
  the open-source variant). Serve adds `Tailscale-User-Login` /
  `Tailscale-User-Name` / `Tailscale-User-Profile-Pic` headers to proxied
  requests and strips any incoming copies, so the backend can know which
  tailnet user is connecting; `tailscale whois <ip> --json` and the LocalAPI
  `whois` endpoint give the same answer for raw connections.
- No port forwarding, no public exposure, WireGuard encryption in transit
  plus TLS at the Serve layer.

**What does not.**

- **coastty would own a web attack surface it does not own today**: HTTP
  parsing, WebSocket framing, TLS termination (or trust in Serve for it),
  origin/CSRF handling, session cookies, rate limiting - in Zig, in a daemon
  that outlives the GUI. ttyd's option list is a catalogue of the things that
  had to be added over years. This is the opposite of Option A's "reuse
  hardened infrastructure."
- **xterm.js is a weak terminal on iOS.** Upstream issues document limited
  touch support (#5377, #1101), predictive-keyboard interference (#2403),
  copy/paste not working on touch devices (#3727), and Safari on
  iPadOS/iOS with a hardware keyboard turning Ctrl-C into Enter (#5721). No
  Ctrl/Esc/arrow row without building one. Moshi and dotMux exist precisely
  because browser terminals on phones are bad; "open a URL" undersells how
  much worse the experience is than a native SSH client.
- **It depends on the user's Tailscale variant and CLI location** (bundled
  inside the app for the GUI variants), and on Tailscale being up. If
  coastty configures Serve itself it is editing another product's state; if
  it does not, "zero setup" is gone. WebSocket upgrades through Serve
  generally work but have had breakages reported by other projects; a
  reconnect-and-`SNAPSHOT` strategy covers transient failures but the
  experience is still worse than mosh roaming.
- **Tailnet identity is not authorization.** Being on the tailnet proves a
  device is enrolled in the tailnet, not that it should have a shell on this
  Mac. Family or shared tailnets, node sharing, and compromised nodes all
  break "if you can reach it you may use it." A pairing step (code shown in
  the coastty GUI, device gets a long-lived credential) plus Tailscale ACLs
  restricting the port to specific devices is still needed. See section 5.
- Binding must be `localhost` behind Serve or the Tailscale interface only,
  never `0.0.0.0`; a page reachable on the coffee-shop LAN over plain HTTP
  would be a disaster.

**Verdict.** Viable and worth doing *after* Option A, as a "glance and approve
from any browser" tier, reusing the same 4.1 foundation and, ideally, the same
role/auth model. Not the foundation: it is more code, more surface, and a
worse terminal than what the user already has in their pocket.

### 4.4 Option C: embed Tailscale in coastty-host (libtailscale / TailscaleKit)

Tailscale publishes `libtailscale`, a C wrapper around `tsnet`, with a Swift
`TailscaleKit.framework` for macOS/iOS. coastty-host could join the tailnet as
its own node, independent of which Tailscale app the user runs, with its own
ACL identity and a built-in `whois`. This removes the "which variant, where is
the CLI" problem from Option B and makes ACL-gating clean.

Costs: a Go runtime linked into a Zig daemon, a separate device to authorise
in the tailnet admin, binary size, and a second Tailscale node on the same
machine. It only makes sense if Option B is pursued seriously; note it, do not
start here.

### 4.5 Option D: emulate tmux control mode for dotMux / iTerm2

Rejected; see section 2. Large, fragile, one-client, and re-imports the
tmux session model. dotMux's plain-terminal fallback plus Option A is the
honest answer.

### 4.6 The other remote case

The v0.1 spec flagged that "remote" may also mean coastty *itself* opening
workspaces where the agent runs on another machine. That is a different
problem (coastty as client, not server), but Option A composes with it:
coastty-host running on the remote box, the GUI's `HostBackend` speaking the
same protocol over an SSH-forwarded Unix socket. Designing the wire protocol's
auth and metadata additions (4.1) with "the client might be a GUI on another
machine" in mind costs nothing now and avoids a second protocol later.

## 5. Security

### 5.1 What is at stake

A pane is an interactive shell running as the user, with the user's keychain
access, SSH agent, cloud credentials in env, and filesystem. An agent pane is
worse in one specific way: its permission prompt is a "run this command as me"
button, so anyone who can type one `y` into it has arbitrary code execution
without needing to know a single command. Read-only attach still exposes
everything the agent prints - source, tokens in logs, `.env` contents it
`cat`s - so observer access is sensitive too, just less catastrophic.

Treat "attach" as "log in" for every decision below.

### 5.2 Adversaries

1. **A malicious or compromised process on the Mac, running as the user.**
   Today any such process can `ATTACH` and `INPUT` to every pane through the
   unauthenticated socket - including a process inside one agent's pane
   typing into another agent's prompt. Remote access does not create this,
   but it multiplies who can become "a process on the Mac."
2. **A device on the same LAN or tailnet.** With Option A: needs an SSH
   credential; tailnet membership alone gets nothing if password auth is off.
   With Option B on tailnet identity alone: a compromised or merely shared
   tailnet node gets a shell. This is the strongest argument for pairing on
   top of tailnet identity.
3. **A stolen or unlocked phone.** Both Moshi and dotMux store keys in the
   Keychain/Secure Enclave with biometric gating, which is as good as mobile
   gets. A browser with a long-lived cookie is weaker; short TTLs and
   "controller" requiring re-confirmation help.
4. **The user themselves, by accident.** Wrong pane, pocket input, a stale
   session left attached. Roles, visible attachment indicators, and a
   one-tap kick address this.

### 5.3 Authentication and authorization

**Option A** inherits `sshd`'s. Recommendations that coastty can document but
not enforce: key-only auth (`PasswordAuthentication no`), one key per device,
and for phone keys an `authorized_keys` entry with `restrict` and
`command="coastty attach"` so the key cannot open port forwards, X11, or scp.
Be honest in the docs that this restricts the *route*, not the *power*: the
picker hands out shells.

For the daemon itself, `sshd` has already authenticated the OS user by the
time `coastty attach` runs, so the client is trusted at the same level as the
GUI. The daemon should still learn a per-attachment label (from
`SSH_CONNECTION`/`SSH_CLIENT`, or the key comment) so the GUI can show and
revoke it.

**Option B** must not accept tailnet identity as sufficient. Layer:
`Tailscale-User-Login` (or `whois`) as the coarse gate, restricted further by
Tailscale ACLs to specific devices; plus an explicit pairing (one-time code
displayed in the coastty GUI, exchanged for a device credential the daemon
stores) so an unfamiliar tailnet device is refused even with a valid user
header; plus origin checks on the WebSocket and a `SameSite`/`HttpOnly`
credential. Tailscale's "check mode" re-authentication is only available for
Tailscale SSH, which macOS GUI variants cannot serve, so it cannot be leaned
on here.

**Per-pane authorization** is probably over-engineering for a single-user
tool. A "private pane" exclusion (never listed, never attachable remotely) is
the one per-pane control worth having - for a pane where the user is doing
something with credentials they would not want on any other device. Per-device
or per-key allow lists are the right granularity for everything else.

**Roles.** Observer by default; controller on explicit action; `RESIZE` only
for a controller and even then subject to a policy that protects the desktop
layout. This is both a UX fix (section 3) and a security fix (the blast radius
of a stolen observer session is disclosure, not execution).

### 5.4 Encryption in transit

Option A: SSH, or mosh's AES-128-OCB3 over UDP with the key exchanged over
SSH. Option B: WireGuard end to end when reached over Tailscale, TLS via Serve's
provisioned certificate on top. In every option, the daemon should never
accept a plaintext network connection; if it listens on TCP at all it binds
`127.0.0.1` behind Serve or the Tailscale interface only.

### 5.5 Hardening the local socket regardless

The remote work is a forcing function to fix the local model:

- Distinguish the GUI from other same-uid clients. The daemon can obtain peer
  credentials on the Unix socket (uid/pid via `LOCAL_PEERCRED`/`getpeereid`),
  but same-uid is the whole problem; a shared secret the GUI generates at
  daemon start (file with 0600 perms, or passed in the daemon's environment)
  and presents on each connection is the simplest meaningful step.
- Refuse `ATTACH` from processes that are descendants of a pane's own child,
  or at least from processes whose environment marks them as agent children.
  `Pane.zig` already scrubs `CLAUDE*`/`AI_AGENT` markers from spawned envs,
  so there is precedent for reasoning about this; it is heuristic, not a
  boundary, but it closes the obvious "agent types into sibling agent" hole.
- Audit log: attach/detach/role-change with client label and timestamp, in
  the daemon's log. Cheap, and the only way to answer "did anything attach
  while I was away?"

### 5.6 "Automatic and invisible" versus "secure by default"

They are in direct tension, and the resolution is to split the timeline:

- **Enrolment: explicit and visible.** Turning on Remote Login, installing
  `mosh-server`, pairing a device, or enabling a web listener are all user
  actions with a clear "this makes my Mac reachable" meaning. coastty should
  guide them, never perform them silently, and should default to *off*.
- **Daily use: invisible.** No per-tab steps, no prompts when attaching from
  an already-enrolled device, no tmux-style chrome.
- **While attached: visible.** A remote-attach indicator in the GUI (per pane
  in the tab bar and/or aggregated in the sidebar), a list of attached
  clients, and a kick action. This is the single highest-value security
  feature in the whole design and also the cheapest, because the daemon
  already tracks subscribers.

## 6. Recommendation

1. Do the transport-independent foundation (section 4.1): pane metadata and
   stable identity in the daemon, observer/controller roles with a resize
   policy, authenticated non-GUI clients with labels, and attachment
   visibility in the GUI. This improves the local product on its own.
2. Ship Option A: a real `coastty attach` picker/terminal client, documented
   alongside macOS Remote Login, Homebrew `mosh`, and Tailscale as the
   recommended network. Offer a `session list --json` command shaped like
   herdr's and approach Moshi about a picker tab.
3. Revisit Option B once A is in use, as a browser tier for machines without
   an SSH client, reusing the same roles and pairing model. Consider Option C
   only if B is pursued and the Tailscale-variant dependency proves painful.
4. Do not pursue tmux compatibility in any form.
5. Reframe issue #7 accordingly: the goal is "coastty panes are first-class
   inside any SSH/mosh session to the Mac," not "works with Mosh out of the
   box" in the sense of protocol compatibility - and record the DX decision
   that exposure is machine-level and explicit, reachability is pane-level and
   implicit.

## 7. Open questions worth settling before anything is ticketed

- Should the daemon run agent detection itself so status survives the GUI
  quitting, or is "status only while coastty is open" acceptable for v1?
- Resize policy: desktop-wins-while-GUI-attached, remote-cannot-resize, or
  explicit take-over? This decides how usable Claude Code is from a phone.
- Where does the pairing/credential state for non-SSH clients live, given
  the earlier "no persistent store" decision? Option A avoids the question; Option
  B cannot.
- Does the per-directory `stableId` get replaced by GUI-assigned ids as part
  of this, or first as its own fix? A picker makes the current ambiguity
  user-visible.
- Is a "private pane" exclusion wanted at all, or is machine-level enrolment
  plus visible attachment enough?

## Sources

coastty: `src/host/wire.zig`, `src/host/Host.zig`, `src/host/Pane.zig`,
`src/host/main.zig`, `src/host/paths.zig`, `src/termio/HostBackend.zig`,
`src/config/Config.zig` (`coastty-process-persistence`),
`src/terminal/tmux/viewer.zig`; the v0.1 spec, the session persistence work
and issue #7.

Moshi: [product page](https://getmoshi.app/),
[App Store listing](https://apps.apple.com/us/app/moshi-ssh-mosh-terminal/id6757859949),
[docs index](https://getmoshi.app/docs),
[terminal sessions](https://getmoshi.app/docs/terminal-sessions),
[connections](https://getmoshi.app/docs/connections),
[multiplexers](https://getmoshi.app/docs/multiplexer),
[herdr](https://getmoshi.app/docs/herdr), [tmux guide](https://getmoshi.app/guides/tmux),
[Tailscale](https://getmoshi.app/docs/tailscale).

dotMux: [dotmux.app](https://dotmux.app/),
[App Store listing](https://apps.apple.com/us/app/dotmux-easy-ssh-with-tmux/id6779584525).

tmux control mode: [tmux wiki: Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode).

ttyd: [project page](https://tsl0922.github.io/ttyd/),
[man page](https://github.com/tsl0922/ttyd/blob/main/man/ttyd.man.md).

mosh: [mosh.org](https://mosh.org/).

Tailscale: [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve),
[Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh),
[macOS variants](https://tailscale.com/docs/concepts/macos-variants),
[Tailscale identity](https://tailscale.com/docs/concepts/tailscale-identity),
[CLI reference (whois)](https://tailscale.com/docs/reference/tailscale-cli),
[tsnet](https://tailscale.com/docs/features/tsnet),
[libtailscale Swift](https://github.com/tailscale/libtailscale/tree/main/swift),
[WebSocket-through-Serve report](https://github.com/openclaw/openclaw/issues/54008).

xterm.js on mobile: issues [#1101](https://github.com/xtermjs/xterm.js/issues/1101),
[#5377](https://github.com/xtermjs/xterm.js/issues/5377),
[#5721](https://github.com/xtermjs/xterm.js/issues/5721),
[#3727](https://github.com/xtermjs/xterm.js/issues/3727),
[#2403](https://github.com/xtermjs/xterm.js/issues/2403).
