//! A single hosted pane: a pty-owned child process plus the terminal
//! state that parses its output. Deliberately built from the same
//! renderer-agnostic pieces `Termio` composes for the GUI (`Terminal`,
//! `stream_terminal.Stream`, `Pty`, `Command`) rather than through
//! `Termio` itself, since `Termio` also carries GPU-renderer plumbing
//! (a `renderer.State` pointer, xev wakeup, apprt mailboxes) that a
//! headless host has no use for and no way to satisfy honestly.
//!
//! A pane outlives any single client connection. Its reader thread keeps
//! draining the pty and feeding the terminal parser for as long as the
//! child is alive, whether or not anyone is attached to watch.
const Pane = @This();

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;

const Pty = @import("../pty.zig").Pty;
const Command = @import("../Command.zig");
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;
const formatter_pkg = terminalpkg.formatter;
const stream_terminal = @import("../terminal/stream_terminal.zig");
const agent_detection = @import("../agent-detection/main.zig");
const Events = @import("Events.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.coastty_host_pane);

alloc: Allocator,
io: Io,
id: []const u8,
cwd: [:0]const u8,
argv: [][:0]const u8,

pty: Pty,
command: Command,

/// Guards `terminal`, `stream`, and `subscribers`. Held only for the
/// short duration of a state update or a subscriber list change, never
/// across a blocking read or write.
mutex: std.Io.Mutex = .init,
terminal: Terminal,
stream: stream_terminal.Stream,
subscribers: std.ArrayList(*Subscriber) = .empty,

reader_thread: ?std.Thread = null,

/// False once the child process has exited. The pane and its final
/// screen contents remain queryable after that; only the pty is gone.
alive: bool = true,

/// How many owners are keeping this pane's memory around: the host's
/// registry holds one, and every in-flight `ATTACH` holds one more for
/// as long as it is talking to the pane. `release` frees at zero, so a
/// `KILL` that drops the registry's reference can't free the pane out
/// from under a client thread still using it.
refs: std.atomic.Value(u32) = .init(1),

/// The foreground process group last reported to subscribers, so
/// `readLoop` only sends a `META` frame when it actually changes rather
/// than on every chunk. Guarded by `mutex` like everything else below.
last_pgid: ?u32 = null,

/// Set when output lands, cleared when a check reads the screen. Detection
/// is a pure function of the screen, so a clean screen cannot read any
/// differently and a check can skip the scan.
screen_dirty: bool = true,

/// The program's last OSC 9;4 progress report, which Claude's rules read.
last_progress: ?terminalpkg.osc.Command.ProgressReport = null,

/// What this pane's agent is doing, as every client sees it.
report: AgentReport = .{},

/// Where this pane reports its exit and its attention changes, for every
/// subscribed client. Set before the reader thread starts, never changed.
events: ?*Events = null,

/// Agent detection against this pane's own terminal state. Only the host's
/// detection loop touches this and the two fields after it, so they take
/// no lock of their own.
detector: agent_detection.Detector,

/// When the detection loop should check this pane next, on the awake clock.
next_check_ms: i64 = 0,

/// Every screen dump is written into this, so a check never allocates one.
screen_buf: std.ArrayList(u8) = .empty,

pub const AgentReport = struct {
    agent: ?agent_detection.Agent = null,
    state: agent_detection.AgentState = .Unknown,

    /// When `state` last changed, on the counter `recency` also draws from.
    state_seq: u64 = 0,

    /// The newest `state_seq` a client has acknowledged. A watermark rather
    /// than a flag, so a client marking seen what it rendered cannot
    /// acknowledge a newer state that landed in the meantime.
    seen_seq: u64 = 0,

    /// Moves whenever `status` does; what orders agents for every client.
    recency: agent_detection.StatusRecency = .{},

    /// Clients looking at this pane right now. A finish while any of them is
    /// counts as seen.
    viewers: u32 = 0,

    pub fn seen(self: AgentReport) bool {
        return self.seen_seq >= self.state_seq;
    }

    pub fn status(self: AgentReport) agent_detection.AgentStatus {
        return .fromState(self.state, self.seen());
    }
};

pub const Subscriber = struct {
    socket: net.Stream,

    /// Serializes writes to `socket` across the pane's broadcaster and
    /// whichever thread owns the connection this subscriber came from.
    /// `attach` below leans on this to guarantee the snapshot it hands
    /// back reaches the wire before any live `DATA` frame does.
    write_mutex: std.Io.Mutex = .init,

    /// Whether this client has said it is looking at the pane. Guarded by
    /// the pane's `mutex`, since it feeds `AgentReport.viewers`.
    viewing: bool = false,
};

pub const SpawnOptions = struct {
    id: []const u8,
    cwd: [:0]const u8,
    argv: []const [:0]const u8,
    cols: u16,
    rows: u16,

    /// Falls back to `default_env` when null - the CLI debug client's
    /// CREATE has no env section (see wire.zig's own CREATE doc
    /// comment), but a real GUI-created pane always sends one.
    env: ?*const std.process.Environ.Map = null,

    events: ?*Events = null,
};

/// Every pane a real daemon spawns shares this same environment - set
/// once by `main.zig` before serving any requests. Left null in tests
/// and the CLI debug client, where a plain inherited environment is
/// fine and there's nothing to scrub.
var default_env: ?*const std.process.Environ.Map = null;

/// The daemon outlives whatever spawned it, so `env` (its own,
/// inherited environment) is a permanent, one-time snapshot from that
/// moment. `spawn` below scrubs whatever env it resolves to use right
/// before spawning, so this doesn't need to arrive pre-cleaned.
pub fn setDefaultEnv(env: *const std.process.Environ.Map) void {
    default_env = env;
}

/// Session markers a tool (an agent CLI) sets in its own child
/// environments. Inherited into a pane that outlives the session that
/// set them, these look live to whatever runs inside it - the daemon's
/// own startup env and a per-CREATE env from the GUI can each carry
/// them independently (either process can just as easily have been
/// launched from inside a tool session), so this is applied once, here,
/// to whichever one `spawn` ends up using - not by each producer, which
/// is exactly the split responsibility that let this leak back in once
/// already.
fn isToolSessionMarker(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "CLAUDE") or std.mem.eql(u8, key, "AI_AGENT");
}

/// A copy of `src` with every `isToolSessionMarker` key dropped - plus
/// `GIT_EDITOR`, but only when the source env actually came from an
/// agent (`CLAUDECODE`/`AI_AGENT` present): Claude Code sets it so git
/// can't block on an interactive editor, and inherited into a
/// persistent pane it makes `git commit`/`rebase` silently abort with
/// an empty message instead. Not stripped unconditionally since it's
/// also a var a user might have genuinely set themselves.
fn envWithoutToolMarkers(alloc: Allocator, src: *const std.process.Environ.Map) !std.process.Environ.Map {
    const from_agent = src.get("CLAUDECODE") != null or src.get("AI_AGENT") != null;
    var out: std.process.Environ.Map = .init(alloc);
    errdefer out.deinit();
    var it = src.iterator();
    while (it.next()) |entry| {
        if (isToolSessionMarker(entry.key_ptr.*)) continue;
        if (from_agent and std.mem.eql(u8, entry.key_ptr.*, "GIT_EDITOR")) continue;
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

/// This process's own environment as a map, for a spawn given none.
fn inheritedEnv(alloc: Allocator) !std.process.Environ.Map {
    var out: std.process.Environ.Map = .init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const field = std.mem.sliceTo(entry, 0);
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        try out.put(field[0..eq], field[eq + 1 ..]);
    }
    return out;
}

/// The environment a pane's process starts with: `src` (or this process's
/// own) without stale tool markers, and with the pane's id set last, so no
/// caller-supplied environment can claim another pane's id.
fn paneEnv(alloc: Allocator, src: ?*const std.process.Environ.Map, id: []const u8) !std.process.Environ.Map {
    var env = if (src) |map| try envWithoutToolMarkers(alloc, map) else blk: {
        var inherited = try inheritedEnv(alloc);
        defer inherited.deinit();
        break :blk try envWithoutToolMarkers(alloc, &inherited);
    };
    errdefer env.deinit();
    try env.put(wire.pane_id_env, id);
    return env;
}

pub fn spawn(alloc: Allocator, io: Io, opts: SpawnOptions) !*Pane {
    const pane = try alloc.create(Pane);
    errdefer alloc.destroy(pane);

    var pty = try Pty.open(.{
        .ws_row = opts.rows,
        .ws_col = opts.cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    });
    errdefer pty.deinit();

    const id = try alloc.dupe(u8, opts.id);
    errdefer alloc.free(id);

    const cwd = try alloc.dupeZ(u8, opts.cwd);
    errdefer alloc.free(cwd);

    const argv = try alloc.alloc([:0]const u8, opts.argv.len);
    var argv_filled: usize = 0;
    errdefer {
        for (argv[0..argv_filled]) |a| alloc.free(a);
        alloc.free(argv);
    }
    for (opts.argv) |a| {
        argv[argv_filled] = try alloc.dupeZ(u8, a);
        argv_filled += 1;
    }

    var terminal = try Terminal.init(io, alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
    });
    errdefer terminal.deinit(alloc);

    var detector = try agent_detection.Detector.init(alloc);
    errdefer detector.deinit();

    pane.* = .{
        .alloc = alloc,
        .io = io,
        .id = id,
        .cwd = cwd,
        .argv = argv,
        .pty = pty,
        .command = undefined,
        .terminal = terminal,
        .stream = undefined,
        .detector = detector,
        .events = opts.events,
    };
    var handler: stream_terminal.Handler = .init(&pane.terminal);
    handler.effects.write_pty = writePtyEffect;
    handler.effects.progress_report = progressReportEffect;
    pane.stream = .init(.{
        .allocator = alloc,
        .handler = handler,
    });

    // Scrubbed here, at the one place a pane's process is actually
    // spawned, so no env source - per-CREATE, daemon-wide fallback, or
    // a future one - can reintroduce a stale tool-session marker by
    // skipping a scrub upstream. `Command.start` copies whatever this
    // points to into its own arena synchronously, before this function
    // returns, so it only needs to outlive `cmd.start` below.
    var env = try paneEnv(alloc, opts.env orelse default_env, id);
    defer env.deinit();

    var cmd: Command = .{
        .path = argv[0],
        .args = argv,
        .env = &env,
        .cwd = pane.cwd,
        .stdin = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .stdout = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .stderr = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } },
        .os_pre_exec = preExec,
        .rt_pre_exec = null,
        .rt_pre_exec_info = .{},
        .rt_post_fork = null,
        .rt_post_fork_info = .{},
        .data = pane,
    };
    try cmd.start(alloc);
    // The child now holds the slave side; leaking our copy would keep
    // the pty from ever reporting EOF once the child exits.
    _ = posix.system.close(pty.slave);
    pane.command = cmd;

    pane.reader_thread = try std.Thread.spawn(.{}, readLoop, .{pane});
    return pane;
}

fn preExec(cmd: *Command) ?u8 {
    const pane = cmd.getData(Pane) orelse unreachable;
    pane.pty.childPreExec() catch return 1;
    return null;
}

/// Runs inside `readLoop`'s locked step, so `mutex` is already held.
fn progressReportEffect(handler: *stream_terminal.Handler, report: terminalpkg.osc.Command.ProgressReport) void {
    const stream_ptr: *stream_terminal.Stream = @fieldParentPtr("handler", handler);
    const pane: *Pane = @alignCast(@fieldParentPtr("stream", stream_ptr));
    pane.last_progress = report;
}

/// Answers the program's queries - cursor position, colours, device
/// attributes - but only while no client is attached. An attached client is
/// the terminal the program is really talking to and answers them itself,
/// with its real theme and geometry; answering here too put a second reply
/// in the program's input after it had stopped reading, and the first one
/// carried this copy's default colours. Runs inside the read loop's or
/// `resize`'s locked step, so `mutex` is held.
fn writePtyEffect(handler: *stream_terminal.Handler, data: [:0]const u8) void {
    const stream_ptr: *stream_terminal.Stream = @fieldParentPtr("handler", handler);
    const pane: *Pane = @alignCast(@fieldParentPtr("stream", stream_ptr));
    if (pane.subscribers.items.len > 0) return;
    pane.writeInput(data) catch |err| {
        log.warn("pane {s}: write_pty failed: {}", .{ pane.id, err });
    };
}

/// Runs for the lifetime of the child process on its own thread: drains
/// the pty, updates terminal state, and fans raw output out to whoever
/// is currently attached.
fn readLoop(pane: *Pane) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(pane.pty.master, &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => 0,
        };
        if (n == 0) break;
        const chunk = buf[0..n];

        // The terminal-state update and the broadcast of these same raw
        // bytes must land as one atomic step under `mutex`, or a
        // concurrent `attach` could slip in between them: it would
        // capture a snapshot that already reflects this chunk and then
        // also receive it again as a live DATA frame, once it registers
        // as a subscriber below.
        pane.mutex.lockUncancelable(pane.io);
        pane.stream.nextSlice(chunk);
        pane.screen_dirty = true;
        pane.broadcastPgidIfChangedLocked();
        pane.broadcastLocked(chunk);
        pane.mutex.unlock(pane.io);
    }

    // EOF here means the child closed its last copy of the pty slave,
    // which happens as part of it exiting. Reap it now rather than
    // leaving it a zombie for however long the host keeps running,
    // which - being a long-lived daemon - could be indefinitely.
    const exit = pane.command.wait(true) catch |err| exit: {
        log.warn("pane {s}: failed to reap exited child: {}", .{ pane.id, err });
        break :exit null;
    };

    pane.mutex.lockUncancelable(pane.io);
    pane.alive = false;
    pane.mutex.unlock(pane.io);
    log.info("pane {s} exited: {?}", .{ pane.id, exit });
    if (pane.events) |events| events.publishPane(.pane_exited, pane.id);
}

/// Fans `data` out to every current subscriber as a `DATA` frame. Caller
/// must already hold `pane.mutex` (see `readLoop`'s doc comment on why
/// this can't be its own separately-locked step).
fn broadcastLocked(pane: *Pane, data: []const u8) void {
    var i: usize = 0;
    while (i < pane.subscribers.items.len) {
        const sub = pane.subscribers.items[i];
        sub.write_mutex.lockUncancelable(pane.io);
        var wbuf: [4096]u8 = undefined;
        var w = sub.socket.writer(pane.io, &wbuf);
        const ok = blk: {
            wire.writeFrame(&w.interface, "DATA", data) catch break :blk false;
            break :blk true;
        };
        sub.write_mutex.unlock(pane.io);
        if (ok) {
            i += 1;
        } else {
            pane.dropSubscriberLocked(i);
        }
    }
}

/// The pane's real foreground process-group id and root child pid, as
/// coastty's own agent-detection (which runs entirely GUI-side, off
/// `Termio`'s backend interface) needs them. Both are plain integers
/// rather than a passed file descriptor: pids are global on the
/// platforms coastty targets, so a GUI process can look up whatever
/// process owns one directly, exactly as it would for a local pane.
pub fn processInfo(pane: *Pane) struct { pgid: ?u32, child_pid: ?u32 } {
    const pgid: ?u32 = if (pane.pty.getProcessInfo(.foreground_pid)) |p|
        std.math.cast(u32, p)
    else
        null;
    const child_pid: ?u32 = if (pane.command.pid) |p| std.math.cast(u32, p) else null;
    return .{ .pgid = pgid, .child_pid = child_pid };
}

/// Writes a `META <pgid> <child_pid>\n` line to every subscriber if the
/// foreground process group changed since the last time this ran (`0`
/// stands in for "unknown" on the wire). Caller must already hold
/// `pane.mutex`; called from the same locked step as `broadcastLocked`
/// so a newly attaching client's own initial `META` line (see `attach`)
/// and this one can never race each other into a stale order.
fn broadcastPgidIfChangedLocked(pane: *Pane) void {
    const info = pane.processInfo();
    if (info.pgid == pane.last_pgid) return;
    pane.last_pgid = info.pgid;

    var i: usize = 0;
    while (i < pane.subscribers.items.len) {
        const sub = pane.subscribers.items[i];
        sub.write_mutex.lockUncancelable(pane.io);
        var wbuf: [128]u8 = undefined;
        var w = sub.socket.writer(pane.io, &wbuf);
        const ok = if (wire.writeHeaderLine(&w.interface, "META {d} {d}", .{
            info.pgid orelse 0,
            info.child_pid orelse 0,
        })) |_| true else |_| false;
        sub.write_mutex.unlock(pane.io);
        if (ok) {
            i += 1;
        } else {
            pane.dropSubscriberLocked(i);
        }
    }
}

/// Registers `socket` as a live subscriber and captures the current
/// screen for it to catch up on, as one atomic step: both the snapshot
/// and the subscriber-list insert happen while `pane.mutex` is held, so
/// `readLoop` cannot slip a `DATA` frame in between them, and the
/// returned subscriber's `write_mutex` comes back *locked* so the
/// caller's own write of that snapshot is guaranteed to reach the wire
/// before `broadcast` (which also takes `write_mutex`) sends anything
/// live to it. The caller must unlock it once the snapshot is written.
pub fn attach(pane: *Pane, socket: net.Stream) !struct {
    sub: *Subscriber,
    snapshot: []const u8,
    pgid: ?u32,
    child_pid: ?u32,
    report: AgentReport,
} {
    const sub = try pane.alloc.create(Subscriber);
    errdefer pane.alloc.destroy(sub);
    sub.* = .{ .socket = socket };
    sub.write_mutex.lockUncancelable(pane.io);
    errdefer sub.write_mutex.unlock(pane.io);

    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    const snap = try snapshot(pane);
    errdefer pane.alloc.free(snap);
    const info = pane.processInfo();
    try pane.subscribers.append(pane.alloc, sub);
    return .{
        .sub = sub,
        .snapshot = snap,
        .pgid = info.pgid,
        .child_pid = info.child_pid,
        .report = pane.report,
    };
}

/// A real VT byte stream that reconstructs this pane's current screen -
/// cursor position, styles, modes, scrolling region, tabstops, palette,
/// all of it - when fed through the same output parser live pty data
/// goes through. A plain-text dump can't do this: it leaves the
/// attaching client's own cursor tracking wherever printing that text
/// happens to land it, not where the real, still-running shell thinks
/// it is - every line-editing redraw after that (history recall
/// included) then lands in the wrong place. Caller must already hold
/// `pane.mutex`.
/// Put the receiving screen in a known state before replaying onto it:
/// home the cursor, erase the display, and drop whatever scrollback the
/// client already had.
///
/// The dump is absolute - it ends in a CUP naming the row and column the
/// cursor belongs on - so it only lands correctly on a screen that starts
/// where the pane's own did. Replayed onto a client mid-line, the first row
/// continues from wherever the cursor sat and every row after it is off by
/// that much, which puts the final CUP somewhere in the middle of the
/// output. Erasing the scrollback matters for the same reason on a
/// reattach: the client's old copy would otherwise sit above the one being
/// replayed.
const reset_before_replay = "\x1b[H\x1b[2J\x1b[3J";

/// How many rows at the bottom of the viewport the formatter will not emit.
///
/// Trailing blank rows are always trimmed - `formatter.Options.trim` says so
/// and offers no way off - so the replayed screen ends short, and the cursor
/// position that follows it, which is relative to a full viewport, lands that
/// many rows too high.
///
/// Counted back from the last row holding text, not from the cursor. A shell
/// leaves nothing below its prompt, so the two agree there, but a full-screen
/// program draws below its cursor and padding by the cursor's own distance
/// from the bottom would scroll all of it away.
fn trailingBlankRows(pane: *Pane) usize {
    const list = &pane.terminal.screens.active.pages;
    var it = list.rowIterator(.left_up, .{ .viewport = .{} }, null);
    var blank: usize = 0;
    while (it.next()) |pin| {
        if (terminalpkg.Cell.hasTextAny(pin.cells(.all))) break;
        blank += 1;
    }
    return blank;
}

/// Tab stops, written after the screen contents rather than before them.
///
/// Setting a stop walks the cursor along the row. The formatter emits them
/// ahead of the contents and relies on its closing cursor position to undo
/// the walk, but the first row of contents is drawn from wherever the walk
/// ended - the last stop, at the far right - so it lands shifted, or wraps.
fn writeTabstops(pane: *Pane, w: *std.Io.Writer) !void {
    try w.writeAll("\x1b[3g");
    for (0..pane.terminal.cols) |col| {
        if (pane.terminal.tabstops.get(col)) try w.print("\x1b[{d}G\x1bH", .{col + 1});
    }
}

fn snapshot(pane: *Pane) ![]const u8 {
    var formatter: formatter_pkg.TerminalFormatter = .init(&pane.terminal, .vt);
    formatter.extra = .all;
    formatter.extra.tabstops = false;

    // The formatter would replay all 256 palette entries, but this terminal
    // never loaded the user's theme, so they are Ghostty's defaults, and the
    // attaching client would take them over its own theme. Only the entries
    // a program changed are pane state; those are written by hand below.
    formatter.extra.palette = false;

    // Placed by hand below, once the rows the formatter drops have been put
    // back - until then there is nothing for it to be measured against.
    formatter.extra.screen.cursor = false;

    var aw: std.Io.Writer.Allocating = .init(pane.alloc);
    defer aw.deinit();
    try aw.writer.writeAll(reset_before_replay);
    try writeChangedPalette(pane, &aw.writer);
    try formatter.format(&aw.writer);

    // The title is real, durable terminal state (OSC 0/2 sets it, it
    // stays set until changed) but `TerminalFormatter` treats it as
    // chrome rather than screen content and never re-emits it - without
    // this, an attaching client never learns it until the shell happens
    // to redraw its prompt, showing the "no title yet" placeholder in
    // the meantime.
    if (pane.terminal.getTitle()) |title| {
        try aw.writer.print("\x1b]0;{s}\x1b\\", .{title});
    }

    try writeTabstops(pane, &aw.writer);

    // The viewport has to occupy a whole screen before the cursor is placed
    // on it: with the trimmed rows back, history scrolls exactly far enough
    // that the last screenful is the viewport, which is what the position
    // below is relative to.
    for (0..trailingBlankRows(pane)) |_| try aw.writer.writeAll("\r\n");

    const cursor = &pane.terminal.screens.active.cursor;
    try aw.writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });

    return try aw.toOwnedSlice();
}

/// OSC 4 for each palette entry a program in the pane set, ahead of the
/// screen so the colours are right as it draws. Entries nobody touched are
/// left out, so the attaching client keeps its own theme for them.
fn writeChangedPalette(pane: *Pane, writer: *std.Io.Writer) !void {
    const palette = &pane.terminal.colors.palette;
    var changed = palette.mask.iterator(.{});
    while (changed.next()) |i| {
        const rgb = palette.current[i];
        try writer.print(
            "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
            .{ i, rgb.r, rgb.g, rgb.b },
        );
    }
}

/// A fresh snapshot for one subscriber, with its writes already held so
/// nothing the pane broadcasts can land in the middle of it. The caller
/// writes it and unlocks, exactly as it does for `attach`.
pub fn resnapshot(pane: *Pane, sub: *Subscriber) ![]const u8 {
    // The terminal is the reader thread's to change, so it is read under
    // `mutex` - taken first, the same order a broadcast takes them in.
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    sub.write_mutex.lockUncancelable(pane.io);
    errdefer sub.write_mutex.unlock(pane.io);
    return try snapshot(pane);
}

pub fn removeSubscriber(pane: *Pane, socket: net.Stream) void {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    for (pane.subscribers.items, 0..) |sub, i| {
        if (sub.socket.socket.handle == socket.socket.handle) {
            pane.dropSubscriberLocked(i);
            return;
        }
    }
}

/// Removes the subscriber at `i`. A client that goes away stops looking at
/// the pane too, or a disconnected viewer would keep marking finishes seen.
fn dropSubscriberLocked(pane: *Pane, i: usize) void {
    const sub = pane.subscribers.swapRemove(i);
    if (sub.viewing) pane.report.viewers -= 1;
    pane.alloc.destroy(sub);
}

/// A client has started or stopped looking at this pane. Starting marks
/// everything so far seen, for every client.
pub fn setViewing(pane: *Pane, sub: *Subscriber, viewing: bool) void {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    if (sub.viewing == viewing) return;

    sub.viewing = viewing;
    if (viewing) {
        pane.report.viewers += 1;
        pane.report.seen_seq = pane.report.state_seq;
    } else {
        pane.report.viewers -= 1;
    }
    pane.noteStatusLocked(false);
}

/// A client acknowledges the state it rendered, named by its `state_seq`.
/// One that rendered an older state than the current one acknowledges only
/// that older state.
pub fn markSeen(pane: *Pane, state_seq: u64) void {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);

    const upto = @min(state_seq, pane.report.state_seq);
    if (upto <= pane.report.seen_seq) return;
    pane.report.seen_seq = upto;
    pane.noteStatusLocked(false);
}

/// A copy of what clients see about this pane's agent.
pub fn agentReportLocked(pane: *Pane) AgentReport {
    return pane.report;
}

/// Records a newly published detection.
fn applyDetectionLocked(pane: *Pane, detection: agent_detection.AgentDetection) void {
    const r = &pane.report;
    const agent_changed = detection.agent != r.agent;
    r.agent = detection.agent;

    if (detection.state != r.state) {
        const previous = r.state;
        const was_seen = r.seen();
        r.state = detection.state;
        r.state_seq = agent_detection.StatusRecency.next();
        if (agent_detection.seenAfterStateChange(previous, r.state, was_seen, r.viewers > 0)) {
            r.seen_seq = r.state_seq;
        }
    }

    pane.noteStatusLocked(agent_changed);
}

/// Moves recency on, and tells subscribers, when the status clients see has
/// changed - or always, with `force`, for a change status alone doesn't show.
fn noteStatusLocked(pane: *Pane, force: bool) void {
    const before = pane.report.recency.change_seq;
    pane.report.recency.note(pane.report.status());
    if (!force and pane.report.recency.change_seq == before) return;
    pane.broadcastStatusLocked();
    pane.publishAttentionLocked();
}

/// Tells every subscribed client what this pane's agent is doing now.
fn publishAttentionLocked(pane: *Pane) void {
    const events = pane.events orelse return;
    if (!events.listening()) return;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeAttentionEvent(&w, pane.id, pane.report) catch return;
    events.publish(w.buffered());
}

/// The `attention_changed` event: the pane, then every field a `STATUS`
/// frame carries.
pub fn writeAttentionEvent(writer: *std.Io.Writer, pane_id: []const u8, report: AgentReport) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("event");
    try json.write("attention_changed");
    try json.objectField("pane");
    try json.write(pane_id);
    try writeReportFields(&json, report);
    try json.endObject();
}

/// How many clients are attached to this pane right now.
pub fn subscriberCount(pane: *Pane) usize {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    return pane.subscribers.items.len;
}

/// Writes `report` as the JSON a `STATUS` frame carries.
pub fn writeReportJson(report: AgentReport, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try writeReportFields(&json, report);
    try json.endObject();
}

fn writeReportFields(json: *std.json.Stringify, report: AgentReport) std.Io.Writer.Error!void {
    try json.objectField("agent");
    try json.write(if (report.agent) |a| a.agentLabel() else null);
    try json.objectField("state");
    try json.write(report.state.name());
    try json.objectField("attention");
    try json.write(report.status().name());
    try json.objectField("seen");
    try json.write(report.seen());
    try json.objectField("state_seq");
    try json.write(report.state_seq);
    try json.objectField("recency");
    try json.write(report.recency.change_seq);
}

/// The current report as one `STATUS` frame, to `sub` alone. Caller holds
/// `sub.write_mutex`.
pub fn writeStatusFrame(pane: *Pane, sub: *Subscriber, report: AgentReport) !void {
    var body_buf: [256]u8 = undefined;
    var body: std.Io.Writer = .fixed(&body_buf);
    try writeReportJson(report, &body);
    var wbuf: [512]u8 = undefined;
    var w = sub.socket.writer(pane.io, &wbuf);
    try wire.writeFrame(&w.interface, "STATUS", body.buffered());
}

fn broadcastStatusLocked(pane: *Pane) void {
    const report = pane.report;
    var i: usize = 0;
    while (i < pane.subscribers.items.len) {
        const sub = pane.subscribers.items[i];
        sub.write_mutex.lockUncancelable(pane.io);
        const ok = if (pane.writeStatusFrame(sub, report)) |_| true else |_| false;
        sub.write_mutex.unlock(pane.io);
        if (ok) {
            i += 1;
        } else {
            pane.dropSubscriberLocked(i);
        }
    }
}

/// Runs a detection check if one is due, and returns when the next one is.
///
/// A pane with no agent is never scanned: finding one is a process probe,
/// not a read of the screen. A pane whose agent is settled is scanned only
/// once its screen has changed. A finish still resolves with no output after
/// it, because the idle confirmation keeps asking for checks until it lands.
pub fn checkAgent(pane: *Pane, now_ms: i64) i64 {
    if (now_ms < pane.next_check_ms) return pane.next_check_ms;
    pane.next_check_ms = if (pane.runCheck(now_ms))
        now_ms + pane.detector.tickIntervalMs(now_ms)
    else
        std.math.maxInt(i64);
    return pane.next_check_ms;
}

/// One check. False once the pane's process has exited and its final state
/// is published, after which there is nothing left to watch.
fn runCheck(pane: *Pane, now_ms: i64) bool {
    pane.mutex.lockUncancelable(pane.io);
    const alive = pane.alive;
    pane.mutex.unlock(pane.io);

    // An exit forces a final idle, so an agent's finish is never missed. A
    // pane that never had an agent has no finish to report.
    if (!alive) {
        if (pane.detector.agent != null) {
            pane.publish(pane.detector.update(pane.alloc, now_ms, pane.detector.agent, true, .{ .screen = "" }));
        }
        return false;
    }

    // Outside the lock: a probe that does run reads process tables, and the
    // reader thread must not wait on that.
    const info = pane.processInfo();
    const observed = pane.detector.observeForegroundProcess(pane.alloc, now_ms, info.child_pid, info.pgid);
    const agent = observed.agent;

    // No agent, a finished one, or a different one: none of these read the
    // screen, so neither does this check.
    if (agent == null or observed.process_exited or agent != pane.detector.agent) {
        pane.publish(pane.detector.update(pane.alloc, now_ms, agent, observed.process_exited, .{ .screen = "" }));
        return true;
    }

    // Nothing can be published until the startup grace window is over.
    if (pane.detector.startup_grace_until_ms) |until| {
        if (now_ms < until) return true;
    }

    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);

    // The idle confirmation and the first read after the grace window are
    // owed a check whether or not anything was drawn since.
    const owed = pane.screen_dirty or
        pane.detector.pending_idle.active() or
        pane.detector.startup_grace_until_ms != null;
    if (!owed) return true;

    const screen = pane.dumpScreenLocked() catch |err| {
        log.warn("pane {s}: could not read the screen for detection: {}", .{ pane.id, err });
        return true;
    };
    pane.screen_dirty = false;

    var progress_buf: [16]u8 = undefined;
    const result = pane.detector.update(pane.alloc, now_ms, agent, false, .{
        .screen = screen,
        .osc_title = pane.terminal.getTitle() orelse "",
        .osc_progress = agent_detection.formatOscProgress(&progress_buf, pane.last_progress),
    });
    if (pane.detected(result)) |detection| pane.applyDetectionLocked(detection);
    return true;
}

fn publish(pane: *Pane, result: anyerror!?agent_detection.AgentDetection) void {
    const detection = pane.detected(result) orelse return;
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    pane.applyDetectionLocked(detection);
}

/// A check's result, or null for nothing to publish - including a check
/// that failed, which only skips this round.
fn detected(pane: *Pane, result: anyerror!?agent_detection.AgentDetection) ?agent_detection.AgentDetection {
    return result catch |err| {
        log.warn("pane {s}: agent detection failed: {}", .{ pane.id, err });
        return null;
    };
}

/// The visible screen as plain text, the way the GUI's detector reads it,
/// written into `screen_buf` so the dump reuses the last one's memory.
fn dumpScreenLocked(pane: *Pane) ![]const u8 {
    const screen = pane.terminal.screens.active;
    pane.screen_buf.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(pane.alloc, &pane.screen_buf);
    defer pane.screen_buf = aw.toArrayList();
    try screen.dumpString(&aw.writer, .{
        .tl = screen.pages.getTopLeft(.viewport),
        .br = screen.pages.getBottomRight(.viewport) orelse return error.UnknownPoint,
        .unwrap = false,
    });
    return aw.writer.buffered();
}

pub fn writeInput(pane: *Pane, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = posix.system.write(pane.pty.master, data[off..].ptr, data.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .AGAIN => continue,
            .INTR => continue,
            else => |e| {
                log.warn("pane {s}: pty write failed errno={}", .{ pane.id, e });
                return error.WriteFailed;
            },
        }
    }
}

pub fn resize(pane: *Pane, cols: u16, rows: u16) !void {
    try pane.pty.setSize(.{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 });
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    try pane.stream.handler.resize(.{ .cols = cols, .rows = rows, .cell_size_px = null });
}

/// The schemes a shell reports OSC 7 under. Ghostty's own shell
/// integration uses `kitty-shell-cwd://`, so a pane the daemon spawned
/// reports that rather than `file://`.
const pwd_uri_schemes = [_][]const u8{ "file://", "kitty-shell-cwd://" };

/// Turns an OSC 7 payload into a plain filesystem path, written into
/// `buf`. The terminal stores that payload unparsed, as a
/// `<scheme>://<host>/<percent-escaped path>` URI, and nothing can
/// change directory to that. Returns null when it doesn't fit.
fn decodePwdUri(raw: []const u8, buf: []u8) ?[]const u8 {
    var path = raw;
    for (pwd_uri_schemes) |scheme| {
        if (!std.mem.startsWith(u8, path, scheme)) continue;

        // Everything up to the first slash is the reporting host's name.
        const after_scheme = path[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
        path = after_scheme[slash..];
        break;
    }

    var len: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        if (len >= buf.len) return null;
        if (path[i] == '%' and i + 3 <= path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16)) |byte| {
                buf[len] = byte;
                len += 1;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[len] = path[i];
        len += 1;
        i += 1;
    }
    return buf[0..len];
}

/// Where this pane's shell currently is, as it last reported (OSC 7),
/// decoded into `buf` and falling back to the directory it was spawned
/// in. This is the fact the model persists, so a pane comes back in the
/// right place after the daemon restarts - which means it has to be a
/// path, not the URI the terminal holds. Caller must already hold
/// `pane.mutex`.
pub fn directoryLocked(pane: *Pane, buf: []u8) []const u8 {
    const pwd = pane.terminal.getPwd() orelse return pane.cwd;
    if (pwd.len == 0) return pane.cwd;

    const decoded = decodePwdUri(pwd, buf) orelse return pane.cwd;
    return if (decoded.len > 0) decoded else pane.cwd;
}

/// This pane's current terminal title, empty until something sets one.
/// Caller must already hold `pane.mutex`.
pub fn titleLocked(pane: *Pane) []const u8 {
    return pane.terminal.getTitle() orelse "";
}

/// What runs in this pane in place of a shell waiting at its prompt,
/// written into `buf`, or null when nothing does: the test the app's close
/// confirmation makes. Without shell integration there is no prompt to see,
/// so anything still alive counts as running.
pub fn runningCommand(pane: *Pane, buf: []u8) ?[]const u8 {
    pane.mutex.lockUncancelable(pane.io);
    const busy = pane.alive and !pane.terminal.cursorIsAtPrompt();
    pane.mutex.unlock(pane.io);
    if (!busy) return null;

    const unknown = "a process";
    const pgid = pane.processInfo().pgid orelse return unknown;
    var arena: std.heap.ArenaAllocator = .init(pane.alloc);
    defer arena.deinit();
    const job = agent_detection.platform.foregroundGroupLeaderJob(arena.allocator(), pgid) orelse return unknown;
    if (job.processes.len == 0) return unknown;

    const name = job.processes[0].argv0 orelse job.processes[0].name;
    const len = @min(name.len, buf.len);
    @memcpy(buf[0..len], name[0..len]);
    return buf[0..len];
}

pub fn isAlive(pane: *Pane) bool {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    return pane.alive;
}

/// How long a pane's process gets to act on SIGTERM before `terminateAll`
/// escalates to SIGKILL. Long enough for a shell or an agent CLI to save
/// state and unwind, short enough that closing a tab never feels stuck.
const terminate_grace_ms = 2000;

/// Ends the process of every pane in `panes` and returns once they are
/// all actually gone: SIGTERM to each process group first, so
/// well-behaved programs get to clean up, then SIGKILL for whoever is
/// still running once the grace period passes. Panes whose processes
/// already exited on their own are no-ops.
///
/// The whole set is signalled before anything is waited on, so a request
/// naming several unresponsive panes costs one grace period rather than
/// one per pane - the point of taking ids in batches in the first place.
pub fn terminateAll(panes: []const *Pane) void {
    for (panes) |pane| pane.signalGroupIfAlive(posix.SIG.TERM);
    if (waitForAllExit(panes, terminate_grace_ms)) return;

    for (panes) |pane| {
        if (!pane.isAlive()) continue;
        log.info("pane {s}: still running after SIGTERM, sending SIGKILL", .{pane.id});
        pane.signalGroupIfAlive(posix.SIG.KILL);
    }
    _ = waitForAllExit(panes, terminate_grace_ms);
}

/// `terminateAll` for a single pane.
pub fn terminate(pane: *Pane) void {
    terminateAll(&.{pane});
}

/// Signals the pane's whole process group rather than just its direct
/// child: the child is its own session and group leader (see
/// `Pty.childPreExec`), so its pid doubles as the group id, and anything
/// the shell started shares that group unless it broke away itself.
fn signalGroupIfAlive(pane: *Pane, sig: posix.SIG) void {
    if (!pane.isAlive()) return;
    const pid = pane.command.pid orelse return;
    posix.kill(-pid, sig) catch |err| log.warn(
        "pane {s}: signal {t} failed: {}",
        .{ pane.id, sig, err },
    );
}

/// Polls until every pane's reader thread has seen pty EOF and reaped its
/// child, or `timeout_ms` elapses. Returns whether they are all gone.
fn waitForAllExit(panes: []const *Pane, timeout_ms: u64) bool {
    const poll_ms = 5;
    var waited: u64 = 0;
    while (true) {
        if (allExited(panes)) return true;
        if (waited >= timeout_ms) return false;
        std.Io.sleep(panes[0].io, .fromMilliseconds(poll_ms), .awake) catch {};
        waited += poll_ms;
    }
}

/// Whether every pane's child process is already gone.
fn allExited(panes: []const *Pane) bool {
    for (panes) |pane| {
        if (pane.isAlive()) return false;
    }
    return true;
}

/// Takes an extra reference for a caller that is about to use this pane
/// outside the lock that found it. Must be called while the owner that
/// handed it out still holds its own reference.
pub fn retain(pane: *Pane) void {
    _ = pane.refs.fetchAdd(1, .monotonic);
}

/// Drops one reference, tearing the pane down once the last one goes.
pub fn release(pane: *Pane) void {
    if (pane.refs.fetchSub(1, .acq_rel) == 1) pane.deinit();
}

/// Tears a pane down once its process has already exited (`readLoop`
/// reaps the child itself as soon as it sees pty EOF) - it joins the
/// reader thread, so calling it on a live pane would block forever.
/// Reached through `release` when the last reference goes, which for the
/// daemon means a `KILL`/`SWEEP` after `terminate` has ended the process.
pub fn deinit(pane: *Pane) void {
    if (pane.reader_thread) |t| t.join();
    pane.detector.deinit();
    pane.screen_buf.deinit(pane.alloc);
    pane.terminal.deinit(pane.alloc);
    pane.stream.deinit();
    for (pane.argv) |a| pane.alloc.free(a);
    pane.alloc.free(pane.argv);
    pane.alloc.free(pane.cwd);
    pane.alloc.free(pane.id);
    for (pane.subscribers.items) |sub| pane.alloc.destroy(sub);
    pane.subscribers.deinit(pane.alloc);
    pane.pty.deinit();
    pane.alloc.destroy(pane);
}

test "spawn runs a command and captures its output" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "echo hello-from-pane" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    // The reader thread clears `alive` once the shell exits and its pty
    // hits EOF; join it (via deinit's join, done up front here so the
    // snapshot below sees the final screen) by waiting on `isAlive`.
    var spins: usize = 0;
    while (pane.isAlive() and spins < 1000) : (spins += 1) {
        std.Thread.yield() catch {};
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "hello-from-pane") != null);

    // A plain-text dump has no way to tell an attaching client where the
    // real cursor actually is - a regression back to it would silently
    // desync every reattach's line editing (see the wire-protocol fix
    // this same commit made for #39). \x1b confirms a real VT stream.
    try std.testing.expect(std.mem.indexOfScalar(u8, snap, 0x1b) != null);
}

test "spawn strips tool-session markers but keeps the rest of the env" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("CLAUDE_CODE_SESSION_ID", "leaked-session-id");
    try env.put("CLAUDECODE", "1");
    try env.put("TERM", "xterm-ghostty");

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-env",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "echo m=[$CLAUDE_CODE_SESSION_ID] t=$TERM" },
        .cols = 80,
        .rows = 24,
        .env = &env,
    });
    defer pane.deinit();

    var spins: usize = 0;
    while (pane.isAlive() and spins < 1000) : (spins += 1) {
        std.Thread.yield() catch {};
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "m=[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "t=xterm-ghostty") != null);
}

/// Runs `script` in a fresh pane and returns the screen it leaves behind.
fn screenAfterRunning(id: []const u8, script: [:0]const u8, env: ?*const std.process.Environ.Map) ![]const u8 {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = id,
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", script },
        .cols = 80,
        .rows = 24,
        .env = env,
    });
    defer pane.deinit();

    var spins: usize = 0;
    while (pane.isAlive() and spins < 1000) : (spins += 1) {
        std.Thread.yield() catch {};
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(!pane.isAlive());
    return pane.snapshotForTest();
}

test "a pane's process knows its own pane id" {
    const snap = try screenAfterRunning("pane-own-id", "echo id=[$COASTTY_PANE_ID]", null);
    defer std.testing.allocator.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "id=[pane-own-id]") != null);
}

test "a caller-supplied environment cannot claim another pane's id" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(wire.pane_id_env, "someone-else");

    const snap = try screenAfterRunning("pane-real-id", "echo id=[$COASTTY_PANE_ID]", &env);
    defer std.testing.allocator.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "id=[pane-real-id]") != null);
}

test "snapshot starts from a known screen rather than wherever the client left off" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-reset",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'abc\\r\\ndef'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    // The dump ends in an absolute CUP, so anything already on the
    // receiving screen has to go before the first row is written.
    try std.testing.expect(std.mem.startsWith(u8, snap, reset_before_replay));
}

test "a pane with no agent is never scanned" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-no-agent",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'plain output'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    var now: i64 = 0;
    while (now < 5_000) : (now += 600) _ = pane.checkAgent(now);

    // Output arrived and checks ran, but finding an agent is a process
    // probe: with none found, no dump was ever made.
    try std.testing.expectEqual(@as(usize, 0), pane.screen_buf.capacity);
    try std.testing.expectEqual(agent_detection.AgentState.Unknown, pane.report.state);
}

test "a pane with no agent stays unknown when its process exits" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-exits",
        .cwd = "/",
        .argv = &.{"/usr/bin/true"},
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    var spins: usize = 0;
    while (pane.isAlive() and spins < 1000) : (spins += 1) {
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(!pane.isAlive());

    _ = pane.checkAgent(0);
    try std.testing.expectEqual(agent_detection.AgentState.Unknown, pane.report.state);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), pane.next_check_ms);
}

test "acknowledging an older state leaves a newer one unseen" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-seen",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    pane.mutex.lockUncancelable(io);
    pane.report.state = .Idle;
    pane.report.state_seq = 10;
    pane.report.seen_seq = 0;
    pane.mutex.unlock(io);

    // A client that rendered the state at 5 cannot acknowledge the one at 10.
    pane.markSeen(5);
    try std.testing.expectEqual(agent_detection.AgentStatus.Done, pane.report.status());

    pane.markSeen(10);
    try std.testing.expectEqual(agent_detection.AgentStatus.Idle, pane.report.status());
}

test "snapshot draws its first row before the tab stops move the cursor" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-tabstops",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'abc'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    // Ahead of the contents, the walk would leave the cursor at the last stop
    // and the first row would be drawn from there instead of column one.
    const text_at = std.mem.indexOf(u8, snap, "abc") orelse return error.TestUnexpectedResult;
    const tabs_at = std.mem.indexOf(u8, snap, "\x1b[3g") orelse return error.TestUnexpectedResult;
    try std.testing.expect(tabs_at > text_at);
}

test "snapshot fills the viewport so the cursor it ends with lands on the prompt" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    // Two rows of text in a 24-row screen leaves the cursor on row 3 with
    // 22 blank rows under it - the shape this whole bug needs.
    const pane = try spawn(alloc, io, .{
        .id = "test-pane-viewport-pad",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'a\\r\\nb\\r\\n'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    // Trimmed rows put back, then the position - without the padding the
    // screen ends after "b" and this CUP lands two rows into the output.
    try std.testing.expect(std.mem.endsWith(u8, snap, "\r\n" ** 22 ++ "\x1b[3;1H"));
}

test "snapshot places the cursor where the shell actually left it" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    // Prints while still alive, unlike the other spawn tests - the
    // point here is a snapshot taken mid-session, the case that
    // actually matters for reattach. Explicit \r\n rather than relying
    // on the pty translating a bare \n, so this only tests snapshot()
    // itself, not incidental pty/termios behavior.
    const pane = try spawn(alloc, io, .{
        .id = "test-pane-cursor",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'abc\\r\\ndef'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(pane.isAlive());

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    // A plain-text dump, or a snapshot with only palette/mode setup and
    // no real cursor tracking, would still contain *some* escape code -
    // asserting the specific CUP the cursor should actually be at (row
    // 2, column 4: past "def" on the second line) is what the plain-
    // text-snapshot bug this test guards against would have failed.
    try std.testing.expect(std.mem.indexOf(u8, snap, "\x1b[2;4H") != null);
}

/// Test-only alias: `attach` always registers a subscriber alongside the
/// snapshot, which a plain state check has no use for.
fn snapshotForTest(pane: *Pane) ![]const u8 {
    pane.mutex.lockUncancelable(pane.io);
    defer pane.mutex.unlock(pane.io);
    return snapshot(pane);
}

test "snapshot leaves the attaching client's palette alone" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-palette-untouched",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf 'abc'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    // Nothing in the pane set a colour, so the client's theme must stand.
    try std.testing.expect(std.mem.indexOf(u8, snap, "\x1b]4;") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "abc") != null);
}

test "snapshot replays only the palette entries a program changed" {
    const alloc = std.testing.allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    const pane = try spawn(alloc, io, .{
        .id = "test-pane-palette-changed",
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "printf '\\033]4;3;rgb:11/22/33\\007'; sleep 5" },
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    // The reader thread parses the OSC on its own schedule.
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        pane.mutex.lockUncancelable(io);
        const set = pane.terminal.colors.palette.mask.isSet(3);
        pane.mutex.unlock(io);
        if (set) break;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }

    const snap = try pane.snapshotForTest();
    defer alloc.free(snap);

    try std.testing.expect(std.mem.indexOf(u8, snap, "\x1b]4;3;rgb:11/22/33\x1b\\") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, snap, "\x1b]4;"));
}

test "decodePwdUri strips the reporting scheme and unescapes the path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // What Ghostty's own shell integration reports.
    try std.testing.expectEqualStrings(
        "/Users/me/dev",
        decodePwdUri("kitty-shell-cwd://air/Users/me/dev", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "/Users/me/my projects",
        decodePwdUri("file://mac.local/Users/me/my%20projects", &buf).?,
    );
    try std.testing.expectEqualStrings("/tmp", decodePwdUri("file:///tmp", &buf).?);

    // A bare path, and a stray percent that isn't an escape, both survive.
    try std.testing.expectEqualStrings("/tmp/100%", decodePwdUri("/tmp/100%", &buf).?);

    var tiny: [4]u8 = undefined;
    try std.testing.expect(decodePwdUri("/a/much/longer/path", &tiny) == null);
}
