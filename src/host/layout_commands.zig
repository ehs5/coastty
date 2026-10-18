//! Layout commands: `coastty tab new` and its kin, run from the command line
//! by people, scripts and agents to change Spaces, tabs and panes. They only
//! ever change layout - nothing here types into a pane or reads one.
//!
//! A command asks the daemon with a `REQUEST` (see `wire.zig`), the daemon
//! hands it to the app, and the command waits until the model shows the
//! change, so a script never acts on something that did not happen. Errors
//! go to stderr; a failure exits 1 and a usage mistake exits 2.
//!
//! Inside coastty a command with no id acts on the caller's own Space, tab
//! or pane. Outside it, `tab new` and `pane split` act on what the user is
//! looking at (see `Focus.zig`); nothing that closes or changes something
//! existing ever does.
//!
//! `space focus`, `tab focus` and `pane focus` bring something to the front
//! and wait until the focus the app reports shows it, rather than the model.
//!
//! Windows are known only as the app reports them (see `Windows.zig`):
//! `window list` shows them, and `space new` and `space move` can name one.
//!
//! `coastty skill` prints the skill file that teaches agents these
//! commands, and `coastty skill install` copies it where Claude Code finds it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const wire = @import("wire.zig");
const paths = @import("paths.zig");
const access = @import("access.zig");

/// How long a command waits for the model to show its change.
pub const default_verify_timeout_ms = 3000;

/// How often a waiting command looks at the model again.
const verify_poll_ms = 50;

pub const not_running = "coastty isn't running";
pub const unverified = "command attempted, but could not verify that coastty applied the change";
pub const nothing_focused = "coastty has no focused window";

/// The skill file teaching agents the layout commands, as shipped in the app bundle.
pub const skill_text = @embedFile("../skills/coastty/SKILL.md");

/// Where `coastty skill install` puts the skill file, below the home folder.
const skill_install_dir = ".claude/skills/coastty";

/// Whether `coastty <command>` is a layout command rather than the app.
pub fn handles(command: []const u8) bool {
    if (std.mem.eql(u8, command, "skill")) return true;
    if (std.mem.eql(u8, command, "focused")) return true;
    return std.meta.stringToEnum(Subject, command) != null;
}

/// Where a command runs from.
pub const Caller = struct {
    socket_path: []const u8,
    /// The pane the command runs in, empty outside coastty.
    pane_id: []const u8,
    cwd: []const u8,
    home: []const u8,
    /// The process group the command leads, null when it runs inside another process's group.
    job: ?u32 = null,
};

pub const Output = struct {
    out: *Io.Writer,
    err: *Io.Writer,
};

pub const exit_ok: u8 = 0;
pub const exit_failed: u8 = 1;
pub const exit_usage: u8 = 2;

/// Why a command stopped, its message already written to stderr.
const Stop = error{ Failed, Usage };

const usage_text =
    \\usage: coastty space new [--name <name>] [--cwd <dir>] [--window <id>] [--focus]
    \\       coastty space close [<id>] [--force]
    \\       coastty space rename [<id>] <name>
    \\       coastty space move [<id>] <position>
    \\       coastty space move [<id>] --window <id> [<position>]
    \\       coastty space focus [<id>]
    \\       coastty tab new [--name <name>] [--cwd <dir>] [--space <id>] [--focus]
    \\       coastty tab close [<id>] [--force]
    \\       coastty tab rename [<id>] <name>
    \\       coastty tab move [<id>] <position>
    \\       coastty tab focus [<id>]
    \\       coastty pane split [<id>] --direction right|down [--cwd <dir>] [--focus]
    \\       coastty pane close [<id>] [--force]
    \\       coastty pane focus [<id>]
    \\       coastty space list [--json]
    \\       coastty tab list [--space <id> | --all] [--json]
    \\       coastty pane list [<tab-id>] [--json]
    \\       coastty window list [--json]
    \\       coastty focused [--json]
    \\       coastty skill [install]
    \\
;

/// What a layout command acts on, named as it is typed.
const Subject = enum {
    space,
    tab,
    pane,
    window,

    /// The `REQUEST` scope that carries it. A window is only ever listed, so it has none.
    fn scope(subject: Subject) wire.Scope {
        return switch (subject) {
            .space => .space,
            .tab => .tab,
            .pane => .pane,
            .window => unreachable,
        };
    }

    /// Whether `command` is one this subject has: a pane is split rather than made new, and has no name or position of its own; a window is only listed.
    fn has(subject: Subject, command: Command) bool {
        return switch (subject) {
            .space, .tab => command != .split,
            .pane => command == .split or command == .close or command == .list or command == .focus,
            .window => command == .list,
        };
    }
};

const Command = enum { new, close, rename, move, split, list, focus };

/// Runs one layout command, `args` being what follows `coastty`, and
/// returns its exit code.
pub fn run(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    args: []const []const u8,
    output: Output,
    verify_timeout_ms: u32,
) u8 {
    dispatch(alloc, io, caller, args, output, verify_timeout_ms) catch |err| {
        output.err.flush() catch {};
        return switch (err) {
            error.Failed => exit_failed,
            error.Usage => exit_usage,
        };
    };
    output.out.flush() catch {};
    return exit_ok;
}

/// Routes `args` to the command it names, rejecting anything unknown as a usage mistake.
fn dispatch(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    args: []const []const u8,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "skill")) return skill(alloc, io, caller, args[1..], output);
    if (args.len > 0 and std.mem.eql(u8, args[0], "focused")) return focused(alloc, io, caller, try parseFocused(args[1..], output.err), output);
    if (args.len < 2) return usage(output.err, "", .{});
    const subject = std.meta.stringToEnum(Subject, args[0]) orelse return usage(output.err, "unknown command: {s}", .{args[0]});
    const command = std.meta.stringToEnum(Command, args[1]) orelse return usage(output.err, "unknown {t} command: {s}", .{ subject, args[1] });
    if (!subject.has(command)) return usage(output.err, "unknown {t} command: {s}", .{ subject, args[1] });

    const rest = args[2..];
    switch (command) {
        .new => switch (subject) {
            .space => return spaceNew(alloc, io, caller, try parseSpaceNew(rest, output.err), output, verify_timeout_ms),
            .tab => return tabNew(alloc, io, caller, try parseTabNew(rest, output.err), output, verify_timeout_ms),
            .pane, .window => unreachable,
        },
        .split => return paneSplit(alloc, io, caller, try parseSplit(rest, output.err), output, verify_timeout_ms),
        .close => return close(alloc, io, caller, subject, try parseClose(rest, subject, caller, output.err), output, verify_timeout_ms),
        .rename => return rename(alloc, io, caller, subject, try parseRename(rest, subject, caller, output.err), output, verify_timeout_ms),
        .move => return move(alloc, io, caller, subject, try parseMove(rest, subject, caller, output.err), output, verify_timeout_ms),
        .list => return list(alloc, io, caller, subject, try parseList(rest, subject, output.err), output),
        .focus => return bringForward(alloc, io, caller, subject, try parseFocus(rest, subject, caller, output.err), output, verify_timeout_ms),
    }
}

/// Writes `fmt` and the usage line to stderr, and stops as a usage mistake.
fn usage(err: *Io.Writer, comptime fmt: []const u8, args: anytype) Stop {
    if (fmt.len > 0) err.print(fmt ++ "\n", args) catch {};
    err.writeAll(usage_text) catch {};
    return error.Usage;
}

/// Writes `fmt` to stderr, and stops as a failure.
fn fail(err: *Io.Writer, comptime fmt: []const u8, args: anytype) Stop {
    err.print(fmt ++ "\n", args) catch {};
    return error.Failed;
}

/// Copies the skill file to `~/.claude/skills/coastty/SKILL.md`, replacing any older copy, and says where.
fn skillInstall(alloc: Allocator, io: Io, caller: Caller, output: Output) Stop!void {
    if (caller.home.len == 0) return fail(output.err, "could not find the home folder", .{});

    const dir = std.fs.path.join(alloc, &.{ caller.home, skill_install_dir }) catch return fail(output.err, "out of memory", .{});
    defer alloc.free(dir);
    const path = std.fs.path.join(alloc, &.{ dir, "SKILL.md" }) catch return fail(output.err, "out of memory", .{});
    defer alloc.free(path);

    Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return fail(output.err, "could not create {s}: {t}", .{ dir, err }),
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = skill_text }) catch |err| {
        return fail(output.err, "could not write {s}: {t}", .{ path, err });
    };
    output.out.print("installed the coastty skill to {s}\n", .{path}) catch {};
}

/// `coastty skill` prints the skill file; `coastty skill install` installs it.
fn skill(alloc: Allocator, io: Io, caller: Caller, args: []const []const u8, output: Output) Stop!void {
    if (args.len == 0) {
        output.out.writeAll(skill_text) catch {};
        return;
    }
    if (args.len > 1) return usage(output.err, "unexpected argument: {s}", .{args[1]});
    if (!std.mem.eql(u8, args[0], "install")) return usage(output.err, "unknown skill command: {s}", .{args[0]});
    return skillInstall(alloc, io, caller, output);
}

const TabNewOptions = struct {
    name: []const u8 = "",
    cwd: []const u8 = "",
    space: []const u8 = "",
    focus: bool = false,
};

/// The value of `--<name> <value>` or `--<name>=<value>` at `args[i.*]`,
/// moving `i` past whatever it consumed; null when the argument is not
/// that option.
fn optionValue(args: []const []const u8, i: *usize, comptime name: []const u8, err: *Io.Writer) Stop!?[]const u8 {
    const arg = args[i.*];
    const flag = "--" ++ name;
    if (std.mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
    if (!std.mem.eql(u8, arg, flag)) return null;

    if (i.* + 1 >= args.len) return usage(err, "{s} needs a value", .{flag});
    i.* += 1;
    return args[i.*];
}

/// Reads the options of `tab new`, rejecting any it doesn't know as a usage mistake.
fn parseTabNew(args: []const []const u8, err: *Io.Writer) Stop!TabNewOptions {
    var options: TabNewOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--focus")) {
            options.focus = true;
            continue;
        }
        if (try optionValue(args, &i, "name", err)) |value| {
            options.name = value;
            continue;
        }
        if (try optionValue(args, &i, "cwd", err)) |value| {
            options.cwd = value;
            continue;
        }
        if (try optionValue(args, &i, "space", err)) |value| {
            options.space = value;
            continue;
        }
        return usage(err, "unknown option: {s}", .{args[i]});
    }
    return options;
}

const SpaceNewOptions = struct {
    name: []const u8 = "",
    cwd: []const u8 = "",
    /// The window the Space joins, empty for the caller's own, else the frontmost.
    window: []const u8 = "",
    focus: bool = false,
};

/// Reads the options of `space new`, rejecting any it doesn't know as a usage mistake.
fn parseSpaceNew(args: []const []const u8, err: *Io.Writer) Stop!SpaceNewOptions {
    var options: SpaceNewOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--focus")) {
            options.focus = true;
            continue;
        }
        if (try optionValue(args, &i, "name", err)) |value| {
            options.name = value;
            continue;
        }
        if (try optionValue(args, &i, "cwd", err)) |value| {
            options.cwd = value;
            continue;
        }
        if (try optionValue(args, &i, "window", err)) |value| {
            options.window = value;
            continue;
        }
        return usage(err, "unknown option: {s}", .{args[i]});
    }
    return options;
}

const SplitOptions = struct {
    /// The pane to split, empty for the caller's own, or the focused one outside coastty.
    id: []const u8 = "",
    direction: wire.SplitDirection,
    cwd: []const u8 = "",
    focus: bool = false,
};

/// Reads `split [<id>] --direction right|down [--cwd <dir>] [--focus]`.
fn parseSplit(args: []const []const u8, err: *Io.Writer) Stop!SplitOptions {
    var id: []const u8 = "";
    var direction: ?wire.SplitDirection = null;
    var cwd: []const u8 = "";
    var focus = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--focus")) {
            focus = true;
            continue;
        }
        if (try optionValue(args, &i, "direction", err)) |value| {
            direction = std.meta.stringToEnum(wire.SplitDirection, value) orelse return usage(err, "--direction must be right or down: {s}", .{value});
            continue;
        }
        if (try optionValue(args, &i, "cwd", err)) |value| {
            cwd = value;
            continue;
        }
        if (std.mem.startsWith(u8, args[i], "--")) return usage(err, "unknown option: {s}", .{args[i]});
        if (id.len > 0) return usage(err, "unexpected argument: {s}", .{args[i]});
        id = args[i];
    }

    return .{
        .id = id,
        .direction = direction orelse return usage(err, "--direction is required", .{}),
        .cwd = cwd,
        .focus = focus,
    };
}

const CloseOptions = struct {
    /// The Space, tab or pane to close, empty for the caller's own.
    id: []const u8 = "",
    force: bool = false,
};

const RenameOptions = struct {
    id: []const u8 = "",
    name: []const u8,
};

const MoveOptions = struct {
    id: []const u8 = "",
    /// 1-based, as typed; null only with `window`, for after the window's last Space.
    position: ?usize,
    /// The window a Space moves to, empty to stay in its own.
    window: []const u8 = "",
};

/// Fails as a usage mistake when a command run outside coastty names no
/// Space, tab or pane, since there is none of the caller's own to default to.
fn requireId(id: []const u8, subject: Subject, caller: Caller, err: *Io.Writer) Stop!void {
    if (id.len > 0 or caller.pane_id.len > 0) return;
    return usage(err, "outside coastty, a {t} id is required", .{subject});
}

/// Reads `close [<id>] [--force]`.
fn parseClose(args: []const []const u8, subject: Subject, caller: Caller, err: *Io.Writer) Stop!CloseOptions {
    var options: CloseOptions = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return usage(err, "unknown option: {s}", .{arg});
        if (options.id.len > 0) return usage(err, "unexpected argument: {s}", .{arg});
        options.id = arg;
    }
    try requireId(options.id, subject, caller, err);
    return options;
}

/// Splits `[<id>] <value>` into the id, empty when left out, and the
/// value. Every argument is positional, so a name may start with a dash.
fn idAndValue(args: []const []const u8, comptime value_name: []const u8, err: *Io.Writer) Stop!struct { id: []const u8, value: []const u8 } {
    return switch (args.len) {
        1 => .{ .id = "", .value = args[0] },
        2 => .{ .id = args[0], .value = args[1] },
        0 => usage(err, "missing " ++ value_name, .{}),
        else => usage(err, "unexpected argument: {s}", .{args[2]}),
    };
}

/// Reads `rename [<id>] <name>`.
fn parseRename(args: []const []const u8, subject: Subject, caller: Caller, err: *Io.Writer) Stop!RenameOptions {
    const parsed = try idAndValue(args, "name", err);
    try requireId(parsed.id, subject, caller, err);
    return .{ .id = parsed.id, .name = parsed.value };
}

/// Reads a 1-based position as typed.
fn parsePosition(value: []const u8, err: *Io.Writer) Stop!usize {
    const position = std.fmt.parseInt(usize, value, 10) catch 0;
    if (position == 0) return usage(err, "position must be a number from 1: {s}", .{value});
    return position;
}

/// Reads `move [<id>] <position>`, or for a Space `move [<id>] --window <id> [<position>]`.
fn parseMove(args: []const []const u8, subject: Subject, caller: Caller, err: *Io.Writer) Stop!MoveOptions {
    var window: []const u8 = "";
    var positional_buf: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (subject == .space) {
            if (try optionValue(args, &i, "window", err)) |value| {
                window = value;
                continue;
            }
        }
        if (positional_count == positional_buf.len) return usage(err, "unexpected argument: {s}", .{args[i]});
        positional_buf[positional_count] = args[i];
        positional_count += 1;
    }
    const positionals = positional_buf[0..positional_count];

    if (window.len == 0) {
        const parsed = try idAndValue(positionals, "position", err);
        try requireId(parsed.id, subject, caller, err);
        return .{ .id = parsed.id, .position = try parsePosition(parsed.value, err) };
    }

    // Space ids are never plain numbers, so a lone number is the position and anything else the Space.
    var options: MoveOptions = .{ .position = null, .window = window };
    switch (positionals.len) {
        0 => {},
        1 => {
            const lone = positionals[0];
            if (std.fmt.parseInt(usize, lone, 10)) |_| {
                options.position = try parsePosition(lone, err);
            } else |_| {
                options.id = lone;
            }
        },
        else => {
            options.id = positionals[0];
            options.position = try parsePosition(positionals[1], err);
        },
    }
    try requireId(options.id, subject, caller, err);
    return options;
}

/// Reads `focus [<id>]`, returning the id, empty for the caller's own.
fn parseFocus(args: []const []const u8, subject: Subject, caller: Caller, err: *Io.Writer) Stop![]const u8 {
    var id: []const u8 = "";
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) return usage(err, "unknown option: {s}", .{arg});
        if (id.len > 0) return usage(err, "unexpected argument: {s}", .{arg});
        id = arg;
    }
    try requireId(id, subject, caller, err);
    return id;
}

const ListOptions = struct {
    /// The Space whose tabs, or the tab whose panes, to list; empty for the caller's own.
    id: []const u8 = "",
    /// Every tab of every Space.
    all: bool = false,
    json: bool = false,
};

/// Reads `space list [--json]`, `tab list [--space <id> | --all] [--json]`, `pane list [<tab-id>] [--json]` or `window list [--json]`.
fn parseList(args: []const []const u8, subject: Subject, err: *Io.Writer) Stop!ListOptions {
    var options: ListOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            options.json = true;
            continue;
        }
        if (subject == .tab) {
            if (std.mem.eql(u8, args[i], "--all")) {
                options.all = true;
                continue;
            }
            if (try optionValue(args, &i, "space", err)) |value| {
                options.id = value;
                continue;
            }
        }
        if (std.mem.startsWith(u8, args[i], "--")) return usage(err, "unknown option: {s}", .{args[i]});
        // Only a pane list names what it lists by position: the tab.
        if (subject != .pane or options.id.len > 0) return usage(err, "unexpected argument: {s}", .{args[i]});
        options.id = args[i];
    }

    switch (subject) {
        // Every Space and every window is listed, so none needs naming.
        .space, .window => {},
        .tab => if (options.all and options.id.len > 0) return usage(err, "--space and --all can't be combined", .{}),
        // Outside coastty, a list naming nothing falls back to the focused Space or tab when it runs.
        .pane => {},
    }
    return options;
}

/// The directory a new tab or split starts in: `--cwd` relative to where
/// the command runs, else the caller's own directory inside coastty and
/// the home folder outside it. The caller frees it.
fn startDirectory(alloc: Allocator, caller: Caller, cwd_option: []const u8) error{ OutOfMemory, NoCwd }![]u8 {
    // An absolute --cwd needs nothing of where the command runs.
    if (std.fs.path.isAbsolute(cwd_option)) return std.fs.path.resolve(alloc, &.{cwd_option});

    // Outside coastty with no --cwd, the command's own directory doesn't matter.
    if (cwd_option.len == 0 and caller.pane_id.len == 0) {
        if (caller.home.len > 0) return alloc.dupe(u8, caller.home);
        return alloc.dupe(u8, "/");
    }

    // A relative --cwd, or the caller's own directory, needs to know where the command runs.
    if (caller.cwd.len == 0) return error.NoCwd;
    if (cwd_option.len > 0) return std.fs.path.resolve(alloc, &.{ caller.cwd, cwd_option });
    return alloc.dupe(u8, caller.cwd);
}

/// Asks for a tab at the end of a Space - the one named, else the caller's own, else the focused one outside coastty - waits until the model holds it, and prints its id.
fn tabNew(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    options: TabNewOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const directory = startDirectory(alloc, caller, options.cwd) catch |err| switch (err) {
        error.OutOfMemory => return fail(output.err, "out of memory", .{}),
        error.NoCwd => return fail(output.err, "could not read the current directory", .{}),
    };
    defer alloc.free(directory);

    const focus: []const u8 = if (options.focus) "1" else "0";
    const fields = [_][]const u8{ options.space, caller.pane_id, options.name, directory, focus };
    var reply = try request(alloc, io, caller.socket_path, .tab, "new", &fields, output.err);
    defer reply.deinit(alloc);

    const tab_id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a tab id", .{});
    try waitFor(alloc, io, caller.socket_path, .tab, tab_id, .present, verify_timeout_ms, output.err);
    output.out.print("{s}\n", .{tab_id}) catch {};
}

/// Asks for a Space with one starter tab - in the window named, else the
/// caller's own, else the frontmost - waits until the model holds the tab,
/// and prints both ids on one line.
fn spaceNew(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    options: SpaceNewOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const directory = startDirectory(alloc, caller, options.cwd) catch |err| switch (err) {
        error.OutOfMemory => return fail(output.err, "out of memory", .{}),
        error.NoCwd => return fail(output.err, "could not read the current directory", .{}),
    };
    defer alloc.free(directory);

    const focus: []const u8 = if (options.focus) "1" else "0";
    const fields = [_][]const u8{ "", caller.pane_id, options.name, directory, focus, options.window };
    var reply = try request(alloc, io, caller.socket_path, .space, "new", &fields, output.err);
    defer reply.deinit(alloc);

    const space_id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a space id", .{});
    const tab_id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a tab id", .{});
    // The starter tab only shows up once its Space has.
    try waitFor(alloc, io, caller.socket_path, .tab, tab_id, .present, verify_timeout_ms, output.err);
    output.out.print("{s} {s}\n", .{ space_id, tab_id }) catch {};
}

/// Asks for a pane beside the target - the one named, else the caller's own, else the focused one outside coastty - waits until the model holds it, and prints its id.
fn paneSplit(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    options: SplitOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const directory = startDirectory(alloc, caller, options.cwd) catch |err| switch (err) {
        error.OutOfMemory => return fail(output.err, "out of memory", .{}),
        error.NoCwd => return fail(output.err, "could not read the current directory", .{}),
    };
    defer alloc.free(directory);

    const focus: []const u8 = if (options.focus) "1" else "0";
    const fields = [_][]const u8{ options.id, caller.pane_id, @tagName(options.direction), directory, focus };
    var reply = try request(alloc, io, caller.socket_path, .pane, "split", &fields, output.err);
    defer reply.deinit(alloc);

    const pane_id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a pane id", .{});
    try waitFor(alloc, io, caller.socket_path, .pane, pane_id, .present, verify_timeout_ms, output.err);
    output.out.print("{s}\n", .{pane_id}) catch {};
}

/// Asks for a Space, tab or pane to close, waits until the model no longer
/// holds it, and prints what was closed and, when forced, what that ended.
fn close(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    subject: Subject,
    options: CloseOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const force: []const u8 = if (options.force) "1" else "0";

    var job_buf: [10]u8 = undefined;
    const job: []const u8 = if (caller.job) |pgid| std.fmt.bufPrint(&job_buf, "{d}", .{pgid}) catch unreachable else "";
    const fields = [_][]const u8{ options.id, caller.pane_id, force, job };
    var reply = try request(alloc, io, caller.socket_path, subject.scope(), "close", &fields, output.err);
    defer reply.deinit(alloc);

    const id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a {t} id", .{subject});
    const ended = reply.ids.rest();
    try waitFor(alloc, io, caller.socket_path, subject, id, .gone, verify_timeout_ms, output.err);

    if (ended.len == 0) {
        output.out.print("closed {t} {s}\n", .{ subject, id }) catch {};
        return;
    }
    output.out.print("closed {t} {s} (ended {s})\n", .{ subject, id, ended }) catch {};
}

/// Asks for a Space's or tab's name to change, waits until the model shows
/// it, and says so.
fn rename(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    subject: Subject,
    options: RenameOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const fields = [_][]const u8{ options.id, caller.pane_id, options.name };
    var reply = try request(alloc, io, caller.socket_path, subject.scope(), "rename", &fields, output.err);
    defer reply.deinit(alloc);

    const id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a {t} id", .{subject});
    try waitFor(alloc, io, caller.socket_path, subject, id, .{ .named = options.name }, verify_timeout_ms, output.err);
    output.out.print("renamed {t} {s} to \"{s}\"\n", .{ subject, id, options.name }) catch {};
}

/// Asks for a Space to move to another window, at a position among that
/// window's visible Spaces or after the last, waits until the app reports
/// it there, and says so.
fn moveToWindow(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    options: MoveOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    var index_buf: [20]u8 = undefined;
    // The daemon counts from 0, and an empty index lands the Space last.
    const index_field: []const u8 = if (options.position) |position| std.fmt.bufPrint(&index_buf, "{d}", .{position - 1}) catch unreachable else "";
    const fields = [_][]const u8{ options.id, caller.pane_id, index_field, options.window };
    var reply = try request(alloc, io, caller.socket_path, .space, "move", &fields, output.err);
    defer reply.deinit(alloc);

    const id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a space id", .{});
    const landing = std.fmt.parseInt(usize, reply.ids.next() orelse "", 10) catch return fail(output.err, "coastty-host answered without a position", .{});
    try waitFor(alloc, io, caller.socket_path, .space, id, .{ .in_window = .{ .window = options.window, .at = landing } }, verify_timeout_ms, output.err);
    output.out.print("moved space {s} to window {s} at {d}\n", .{ id, options.window, landing + 1 }) catch {};
}

/// Asks for a tab to move within its Space, or a Space among the visible
/// ones or to another window, waits until it shows there, and says so.
fn move(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    subject: Subject,
    options: MoveOptions,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    if (options.window.len > 0) return moveToWindow(alloc, io, caller, options, output, verify_timeout_ms);

    // Without a window a position is always given; the model counts from 0, people from 1.
    const index = (options.position orelse return usage(output.err, "missing position", .{})) - 1;

    var index_buf: [20]u8 = undefined;
    const index_field = std.fmt.bufPrint(&index_buf, "{d}", .{index}) catch unreachable;
    const fields = [_][]const u8{ options.id, caller.pane_id, index_field };
    var reply = try request(alloc, io, caller.socket_path, subject.scope(), "move", &fields, output.err);
    defer reply.deinit(alloc);

    const id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a {t} id", .{subject});
    try waitFor(alloc, io, caller.socket_path, subject, id, .{ .at = index }, verify_timeout_ms, output.err);
    output.out.print("moved {t} {s} to {d}\n", .{ subject, id, index + 1 }) catch {};
}

/// Asks for a Space, tab or pane to be brought to the front, waits until the focus the app reports shows it, and says so.
fn bringForward(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    subject: Subject,
    id: []const u8,
    output: Output,
    verify_timeout_ms: u32,
) Stop!void {
    const fields = [_][]const u8{ id, caller.pane_id };
    var reply = try request(alloc, io, caller.socket_path, subject.scope(), "focus", &fields, output.err);
    defer reply.deinit(alloc);

    const focused_id = reply.ids.next() orelse return fail(output.err, "coastty-host answered without a {t} id", .{subject});
    try waitFor(alloc, io, caller.socket_path, subject, focused_id, .focused, verify_timeout_ms, output.err);
    output.out.print("focused {t} {s}\n", .{ subject, focused_id }) catch {};
}

/// Reads `focused [--json]`.
fn parseFocused(args: []const []const u8, err: *Io.Writer) Stop!bool {
    var json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return usage(err, "unknown option: {s}", .{arg});
        return usage(err, "unexpected argument: {s}", .{arg});
    }
    return json;
}

/// What `focused` prints: the Space, tab and pane the user was last in, each with the name the sidebar shows for it.
const FocusedView = struct {
    space: Named,
    tab: Named,
    pane: struct { id: []const u8, title: []const u8, directory: []const u8 },

    const Named = struct { id: []const u8, name: []const u8 };
};

/// Prints the Space, tab and pane the user was last in, with their names, as a table or as JSON with `--json`.
fn focused(alloc: Allocator, io: Io, caller: Caller, json: bool, output: Output) Stop!void {
    const body = fetchFocus(alloc, io, caller.socket_path) orelse return fail(output.err, not_running, .{});
    defer alloc.free(body);
    const focus = Focused.parse(body) orelse return fail(output.err, nothing_focused, .{});

    const document = fetchModel(alloc, io, caller.socket_path) orelse return fail(output.err, not_running, .{});
    defer alloc.free(document);
    const parsed = std.json.parseFromSlice(ModelView, alloc, document, .{ .ignore_unknown_fields = true }) catch {
        return fail(output.err, "coastty-host answered with a model that could not be read", .{});
    };
    defer parsed.deinit();

    // The model may have moved on between the two reads, so anything it no longer holds is shown by id alone.
    const space = findSpaceView(parsed.value, focus.space);
    const tab = if (space) |s| findTabView(s, focus.tab) else null;
    const pane = if (tab) |t| findPaneView(t, focus.pane) else null;
    const pane_title = if (pane) |p| p.title else "";
    const view: FocusedView = .{
        .space = .{ .id = focus.space, .name = if (space) |s| s.shownName() else "" },
        .tab = .{ .id = focus.tab, .name = if (tab) |t| t.shownName(pane_title) else "" },
        .pane = .{ .id = focus.pane, .title = pane_title, .directory = if (pane) |p| p.directory else "" },
    };

    if (json) return writeJson(output.out, view);
    writeTable(output.out, &.{ "KIND", "ID", "NAME" }, &.{
        &.{ "space", view.space.id, view.space.name },
        &.{ "tab", view.tab.id, view.tab.name },
        &.{ "pane", view.pane.id, view.pane.title },
    }) catch {};
}

/// Prints the Spaces, tabs or panes the model holds, or the windows the app
/// reports, as a table or as JSON with `--json`, marking the caller's own
/// and the focused one. Needs only the daemon, not the app, though windows
/// are only known while the app is connected.
fn list(
    alloc: Allocator,
    io: Io,
    caller: Caller,
    subject: Subject,
    options: ListOptions,
    output: Output,
) Stop!void {
    const document = fetchModel(alloc, io, caller.socket_path) orelse return fail(output.err, not_running, .{});
    defer alloc.free(document);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = std.json.parseFromSliceLeaky(ModelView, arena, document, .{ .ignore_unknown_fields = true }) catch {
        return fail(output.err, "coastty-host answered with a model that could not be read", .{});
    };

    // A daemon gone between the reads just marks nothing as focused and shows no windows.
    const focus_body = fetchFocus(arena, io, caller.socket_path) orelse "";
    const marks: Marks = .{ .caller = caller.pane_id, .focus = Focused.parse(focus_body) orelse .{} };
    const windows_body = fetchWindows(arena, io, caller.socket_path) orelse "";

    const listed = switch (subject) {
        .space => listSpaces(arena, model, marks, windows_body, options, output.out),
        .tab => listTabs(arena, model, caller, marks, options, output.out),
        .pane => listPanes(arena, model, caller, marks, options, output.out),
        .window => listWindows(arena, model, marks, windows_body, options, output.out),
    };
    listed catch |err| switch (err) {
        error.OutOfMemory => return fail(output.err, "out of memory", .{}),
        error.NoSuchSpace => return fail(output.err, "no such space", .{}),
        error.NoSuchTab => return fail(output.err, "no such tab", .{}),
        error.NoSuchPane => return fail(output.err, "no such pane", .{}),
        error.NothingFocused => return fail(output.err, nothing_focused, .{}),
    };
}

const ListError = error{ OutOfMemory, NoSuchSpace, NoSuchTab, NoSuchPane, NothingFocused };

/// What a list names when the command named nothing: the caller's own inside coastty, else the focused one, else nothing to list.
fn listedId(named: []const u8, caller: Caller, focus_id: []const u8) ListError![]const u8 {
    if (named.len > 0 or caller.pane_id.len > 0) return named;
    if (focus_id.len == 0) return error.NothingFocused;
    return focus_id;
}

/// The Space, tab and pane the user was last in, borrowed from a `FOCUSED` answer; all empty when nothing is focused.
const Focused = struct {
    space: []const u8 = "",
    tab: []const u8 = "",
    pane: []const u8 = "",

    /// The focus a `FOCUSED` body holds, or null when it holds none.
    fn parse(body: []const u8) ?Focused {
        var fields: wire.FieldIterator = .init(body);
        const focus: Focused = .{
            .space = fields.next() orelse "",
            .tab = fields.next() orelse "",
            .pane = fields.next() orelse "",
        };
        if (focus.space.len == 0 or focus.tab.len == 0 or focus.pane.len == 0) return null;
        return focus;
    }
};

/// What a list marks: what holds the pane the command runs in, and what the user was last in.
const Marks = struct {
    /// The caller's pane, empty outside coastty.
    caller: []const u8,
    focus: Focused,
};

/// The marker column's cell: `*` for the caller's own, `>` for the focused one.
fn markerText(caller: bool, focus: bool) []const u8 {
    if (caller and focus) return "*>";
    if (caller) return "*";
    if (focus) return ">";
    return "";
}

const SpaceRow = struct {
    id: []const u8,
    name: []const u8,
    tabs: usize,
    hidden: bool,
    /// The window showing it, empty when no window does or the app isn't connected.
    window: []const u8,
    /// Holds the pane the command runs in.
    caller: bool,
    /// The Space the user was last in.
    focused: bool,
};

/// Prints every Space, hidden ones included, with the window showing it, marking the one holding the caller and the focused one.
fn listSpaces(arena: Allocator, model: ModelView, marks: Marks, windows_body: []const u8, options: ListOptions, out: *Io.Writer) ListError!void {
    const rows = try arena.alloc(SpaceRow, model.spaces.len);
    for (model.spaces, rows) |space, *row| {
        const window: []const u8 = if (wire.WindowIterator.holding(windows_body, space.id)) |shown| shown.id else "";
        row.* = .{
            .id = space.id,
            .name = space.shownName(),
            .tabs = space.tabs.len,
            .hidden = space.hidden,
            .window = window,
            .caller = marks.caller.len > 0 and spaceHoldsPane(space, marks.caller),
            .focused = std.mem.eql(u8, space.id, marks.focus.space),
        };
    }
    if (options.json) return writeJson(out, rows);

    const cells = try arena.alloc([]const []const u8, rows.len);
    for (rows, cells) |row, *cell| {
        const hidden: []const u8 = if (row.hidden) "yes" else "no";
        cell.* = try arena.dupe([]const u8, &.{ markerText(row.caller, row.focused), row.id, row.name, try countText(arena, row.tabs), row.window, hidden });
    }
    writeTable(out, &.{ "", "ID", "NAME", "TABS", "WINDOW", "HIDDEN" }, cells) catch {};
}

const WindowRow = struct {
    id: []const u8,
    /// The Space showing in it, empty when none is.
    active: []const u8,
    /// Every Space it shows, in order.
    spaces: []const []const u8,
    /// Shows the Space holding the pane the command runs in.
    caller: bool,
    /// Shows the Space the user was last in.
    focused: bool,
};

/// Prints every window the app reports with the Spaces it shows and its active one, marking the one holding the caller and the focused one.
fn listWindows(arena: Allocator, model: ModelView, marks: Marks, windows_body: []const u8, options: ListOptions, out: *Io.Writer) ListError!void {
    // The Space holding the caller's pane, so a window showing it can be marked.
    var caller_space: []const u8 = "";
    if (marks.caller.len > 0) {
        for (model.spaces) |space| {
            if (spaceHoldsPane(space, marks.caller)) caller_space = space.id;
        }
    }

    var rows: std.ArrayList(WindowRow) = .empty;
    var windows: wire.WindowIterator = .init(windows_body);
    while (windows.next()) |window| {
        var spaces: std.ArrayList([]const u8) = .empty;
        var ids = window.spaceIds();
        while (ids.next()) |id| try spaces.append(arena, id);

        try rows.append(arena, .{
            .id = window.id,
            .active = window.active,
            .spaces = spaces.items,
            .caller = caller_space.len > 0 and window.shows(caller_space),
            .focused = marks.focus.space.len > 0 and window.shows(marks.focus.space),
        });
    }
    if (options.json) return writeJson(out, rows.items);

    const cells = try arena.alloc([]const []const u8, rows.items.len);
    for (rows.items, cells) |row, *cell| {
        const spaces = try std.mem.join(arena, ",", row.spaces);
        cell.* = try arena.dupe([]const u8, &.{ markerText(row.caller, row.focused), row.id, row.active, spaces });
    }
    writeTable(out, &.{ "", "ID", "ACTIVE", "SPACES" }, cells) catch {};
}

const TabRow = struct {
    id: []const u8,
    name: []const u8,
    space: []const u8,
    panes: usize,
    /// 1-based within its Space.
    position: usize,
    /// Holds the pane the command runs in.
    caller: bool,
    /// The tab the user was last in.
    focused: bool,
};

/// Adds a row for each of `space`'s tabs, in order.
fn appendTabRows(arena: Allocator, rows: *std.ArrayList(TabRow), space: SpaceView, marks: Marks) error{OutOfMemory}!void {
    for (space.tabs, 1..) |tab, position| {
        try rows.append(arena, .{
            .id = tab.id,
            .name = tab.shownName(if (tab.panes.len > 0) tab.panes[0].title else ""),
            .space = space.id,
            .panes = tab.panes.len,
            .position = position,
            .caller = marks.caller.len > 0 and holdsPane(tab.panes, marks.caller),
            .focused = std.mem.eql(u8, tab.id, marks.focus.tab),
        });
    }
}

/// Prints the tabs of the caller's Space, the one `--space` names, or every
/// Space with `--all`. Only `--all` shows which Space each tab is in.
fn listTabs(arena: Allocator, model: ModelView, caller: Caller, marks: Marks, options: ListOptions, out: *Io.Writer) ListError!void {
    var rows: std.ArrayList(TabRow) = .empty;
    if (options.all) {
        for (model.spaces) |space| try appendTabRows(arena, &rows, space, marks);
    } else {
        try appendTabRows(arena, &rows, try listedSpace(model, caller, try listedId(options.id, caller, marks.focus.space)), marks);
    }
    if (options.json) return writeJson(out, rows.items);

    const cells = try arena.alloc([]const []const u8, rows.items.len);
    for (rows.items, cells) |row, *cell| {
        const marker = markerText(row.caller, row.focused);
        const panes = try countText(arena, row.panes);
        const position = try countText(arena, row.position);
        if (options.all) {
            cell.* = try arena.dupe([]const u8, &.{ marker, row.id, row.name, row.space, panes, position });
            continue;
        }
        cell.* = try arena.dupe([]const u8, &.{ marker, row.id, row.name, panes, position });
    }

    const header: []const []const u8 = if (options.all) &.{ "", "ID", "NAME", "SPACE", "PANES", "POSITION" } else &.{ "", "ID", "NAME", "PANES", "POSITION" };
    writeTable(out, header, cells) catch {};
}

const PaneRow = struct {
    id: []const u8,
    /// The pane the command runs in.
    caller: bool,
    /// The pane the user was last in.
    focused: bool,
};

/// Prints the panes of the caller's tab, or of the tab named.
fn listPanes(arena: Allocator, model: ModelView, caller: Caller, marks: Marks, options: ListOptions, out: *Io.Writer) ListError!void {
    const tab = try listedTab(model, caller, try listedId(options.id, caller, marks.focus.tab));

    const rows = try arena.alloc(PaneRow, tab.panes.len);
    for (tab.panes, rows) |pane, *row| {
        row.* = .{
            .id = pane.id,
            .caller = std.mem.eql(u8, pane.id, marks.caller),
            .focused = std.mem.eql(u8, pane.id, marks.focus.pane),
        };
    }
    if (options.json) return writeJson(out, rows);

    const cells = try arena.alloc([]const []const u8, rows.len);
    for (rows, cells) |row, *cell| cell.* = try arena.dupe([]const u8, &.{ markerText(row.caller, row.focused), row.id });
    writeTable(out, &.{ "", "ID" }, cells) catch {};
}

/// The Space with this id, else the one holding the caller's pane.
fn listedSpace(model: ModelView, caller: Caller, id: []const u8) ListError!SpaceView {
    for (model.spaces) |space| {
        if (id.len > 0 and std.mem.eql(u8, space.id, id)) return space;
        if (id.len == 0 and spaceHoldsPane(space, caller.pane_id)) return space;
    }
    if (id.len > 0) return error.NoSuchSpace;
    return error.NoSuchPane;
}

/// The tab with this id, else the one holding the caller's pane.
fn listedTab(model: ModelView, caller: Caller, id: []const u8) ListError!TabView {
    for (model.spaces) |space| {
        for (space.tabs) |tab| {
            if (id.len > 0 and std.mem.eql(u8, tab.id, id)) return tab;
            if (id.len == 0 and holdsPane(tab.panes, caller.pane_id)) return tab;
        }
    }
    if (id.len > 0) return error.NoSuchTab;
    return error.NoSuchPane;
}

/// Whether any tab of `space` holds the pane with this id.
fn spaceHoldsPane(space: SpaceView, id: []const u8) bool {
    for (space.tabs) |tab| {
        if (holdsPane(tab.panes, id)) return true;
    }
    return false;
}

/// `count` as text a table cell can hold.
fn countText(arena: Allocator, count: usize) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{count});
}

/// Writes `rows` as an indented JSON array on a line of its own.
fn writeJson(out: *Io.Writer, rows: anytype) void {
    std.json.Stringify.value(rows, .{ .whitespace = .indent_2 }, out) catch return;
    out.writeAll("\n") catch {};
}

/// Writes `header` and `rows` as columns two spaces apart, each as wide as
/// its widest cell, the last left unpadded.
fn writeTable(out: *Io.Writer, header: []const []const u8, rows: []const []const []const u8) Io.Writer.Error!void {
    var widths: [8]usize = @splat(0);
    std.debug.assert(header.len <= widths.len);
    for (header, 0..) |cell, column| widths[column] = cellWidth(cell);
    for (rows) |row| {
        for (row, 0..) |cell, column| widths[column] = @max(widths[column], cellWidth(cell));
    }

    try writeTableRow(out, header, widths[0..header.len]);
    for (rows) |row| try writeTableRow(out, row, widths[0..header.len]);
}

/// Writes one table line, padding every cell but the last to its column's width.
fn writeTableRow(out: *Io.Writer, row: []const []const u8, widths: []const usize) Io.Writer.Error!void {
    for (row, widths, 0..) |cell, width, column| {
        try out.writeAll(cell);
        if (column + 1 == row.len) break;
        try out.splatByteAll(' ', width - cellWidth(cell) + 2);
    }
    try out.writeAll("\n");
}

/// How many columns `cell` takes: one per code point, so a name with accents lines up.
fn cellWidth(cell: []const u8) usize {
    return std.unicode.utf8CountCodepoints(cell) catch cell.len;
}

/// The ids an accepted request was answered with, in order.
const Reply = struct {
    line: []u8,
    ids: std.mem.TokenIterator(u8, .scalar),

    /// Frees the answer line the ids borrow from.
    fn deinit(self: *Reply, alloc: Allocator) void {
        alloc.free(self.line);
    }
};

/// Sends one `REQUEST` and returns what an `OK` carried. A refusal is
/// written to stderr as a failure.
fn request(
    alloc: Allocator,
    io: Io,
    socket_path: []const u8,
    scope: wire.Scope,
    op: []const u8,
    fields: []const []const u8,
    err: *Io.Writer,
) Stop!Reply {
    const conn = access.connect(io, socket_path) orelse return fail(err, not_running, .{});
    defer conn.close(io);

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeRequest(&w.interface, scope, op, fields) catch return fail(err, not_running, .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const line = (wire.readHeader(alloc, &r.interface) catch null) orelse return fail(err, not_running, .{});
    errdefer alloc.free(line);

    if (std.mem.startsWith(u8, line, "ERR ")) {
        const reason = line["ERR ".len..];
        if (std.mem.eql(u8, reason, "app not running")) return fail(err, not_running, .{});
        if (std.mem.eql(u8, reason, "nothing focused")) return fail(err, nothing_focused, .{});
        return fail(err, "{s}", .{reason});
    }
    if (!std.mem.startsWith(u8, line, "OK")) return fail(err, "coastty-host answered something unexpected: {s}", .{line});

    var ids = std.mem.tokenizeScalar(u8, line, ' ');
    _ = ids.next();
    return .{ .line = line, .ids = ids };
}

/// What the model must show of a Space, tab or pane for a command to count as done.
const Condition = union(enum) {
    present,
    gone,
    named: []const u8,
    /// At this 0-based position: a tab within its Space, a Space among the visible ones.
    at: usize,
    /// A Space the app reports in this window, at this 0-based position among its visible Spaces.
    in_window: struct { window: []const u8, at: usize },
    /// What the app reports the user is in: the Space itself, the tab itself, or the pane itself.
    focused,
};

/// Looks at the model until it shows `condition` for the Space, tab or
/// pane with this id, failing once `timeout_ms` has gone by without it.
fn waitFor(
    alloc: Allocator,
    io: Io,
    socket_path: []const u8,
    subject: Subject,
    id: []const u8,
    condition: Condition,
    timeout_ms: u32,
    err: *Io.Writer,
) Stop!void {
    const start = Io.Timestamp.now(io, .awake);
    while (true) {
        const shown = switch (condition) {
            .in_window => |placed| windowShows(alloc, io, socket_path, id, placed.window, placed.at),
            .focused => focusShows(alloc, io, socket_path, subject, id),
            else => modelShows(alloc, io, socket_path, subject, id, condition),
        };
        if (shown) return;

        const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
        if (elapsed.toMilliseconds() >= timeout_ms) return fail(err, unverified, .{});
        Io.sleep(io, .fromMilliseconds(verify_poll_ms), .awake) catch return fail(err, unverified, .{});
    }
}

/// What a waiting or listing command reads of the model document.
const ModelView = struct {
    spaces: []const SpaceView,
};

const SpaceView = struct {
    id: []const u8,
    name: []const u8,
    default_name: []const u8 = "",
    hidden: bool,
    tabs: []const TabView,

    /// The name the sidebar shows: the user's own, else the one its starter pane's directory gave it.
    fn shownName(space: SpaceView) []const u8 {
        if (space.name.len > 0) return space.name;
        return space.default_name;
    }
};

const TabView = struct {
    id: []const u8,
    name: []const u8,
    panes: []const PaneView,

    /// The name the tab bar shows: the user's own, else the title of the pane it is looking at.
    fn shownName(tab: TabView, pane_title: []const u8) []const u8 {
        if (tab.name.len > 0) return tab.name;
        return pane_title;
    }
};

const PaneView = struct {
    id: []const u8,
    /// The live terminal title, empty until something sets one.
    title: []const u8 = "",
    directory: []const u8 = "",
};

/// Whether the daemon's model currently shows `condition` for the Space,
/// tab or pane with this id. A model that can't be fetched or read shows
/// nothing yet.
fn modelShows(alloc: Allocator, io: Io, socket_path: []const u8, subject: Subject, id: []const u8, condition: Condition) bool {
    const document = fetchModel(alloc, io, socket_path) orelse return false;
    defer alloc.free(document);

    const parsed = std.json.parseFromSlice(ModelView, alloc, document, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    var visible_count: usize = 0;
    for (parsed.value.spaces) |space| {
        const visible_index = visible_count;
        if (!space.hidden) visible_count += 1;

        if (subject == .space) {
            if (!std.mem.eql(u8, space.id, id)) continue;
            return switch (condition) {
                .present => true,
                .gone => false,
                .named => |name| std.mem.eql(u8, space.name, name),
                .at => |at| !space.hidden and visible_index == at,
                .in_window, .focused => false,
            };
        }

        for (space.tabs, 0..) |tab, index| {
            if (subject == .pane) {
                if (!holdsPane(tab.panes, id)) continue;
                // A pane has no name or position a command waits on.
                return condition == .present;
            }

            if (!std.mem.eql(u8, tab.id, id)) continue;
            return switch (condition) {
                .present => true,
                .gone => false,
                .named => |name| std.mem.eql(u8, tab.name, name),
                .at => |at| index == at,
                .in_window, .focused => false,
            };
        }
    }
    return condition == .gone;
}

/// Whether the app currently reports the Space with this id in the window `window_id`, at 0-based position `at` among that window's visible Spaces. A model or report that can't be fetched shows nothing yet.
fn windowShows(alloc: Allocator, io: Io, socket_path: []const u8, space_id: []const u8, window_id: []const u8, at: usize) bool {
    const windows_body = fetchWindows(alloc, io, socket_path) orelse return false;
    defer alloc.free(windows_body);
    const window = wire.WindowIterator.find(windows_body, window_id) orelse return false;

    const document = fetchModel(alloc, io, socket_path) orelse return false;
    defer alloc.free(document);
    const parsed = std.json.parseFromSlice(ModelView, alloc, document, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    var visible_index: usize = 0;
    var ids = window.spaceIds();
    while (ids.next()) |id| {
        if (std.mem.eql(u8, id, space_id)) return visible_index == at;
        // Only visible Spaces the model holds count towards a position.
        const space = findSpaceView(parsed.value, id) orelse continue;
        if (space.hidden) continue;
        visible_index += 1;
    }
    return false;
}

/// Whether the focus the app reports is on the Space, tab or pane with this id. A focus that can't be fetched shows nothing yet.
fn focusShows(alloc: Allocator, io: Io, socket_path: []const u8, subject: Subject, id: []const u8) bool {
    const body = fetchFocus(alloc, io, socket_path) orelse return false;
    defer alloc.free(body);
    const focus = Focused.parse(body) orelse return false;

    const shown = switch (subject) {
        .space => focus.space,
        .tab => focus.tab,
        .pane => focus.pane,
        .window => unreachable,
    };
    return std.mem.eql(u8, shown, id);
}

/// The Space with this id in `model`, or null when it holds none.
fn findSpaceView(model: ModelView, id: []const u8) ?SpaceView {
    for (model.spaces) |space| {
        if (std.mem.eql(u8, space.id, id)) return space;
    }
    return null;
}

/// The tab with this id in `space`, if it holds one.
fn findTabView(space: SpaceView, id: []const u8) ?TabView {
    for (space.tabs) |tab| {
        if (std.mem.eql(u8, tab.id, id)) return tab;
    }
    return null;
}

/// The pane with this id in `tab`, if it holds one.
fn findPaneView(tab: TabView, id: []const u8) ?PaneView {
    for (tab.panes) |pane| {
        if (std.mem.eql(u8, pane.id, id)) return pane;
    }
    return null;
}

/// Whether `panes` holds the pane with this id.
fn holdsPane(panes: []const PaneView, id: []const u8) bool {
    for (panes) |pane| {
        if (std.mem.eql(u8, pane.id, id)) return true;
    }
    return false;
}

/// The whole model document, owned by the caller, or null when no daemon
/// answered.
fn fetchModel(alloc: Allocator, io: Io, socket_path: []const u8) ?[]u8 {
    return fetchBody(alloc, io, socket_path, "MODEL");
}

/// The body the daemon answered `verb` with, owned by the caller, or null
/// when no daemon answered.
fn fetchBody(alloc: Allocator, io: Io, socket_path: []const u8, comptime verb: []const u8) ?[]u8 {
    const conn = access.connect(io, socket_path) orelse return null;
    defer conn.close(io);

    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, verb, .{}) catch return null;

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const status = (wire.readHeader(alloc, &r.interface) catch return null) orelse return null;
    defer alloc.free(status);
    if (!std.mem.startsWith(u8, status, "OK ")) return null;

    const len = std.fmt.parseInt(usize, status["OK ".len..], 10) catch return null;
    return wire.readBody(alloc, &r.interface, len) catch null;
}

/// What the daemon answered `WINDOWS` with, owned by the caller and empty
/// when no window is known, or null when no daemon answered.
fn fetchWindows(alloc: Allocator, io: Io, socket_path: []const u8) ?[]u8 {
    return fetchBody(alloc, io, socket_path, "WINDOWS");
}

/// What the daemon answered `FOCUSED` with, owned by the caller and empty
/// when nothing is focused, or null when no daemon answered.
fn fetchFocus(alloc: Allocator, io: Io, socket_path: []const u8) ?[]u8 {
    return fetchBody(alloc, io, socket_path, "FOCUSED");
}

/// The process environment, read straight from libc like `paths.zig` does.
fn env(name: [*:0]const u8) []const u8 {
    const value = std.c.getenv(name) orelse return "";
    return std.mem.sliceTo(value, 0);
}

/// Writes `message` to stderr for a command that couldn't start, and returns the failure exit code.
fn startupFailure(err: *Io.Writer, message: []const u8) u8 {
    err.print("{s}\n", .{message}) catch {};
    err.flush() catch {};
    return exit_failed;
}

extern "c" fn getpgrp() std.c.pid_t;

/// The process group this process leads, as a shell makes for a command typed at its prompt, or null when it runs inside someone else's.
fn ownJob() ?u32 {
    const pgid = getpgrp();
    // A command started by an agent or a script inside its group would otherwise speak for that whole group.
    if (pgid != std.c.getpid()) return null;
    return std.math.cast(u32, pgid);
}

/// Runs the layout command in `argv` - what follows the binary's own name -
/// as a process of its own, before anything of the app starts, and returns
/// its exit code.
/// Prints the layout commands and how to open the app, for a bare `coastty` typed in a terminal.
pub fn printHelp() void {
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    var out_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io_owner.io(), &out_buf);
    stdout.interface.writeAll(usage_text ++ "\nTo open the app: open -a Coastty\n") catch {};
    stdout.interface.flush() catch {};
}

pub fn main(argv: []const [*:0]const u8) u8 {
    const alloc = std.heap.c_allocator;
    var io_owner: Io.Threaded = .init_single_threaded;
    defer io_owner.deinit();
    const io = io_owner.io();

    var err_buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(io, &err_buf);
    var out_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);

    const args = alloc.alloc([]const u8, argv.len) catch return startupFailure(&stderr.interface, "out of memory");
    defer alloc.free(args);
    for (args, argv) |*arg, raw| arg.* = std.mem.sliceTo(raw, 0);

    const socket_path = paths.socketPath(alloc) catch return startupFailure(&stderr.interface, "could not work out coastty-host's socket path");
    defer alloc.free(socket_path);

    // Only some commands need the current directory, so one that can't be read is left for them to report.
    const cwd: [:0]const u8 = std.process.currentPathAlloc(io, alloc) catch "";
    defer if (cwd.len > 0) alloc.free(cwd);

    const caller: Caller = .{
        .socket_path = socket_path,
        .pane_id = env(wire.pane_id_env),
        .cwd = cwd,
        .home = paths.homeDir(),
        .job = ownJob(),
    };
    return run(alloc, io, caller, args, .{ .out = &stdout.interface, .err = &stderr.interface }, default_verify_timeout_ms);
}

const testing = std.testing;

/// Runs `args` with no daemon to talk to, returning the exit code and what
/// went to stderr, which the caller frees.
fn runOffline(caller: Caller, args: []const []const u8) !struct { code: u8, err: []u8 } {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    errdefer err.deinit();

    const code = run(testing.allocator, testing.io, caller, args, .{ .out = &out.writer, .err = &err.writer }, 100);
    try testing.expectEqualStrings("", out.written());
    return .{ .code = code, .err = try err.toOwnedSlice() };
}

const offline_caller: Caller = .{
    .socket_path = "/tmp/coastty-layout-test-no-such.sock",
    .pane_id = "surface:A",
    .cwd = "/work",
    .home = "/home",
};

test "an unknown command or option is a usage mistake" {
    inline for (.{
        &[_][]const u8{"tab"},
        &[_][]const u8{ "tab", "fold" },
        &[_][]const u8{ "tab", "new", "--colour" },
        &[_][]const u8{ "tab", "new", "--name" },
        &[_][]const u8{"space"},
        &[_][]const u8{ "space", "list-ish" },
        &[_][]const u8{ "pane", "new" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }
}

test "outside coastty, tab new and pane split need no id, and fail only for want of a daemon" {
    var caller = offline_caller;
    caller.pane_id = "";
    inline for (.{
        &[_][]const u8{ "tab", "new" },
        &[_][]const u8{ "pane", "split", "--direction", "right" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_failed, result.code);
        try testing.expectEqualStrings(not_running ++ "\n", result.err);
    }
}

test "with no daemon to ask, a command fails saying coastty isn't running" {
    const result = try runOffline(offline_caller, &.{ "tab", "new" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings(not_running ++ "\n", result.err);
}

test "a new tab starts in the caller's directory, --cwd relative to it, and home outside coastty" {
    const alloc = testing.allocator;

    const own = try startDirectory(alloc, offline_caller, "");
    defer alloc.free(own);
    try testing.expectEqualStrings("/work", own);

    const relative = try startDirectory(alloc, offline_caller, "../sibling");
    defer alloc.free(relative);
    try testing.expectEqualStrings("/sibling", relative);

    const absolute = try startDirectory(alloc, offline_caller, "/elsewhere");
    defer alloc.free(absolute);
    try testing.expectEqualStrings("/elsewhere", absolute);

    var outside = offline_caller;
    outside.pane_id = "";
    const home = try startDirectory(alloc, outside, "");
    defer alloc.free(home);
    try testing.expectEqualStrings("/home", home);
}

test "an unreadable current directory only matters when the start directory needs it" {
    const alloc = testing.allocator;
    var no_cwd = offline_caller;
    no_cwd.cwd = "";

    try testing.expectError(error.NoCwd, startDirectory(alloc, no_cwd, ""));
    try testing.expectError(error.NoCwd, startDirectory(alloc, no_cwd, "sub"));

    const absolute = try startDirectory(alloc, no_cwd, "/elsewhere");
    defer alloc.free(absolute);
    try testing.expectEqualStrings("/elsewhere", absolute);

    no_cwd.pane_id = "";
    const home = try startDirectory(alloc, no_cwd, "");
    defer alloc.free(home);
    try testing.expectEqualStrings("/home", home);
}

test "inside coastty with no current directory, tab new fails saying so" {
    var caller = offline_caller;
    caller.cwd = "";
    const result = try runOffline(caller, &.{ "tab", "new" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings("could not read the current directory\n", result.err);
}

test "options take their value either after a space or after =" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const options = try parseTabNew(&.{ "--name", "build", "--cwd=/tmp", "--space=S", "--focus" }, &err.writer);
    try testing.expectEqualStrings("build", options.name);
    try testing.expectEqualStrings("/tmp", options.cwd);
    try testing.expectEqualStrings("S", options.space);
    try testing.expect(options.focus);
}

test "close, rename and move take an optional tab id before their value" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const closing = try parseClose(&.{ "T", "--force" }, .tab, offline_caller, &err.writer);
    try testing.expectEqualStrings("T", closing.id);
    try testing.expect(closing.force);

    const own = try parseRename(&.{"-build-"}, .tab, offline_caller, &err.writer);
    try testing.expectEqualStrings("", own.id);
    try testing.expectEqualStrings("-build-", own.name);

    const cleared = try parseRename(&.{ "T", "" }, .tab, offline_caller, &err.writer);
    try testing.expectEqualStrings("T", cleared.id);
    try testing.expectEqualStrings("", cleared.name);

    const moving = try parseMove(&.{ "T", "3" }, .tab, offline_caller, &err.writer);
    try testing.expectEqualStrings("T", moving.id);
    try testing.expectEqual(@as(usize, 3), moving.position);
}

test "a missing value, an extra argument or a position below 1 is a usage mistake" {
    inline for (.{
        &[_][]const u8{ "tab", "close", "A", "B" },
        &[_][]const u8{ "tab", "close", "--gently" },
        &[_][]const u8{ "tab", "rename" },
        &[_][]const u8{ "tab", "rename", "A", "B", "C" },
        &[_][]const u8{ "tab", "move" },
        &[_][]const u8{ "tab", "move", "0" },
        &[_][]const u8{ "tab", "move", "first" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }
}

test "space new takes --name, --cwd and --focus but not --space" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const options = try parseSpaceNew(&.{ "--name=task", "--cwd", "/tmp", "--focus" }, &err.writer);
    try testing.expectEqualStrings("task", options.name);
    try testing.expectEqualStrings("/tmp", options.cwd);
    try testing.expect(options.focus);

    const result = try runOffline(offline_caller, &.{ "space", "new", "--space", "S" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_usage, result.code);
}

test "outside coastty, space new needs no id, and fails only for want of a daemon" {
    var caller = offline_caller;
    caller.pane_id = "";
    const result = try runOffline(caller, &.{ "space", "new" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings(not_running ++ "\n", result.err);
}

test "outside coastty, space close, rename and move need a space id" {
    var caller = offline_caller;
    caller.pane_id = "";
    inline for (.{
        &[_][]const u8{ "space", "close", "--force" },
        &[_][]const u8{ "space", "rename", "task" },
        &[_][]const u8{ "space", "move", "2" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "a space id is required") != null);
    }
}

test "outside coastty, close, rename and move need a tab id" {
    var caller = offline_caller;
    caller.pane_id = "";
    inline for (.{
        &[_][]const u8{ "tab", "close", "--force" },
        &[_][]const u8{ "tab", "rename", "build" },
        &[_][]const u8{ "tab", "move", "2" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "a tab id is required") != null);
    }
}

test "a pane only splits and closes, and a Space or tab never splits" {
    inline for (.{
        &[_][]const u8{ "pane", "rename", "build" },
        &[_][]const u8{ "pane", "move", "2" },
        &[_][]const u8{ "tab", "split", "--direction", "right" },
        &[_][]const u8{ "space", "split", "--direction", "down" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }
}

test "pane split needs --direction right or down" {
    inline for (.{
        &[_][]const u8{ "pane", "split" },
        &[_][]const u8{ "pane", "split", "--direction", "left" },
        &[_][]const u8{ "pane", "split", "--direction" },
        &[_][]const u8{ "pane", "split", "A", "B", "--direction", "down" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
    }
}

test "pane split takes an optional pane id, --cwd and --focus" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const own = try parseSplit(&.{ "--direction", "down" }, &err.writer);
    try testing.expectEqualStrings("", own.id);
    try testing.expectEqual(wire.SplitDirection.down, own.direction);
    try testing.expect(!own.focus);

    const other = try parseSplit(&.{ "surface:B", "--direction=right", "--cwd", "/tmp", "--focus" }, &err.writer);
    try testing.expectEqualStrings("surface:B", other.id);
    try testing.expectEqual(wire.SplitDirection.right, other.direction);
    try testing.expectEqualStrings("/tmp", other.cwd);
    try testing.expect(other.focus);
}

test "outside coastty, tab list and pane list name nothing and fail only for want of a daemon" {
    var caller = offline_caller;
    caller.pane_id = "";

    inline for (.{
        &[_][]const u8{ "tab", "list" },
        &[_][]const u8{ "pane", "list", "--json" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_failed, result.code);
        try testing.expectEqualStrings(not_running ++ "\n", result.err);
    }

    // A space list, a tab list naming what it lists, and a pane list naming its tab only lack a daemon.
    inline for (.{
        &[_][]const u8{ "space", "list" },
        &[_][]const u8{ "tab", "list", "--all" },
        &[_][]const u8{ "tab", "list", "--space=S" },
        &[_][]const u8{ "pane", "list", "T" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_failed, result.code);
        try testing.expectEqualStrings(not_running ++ "\n", result.err);
    }
}

test "a list takes only its own options and arguments" {
    inline for (.{
        &[_][]const u8{ "space", "list", "S" },
        &[_][]const u8{ "space", "list", "--all" },
        &[_][]const u8{ "tab", "list", "T" },
        &[_][]const u8{ "tab", "list", "--all", "--space", "S" },
        &[_][]const u8{ "tab", "list", "--space" },
        &[_][]const u8{ "pane", "list", "A", "B" },
        &[_][]const u8{ "pane", "list", "--all" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }
}

test "a Space shows its own name, else the one its directory gave it" {
    const named: SpaceView = .{ .id = "S", .name = "task", .default_name = "repo", .hidden = false, .tabs = &.{} };
    try testing.expectEqualStrings("task", named.shownName());

    const unnamed: SpaceView = .{ .id = "S", .name = "", .default_name = "repo", .hidden = false, .tabs = &.{} };
    try testing.expectEqualStrings("repo", unnamed.shownName());
}

test "outside coastty, pane close needs a pane id" {
    var caller = offline_caller;
    caller.pane_id = "";
    const result = try runOffline(caller, &.{ "pane", "close", "--force" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_usage, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err, "a pane id is required") != null);
}

test "coastty focused takes only --json, and fails only for want of a daemon" {
    try testing.expect(handles("focused"));

    inline for (.{
        &[_][]const u8{ "focused", "S" },
        &[_][]const u8{ "focused", "--all" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }

    var caller = offline_caller;
    caller.pane_id = "";
    const result = try runOffline(caller, &.{ "focused", "--json" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings(not_running ++ "\n", result.err);
}

test "a focus is all three ids or none, and lists mark it beside the caller's own" {
    const focus = Focused.parse("space-a\x00tab-1\x00surface:p1").?;
    try testing.expectEqualStrings("space-a", focus.space);
    try testing.expectEqualStrings("tab-1", focus.tab);
    try testing.expectEqualStrings("surface:p1", focus.pane);

    try testing.expectEqual(@as(?Focused, null), Focused.parse(""));
    try testing.expectEqual(@as(?Focused, null), Focused.parse("space-a\x00tab-1\x00"));

    try testing.expectEqualStrings("*>", markerText(true, true));
    try testing.expectEqualStrings("*", markerText(true, false));
    try testing.expectEqualStrings(">", markerText(false, true));
    try testing.expectEqualStrings("", markerText(false, false));
}

/// Runs `args` with no daemon to talk to, returning the exit code and what went to stdout and stderr, which the caller frees.
fn runCapturing(caller: Caller, args: []const []const u8) !struct { code: u8, out: []u8, err: []u8 } {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    errdefer err.deinit();

    const code = run(testing.allocator, testing.io, caller, args, .{ .out = &out.writer, .err = &err.writer }, 100);
    return .{ .code = code, .out = try out.toOwnedSlice(), .err = try err.toOwnedSlice() };
}

test "coastty skill prints the skill file and needs no daemon" {
    try testing.expect(handles("skill"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var caller = offline_caller;
    caller.home = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(caller.home);

    const result = try runCapturing(caller, &.{"skill"});
    defer testing.allocator.free(result.out);
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_ok, result.code);
    try testing.expectEqualStrings(skill_text, result.out);
    try testing.expectEqualStrings("", result.err);

    // Printing it writes nothing to the home folder.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".claude", .{}));
}

test "coastty skill install copies the skill file under the home folder and says where" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var caller = offline_caller;
    caller.home = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(caller.home);

    // An older copy is replaced.
    try tmp.dir.createDirPath(testing.io, ".claude/skills/coastty");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".claude/skills/coastty/SKILL.md", .data = "an older skill file, much longer than nothing at all" ** 200 });

    const result = try runCapturing(caller, &.{ "skill", "install" });
    defer testing.allocator.free(result.out);
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);

    const expected_out = try std.fmt.allocPrint(testing.allocator, "installed the coastty skill to {s}/.claude/skills/coastty/SKILL.md\n", .{caller.home});
    defer testing.allocator.free(expected_out);
    try testing.expectEqualStrings(expected_out, result.out);

    const installed = try tmp.dir.readFileAlloc(testing.io, ".claude/skills/coastty/SKILL.md", testing.allocator, .unlimited);
    defer testing.allocator.free(installed);
    try testing.expectEqualStrings(skill_text, installed);
}

test "coastty skill install fails without a home folder" {
    var caller = offline_caller;
    caller.home = "";
    const result = try runCapturing(caller, &.{ "skill", "install" });
    defer testing.allocator.free(result.out);
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings("", result.out);
    try testing.expectEqualStrings("could not find the home folder\n", result.err);
}

test "coastty skill takes only install" {
    inline for (.{
        &[_][]const u8{ "skill", "uninstall" },
        &[_][]const u8{ "skill", "install", "--force" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }
}

test "the skill file covers every layout command and its exit codes" {
    var lines = std.mem.tokenizeScalar(u8, usage_text, '\n');
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, "coastty ") orelse continue;
        // The command as typed, without its arguments: `coastty tab new`.
        var words = std.mem.tokenizeScalar(u8, line[start..], ' ');
        _ = words.next();
        const subject = words.next() orelse continue;
        // `coastty focused [--json]` has no command word, only an option.
        const next = words.next() orelse "";
        const command = if (std.mem.startsWith(u8, next, "[")) "" else next;
        const typed = if (command.len == 0)
            try std.fmt.allocPrint(testing.allocator, "coastty {s}", .{subject})
        else
            try std.fmt.allocPrint(testing.allocator, "coastty {s} {s}", .{ subject, command });
        defer testing.allocator.free(typed);

        // `coastty skill [install]` is spelled out as its two forms.
        const looked_for = if (std.mem.eql(u8, subject, "skill")) "coastty skill install" else typed;
        if (std.mem.indexOf(u8, skill_text, looked_for) == null) {
            std.debug.print("the skill file doesn't mention `{s}`\n", .{looked_for});
            return error.TestUnexpectedResult;
        }
    }

    try testing.expect(std.mem.indexOf(u8, skill_text, "--force") != null);
    try testing.expect(std.mem.indexOf(u8, skill_text, "never type into a pane or read one") != null);
    try testing.expect(std.mem.indexOf(u8, skill_text, "Exit code 0 is success, 1 a failure, 2 a usage mistake") != null);
    try testing.expect(std.mem.indexOf(u8, skill_text, not_running) != null);
    try testing.expect(std.mem.indexOf(u8, skill_text, unverified) != null);
    try testing.expect(std.mem.indexOf(u8, skill_text, nothing_focused) != null);
}

test "space move takes --window with an optional Space id and position" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const own = try parseMove(&.{ "--window", "W" }, .space, offline_caller, &err.writer);
    try testing.expectEqualStrings("", own.id);
    try testing.expectEqualStrings("W", own.window);
    try testing.expectEqual(@as(?usize, null), own.position);

    const placed = try parseMove(&.{ "--window=W", "2" }, .space, offline_caller, &err.writer);
    try testing.expectEqualStrings("", placed.id);
    try testing.expectEqual(@as(?usize, 2), placed.position);

    const named = try parseMove(&.{ "S", "--window", "W" }, .space, offline_caller, &err.writer);
    try testing.expectEqualStrings("S", named.id);
    try testing.expectEqual(@as(?usize, null), named.position);

    const both = try parseMove(&.{ "S", "--window", "W", "3" }, .space, offline_caller, &err.writer);
    try testing.expectEqualStrings("S", both.id);
    try testing.expectEqual(@as(?usize, 3), both.position);

    const plain = try parseMove(&.{ "S", "1" }, .space, offline_caller, &err.writer);
    try testing.expectEqualStrings("", plain.window);
    try testing.expectEqual(@as(?usize, 1), plain.position);
}

test "space move --window outside coastty needs a Space id, and a tab never moves to a window" {
    var caller = offline_caller;
    caller.pane_id = "";
    inline for (.{
        &[_][]const u8{ "space", "move", "--window", "W" },
        &[_][]const u8{ "space", "move", "--window", "W", "2" },
        &[_][]const u8{ "space", "move", "S", "--window", "W", "0" },
        &[_][]const u8{ "space", "move", "S", "--window", "W", "1", "2" },
        &[_][]const u8{ "space", "move", "S", "--window" },
    }) |args| {
        const result = try runOffline(caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
    }

    const tab = try runOffline(offline_caller, &.{ "tab", "move", "T", "--window", "W" });
    defer testing.allocator.free(tab.err);
    try testing.expectEqual(exit_usage, tab.code);
}

test "space new takes --window" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const options = try parseSpaceNew(&.{ "--window", "W", "--name=task" }, &err.writer);
    try testing.expectEqualStrings("W", options.window);
    try testing.expectEqualStrings("task", options.name);
}

test "a window is only listed, and the list needs only a daemon" {
    try testing.expect(handles("window"));

    inline for (.{
        &[_][]const u8{ "window", "new" },
        &[_][]const u8{ "window", "close" },
        &[_][]const u8{ "window", "list", "W" },
        &[_][]const u8{ "window", "list", "--all" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }

    var caller = offline_caller;
    caller.pane_id = "";
    const result = try runOffline(caller, &.{ "window", "list", "--json" });
    defer testing.allocator.free(result.err);
    try testing.expectEqual(exit_failed, result.code);
    try testing.expectEqualStrings(not_running ++ "\n", result.err);
}

test "focus takes only an optional id, and outside coastty needs one" {
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqualStrings("", try parseFocus(&.{}, .tab, offline_caller, &err.writer));
    try testing.expectEqualStrings("surface:B", try parseFocus(&.{"surface:B"}, .pane, offline_caller, &err.writer));

    inline for (.{
        &[_][]const u8{ "tab", "focus", "A", "B" },
        &[_][]const u8{ "space", "focus", "--json" },
        &[_][]const u8{ "window", "focus", "W" },
    }) |args| {
        const result = try runOffline(offline_caller, args);
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "usage:") != null);
    }

    var outside = offline_caller;
    outside.pane_id = "";
    inline for (.{ "space", "tab", "pane" }) |subject| {
        const result = try runOffline(outside, &.{ subject, "focus" });
        defer testing.allocator.free(result.err);
        try testing.expectEqual(exit_usage, result.code);
        try testing.expect(std.mem.indexOf(u8, result.err, "outside coastty, a " ++ subject ++ " id is required") != null);
    }

    // With an id, only the daemon is missing.
    const named = try runOffline(outside, &.{ "pane", "focus", "surface:B" });
    defer testing.allocator.free(named.err);
    try testing.expectEqual(exit_failed, named.code);
    try testing.expectEqualStrings(not_running ++ "\n", named.err);
}
