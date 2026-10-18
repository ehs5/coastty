//! coastty-host: a small headless daemon that owns pane ptys directly,
//! independent of the coastty GUI's own lifetime. See `Host.zig` for the
//! server and `Pane.zig` for how a pane composes `Terminal` + `Pty`.
//!
//! This binary is also its own debug client (`create`/`list`/`attach`,
//! and `model`/`space`/`tab`/`pane` for the model) so the daemon can be
//! exercised and verified by hand without the GUI - build a Space and a
//! tab, restart the daemon, and ask it for the model to see it intact.
//! `create`, `kill`, `sweep` and `attach` send the token the daemon
//! published beside its socket, as the app does.
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;

const Host = @import("Host.zig");
const Pane = @import("Pane.zig");
const wire = @import("wire.zig");
const paths = @import("paths.zig");
const access = @import("access.zig");

const log = std.log.scoped(.coastty_host_main);

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // argv[0]

    const sub = args.next() orelse return usage(io);

    if (std.mem.eql(u8, sub, "run")) {
        setGhosttyTerminalEnv(io, init.environ_map);
        Pane.setDefaultEnv(init.environ_map);
        return runForeground(alloc, io);
    } else if (std.mem.eql(u8, sub, "start")) {
        setGhosttyTerminalEnv(io, init.environ_map);
        Pane.setDefaultEnv(init.environ_map);
        return start(alloc);
    } else if (std.mem.eql(u8, sub, "create")) {
        return create(alloc, io, &args);
    } else if (std.mem.eql(u8, sub, "list")) {
        return list(alloc, io);
    } else if (std.mem.eql(u8, sub, "kill")) {
        return idCommand(alloc, io, "KILL", &args);
    } else if (std.mem.eql(u8, sub, "sweep")) {
        return idCommand(alloc, io, "SWEEP", &args);
    } else if (std.mem.eql(u8, sub, "attach")) {
        return attach(alloc, io, &args);
    } else if (std.mem.eql(u8, sub, "model")) {
        return model(alloc, io);
    } else if (std.mem.eql(u8, sub, "events")) {
        return events(alloc, io);
    } else if (std.mem.eql(u8, sub, "space")) {
        return modelOp(alloc, io, "SPACE", &args);
    } else if (std.mem.eql(u8, sub, "tab")) {
        return modelOp(alloc, io, "TAB", &args);
    } else if (std.mem.eql(u8, sub, "pane")) {
        return modelOp(alloc, io, "PANE", &args);
    }
    return usage(io);
}

/// Subscribes as an outside client and prints the answer line, then one
/// event per line as they arrive, until interrupted.
fn events(alloc: Allocator, io: Io) !void {
    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);

    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "SUBSCRIBE {d} client", .{wire.protocol_version});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);

    const answer = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(answer);
    if (!std.mem.startsWith(u8, answer, "OK ")) {
        log.err("subscribe failed: {s}", .{answer});
        return error.SubscribeFailed;
    }
    try stdout.interface.print("{s}\n", .{answer});
    try stdout.interface.flush();

    while (true) {
        const header = (try wire.readHeader(alloc, &r.interface)) orelse break;
        defer alloc.free(header);
        var it = std.mem.tokenizeScalar(u8, header, ' ');
        _ = it.next();
        const len = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
        const body = try wire.readBody(alloc, &r.interface, len);
        defer alloc.free(body);
        try stdout.interface.print("{s}\n", .{body});
        try stdout.interface.flush();
    }
}

fn usage(io: Io) !void {
    var buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &buf);
    try stderr.interface.writeAll(
        \\usage: coastty-host <command>
        \\
        \\  start                          daemonize and serve, if not already running
        \\  run                            serve in the foreground (for tests/debugging)
        \\  create <cwd> <argv...>         start a pane, print its id
        \\  create --id <id> <cwd> <argv..> start-or-reuse a pane under a caller-chosen id
        \\  list                           list live panes
        \\  kill <id...>                   end the named panes' processes
        \\  sweep <id...>                  end every pane except the named ones
        \\  attach <id>                    print a pane's screen and follow its output
        \\  model                          print the model: Spaces, tabs, pane membership
        \\  events                         subscribe and print each event as it happens
        \\  space <op> <field...>          change a Space (new/close/rename/move/hide/show)
        \\  tab <op> <field...>            change a tab (new/close/rename/move)
        \\  pane <op> <field...>           move a pane into a tab (move <pane> <tab> <index>)
        \\
    );
    try stderr.interface.flush();
}

fn runForeground(alloc: Allocator, io: Io) !void {
    // Ignore SIGPIPE: this process outlives whatever terminal launched
    // it, and a write to a subscriber that has since gone away must
    // surface as a normal write error, not tear the whole daemon down.
    ignoreSigpipe();
    catchShutdownSignals();
    var host: Host = .init(alloc, io);
    try host.run();
}

/// Forks once and lets the child become the daemon; the original process
/// (the GUI's launch of `coastty-host start`, or this CLI invocation)
/// returns right away. `setsid` in the child drops the controlling
/// terminal so the daemon can't be taken down by the launcher's own
/// session or process-group closing, matching how herdr's server
/// detaches itself.
fn start(alloc: Allocator) !void {
    const pid = try forkPosix();
    if (pid != 0) return;

    if (std.c.setsid() < 0) log.warn("setsid failed, continuing anyway", .{});

    var io_owner: std.Io.Threaded = .init_single_threaded;
    const io = io_owner.io();
    ignoreSigpipe();
    catchShutdownSignals();
    var host: Host = .init(alloc, io);
    host.run() catch |err| log.err("host exited: {}", .{err});
    std.process.exit(0);
}

/// `Surface.zig`'s local exec path sets these per-surface from the
/// GUI's own live config and resources dir (see `Termio.Exec.init`) -
/// this daemon has no per-surface config to read them from, so it
/// derives the same values once, from its own location alongside the
/// GUI in the same app bundle, and shares them across every pane.
/// Without this, a host-attached pane's shell has no TERM at all -
/// title-setting, colors, and anything else that checks it silently
/// behave as if talking to a dumb terminal.
fn setGhosttyTerminalEnv(io: Io, env: *std.process.Environ.Map) void {
    const resources_dir: ?[]const u8 = resources_dir: {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_len = std.process.executablePath(io, &exe_buf) catch break :resources_dir null;
        const exe = exe_buf[0..exe_len];

        // .../Contents/MacOS/coastty-host -> .../Contents/Resources/ghostty,
        // the same layout build.zig already assumes when it copies this
        // binary in alongside the GUI's own.
        const macos_dir = std.fs.path.dirname(exe) orelse break :resources_dir null;
        const contents_dir = std.fs.path.dirname(macos_dir) orelse break :resources_dir null;

        // The terminfo db itself lives directly under Resources/, as a
        // sibling of the "ghostty" resources subdir - not nested inside
        // it, even though `GHOSTTY_RESOURCES_DIR` below points at the
        // subdir.
        var sentinel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sentinel = std.fmt.bufPrint(&sentinel_buf, "{s}/Resources/terminfo/78/xterm-ghostty", .{contents_dir}) catch break :resources_dir null;
        if (std.Io.Dir.accessAbsolute(io, sentinel, .{})) {} else |_| break :resources_dir null;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        break :resources_dir std.fmt.bufPrint(&buf, "{s}/Resources/ghostty", .{contents_dir}) catch break :resources_dir null;
    };

    env.put("COLORTERM", "truecolor") catch {};
    if (resources_dir) |dir| {
        env.put("TERM", "xterm-ghostty") catch {};
        var terminfo_buf: [std.fs.max_path_bytes]u8 = undefined;
        const terminfo = std.fmt.bufPrint(&terminfo_buf, "{s}/terminfo", .{std.fs.path.dirname(dir) orelse dir}) catch return;
        env.put("TERMINFO", terminfo) catch {};
        env.put("GHOSTTY_RESOURCES_DIR", dir) catch {};
    } else {
        log.warn("ghostty terminfo not found alongside coastty-host, using xterm-256color", .{});
        env.put("TERM", "xterm-256color") catch {};
    }
}

/// Raises `Host.shutdown_requested` so the flush loop can write the model
/// out before the process goes. Nothing else is safe to do here: a signal
/// handler may not allocate or take a lock.
fn onShutdownSignal(_: posix.SIG) callconv(.c) void {
    Host.shutdown_requested.store(true, .release);
}

/// Catches the signals this daemon is normally ended with - `pkill` from
/// `coastty-build-dev`, and shutdown - so a structural change made in the
/// moment before is not lost. SIGKILL cannot be caught, and that case
/// still loses whatever the last write missed.
fn catchShutdownSignals() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    posix.sigaction(posix.SIG.INT, &sa, null);
}

fn ignoreSigpipe() void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
}

fn forkPosix() !posix.pid_t {
    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn connectOrFail(alloc: Allocator, io: Io) !net.Stream {
    const path = try paths.socketPath(alloc);
    defer alloc.free(path);
    return access.connect(io, path) orelse {
        log.err("no coastty-host running (looked for {s}); run `coastty-host start` first", .{path});
        return error.NoHost;
    };
}

fn create(alloc: Allocator, io: Io, args: *std.process.Args.Iterator) !void {
    var id: []const u8 = "";
    var first = args.next() orelse return usage(io);
    if (std.mem.eql(u8, first, "--id")) {
        id = args.next() orelse return usage(io);
        first = args.next() orelse return usage(io);
    }
    const cwd = first;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    while (args.next()) |a| try argv.append(alloc, a);
    if (argv.items.len == 0) return usage(io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, id);
    try body.append(alloc, 0);
    try body.appendSlice(alloc, cwd);
    for (argv.items) |a| {
        try body.append(alloc, 0);
        try body.appendSlice(alloc, a);
    }

    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);
    const token = access.socketTokenArg(alloc, io);
    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try w.interface.print("CREATE {d} {d} {d}{s}\n", .{ 80, 24, body.items.len, token.text() });
    try w.interface.writeAll(body.items);
    try w.interface.flush();

    try printResponse(alloc, io, conn);
}

fn list(alloc: Allocator, io: Io) !void {
    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "LIST", .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    while (true) {
        const line = (try wire.readHeader(alloc, &r.interface)) orelse break;
        defer alloc.free(line);
        try stdout.interface.print("{s}\n", .{line});
    }
    try stdout.interface.flush();
}

/// Sends one of the id-list verbs (`KILL`, `SWEEP`) with whatever ids
/// follow on the command line and prints the daemon's acknowledgement.
fn idCommand(alloc: Allocator, io: Io, verb: []const u8, args: *std.process.Args.Iterator) !void {
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    while (args.next()) |id| try ids.append(alloc, id);

    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);
    const token = access.socketTokenArg(alloc, io);
    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeIdCommandLine(&w.interface, verb, ids.items, token.text());

    try printResponse(alloc, io, conn);
}

/// Prints the daemon's one-line acknowledgement of a request.
fn printResponse(alloc: Allocator, io: Io, conn: net.Stream) !void {
    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const resp = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(resp);

    var stdout_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout.interface.print("{s}\n", .{resp});
    try stdout.interface.flush();
}

/// Prints the daemon's whole model as the one JSON document it answers
/// `MODEL` with - enough to see that a restarted daemon came back with
/// the Spaces and tabs it had.
fn model(alloc: Allocator, io: Io) !void {
    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);

    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "MODEL", .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const status = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(status);
    if (!std.mem.startsWith(u8, status, "OK ")) {
        log.err("model request failed: {s}", .{status});
        return error.ModelFailed;
    }

    const len = try std.fmt.parseInt(usize, status["OK ".len..], 10);
    const document = try wire.readBody(alloc, &r.interface, len);
    defer alloc.free(document);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout.interface.print("{s}\n", .{document});
    try stdout.interface.flush();
}

/// Sends one structural change - `space new <id> <name>`, `pane move
/// <pane-id> <tab-id> <index>` - with its arguments as the NUL-separated
/// body the daemon expects (see `wire.zig`).
fn modelOp(alloc: Allocator, io: Io, verb: []const u8, args: *std.process.Args.Iterator) !void {
    const op = args.next() orelse return usage(io);

    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(alloc);
    while (args.next()) |field| try fields.append(alloc, field);
    if (fields.items.len == 0) return usage(io);

    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeModelOp(&w.interface, verb, op, fields.items);

    try printResponse(alloc, io, conn);
}

fn attach(alloc: Allocator, io: Io, args: *std.process.Args.Iterator) !void {
    const id = args.next() orelse return usage(io);
    const conn = try connectOrFail(alloc, io);
    defer conn.close(io);
    const token = access.socketTokenArg(alloc, io);

    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s}{s}", .{ id, token.text() });

    var rbuf: [1 << 20]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const status = (try wire.readHeader(alloc, &r.interface)) orelse return error.NoResponse;
    defer alloc.free(status);
    if (!std.mem.eql(u8, status, "OK")) {
        log.err("attach failed: {s}", .{status});
        return error.AttachFailed;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buf);
    while (true) {
        const header = (try wire.readHeader(alloc, &r.interface)) orelse break;
        defer alloc.free(header);
        var it = std.mem.tokenizeScalar(u8, header, ' ');
        const tag = it.next() orelse continue;

        // META is a header-only line (no length-prefixed body): the two
        // tokens after it are the pgid/child_pid themselves, not a body
        // length, so it can't go through the generic tag/len/body path
        // below.
        if (std.mem.eql(u8, tag, "META")) continue;

        const len = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
        const body = try wire.readBody(alloc, &r.interface, len);
        defer alloc.free(body);
        if (std.mem.eql(u8, tag, "SNAPSHOT") or std.mem.eql(u8, tag, "DATA")) {
            try stdout.interface.writeAll(body);
            try stdout.interface.flush();
        }
    }
}
