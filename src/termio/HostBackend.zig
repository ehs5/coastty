//! A `Termio` backend that reads and writes through coastty-host's control
//! socket instead of owning a local pty directly, so a pane's real process
//! keeps running - and can be reattached to - independent of the GUI's own
//! lifetime. See `src/host/wire.zig` for the protocol this speaks and
//! `src/host/Host.zig`/`src/host/Pane.zig` for the daemon on the other end
//! of it; this file only talks that protocol over a socket, it does not
//! reach into any of the host's internals directly.
//!
//! `connect` below does the (possibly slow, host-starting) handshake
//! before any of this exists, so a `Surface` can fall back to spawning a
//! pane locally (via `Exec`, unchanged) on any failure - a `HostBackend`
//! is only ever constructed once attaching has already succeeded.
const HostBackend = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const internal_os = @import("../os/main.zig");
const posix = std.posix;
const Io = std.Io;
const global = @import("../global.zig");
const lib = @import("../lib/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const wire = @import("../host/wire.zig");
const agent_detection = @import("../agent-detection/main.zig");
const paths = @import("../host/paths.zig");
const access = @import("../host/access.zig");
const upgrade = @import("../host/upgrade.zig");

const log = std.log.scoped(.io_host);

alloc: Allocator,

/// The pane's live, already-attached connection to coastty-host.
conn: net.Stream,

/// The daemon's id for this pane, so the GUI can name it in a `KILL` or
/// `SWEEP` request when the tab/Space/window holding it is closed. Owned
/// by this backend.
pane_id: []const u8,

/// True when the daemon replaced a pane that had died on its own with a
/// fresh one under the same id: the session this pane was meant to come
/// back to ended while coastty was gone. Shown once, on `threadEnter`,
/// so the tab doesn't silently pass the new shell off as the old session.
prior_session_ended: bool,

/// The initial screen contents the pane already had when we attached,
/// fed into the terminal the moment `threadEnter` has a `Termio` to feed
/// it through. Consumed (and freed) exactly once.
initial_snapshot: ?[]u8,

/// The pane's initial working directory, if known, so `initTerminal` can
/// seed the terminal's pwd the same way `Exec.initTerminal` does for a
/// local pane. Owned by this backend.
cwd: ?[]const u8,

/// Cached, best-effort process info relayed from the host's `META`
/// frames (see `wire.zig`). Guarded by `info_mutex`: the read thread
/// updates these from a different thread than `getProcessInfo` and
/// `paneChildPid` are called from.
info_mutex: std.Io.Mutex = .init,
pgid: ?u32,
child_pid: ?u32,

/// Guards writes to `conn`: `queueWrite` and `resize` both write to it,
/// potentially from different callers.
write_mutex: std.Io.Mutex = .init,

/// Set once the connection is known gone (EOF, a write failure, or
/// `threadExit`). Past this point writes are silently dropped rather
/// than attempted, matching how `Exec` stops writing to an exited child.
closed: std.atomic.Value(bool) = .init(false),

/// The connection's read buffer, from the attach reply through the life
/// of the read thread. One buffer for both, because whatever arrived with
/// the reply - the first `STATUS`, live output - is already in it.
read_buf: []u8,
read_seek: usize,
read_end: usize,

pub const Attached = struct {
    conn: net.Stream,
    pane_id: []const u8,
    snapshot: []u8,
    pgid: ?u32,
    child_pid: ?u32,
    prior_session_ended: bool = false,
    read_buf: []u8,
    read_seek: usize,
    read_end: usize,
};

/// How much of the stream the read thread buffers at a time.
const read_buf_len = 64 * 1024;

pub const ConnectOptions = struct {
    /// The pane's working directory. Only doubles as its identity when
    /// `id` is null (see `stableId`).
    cwd: []const u8,

    /// The GUI's own per-pane identity, stable across quit/relaunch
    /// because it is persisted with the restored session. This is what
    /// makes every pane - not just a directory's first - reattach to its
    /// own process. Null for callers that have no such identity (the CLI
    /// debug client, non-macOS apprts), which fall back to `stableId`.
    id: ?[]const u8 = null,

    argv: []const [:0]const u8,
    cols: u16,
    rows: u16,

    /// The environment this pane's process should run with. Null falls
    /// back to whatever the daemon's own `Pane.setDefaultEnv` provides -
    /// fine for the CLI debug client, but a real GUI-created pane always
    /// sends this (see `connectForExec`) so its shell has the same
    /// shell-integration setup a local pane's would.
    env: ?*const std.process.Environ.Map = null,
};

/// Tries to route `exec`'s already-resolved command through coastty-host
/// instead of spawning it locally. `exec` must not have been started yet
/// (see `Exec.init`'s own doc comment: it only prepares state, the pty/
/// fork happen in `threadEnter`) - this reuses its cwd/args/env rather
/// than resolving a thinner, separate command, so a host-attached pane's
/// shell ends up running with the same env (shell integration included)
/// a local pane's would - see #39's follow-up on OSC 7/133 and titles
/// silently never working for a host-attached pane otherwise.
///
/// Returns null whenever this pane should just spawn `exec` locally
/// instead - the toggle being off, no working directory to key an
/// identity on, or any failure to reach or start the daemon - matching
/// `Exec`'s own "never fail surface startup over this" contract. Either
/// way, `exec` itself is left untouched; the caller decides what to do
/// with it (spawn it, or discard it because this succeeded).
pub fn connectForExec(
    alloc: Allocator,
    io: Io,
    persistence_enabled: bool,
    exec: *const termio.Exec,
    pane_id: ?[]const u8,
    cols: u16,
    rows: u16,
) ?Attached {
    if (!persistence_enabled) {
        log.info("coastty-host: skipped, coastty-process-persistence is off", .{});
        return null;
    }
    const cwd = resolveCwd(exec.subprocess.cwd) orelse {
        log.info("coastty-host: skipped, no working directory and no home to fall back to", .{});
        return null;
    };

    return connect(alloc, io, .{
        .cwd = cwd,
        .id = pane_id,
        .argv = exec.subprocess.args,
        .env = if (exec.subprocess.env) |*e| e else null,
        .cols = cols,
        .rows = rows,
    }) catch |err| {
        log.info(
            "coastty-host unavailable, spawning this pane locally instead, err={}",
            .{err},
        );
        return null;
    };
}

/// Reaches coastty-host (starting it if it isn't already running),
/// creates or reuses the pane `opts` identifies, and attaches to it.
pub fn connect(alloc: Allocator, io: Io, opts: ConnectOptions) !Attached {
    const id = try resolveId(alloc, opts);
    errdefer alloc.free(id);

    // CREATE is a one-shot request/response over its own connection
    // (see `host/wire.zig`); the pane may already be live from a prior
    // run under this same id, in which case the host just resizes it
    // and hands it back rather than spawning a duplicate.
    var token: access.TokenArg = undefined;
    const outcome = outcome: {
        const conn = try connectOrStartHost(alloc, io);
        defer conn.close(io);
        // Read once connected, since a daemon this just started publishes its token on start.
        token = access.socketTokenArg(alloc, io);
        break :outcome try sendCreate(alloc, io, conn, id, opts, token.text());
    };

    // ATTACH keeps its connection open as the pane's live stream for the
    // rest of this backend's life.
    const conn = try connectOrStartHost(alloc, io);
    errdefer conn.close(io);
    var attached = try sendAttach(alloc, io, conn, id, token.text());
    // A null outcome (a daemon that reported no token) counts as an
    // ordinary attach, not a session that ended.
    attached.prior_session_ended = outcome == wire.CreateOutcome.ended;
    return attached;
}

/// Ends the named panes on coastty-host - one request for the whole
/// batch, so closing a Space full of tabs doesn't cost a round trip per
/// pane. Best-effort: with no daemon running there is nothing to kill,
/// and a close must never fail over this.
pub fn killPanes(alloc: Allocator, io: Io, ids: []const []const u8) void {
    sendIdCommand(alloc, io, "KILL", ids) catch |err| {
        log.warn("could not kill {d} pane(s) on coastty-host: {}", .{ ids.len, err });
    };
}

/// Hands the daemon the full set of panes the GUI still wants and lets it
/// kill whatever else it is holding - anything a previous run left behind
/// that nothing in the restored session reattached to. The set difference
/// is the daemon's to compute; see `host/wire.zig`'s `SWEEP`.
pub fn sweepPanes(alloc: Allocator, io: Io, keep: []const []const u8) void {
    sendIdCommand(alloc, io, "SWEEP", keep) catch |err| {
        log.warn("could not sweep orphaned panes on coastty-host: {}", .{err});
    };
}

fn sendIdCommand(alloc: Allocator, io: Io, verb: []const u8, ids: []const []const u8) !void {
    const conn = try connectForCommand(alloc, io);
    defer conn.close(io);
    const token = access.socketTokenArg(alloc, io);

    var wbuf: [wire.max_header_len]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeIdCommandLine(&w.interface, verb, ids, token.text());

    // Read the acknowledgement before closing: the daemon terminates the
    // panes before answering, so returning early would let the GUI move on
    // (and, on quit, exit) while its processes are still winding down.
    try readAck(alloc, io, conn);
}

/// One structural change the GUI reports to the daemon's model, flattened
/// from `wire`'s per-scope op enums into the single enum the C ABI hands
/// across. The wire tokens still come from `wire`, so the vocabulary is
/// defined in one place and a rename there can't drift past this.
pub const ModelOp = enum(c_int) {
    space_new,
    space_close,
    space_rename,
    space_move,
    space_hide,
    space_show,
    tab_new,
    tab_close,
    tab_rename,
    tab_move,
    pane_move,

    /// The request verb and op token this change travels as.
    fn tokens(self: ModelOp) struct { []const u8, []const u8 } {
        return switch (self) {
            .space_new => .{ "SPACE", @tagName(wire.SpaceOp.new) },
            .space_close => .{ "SPACE", @tagName(wire.SpaceOp.close) },
            .space_rename => .{ "SPACE", @tagName(wire.SpaceOp.rename) },
            .space_move => .{ "SPACE", @tagName(wire.SpaceOp.move) },
            .space_hide => .{ "SPACE", @tagName(wire.SpaceOp.hide) },
            .space_show => .{ "SPACE", @tagName(wire.SpaceOp.show) },
            .tab_new => .{ "TAB", @tagName(wire.TabOp.new) },
            .tab_close => .{ "TAB", @tagName(wire.TabOp.close) },
            .tab_rename => .{ "TAB", @tagName(wire.TabOp.rename) },
            .tab_move => .{ "TAB", @tagName(wire.TabOp.move) },
            .pane_move => .{ "PANE", @tagName(wire.PaneOp.move) },
        };
    }

    test "ghostty.h ModelOp" {
        try lib.checkGhosttyHEnum(ModelOp, "GHOSTTY_HOST_MODEL_OP_");
    }
};

/// How a reported change landed. The caller needs the two failures apart:
/// a refusal means the daemon is there and already disagrees, so the next
/// report should carry on from here, while an unreachable daemon means
/// nothing landed at all and the change is still owed.
pub const ModelOpResult = enum(c_int) {
    ok,
    refused,
    no_host,

    test "ghostty.h ModelOpResult" {
        try lib.checkGhosttyHEnum(ModelOpResult, "GHOSTTY_HOST_MODEL_RESULT_");
    }
};

/// Reports one structural change to the daemon's model - see `SPACE`,
/// `TAB` and `PANE` in `host/wire.zig` for what each op's fields mean.
/// The GUI reports; the daemon decides what the change means for the
/// model it owns.
pub fn sendModelOp(
    alloc: Allocator,
    io: Io,
    op: ModelOp,
    fields: []const []const u8,
) ModelOpResult {
    const conn = connectForCommand(alloc, io) catch return .no_host;
    defer conn.close(io);

    const verb, const token = op.tokens();
    var wbuf: [wire.max_header_len]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeModelOp(&w.interface, verb, token, fields) catch return .no_host;

    readAck(alloc, io, conn) catch |err| {
        log.warn("coastty-host refused {s} {s}: {}", .{ verb, token, err });
        return .refused;
    };
    return .ok;
}

/// The directory the daemon should spawn this pane in after a restart.
///
/// A pane the GUI gave no directory still has one - it inherits the app's - but
/// the daemon needs a concrete path to come back to. Home is what the GUI itself
/// falls back to. Skipping instead would leave the pane local and invisible to
/// the daemon, so it could not survive a quit, which is the one thing
/// persistence is for.
fn resolveCwd(configured: ?[:0]const u8) ?[]const u8 {
    if (configured) |cwd| {
        if (cwd.len > 0) return cwd;
    }
    const home = paths.homeDir();
    return if (home.len > 0) home else null;
}

/// What the app tells the user about the daemon it found at launch, once its windows are up.
pub const DaemonNotice = enum(c_int) {
    /// Nothing to tell: the daemon was kept as it is, or this app started it.
    none,
    /// The running daemon has an older daemon version; restarting it is the user's choice.
    update_available,
    /// The running daemon spoke another protocol, so it was restarted and every pane started again.
    restarted,
    /// The running daemon spoke another protocol and could not be stopped.
    restart_failed,

    test "ghostty.h DaemonNotice" {
        try lib.checkGhosttyHEnum(DaemonNotice, "GHOSTTY_HOST_DAEMON_NOTICE_");
    }
};

var daemon_notice: std.atomic.Value(DaemonNotice) = .init(.none);

/// Set once the daemon running at launch has been compared with this app, so a later `ensureRunning` never does it again.
var daemon_checked: std.atomic.Value(bool) = .init(false);

/// How long a daemon being restarted gets to write its model out and exit.
const stop_timeout_ms = 5000;

/// Returns what the user should be told about the daemon found at launch, once: a second call returns `none`.
pub fn takeDaemonNotice() DaemonNotice {
    return daemon_notice.swap(.none, .acq_rel);
}

/// The daemon's answer to `VERSION` on `conn`, or null when it gave none. Caller owns it.
fn askVersions(alloc: Allocator, io: Io, conn: net.Stream) ?[]u8 {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "VERSION", .{}) catch return null;

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    return wire.readHeader(alloc, &r.interface) catch null;
}

/// Ends the daemon at `pid` with SIGTERM, which has it write its model out first, and waits for it to exit. False when it could not be stopped.
fn stopDaemon(io: Io, pid: ?posix.pid_t) bool {
    const daemon_pid = pid orelse {
        log.warn("coastty-host's pid is unknown, so it cannot be stopped", .{});
        return false;
    };

    posix.kill(daemon_pid, .TERM) catch |err| {
        log.warn("could not stop coastty-host (pid {d}): {t}", .{ daemon_pid, err });
        return false;
    };

    if (access.waitForProcessGone(io, daemon_pid, stop_timeout_ms)) return true;
    log.warn("coastty-host (pid {d}) has not exited", .{daemon_pid});
    return false;
}

/// Compares the daemon already running with this app, restarting it only when the two cannot talk, and notes what the user should be told.
fn checkRunningDaemon(alloc: Allocator, io: Io) void {
    const path = paths.socketPath(alloc) catch return;
    defer alloc.free(path);

    // Nothing running: the daemon this app starts is its own
    const conn = access.connect(io, path) orelse return;
    const pid = access.peerPid(conn);
    const answer = askVersions(alloc, io, conn);
    conn.close(io);

    // Without an answer nothing is known about it, and a restart would end every pane for nothing
    const text = answer orelse return;
    defer alloc.free(text);
    const found = upgrade.parseAnswer(text) orelse {
        log.warn("coastty-host answered VERSION with '{s}'; keeping it", .{text});
        return;
    };

    switch (upgrade.decide(found, upgrade.ours)) {
        .keep => {},
        .ask => {
            log.info("coastty-host is daemon version {d} and this app's is {d}; keeping it until the user restarts it", .{ found.daemon, upgrade.ours.daemon });
            daemon_notice.store(.update_available, .release);
        },
        .restart => {
            log.info("coastty-host speaks protocol {d} and this app {d}; restarting it", .{ found.protocol, upgrade.ours.protocol });
            const notice: DaemonNotice = if (stopDaemon(io, pid)) .restarted else .restart_failed;
            daemon_notice.store(notice, .release);
        },
    }
}

/// Stops the running daemon for a restart the user chose. The app relaunches next, and the daemon its launch starts brings every Space and tab back with fresh shells. False when it could not be stopped.
pub fn stopForRestart(alloc: Allocator, io: Io) bool {
    const path = paths.socketPath(alloc) catch return false;
    defer alloc.free(path);

    // Already gone: the relaunch starts the new one all the same
    const conn = access.connect(io, path) orelse return true;
    const pid = access.peerPid(conn);
    conn.close(io);
    return stopDaemon(io, pid);
}

/// Opens the app at `app_path` again once this process has exited, for the relaunch that finishes a daemon restart.
/// A shell waits for the exit, since LaunchServices only brings a still-running app to the front.
pub fn relaunchAfterExit(alloc: Allocator, app_path: []const u8) void {
    relaunchAfterExitOrFail(alloc, app_path) catch |err| {
        log.warn("could not relaunch {s}: {}", .{ app_path, err });
    };
}

fn relaunchAfterExitOrFail(alloc: Allocator, app_path: []const u8) !void {
    const pid = try std.fmt.allocPrintSentinel(alloc, "{d}", .{std.c.getpid()}, 0);
    defer alloc.free(pid);
    const app = try alloc.dupeZ(u8, app_path);
    defer alloc.free(app);

    const script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"";
    const args = [_][:0]const u8{ "/bin/sh", "-c", script, "sh", pid, app };
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &args,
        .env = null,
        .cwd = null,
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_pre_exec_info = .{},
        .rt_post_fork = null,
        .rt_post_fork_info = .{},
        .data = null,
    };

    // Not waited for: it outlives this process, which is about to exit
    try cmd.start(alloc);
}

/// Starts the daemon if it isn't already running, and reports whether one
/// is reachable afterwards. The GUI calls this before asking for the
/// model: the daemon owns the Spaces and tabs a window is built from, so
/// waiting for a pane to need one would be backwards.
/// The first call compares a daemon already running with this app, and restarts it when the two cannot talk; see `host/upgrade.zig`.
pub fn ensureRunning(alloc: Allocator, io: Io) bool {
    if (!daemon_checked.swap(true, .acq_rel)) checkRunningDaemon(alloc, io);
    const conn = connectOrStartHost(alloc, io) catch return false;
    conn.close(io);
    startAppSubscription(alloc, io);
    return true;
}

var app_subscription_started: std.atomic.Value(bool) = .init(false);

/// Receives a `request` event's JSON - a change a layout command asks the
/// app to make - on the subscription's own thread. The bytes are only valid
/// for the call.
pub const RequestHandler = *const fn (json: [*]const u8, len: usize) callconv(.c) void;

var request_handler: std.atomic.Value(?RequestHandler) = .init(null);

/// Sets who carries out the requests the daemon hands the app. Set before
/// the subscription starts, or a request arriving first is dropped.
pub fn setRequestHandler(handler: ?RequestHandler) void {
    request_handler.store(handler, .release);
}

/// Guards `focus_conn`, `focus_body` and `windows_body`.
var focus_mutex: std.Io.Mutex = .init;

/// The app subscription's connection while it is up: where focus and windows are reported.
var focus_conn: ?net.Stream = null;

/// The focus last reported, as its `FOCUS` body, empty for nothing focused. Sent again to a daemon the subscription reconnects to.
var focus_body: std.ArrayList(u8) = .empty;

/// The windows last reported, as their `WINDOWS` body. Sent again to a daemon the subscription reconnects to.
var windows_body: std.ArrayList(u8) = .empty;

/// Whether any windows were reported yet, so the first report is sent even when no window is open.
var windows_reported = false;

/// Tells the daemon which windows are open and the Spaces each shows, as a
/// `WINDOWS` body (see `host/wire.zig`), over the app subscription. A
/// report matching the last one is not sent again.
pub fn reportWindows(alloc: Allocator, io: Io, body: []const u8) void {
    focus_mutex.lockUncancelable(io);
    defer focus_mutex.unlock(io);

    if (windows_reported and std.mem.eql(u8, body, windows_body.items)) return;
    windows_body.clearRetainingCapacity();
    windows_body.appendSlice(alloc, body) catch |err| {
        log.warn("could not report windows: {}", .{err});
        windows_reported = false;
        return;
    };
    windows_reported = true;

    // With no subscription up, the next one sends it.
    const conn = focus_conn orelse return;
    sendWindowsLocked(io, conn);
}

/// Writes the held windows to `conn`. Caller must hold `focus_mutex`.
fn sendWindowsLocked(io: Io, conn: net.Stream) void {
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeFrame(&w.interface, "WINDOWS", windows_body.items) catch |err| {
        log.warn("windows: could not reach coastty-host: {}", .{err});
    };
}

/// Tells the daemon which Space, tab and pane the user is looking at - any
/// of them empty for nothing - over the app subscription (see `FOCUS` in
/// `host/wire.zig`). A report matching the last one is not sent again.
pub fn reportFocus(alloc: Allocator, io: Io, space: []const u8, tab: []const u8, pane: []const u8) void {
    var body: std.ArrayList(u8) = .empty;
    // A window with no tab or pane to show focuses nothing a command could target.
    if (space.len > 0 and tab.len > 0 and pane.len > 0) {
        buildFocusBody(alloc, &body, space, tab, pane) catch |err| {
            log.warn("could not report focus: {}", .{err});
            body.deinit(alloc);
            return;
        };
    }

    focus_mutex.lockUncancelable(io);
    defer focus_mutex.unlock(io);

    if (std.mem.eql(u8, body.items, focus_body.items)) {
        body.deinit(alloc);
        return;
    }
    focus_body.deinit(alloc);
    focus_body = body;

    // With no subscription up, the next one sends it.
    const conn = focus_conn orelse return;
    sendFocusLocked(io, conn);
}

/// Appends `space`, `tab` and `pane` to `body`, NUL-separated.
fn buildFocusBody(alloc: Allocator, body: *std.ArrayList(u8), space: []const u8, tab: []const u8, pane: []const u8) Allocator.Error!void {
    try body.appendSlice(alloc, space);
    try body.append(alloc, 0);
    try body.appendSlice(alloc, tab);
    try body.append(alloc, 0);
    try body.appendSlice(alloc, pane);
}

/// Writes the held focus to `conn`. Caller must hold `focus_mutex`.
fn sendFocusLocked(io: Io, conn: net.Stream) void {
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeFrame(&w.interface, "FOCUS", focus_body.items) catch |err| {
        log.warn("focus: could not reach coastty-host: {}", .{err});
    };
}

/// Subscribes the app to the daemon's events, once per process, on a
/// thread of its own.
///
/// The only events acted on are requests, handed to the request handler;
/// the app still builds itself from the model at launch. The subscription
/// also holds the app to the daemon's exact protocol version, saying so in
/// the log when a stale build is talking to the daemon, and notices the
/// daemon restarting.
fn startAppSubscription(alloc: Allocator, io: Io) void {
    if (app_subscription_started.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, appSubscriptionLoop, .{ alloc, io }) catch |err| {
        log.warn("no event subscription for the app: {}", .{err});
        app_subscription_started.store(false, .release);
        return;
    };
    thread.detach();
}

fn appSubscriptionLoop(alloc: Allocator, io: Io) void {
    var run_id: [32]u8 = @splat(0);
    while (true) {
        holdAppSubscription(alloc, io, &run_id) catch |err| switch (err) {
            // A mismatch only resolves with a restart; retrying would only
            // fill the log.
            error.Refused => return,
            else => {},
        };
        std.Io.sleep(io, .fromSeconds(1), .awake) catch {};
    }
}

/// One subscription, held until the daemon goes away. `run_id` carries the
/// last daemon run seen across reconnects.
fn holdAppSubscription(alloc: Allocator, io: Io, run_id: *[32]u8) !void {
    const path = try paths.socketPath(alloc);
    defer alloc.free(path);
    const conn = access.connect(io, path) orelse return error.NoHost;
    defer conn.close(io);

    const token = access.tokenArg(io, path);
    var wbuf: [128]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "SUBSCRIBE {d} app{s}", .{ wire.protocol_version, token.text() });

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const answer = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoHost;
    defer alloc.free(answer);
    if (!std.mem.startsWith(u8, answer, "OK ")) {
        log.err("coastty-host refused this app's event subscription: {s}", .{answer});
        return error.Refused;
    }

    var it = std.mem.tokenizeScalar(u8, answer, ' ');
    _ = it.next();
    _ = it.next();
    const run = it.next() orelse return error.ProtocolError;
    if (run.len == run_id.len and !std.mem.eql(u8, run, run_id)) {
        if (run_id[0] != 0) log.info("coastty-host restarted (run {s}); the model this app built from is stale", .{run});
        @memcpy(run_id, run);
    }

    // A daemon that restarted, or just started, has no focus or windows until it is told.
    focus_mutex.lockUncancelable(io);
    focus_conn = conn;
    if (focus_body.items.len > 0) sendFocusLocked(io, conn);
    if (windows_reported) sendWindowsLocked(io, conn);
    focus_mutex.unlock(io);
    defer {
        focus_mutex.lockUncancelable(io);
        focus_conn = null;
        focus_mutex.unlock(io);
    }

    while (true) {
        const header = (try wire.readHeader(alloc, &r.interface)) orelse return;
        defer alloc.free(header);
        var hit = std.mem.tokenizeScalar(u8, header, ' ');
        _ = hit.next();
        const len = parseUsize(hit.next()) orelse return error.ProtocolError;
        const body = try wire.readBody(alloc, &r.interface, len);
        defer alloc.free(body);
        if (isRequestEvent(alloc, body)) {
            if (request_handler.load(.acquire)) |handler| handler(body.ptr, body.len);
        }
    }
}

/// Whether an event's JSON is a `request`.
fn isRequestEvent(alloc: Allocator, json: []const u8) bool {
    const Event = struct { event: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Event, alloc, json, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.event, "request");
}

/// Writes the daemon's whole model document into `buf` as JSON and
/// returns its length, or the length it would have needed when that does
/// not fit, so a caller can retry with a bigger buffer. Zero means no
/// daemon answered.
pub fn fetchModel(alloc: Allocator, io: Io, buf: []u8) usize {
    const conn = connectForCommand(alloc, io) catch return 0;
    defer conn.close(io);

    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "MODEL", .{}) catch return 0;

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const status = (wire.readHeader(alloc, &r.interface) catch return 0) orelse return 0;
    defer alloc.free(status);
    if (!std.mem.startsWith(u8, status, "OK ")) return 0;

    const len = std.fmt.parseInt(usize, status["OK ".len..], 10) catch return 0;
    const body = wire.readBody(alloc, &r.interface, len) catch return 0;
    defer alloc.free(body);

    if (body.len <= buf.len) @memcpy(buf[0..body.len], body);
    return body.len;
}

/// Opens a connection for one control request. Deliberately not
/// `connectOrStartHost`: a daemon that isn't running owns no panes and no
/// model, and starting one just to tell it about a change the GUI is
/// about to stop believing in would be backwards.
fn connectForCommand(alloc: Allocator, io: Io) !net.Stream {
    const path = try paths.socketPath(alloc);
    defer alloc.free(path);
    return access.connect(io, path) orelse error.NoHost;
}

/// Reads the daemon's one-line acknowledgement of a control request.
fn readAck(alloc: Allocator, io: Io, conn: net.Stream) !void {
    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const resp = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(resp);
    if (!std.mem.startsWith(u8, resp, "OK")) return error.CommandFailed;
}

pub fn init(alloc: Allocator, attached: Attached, cwd: ?[]const u8) HostBackend {
    return .{
        .alloc = alloc,
        .conn = attached.conn,
        .pane_id = attached.pane_id,
        .prior_session_ended = attached.prior_session_ended,
        .initial_snapshot = attached.snapshot,
        .cwd = cwd,
        .pgid = attached.pgid,
        .child_pid = attached.child_pid,
        .read_buf = attached.read_buf,
        .read_seek = attached.read_seek,
        .read_end = attached.read_end,
    };
}

/// Releases whatever `init` produced. Called either as the very last
/// step of a normal `Termio` teardown (after `threadExit` has already
/// stopped the read thread and shut down the read side) or, on an
/// `errdefer`, right after construction if nothing further ever ran -
/// either way this is the one place that actually closes `conn`.
pub fn deinit(self: *HostBackend) void {
    if (self.initial_snapshot) |snap| self.alloc.free(snap);
    self.alloc.free(self.read_buf);
    self.alloc.free(self.pane_id);
    self.conn.close(global.io());
}

/// The daemon's id for this pane, for a caller assembling a `KILL` or
/// `SWEEP` request. Borrowed - valid only while this backend is.
pub fn paneId(self: *HostBackend) []const u8 {
    return self.pane_id;
}

pub fn initTerminal(self: *HostBackend, term: *terminal.Terminal) void {
    if (self.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };
}

/// Printed into a restored tab whose pane had already exited, dim and on
/// its own line so it reads as coastty's own note rather than output from
/// the new shell that took the dead pane's place.
const session_ended_notice = "\r\n\x1b[2m[coastty] The session in this tab ended while coastty was closed. This is a new shell.\x1b[0m\r\n";

pub fn threadEnter(
    self: *HostBackend,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Seed the terminal with whatever the pane already showed before we
    // attached. This is a plain-text approximation (see `host/wire.zig`),
    // not a full-fidelity replay of colors/cursor position, but it's the
    // pane's real current content rather than a blank screen.
    if (self.initial_snapshot) |snap| {
        io.processOutput(snap);
        self.alloc.free(snap);
        self.initial_snapshot = null;
    }

    // Ahead of anything the fresh shell prints, so the first thing in the
    // tab says what happened to the session it was supposed to resume.
    if (self.prior_session_ended) {
        io.processOutput(session_ended_notice);
        self.prior_session_ended = false;
    }

    // On macOS a shutdown of the socket does not wake a thread blocked reading it, so the reader also watches this pipe and `threadExit` writes to it.
    const quit_pipe = try internal_os.pipe();
    errdefer _ = posix.system.close(quit_pipe[0]);
    errdefer _ = posix.system.close(quit_pipe[1]);

    const read_thread = try std.Thread.spawn(.{}, readThreadMain, .{ self, io, quit_pipe[0] });
    td.backend = .{ .host = .{ .read_thread = read_thread, .quit_fd = quit_pipe[1] } };
}

pub fn threadExit(self: *HostBackend, td: *termio.Termio.ThreadData) void {
    self.closed.store(true, .release);
    // EPIPE only means the reader is already gone, which is the point.
    _ = posix.system.write(td.backend.host.quit_fd, "x", 1);
    self.conn.shutdown(global.io(), .recv) catch {};
    td.backend.host.read_thread.join();
    _ = posix.system.close(td.backend.host.quit_fd);
}

pub fn focusGained(self: *HostBackend, td: *termio.Termio.ThreadData, focused: bool) !void {
    _ = self;
    _ = td;
    _ = focused;
    // No termios-based password-mode polling for a host-backed pane yet
    // (that's `Exec`'s termios timer, tied to a local pty fd we don't
    // have); a known, minor gap rather than an oversight.
}

/// Tells the daemon whether the user is looking at this pane, which it
/// counts as seeing the pane for every client.
pub fn setViewed(self: *HostBackend, viewed: bool) void {
    if (self.closed.load(.acquire)) return;
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    var wbuf: [32]u8 = undefined;
    var w = self.conn.writer(global.io(), &wbuf);
    wire.writeHeaderLine(&w.interface, "VIEW {d}", .{@intFromBool(viewed)}) catch |err| {
        log.warn("view: could not reach coastty-host: {}", .{err});
    };
}

pub fn resize(self: *HostBackend, grid_size: renderer.GridSize, screen_size: renderer.ScreenSize) !void {
    _ = screen_size;
    if (self.closed.load(.acquire)) return;

    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    var wbuf: [128]u8 = undefined;
    var w = self.conn.writer(global.io(), &wbuf);
    wire.writeHeaderLine(&w.interface, "RESIZE {d} {d}", .{ grid_size.columns, grid_size.rows }) catch |err| {
        log.warn("resize: could not reach coastty-host: {}", .{err});
    };
}

pub fn queueWrite(
    self: *HostBackend,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    if (self.closed.load(.acquire)) return;

    // INPUT frames are length-prefixed, so a `\r` -> `\r\n` expansion (the
    // same one a local pty in cooked mode would do) has to happen before
    // the header goes out, not as we go.
    const body: []const u8 = if (!linefeed) data else try expandCarriageReturns(alloc, data);
    defer if (linefeed) alloc.free(body);

    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    var wbuf: [4096]u8 = undefined;
    var w = self.conn.writer(global.io(), &wbuf);
    wire.writeFrame(&w.interface, "INPUT", body) catch |err| {
        log.warn("queueWrite: could not reach coastty-host: {}", .{err});
    };
}

/// Replaces every `\r` with `\r\n`, the same expansion a local pty in
/// cooked mode applies to a carriage return - needed here because an
/// `INPUT` frame is length-prefixed and so has to know its final size up
/// front, rather than growing it as bytes are written.
fn expandCarriageReturns(alloc: Allocator, data: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, data.len * 2);
    var n: usize = 0;
    for (data) |ch| {
        if (ch == '\r') {
            buf[n] = '\r';
            buf[n + 1] = '\n';
            n += 2;
        } else {
            buf[n] = ch;
            n += 1;
        }
    }
    // `buf` was allocated at worst-case size (every byte a `\r`); shrink
    // it to what was actually written; a safety-checked allocator (as
    // `std.testing.allocator` is) requires `free` to see the exact size
    // it handed out, and freeing a shorter slice of an oversized
    // allocation is exactly the mismatch that trips it up.
    return try alloc.realloc(buf, n);
}

pub fn childExitedAbnormally(
    self: *HostBackend,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

pub fn getProcessInfo(self: *HostBackend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return switch (info) {
        .foreground_pid => blk: {
            self.info_mutex.lockUncancelable(global.io());
            defer self.info_mutex.unlock(global.io());
            break :blk if (self.pgid) |p| @as(u64, p) else null;
        },
        .tty_name => null,
    };
}

pub fn paneChildPid(self: *HostBackend) ?u32 {
    self.info_mutex.lockUncancelable(global.io());
    defer self.info_mutex.unlock(global.io());
    return self.child_pid;
}

pub const ThreadData = struct {
    read_thread: std.Thread,
    /// The write end of the pipe that tells the read thread to stop.
    quit_fd: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// Runs for the lifetime of the attached connection: relays `DATA` into
/// the terminal parser and updates the cached process info from `META`,
/// exactly the way `Exec`'s own read thread relays pty bytes. Ends when
/// `threadExit` shuts the read side down, or the host drops the
/// connection (the pane exited, or the host itself went away) - either
/// way the pane just stops updating rather than tearing anything down.
fn readThreadMain(self: *HostBackend, io: *termio.Termio, quit: posix.fd_t) void {
    defer _ = posix.system.close(quit);
    if (builtin.os.tag.isDarwin()) internal_os.macos.pthread_setname_np(&"io-host-reader".*);

    var reader = self.conn.reader(global.io(), self.read_buf);
    reader.interface.seek = self.read_seek;
    reader.interface.end = self.read_end;

    var fds = [_]posix.pollfd{
        .{ .fd = self.conn.socket.handle, .events = posix.POLL.IN, .revents = undefined },
        .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
    };

    while (true) {
        // Wait for the socket or the quit pipe before a blocking read, unless the buffer already holds the next frame's bytes.
        if (reader.interface.seek == reader.interface.end) {
            _ = posix.poll(&fds, -1) catch break;
            if (fds[1].revents != 0) break;
        }
        const line = (wire.readHeader(io.alloc, &reader.interface) catch break) orelse break;
        defer io.alloc.free(line);

        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = it.next() orelse continue;

        if (std.mem.eql(u8, tag, "META")) {
            const pgid = parseU32(it.next());
            const child_pid = parseU32(it.next());
            self.info_mutex.lockUncancelable(global.io());
            self.pgid = pgid;
            self.child_pid = child_pid;
            self.info_mutex.unlock(global.io());
            continue;
        }

        const len = parseUsize(it.next()) orelse continue;
        const body = wire.readBody(io.alloc, &reader.interface, len) catch break;
        defer io.alloc.free(body);

        // A SNAPSHOT arriving mid-stream is the daemon replaying the pane
        // for the size this end has since measured; it resets the screen
        // before it draws, so it replaces rather than repeats.
        if (std.mem.eql(u8, tag, "DATA") or std.mem.eql(u8, tag, "SNAPSHOT")) {
            io.processOutput(body);
        } else if (std.mem.eql(u8, tag, "STATUS")) {
            const detection = parseStatus(io.alloc, body) orelse continue;
            _ = io.surface_mailbox.push(.{ .agent_state_change = detection }, .{ .forever = {} });
        }
    }

    self.closed.store(true, .release);
}

/// The daemon's view of this pane's agent, as the apprt receives a
/// detection - with the daemon's attention state and recency attached, so
/// the app takes seen and ordering from the daemon too. Null for a body
/// this build cannot read.
fn parseStatus(alloc: Allocator, body: []const u8) ?agent_detection.AgentDetection {
    const Status = struct {
        agent: ?[]const u8 = null,
        state: []const u8,
        attention: []const u8,
        recency: u64,
    };
    const parsed = std.json.parseFromSlice(Status, alloc, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const status = parsed.value;
    const state = agent_detection.AgentState.fromName(status.state) orelse return null;
    const attention = agent_detection.AgentStatus.fromName(status.attention) orelse return null;
    return .{
        .state = state,
        .agent = if (status.agent) |label| agent_detection.Agent.fromLabel(label) else null,
        .host = .{ .attention = attention, .recency = status.recency },
    };
}

/// The id the daemon knows this pane by. A GUI-supplied id is namespaced
/// so it can never be mistaken for - or collide with - a cwd-derived one
/// from `stableId`.
fn resolveId(alloc: Allocator, opts: ConnectOptions) ![]u8 {
    const id = opts.id orelse "";
    if (id.len == 0) return stableId(alloc, opts.cwd);

    return std.fmt.allocPrint(alloc, "surface:{s}", .{id});
}

/// A stable per-cwd counter, alive for as long as this process is: the
/// first pane opened at a given directory this run gets a plain,
/// deterministic id (so relaunching coastty and opening that same
/// directory again reattaches it). Only the fallback for callers with no
/// identity of their own to give; see `ConnectOptions.id`.
var cwd_counts: std.StringHashMapUnmanaged(u32) = .empty;
var cwd_counts_mutex: std.Io.Mutex = .init;

/// Folded into every id after a cwd's first (see `stableId`), lazily
/// generated once per process and guarded by the same mutex as
/// `cwd_counts`.
var run_token: ?u64 = null;

/// `Host.handleCreate` reuses whatever pane already answers to an id -
/// it has no way to tell "the caller meant to reattach this" apart from
/// "the count just happens to match". Since this counter always
/// restarts at 0 on every process run, a directory's *first* tab is the
/// only one whose id is meant to (and safely can) repeat across runs;
/// its second, third, ... tab would otherwise repeat too, and silently
/// resume whatever an earlier, unrelated run happened to still have
/// running under that same count. So only count 0 keeps the bare,
/// cross-run-stable id; everything after it gets `run_token` folded in
/// to make it unique to this process, however many tabs this cwd ends
/// up with.
fn stableId(alloc: Allocator, cwd: []const u8) ![]u8 {
    cwd_counts_mutex.lockUncancelable(global.io());
    defer cwd_counts_mutex.unlock(global.io());

    const count: u32 = if (cwd_counts.getPtr(cwd)) |p| blk: {
        const c = p.*;
        p.* += 1;
        break :blk c;
    } else blk: {
        const key = try std.heap.page_allocator.dupe(u8, cwd);
        try cwd_counts.put(std.heap.page_allocator, key, 1);
        break :blk 0;
    };

    if (count == 0) return std.fmt.allocPrint(alloc, "{s}#{d}", .{ cwd, count });

    const token = run_token orelse token: {
        const rng_impl: std.Random.IoSource = .{ .io = global.io() };
        const t = rng_impl.interface().int(u64);
        run_token = t;
        break :token t;
    };
    return std.fmt.allocPrint(alloc, "{s}#{d}~{x}", .{ cwd, count, token });
}

fn sendCreate(
    alloc: Allocator,
    io: Io,
    conn: net.Stream,
    id: []const u8,
    opts: ConnectOptions,
    token_arg: []const u8,
) !?wire.CreateOutcome {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, id);
    try body.append(alloc, 0);
    try body.appendSlice(alloc, opts.cwd);
    for (opts.argv) |a| {
        try body.append(alloc, 0);
        try body.appendSlice(alloc, a);
    }

    // A separate, own-length section rather than more NUL-joined fields
    // in `body` - env values are unconstrained (an env var's value can
    // itself contain NULs on some systems), so folding it into the same
    // NUL-delimited body would make argv/env ambiguous to split back
    // apart.
    var env_body: std.ArrayList(u8) = .empty;
    defer env_body.deinit(alloc);
    if (opts.env) |env| {
        var it = env.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try env_body.append(alloc, 0);
            first = false;
            try env_body.appendSlice(alloc, entry.key_ptr.*);
            try env_body.append(alloc, '=');
            try env_body.appendSlice(alloc, entry.value_ptr.*);
        }
    }

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try w.interface.print("CREATE {d} {d} {d} {d}{s}\n", .{ opts.cols, opts.rows, body.items.len, env_body.items.len, token_arg });
    try w.interface.writeAll(body.items);
    try w.interface.writeAll(env_body.items);
    try w.interface.flush();

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const resp = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(resp);
    if (!std.mem.startsWith(u8, resp, "OK ")) return error.CreateFailed;
    return wire.parseCreateOutcome(resp["OK ".len..]);
}

fn sendAttach(alloc: Allocator, io: Io, conn: net.Stream, id: []const u8, token_arg: []const u8) !Attached {
    {
        var wbuf: [256]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        try wire.writeHeaderLine(&w.interface, "ATTACH {s}{s}", .{ id, token_arg });
    }

    const read_buf = try alloc.alloc(u8, read_buf_len);
    errdefer alloc.free(read_buf);
    var r = conn.reader(io, read_buf);

    const status = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(status);
    if (!std.mem.eql(u8, status, "OK")) return error.AttachFailed;

    const meta_line = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(meta_line);
    var mit = std.mem.tokenizeScalar(u8, meta_line, ' ');
    if (!std.mem.eql(u8, mit.next() orelse "", "META")) return error.ProtocolError;
    const pgid = parseU32(mit.next());
    const child_pid = parseU32(mit.next());

    const snap_header = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(snap_header);
    var sit = std.mem.tokenizeScalar(u8, snap_header, ' ');
    if (!std.mem.eql(u8, sit.next() orelse "", "SNAPSHOT")) return error.ProtocolError;
    const len = parseUsize(sit.next()) orelse return error.ProtocolError;
    const snapshot = try wire.readBody(alloc, &r.interface, len);

    return .{
        .conn = conn,
        .pane_id = id,
        .snapshot = snapshot,
        .pgid = pgid,
        .child_pid = child_pid,
        .read_buf = read_buf,
        .read_seek = r.interface.seek,
        .read_end = r.interface.end,
    };
}

fn connectOrStartHost(alloc: Allocator, io: Io) !net.Stream {
    const path = try paths.socketPath(alloc);
    defer alloc.free(path);

    if (access.connect(io, path)) |conn| return conn;

    // coastty-host isn't running on the well-known socket. Only macOS
    // gets an attempt at starting it (see `spawnHost`); everywhere else
    // this just falls back to a locally spawned pane, same as today.
    if (comptime !builtin.target.os.tag.isDarwin()) return error.NoHost;
    spawnHost(alloc) catch |err| {
        log.info("could not start coastty-host: {}", .{err});
        return error.NoHost;
    };

    // `start` forks the daemon and returns immediately; give the fork a
    // moment to bind the socket before giving up. Measured cold-start
    // cost is a handful of ms, so start with a short sleep and back off
    // rather than a fixed 25ms every time - that could burn up to a full
    // second of this (main) thread per new surface for no real reason.
    var delay_ms: i64 = 2;
    var elapsed_ms: i64 = 0;
    while (elapsed_ms < 250) {
        std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
        if (access.connect(io, path)) |conn| return conn;
        elapsed_ms += delay_ms;
        delay_ms = @min(delay_ms * 2, 25);
    }
    return error.NoHost;
}

/// Spawns `coastty-host start`, preferring the copy bundled alongside
/// this GUI binary (see `build.zig`'s post-build copy into
/// `Contents/MacOS/`) and falling back to a bare, `PATH`-resolved name
/// for a dev build that hasn't been through that step.
fn spawnHost(alloc: Allocator) !void {
    const host_path = try hostBinaryPath(alloc);
    defer alloc.free(host_path);

    const args = [_][:0]const u8{ host_path, "start" };
    var cmd: Command = .{
        .path = host_path,
        .args = &args,
        .env = null,
        .cwd = null,
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_pre_exec_info = .{},
        .rt_post_fork = null,
        .rt_post_fork_info = .{},
        .data = null,
    };
    try cmd.start(alloc);
    // `start` forks its own daemon and the outer process we just spawned
    // exits right away; reap it now rather than leaving a zombie.
    _ = cmd.wait(true) catch {};
}

fn hostBinaryPath(alloc: Allocator) ![:0]const u8 {
    var buf: [1024]u8 = undefined;
    if (selfExeDir(&buf)) |dir| {
        return std.fmt.allocPrintSentinel(alloc, "{s}/coastty-host", .{dir}, 0);
    }
    return alloc.dupeZ(u8, "coastty-host");
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// The directory of the currently running executable, macOS only (this
/// is only ever consulted from `spawnHost`, itself gated the same way).
/// Points into `buf`.
fn selfExeDir(buf: []u8) ?[]const u8 {
    if (comptime !builtin.target.os.tag.isDarwin()) return null;
    var size: u32 = @intCast(buf.len);
    if (_NSGetExecutablePath(buf.ptr, &size) != 0) return null;
    const path = buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse size)];
    return std.fs.path.dirname(path);
}

fn parseU32(tok: ?[]const u8) ?u32 {
    const v = std.fmt.parseInt(u32, tok orelse return null, 10) catch return null;
    return if (v == 0) null else v;
}

fn parseUsize(tok: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, tok orelse return null, 10) catch null;
}

// No end-to-end test against a live `Host` here on purpose: importing
// `host/Host.zig` (even just for a test harness) makes its own `test`
// blocks reachable from this file's module graph too, and so from
// whatever root pulls this file in - which, unlike the small dedicated
// `coastty-host-test` binary those tests were written for, runs
// thousands of other tests in the same process. Host.zig's CREATE/ATTACH
// tests reproducibly corrupt each other's connections once enough of
// them (from either file) share that process - not a timing flake, the
// same failures reproduce identically across repeated runs and vanish
// again the moment the two files' tests aren't both loaded into it. The
// wire-level logic below is instead covered by unit tests against pure
// helpers, plus Host.zig's own suite (still exercised via
// `coastty-host-test`) covering the server side of the exact same
// protocol these functions speak.
const testing = std.testing;

test "expandCarriageReturns doubles a lone CR into CRLF and leaves everything else alone" {
    const alloc = testing.allocator;

    const plain = try expandCarriageReturns(alloc, "hi\r");
    defer alloc.free(plain);
    try testing.expectEqualStrings("hi\r\n", plain);

    const none = try expandCarriageReturns(alloc, "hello");
    defer alloc.free(none);
    try testing.expectEqualStrings("hello", none);

    const many = try expandCarriageReturns(alloc, "\r\r\r");
    defer alloc.free(many);
    try testing.expectEqualStrings("\r\n\r\n\r\n", many);

    const empty = try expandCarriageReturns(alloc, "");
    defer alloc.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "resolveId namespaces the GUI's own pane id and ignores cwd" {
    const alloc = testing.allocator;

    const id = try resolveId(alloc, .{
        .cwd = "/tmp/host-backend-resolveid-test",
        .id = "6E8F1B0C-0E5A-4A1E-9D8E-2B5C7A0F1234",
        .argv = &.{},
        .cols = 80,
        .rows = 24,
    });
    defer alloc.free(id);

    try testing.expectEqualStrings("surface:6E8F1B0C-0E5A-4A1E-9D8E-2B5C7A0F1234", id);
}

// The CLI debug client and any apprt with no pane identity of its own
// must keep the pre-existing cwd-derived behavior.
test "resolveId falls back to stableId without a usable GUI pane id" {
    const alloc = testing.allocator;
    const cwd = "/tmp/host-backend-resolveid-fallback-test";

    const from_null = try resolveId(alloc, .{ .cwd = cwd, .argv = &.{}, .cols = 80, .rows = 24 });
    defer alloc.free(from_null);
    const from_empty = try resolveId(alloc, .{ .cwd = cwd, .id = "", .argv = &.{}, .cols = 80, .rows = 24 });
    defer alloc.free(from_empty);

    try testing.expectEqualStrings(cwd ++ "#0", from_null);
    try testing.expect(std.mem.startsWith(u8, from_empty, cwd ++ "#1"));
}

test "stableId gives repeat callers for the same cwd their own id, in order" {
    const alloc = testing.allocator;
    const cwd = "/tmp/host-backend-stableid-test";

    const id0 = try stableId(alloc, cwd);
    defer alloc.free(id0);
    const id1 = try stableId(alloc, cwd);
    defer alloc.free(id1);
    const id2 = try stableId(alloc, cwd);
    defer alloc.free(id2);

    try testing.expectEqualStrings("/tmp/host-backend-stableid-test#0", id0);
    try testing.expect(std.mem.startsWith(u8, id1, "/tmp/host-backend-stableid-test#1"));
    try testing.expect(std.mem.startsWith(u8, id2, "/tmp/host-backend-stableid-test#2"));
    try testing.expect(!std.mem.eql(u8, id1, id2));
}

// Regression test for the tab-resumes-another-tab's-session bug; see
// `stableId`'s doc comment for why count 0 is special-cased.
//
// `run_token` is a module-level var, so its state going into this test
// depends on whether an earlier test in this same compilation unit has
// already forced the "generate a token" branch. Reset it here so this
// test's own assertion doesn't depend on run order.
test "stableId never repeats the bare id an earlier run's non-first tab would have used" {
    const alloc = testing.allocator;
    const cwd = "/tmp/host-backend-stableid-no-cross-run-collision-test";
    run_token = null;

    const id0 = try stableId(alloc, cwd); // count 0, this tab
    defer alloc.free(id0);
    const id1 = try stableId(alloc, cwd); // count 1, this tab
    defer alloc.free(id1);

    // The bare id a directory's second tab would get without the token
    // folded in - what an earlier run's second tab in this same
    // directory would still be live under.
    try testing.expect(!std.mem.eql(u8, id1, cwd ++ "#1"));
}

// Deliberately does not touch Host.zig (see the comment above `testing`
// below) - a raw listener that reads the CREATE request itself, so this
// isolates sendCreate's own encoding from the daemon's decoding.
const SendCreateFidelityCtx = struct {
    var received_header: ?[]u8 = null;
    var received_body: ?[]u8 = null;
    var received_env: ?[]u8 = null;

    fn acceptAndRead(listener: *net.Server) void {
        const conn = listener.accept(testing.io) catch |err| {
            log.warn("test: accept failed: {}", .{err});
            return;
        };
        defer conn.close(testing.io);

        var rbuf: [wire.max_header_len]u8 = undefined;
        var reader = conn.reader(testing.io, &rbuf);
        const header = (wire.readHeader(testing.allocator, &reader.interface) catch return) orelse return;
        received_header = testing.allocator.dupe(u8, header) catch null;
        defer testing.allocator.free(header);

        var it = std.mem.tokenizeScalar(u8, header, ' ');
        _ = it.next(); // "CREATE"
        _ = it.next(); // cols
        _ = it.next(); // rows
        const len = std.fmt.parseInt(usize, it.next() orelse return, 10) catch return;
        const env_len = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch return;
        received_body = wire.readBody(testing.allocator, &reader.interface, len) catch return;
        received_env = wire.readBody(testing.allocator, &reader.interface, env_len) catch return;

        var wbuf: [64]u8 = undefined;
        var w = conn.writer(testing.io, &wbuf);
        wire.writeHeaderLine(&w.interface, "OK test-id", .{}) catch {};
    }
};

test "sendCreate transmits a multi-word last argv element byte-for-byte" {
    const alloc = testing.allocator;
    const path = "/tmp/host-backend-sendcreate-fidelity-test.sock";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var listener = try addr.listen(testing.io, .{});
    defer listener.deinit(testing.io);

    SendCreateFidelityCtx.received_body = null;
    SendCreateFidelityCtx.received_env = null;
    const thread = try std.Thread.spawn(.{}, SendCreateFidelityCtx.acceptAndRead, .{&listener});
    const client = try addr.connect(testing.io);
    defer client.close(testing.io);

    _ = try sendCreate(alloc, testing.io, client, "test-id-1", .{
        .cwd = "/tmp",
        .argv = &.{
            "/usr/bin/login",
            "-q",
            "-flp",
            "espen",
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-c",
            "exec -l /bin/zsh",
        },
        .cols = 80,
        .rows = 24,
    }, "");
    thread.join();
    if (SendCreateFidelityCtx.received_header) |h| testing.allocator.free(h);

    const body = SendCreateFidelityCtx.received_body orelse return error.NoBodyReceived;
    defer testing.allocator.free(body);
    if (SendCreateFidelityCtx.received_env) |env| testing.allocator.free(env);

    var fields = wire.FieldIterator.init(body);
    try testing.expectEqualStrings("test-id-1", fields.next() orelse return error.MissingId);
    try testing.expectEqualStrings("/tmp", fields.next() orelse return error.MissingCwd);
    var last: []const u8 = "";
    while (fields.next()) |f| last = f;
    try testing.expectEqualStrings("exec -l /bin/zsh", last);
}

test "sendCreate transmits the pane's real env, including shell-integration vars" {
    const alloc = testing.allocator;
    const path = "/tmp/host-backend-sendcreate-env-test.sock";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var listener = try addr.listen(testing.io, .{});
    defer listener.deinit(testing.io);

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor:blink,path,title");

    SendCreateFidelityCtx.received_body = null;
    SendCreateFidelityCtx.received_env = null;
    const thread = try std.Thread.spawn(.{}, SendCreateFidelityCtx.acceptAndRead, .{&listener});
    const client = try addr.connect(testing.io);
    defer client.close(testing.io);

    _ = try sendCreate(alloc, testing.io, client, "test-id-2", .{
        .cwd = "/tmp",
        .argv = &.{"/bin/zsh"},
        .env = &env,
        .cols = 80,
        .rows = 24,
    }, "");
    thread.join();
    if (SendCreateFidelityCtx.received_header) |h| testing.allocator.free(h);

    if (SendCreateFidelityCtx.received_body) |b| testing.allocator.free(b);
    const received = SendCreateFidelityCtx.received_env orelse return error.NoEnvReceived;
    defer testing.allocator.free(received);

    var parsed = try wire.parseEnvBody(alloc, received);
    defer parsed.deinit();
    try testing.expectEqualStrings("xterm-ghostty", parsed.get("TERM").?);
    try testing.expectEqualStrings("cursor:blink,path,title", parsed.get("GHOSTTY_SHELL_FEATURES").?);
}

test "sendCreate sends the token on the request line only, never in the pane's body or env" {
    const alloc = testing.allocator;
    const path = "/tmp/host-backend-sendcreate-token-test.sock";
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var listener = try addr.listen(testing.io, .{});
    defer listener.deinit(testing.io);

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");

    const token = access.newToken(testing.io);
    const token_arg: access.TokenArg = .init(&token);

    SendCreateFidelityCtx.received_header = null;
    SendCreateFidelityCtx.received_body = null;
    SendCreateFidelityCtx.received_env = null;
    const thread = try std.Thread.spawn(.{}, SendCreateFidelityCtx.acceptAndRead, .{&listener});
    const client = try addr.connect(testing.io);
    defer client.close(testing.io);

    _ = try sendCreate(alloc, testing.io, client, "test-id-3", .{
        .cwd = "/tmp",
        .argv = &.{"/bin/zsh"},
        .env = &env,
        .cols = 80,
        .rows = 24,
    }, token_arg.text());
    thread.join();

    const header = SendCreateFidelityCtx.received_header orelse return error.NoHeaderReceived;
    defer testing.allocator.free(header);
    const body = SendCreateFidelityCtx.received_body orelse return error.NoBodyReceived;
    defer testing.allocator.free(body);
    const received_env = SendCreateFidelityCtx.received_env orelse return error.NoEnvReceived;
    defer testing.allocator.free(received_env);

    try testing.expect(std.mem.endsWith(u8, header, token_arg.text()));
    try testing.expect(std.mem.indexOf(u8, body, &token) == null);
    try testing.expect(std.mem.indexOf(u8, received_env, &token) == null);
}

/// A minimal, never-started `Exec` for testing `connectForExec`'s own
/// guards, which return before ever touching `exec.subprocess.args` or
/// spawning anything - so what it resolves to run doesn't matter here.
fn testExec(alloc: Allocator, working_directory: ?[]const u8) !termio.Exec {
    return termio.Exec.init(alloc, .{
        .command = .{ .shell = "sh" },
        .env = .init(alloc),
        .resources_dir = null,
        .term = "xterm-256color",
        .working_directory = working_directory,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    });
}

test "connectForExec skips when coastty-process-persistence is off" {
    const alloc = testing.allocator;
    var exec = try testExec(alloc, "/tmp");
    defer exec.deinit();

    try testing.expectEqual(@as(?Attached, null), connectForExec(alloc, testing.io, false, &exec, null, 80, 24));
}

test "a pane with no explicit working directory falls back to home rather than going local" {
    // Going local would mean the daemon never hears about the pane, so it could
    // not come back after a quit - the one thing persistence exists for.
    try testing.expectEqualStrings("/tmp/somewhere", resolveCwd("/tmp/somewhere").?);
    try testing.expectEqualStrings(paths.homeDir(), resolveCwd(null).?);
    try testing.expectEqualStrings(paths.homeDir(), resolveCwd("").?);
}
