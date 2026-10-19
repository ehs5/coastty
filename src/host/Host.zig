//! The headless host's control-socket server: the registry of live panes,
//! the model those panes sit in, and one thread per connection to talk
//! the `wire` protocol to both.
//!
//! The pane registry only exists in memory - a pty and a running process
//! cannot be restored from disk, and a GUI relaunching after a crash
//! just reconnects to the same well-known socket (see `paths.zig`) and
//! asks what is still running. The model outlives the daemon itself: it
//! is written to the daemon's own file (see `Model.zig`) and read back
//! on start, so the Spaces, tabs and pane membership a user built are
//! still there after a reboot, as fresh shells in the right places.
const Host = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;

const Events = @import("Events.zig");
const Focus = @import("Focus.zig");
const Windows = @import("Windows.zig");
const Model = @import("Model.zig");
const Pane = @import("Pane.zig");
const wire = @import("wire.zig");
const upgrade = @import("upgrade.zig");
const paths = @import("paths.zig");
const access = @import("access.zig");
const layout_commands = @import("layout_commands.zig");

const log = std.log.scoped(.coastty_host);

/// How long a burst of changes collects before the model goes to disk.
/// Long enough that dragging a Space through ten positions costs one
/// write rather than ten, short enough that a crash loses nothing a user
/// would notice having done.
const model_flush_interval_ms = 500;

/// The longest the detection loop sleeps, so a pane created while it sleeps
/// waits at most this long for its first check. Matches the check interval
/// of a pane with no agent, so an idle daemon wakes no more often than its
/// panes would ask it to.
const detection_max_sleep_ms = 500;

/// How often the flush loop looks up from waiting to notice a shutdown.
/// Small enough that a `pkill` returns promptly, large enough that an
/// idle daemon is not spinning.
const shutdown_poll_ms = 25;

/// How long a daemon still on the old socket gets to write its model out
/// and exit before this one reads the model anyway.
const legacy_exit_timeout_ms = 3000;

/// Raised by the SIGTERM/SIGINT handler (see `main.zig`). A signal
/// handler may not allocate or take a lock, so it only sets this and the
/// flush loop does the writing. Without it the routine ways this process
/// ends - `coastty-build-dev`, a reboot - silently drop whatever changed
/// since the last write.
pub var shutdown_requested: std.atomic.Value(bool) = .init(false);

alloc: Allocator,
io: Io,
mutex: std.Io.Mutex = .init,
panes: std.StringHashMap(*Pane),

/// Guards `model`. Separate from `mutex` because the two protect
/// different things and a model request has no business waiting behind a
/// pane spawn. Never taken while `mutex` is held; `syncPaneFacts` takes
/// them in that order and is the only place both are involved.
model_mutex: std.Io.Mutex = .init,
model: Model,

/// Where the model is written, once `openModel` has been given a path.
/// Null until then, which is how tests and the CLI run without touching
/// a real user's file.
model_path: ?[]u8 = null,

/// Set by whatever changed the model, cleared by the flusher thread that
/// writes it out. Atomic so a change never has to take the model lock
/// just to say a write is owed.
model_dirty: std.atomic.Value(bool) = .init(false),

/// What changed, pushed to every client that subscribed.
events: Events,

/// Which Space, tab and pane the user was last in, as the app reports it. Never part of the model.
focus: Focus,

/// The app's windows and the Spaces each shows, as the app reports them. Never part of the model.
windows: Windows,

/// What the app sends to read or type into a pane, start one, end one or subscribe as the app. Made fresh each run and published beside the socket; see `access.zig`.
token: access.Token,

/// Runs agent detection for every pane; see `detectionLoop`.
detection_thread: ?std.Thread = null,
detection_stop: std.atomic.Value(bool) = .init(false),

pub fn init(alloc: Allocator, io: Io) Host {
    return .{
        .alloc = alloc,
        .io = io,
        .panes = .init(alloc),
        .model = .init(alloc, randomId(io)),
        .token = access.newToken(io),
        .events = .init(alloc, io),
        .focus = .init(alloc, io),
        .windows = .init(alloc, io),
    };
}

/// Frees what the host itself owns. `run` never returns, so this is for
/// tests and for anything that builds a host without serving on it.
pub fn deinit(host: *Host) void {
    host.stopDetection();
    host.events.deinit();
    host.focus.deinit();
    host.windows.deinit();
    host.model.deinit();
    if (host.model_path) |path| host.alloc.free(path);
    host.panes.deinit();
}

/// Points the daemon at the file it keeps its model in and adopts
/// whatever a previous run left there. `path` becomes the host's to
/// free. Call once, before serving.
pub fn openModel(host: *Host, path: []u8) void {
    host.model_path = path;
    host.model.load(host.io, path) catch |err| log.warn(
        "could not read the model at {s}, starting empty: {t}",
        .{ path, err },
    );
}

/// Binds the well-known socket and serves connections until the process
/// is killed. Never returns on success.
pub fn run(host: *Host) !void {
    const path = try paths.socketPath(host.alloc);
    defer host.alloc.free(path);

    if (try paths.privateSocketDir(host.alloc)) |dir| {
        defer host.alloc.free(dir);
        access.ensurePrivateDir(dir) catch |err| {
            log.err("refusing to serve from {s}: {t}; it must be a directory owned by this user with mode 0700", .{ dir, err });
            return err;
        };
    }

    // Held for the daemon's whole life, so a second daemon started alongside exits here before touching the token or the socket.
    const lock = access.lockSocket(host.io, path) catch |err| {
        log.err("refusing to serve: could not take the start lock beside {s}: {t}", .{ path, err });
        return err;
    } orelse {
        log.info("another coastty host is starting or serving on {s}, exiting", .{path});
        return;
    };
    defer lock.close(host.io);

    // A stale socket file from a host that didn't exit cleanly (e.g.
    // killed for a test, or a crash) blocks a fresh bind. If a live
    // host actually still owns it, connecting to it before removing it
    // tells us to back off instead.
    if (isHostAlive(host.io, path)) {
        log.info("a coastty host is already listening on {s}, exiting", .{path});
        return;
    }
    std.Io.Dir.cwd().deleteFile(host.io, path) catch {};

    // Published before the socket exists, so an app that finds the socket finds this run's token beside it; the start lock keeps a second daemon from overwriting it.
    var token_buf: [std.posix.PATH_MAX]u8 = undefined;
    const token_path = try paths.tokenPath(&token_buf, path);
    access.writeToken(host.io, token_path, &host.token) catch |err| {
        log.err("refusing to serve: could not write the app's token to {s}: {t}", .{ token_path, err });
        return err;
    };

    const addr = try net.UnixAddress.init(path);
    var server = try access.listenOwnerOnly(host.io, &addr);
    defer server.deinit(host.io);
    log.info("listening on {s}", .{path});

    host.retireLegacyHost();

    if (paths.modelPath(host.alloc)) |model_path| {
        host.openModel(model_path);
    } else |err| log.warn("no model file for this daemon, nothing will persist: {t}", .{err});

    if (std.Thread.spawn(.{}, modelFlushLoop, .{host})) |flusher| {
        flusher.detach();
    } else |err| log.warn("no model flusher thread, nothing will persist: {t}", .{err});

    host.startDetection() catch |err| log.warn("no agent detection thread, status will not be known: {t}", .{err});

    while (true) {
        const conn = server.accept(host.io) catch |err| {
            log.warn("accept failed: {}", .{err});
            continue;
        };
        if (!access.peerIsUser(conn)) {
            log.warn("dropped a connection from a process not running as this user", .{});
            conn.close(host.io);
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ host, conn }) catch |err| {
            log.warn("could not spawn connection thread: {}", .{err});
            conn.close(host.io);
            continue;
        };
        thread.detach();
    }
}

/// Whether a daemon running as this user already serves `path`. One run
/// by anyone else doesn't count, so its socket never passes for ours.
fn isHostAlive(io: Io, path: []const u8) bool {
    const stream = access.connect(io, path) orelse return false;
    stream.close(io);
    return true;
}

/// Stops a daemon started before the socket moved into its private
/// directory, and waits for it to write its model out and exit. It shares
/// this daemon's model file, so left running the two would overwrite each
/// other's model while its panes sat out of the GUI's reach.
fn retireLegacyHost(host: *Host) void {
    const path = (paths.legacySocketPath(host.alloc) catch return) orelse return;
    defer host.alloc.free(path);

    const stream = access.connect(host.io, path) orelse return;
    const peer = access.peerPid(stream);
    stream.close(host.io);
    const pid = peer orelse {
        log.warn("a coastty host still serves the old socket {s}, but its pid is unknown; stop it by hand", .{path});
        return;
    };

    log.info("stopping the coastty host (pid {d}) still serving the old socket {s}", .{ pid, path });
    std.posix.kill(pid, .TERM) catch |err| {
        log.warn("could not stop the coastty host (pid {d}): {t}", .{ pid, err });
        return;
    };

    // Its SIGTERM handler flushes the model before exiting, so read it only after.
    if (access.waitForProcessGone(host.io, pid, legacy_exit_timeout_ms)) return;
    log.warn("the coastty host (pid {d}) on the old socket has not exited; its model writes may race this one's", .{pid});
}

/// The requests that reach inside a pane, and so must end with the app's token.
const token_verbs = [_][]const u8{ "CREATE", "ATTACH", "KILL", "SWEEP" };

/// Whether `header` must carry the app's token: it reaches inside a pane, or subscribes as the app, which carries out layout requests and reports focus and windows.
fn needsToken(header: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, header, ' ');
    const cmd = it.next() orelse return false;
    for (token_verbs) |verb| {
        if (std.mem.eql(u8, cmd, verb)) return true;
    }
    if (!std.mem.eql(u8, cmd, "SUBSCRIBE")) return false;

    _ = it.next(); // version
    return std.mem.eql(u8, it.next() orelse "", "app");
}

/// `header` without the token it ends with, or null when that last argument is not this run's token.
fn withoutToken(host: *Host, header: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, header, " ");
    const space = std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse return null;
    if (!access.tokenMatches(&host.token, trimmed[space + 1 ..])) return null;
    return trimmed[0..space];
}

/// Serves exactly one request (or, for `ATTACH`, one pane's whole live
/// stream) on `conn`.
fn handleConnection(host: *Host, conn: net.Stream) void {
    var rbuf: [wire.max_header_len]u8 = undefined;
    var reader = conn.reader(host.io, &rbuf);

    const header = (wire.readHeader(host.alloc, &reader.interface) catch |err| {
        log.warn("bad request: {}", .{err});
        conn.close(host.io);
        return;
    }) orelse {
        conn.close(host.io);
        return;
    };
    defer host.alloc.free(header);

    var request: []const u8 = header;
    if (needsToken(header)) {
        request = host.withoutToken(header) orelse {
            respondErr(host.io, conn, "unauthorized");
            conn.close(host.io);
            return;
        };
    }

    var it = std.mem.tokenizeScalar(u8, request, ' ');
    const cmd = it.next() orelse {
        conn.close(host.io);
        return;
    };

    if (std.mem.eql(u8, cmd, "CREATE")) {
        host.handleCreate(conn, &reader.interface, &it);
    } else if (std.mem.eql(u8, cmd, "LIST")) {
        host.handleList(conn);
    } else if (std.mem.eql(u8, cmd, "KILL")) {
        host.handleKill(conn, &it);
    } else if (std.mem.eql(u8, cmd, "SWEEP")) {
        host.handleSweep(conn, &it);
    } else if (std.mem.eql(u8, cmd, "MODEL")) {
        host.handleModel(conn);
    } else if (std.mem.eql(u8, cmd, "VERSION")) {
        respondOkVersions(host.io, conn);
    } else if (std.mem.eql(u8, cmd, "FOCUSED")) {
        host.handleFocused(conn);
    } else if (std.mem.eql(u8, cmd, "WINDOWS")) {
        host.handleWindows(conn);
    } else if (std.mem.eql(u8, cmd, "SPACE")) {
        host.handleModelOp(conn, &reader.interface, &it, .space);
    } else if (std.mem.eql(u8, cmd, "TAB")) {
        host.handleModelOp(conn, &reader.interface, &it, .tab);
    } else if (std.mem.eql(u8, cmd, "PANE")) {
        host.handleModelOp(conn, &reader.interface, &it, .pane);
    } else if (std.mem.eql(u8, cmd, "REQUEST")) {
        host.handleRequest(conn, &reader.interface, &it);
    } else if (std.mem.eql(u8, cmd, "ATTACH")) {
        host.handleAttach(conn, &reader.interface, &it);
        return; // handleAttach owns the connection's lifetime
    } else if (std.mem.eql(u8, cmd, "SUBSCRIBE")) {
        host.handleSubscribe(conn, &reader.interface, &it);
    } else {
        respondErr(host.io, conn, "unknown command");
    }
    conn.close(host.io);
}

fn handleCreate(
    host: *Host,
    conn: net.Stream,
    reader: *Io.Reader,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    const cols = parseU16(it.next()) orelse return respondErr(host.io, conn, "bad cols");
    const rows = parseU16(it.next()) orelse return respondErr(host.io, conn, "bad rows");
    const body_len = parseUsize(it.next()) orelse return respondErr(host.io, conn, "bad body length");
    // Absent for the CLI debug client and any daemon predating this
    // field - see wire.zig's own CREATE doc comment.
    const env_len = parseUsize(it.next()) orelse 0;

    const body = wire.readBody(host.alloc, reader, body_len) catch
        return respondErr(host.io, conn, "short body");
    defer host.alloc.free(body);

    const env_body = wire.readBody(host.alloc, reader, env_len) catch
        return respondErr(host.io, conn, "short env body");
    defer host.alloc.free(env_body);
    var env = wire.parseEnvBody(host.alloc, env_body) catch return respondErr(host.io, conn, "oom");
    defer env.deinit();

    var fields: wire.FieldIterator = .init(body);
    const id_field = fields.next() orelse return respondErr(host.io, conn, "missing id field");
    const cwd = fields.next() orelse return respondErr(host.io, conn, "missing cwd");

    var argv: std.ArrayList([:0]const u8) = .empty;
    defer argv.deinit(host.alloc);
    while (fields.next()) |a| {
        const dup = host.alloc.dupeZ(u8, a) catch return respondErr(host.io, conn, "oom");
        argv.append(host.alloc, dup) catch return respondErr(host.io, conn, "oom");
    }
    defer for (argv.items) |a| host.alloc.free(a);
    if (argv.items.len == 0) return respondErr(host.io, conn, "missing argv");

    // Reuse: if the caller named a pane it already owns (typically the
    // stable id the GUI's own session-shape store assigns a tab), hand
    // back the live pane instead of spawning a duplicate. When the id
    // isn't live yet, the mutex below is left held (the `defer` after
    // this block only registers once we fall through past it) all the
    // way through spawning and registering the new pane, so a second
    // CREATE racing for that same not-yet-existing id can't also pass
    // this check and spawn a second, orphaned pane for it.
    host.mutex.lockUncancelable(host.io);
    // Whether the id named a pane whose process had already exited on its
    // own - the caller is reattaching to something that ended while it was
    // away, which it wants to show rather than silently paper over.
    var replaced_dead = false;
    if (id_field.len > 0) {
        if (host.panes.get(id_field)) |existing| {
            if (existing.isAlive()) {
                // Retained under the same lock that found it: a KILL or
                // SWEEP for this id can land the instant the lock drops,
                // and the registry's own reference is the only other one
                // keeping the pane's memory alive.
                existing.retain();
                host.mutex.unlock(host.io);
                defer existing.release();

                // Deliberately not resized. A caller's geometry at CREATE is
                // whatever its surface measured before layout, and the
                // snapshot the following ATTACH replays is rendered at the
                // pane's size - so shrinking here hard-wraps scrollback that
                // was written wider, and the text stays wrapped when the real
                // size arrives. The caller sends that size as a RESIZE once it
                // has one, which reflows instead of rewrapping.
                return respondOkId(host.io, conn, id_field, .reused);
            }

            // Registry presence alone doesn't mean there's anything left to
            // talk to: drop the corpse so the spawn below takes its id.
            _ = host.panes.remove(id_field);
            existing.release();
            replaced_dead = true;
        }
    }
    defer host.mutex.unlock(host.io);

    var id_buf: [32]u8 = undefined;
    const id: []const u8 = if (id_field.len > 0) id_field else blk: {
        id_buf = randomId(host.io);
        break :blk &id_buf;
    };
    const cwd_z = host.alloc.dupeZ(u8, cwd) catch return respondErr(host.io, conn, "oom");
    defer host.alloc.free(cwd_z);

    const pane = Pane.spawn(host.alloc, host.io, .{
        .id = id,
        .cwd = cwd_z,
        .argv = argv.items,
        .cols = cols,
        .rows = rows,
        .env = if (env_len > 0) &env else null,
        .events = &host.events,
    }) catch |err| {
        log.warn("spawn failed: {}", .{err});
        return respondErr(host.io, conn, "spawn failed");
    };

    // Still holding the mutex locked above; the `defer` there unlocks it
    // once this function returns, on every path from here on.
    host.panes.put(pane.id, pane) catch return respondErr(host.io, conn, "oom");

    host.events.publishPane(.pane_created, pane.id);
    respondOkId(host.io, conn, pane.id, if (replaced_dead) .ended else .new);
}

/// `KILL <id> [<id> ...]`: ends each named pane's process and forgets it.
/// Takes every id in one request so closing something with many panes
/// costs one round trip rather than one per pane.
fn handleKill(
    host: *Host,
    conn: net.Stream,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    // Collected first, ended together: `Pane.terminateAll` waits on the
    // whole set at once, so a request naming several processes that ignore
    // SIGTERM costs one grace period instead of one each.
    var doomed: std.ArrayList(*Pane) = .empty;
    defer doomed.deinit(host.alloc);

    var killed: usize = 0;
    while (it.next()) |id| {
        host.mutex.lockUncancelable(host.io);
        const entry = host.panes.fetchRemove(id);
        host.mutex.unlock(host.io);

        const pane = (entry orelse continue).value;
        killed += 1;
        doomed.append(host.alloc, pane) catch {
            // Already out of the registry, so it has to die here or never.
            pane.terminate();
            pane.release();
        };
    }

    host.forgetPanes(doomed.items);
    Pane.terminateAll(doomed.items);
    for (doomed.items) |pane| {
        host.events.publishPane(.pane_killed, pane.id);
        pane.release();
    }
    respondOkCount(host.io, conn, killed);
}

/// `SWEEP <id> <id> ...`: the caller names every pane it still wants, and
/// the daemon kills the rest. The set difference happens here rather than
/// in the client so nobody has to fetch a full `LIST` and diff it locally.
fn handleSweep(
    host: *Host,
    conn: net.Stream,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    var keep: std.StringHashMap(void) = .init(host.alloc);
    defer keep.deinit();
    while (it.next()) |id| keep.put(id, {}) catch return respondErr(host.io, conn, "oom");

    // Collect first, remove after: mutating the registry while iterating it
    // would invalidate the iterator mid-sweep.
    var doomed: std.ArrayList(*Pane) = .empty;
    defer doomed.deinit(host.alloc);

    host.mutex.lockUncancelable(host.io);
    var vit = host.panes.valueIterator();
    while (vit.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        if (keep.contains(pane.id)) continue;
        doomed.append(host.alloc, pane) catch break;
    }
    for (doomed.items) |pane| _ = host.panes.remove(pane.id);
    host.mutex.unlock(host.io);

    for (doomed.items) |pane| log.info("sweeping unclaimed pane {s}", .{pane.id});
    host.forgetPanes(doomed.items);
    Pane.terminateAll(doomed.items);
    for (doomed.items) |pane| {
        host.events.publishPane(.pane_killed, pane.id);
        pane.release();
    }
    respondOkCount(host.io, conn, doomed.items.len);
}

fn handleList(host: *Host, conn: net.Stream) void {
    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);

    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);

    wire.writeHeaderLine(&w.interface, "OK {d}", .{host.panes.count()}) catch return;
    var vit = host.panes.valueIterator();
    while (vit.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        wire.writeHeaderLine(&w.interface, "{s} {d} {d} {d}", .{
            pane.id,
            pane.terminal.cols,
            pane.terminal.rows,
            @intFromBool(pane.isAlive()),
        }) catch return;
    }
}

/// `MODEL`: the whole model in one document. Rendered into one buffer
/// under the model lock and sent as a single length-prefixed frame, so a
/// client gets everything it draws from one round trip.
fn handleModel(host: *Host, conn: net.Stream) void {
    host.syncPaneFacts();

    host.model_mutex.lockUncancelable(host.io);
    const rendered = host.model.renderSnapshot(host.alloc);
    host.model_mutex.unlock(host.io);

    const document = rendered catch return respondErr(host.io, conn, "oom");
    defer host.alloc.free(document);

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    wire.writeFrame(&w.interface, "OK", document) catch {};
}

/// `FOCUSED`: the Space, tab and pane the user was last in, as one body, empty when nothing is focused.
fn handleFocused(host: *Host, conn: net.Stream) void {
    const held = host.focus.snapshot(host.alloc) catch return respondErr(host.io, conn, "oom");
    defer if (held) |focus| focus.deinit(host.alloc);

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    const focus = held orelse {
        wire.writeFrame(&w.interface, "OK", "") catch {};
        return;
    };
    wire.writeFields(&w.interface, "OK", &.{ focus.space, focus.tab, focus.pane }) catch {};
}

/// `WINDOWS`: the app's windows and the Spaces each shows, as the app last reported them, empty when none are known.
fn handleWindows(host: *Host, conn: net.Stream) void {
    const body = host.windows.snapshot(host.alloc) catch return respondErr(host.io, conn, "oom");
    defer host.alloc.free(body);

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    wire.writeFrame(&w.interface, "OK", body) catch {};
}

const Scope = wire.Scope;

/// One structural change to the model. Every client changes the model
/// through here - the GUI has no privileged path of its own - so the
/// reply is the new revision, which is what a client checks its own
/// cached copy against.
fn handleModelOp(
    host: *Host,
    conn: net.Stream,
    reader: *Io.Reader,
    it: *std.mem.TokenIterator(u8, .scalar),
    scope: Scope,
) void {
    const op = it.next() orelse return respondErr(host.io, conn, "missing op");
    const body_len = parseUsize(it.next()) orelse return respondErr(host.io, conn, "bad body length");
    const body = wire.readBody(host.alloc, reader, body_len) catch
        return respondErr(host.io, conn, "short body");
    defer host.alloc.free(body);

    host.model_mutex.lockUncancelable(host.io);
    const applied = host.applyModelOp(scope, op, body);
    const revision = host.model.revision;
    host.model_mutex.unlock(host.io);

    applied catch |err| return respondErr(host.io, conn, opErrorReason(err));
    host.model_dirty.store(true, .release);
    host.events.publishModelChanged(revision);
    respondOkRevision(host.io, conn, revision);
}

/// Caller must already hold `model_mutex`.
fn applyModelOp(host: *Host, scope: Scope, op_token: []const u8, body: []const u8) !void {
    var fields: wire.FieldIterator = .init(body);

    // The first field is always the id the op starts from: the Space a
    // new tab joins, otherwise the thing being changed itself.
    const subject = fields.next() orelse return error.MissingField;

    switch (scope) {
        .space => {
            const op = std.meta.stringToEnum(wire.SpaceOp, op_token) orelse return error.UnknownOp;
            return switch (op) {
                .new => host.model.createSpace(subject, fields.next() orelse ""),
                .close => host.model.closeSpace(subject),
                .rename => host.model.renameSpace(subject, fields.next() orelse ""),
                .move => host.model.moveSpace(subject, try nextIndex(&fields)),
                .hide => host.model.hideSpace(subject),
                .show => host.model.showSpace(subject),
            };
        },
        .tab => {
            const op = std.meta.stringToEnum(wire.TabOp, op_token) orelse return error.UnknownOp;
            return switch (op) {
                .new => host.model.createTab(
                    subject,
                    fields.next() orelse return error.MissingField,
                    fields.next() orelse "",
                ),
                .close => host.model.closeTab(subject),
                .rename => host.model.renameTab(subject, fields.next() orelse ""),
                .move => host.model.moveTab(subject, try nextIndex(&fields)),
            };
        },
        .pane => {
            const op = std.meta.stringToEnum(wire.PaneOp, op_token) orelse return error.UnknownOp;
            return switch (op) {
                .move => host.model.movePane(
                    subject,
                    fields.next() orelse return error.MissingField,
                    try nextIndex(&fields),
                ),
            };
        },
    }
}

/// Reads a position out of the next body field. Indices ride in the body
/// with the ids rather than in the header so each op's arguments stay
/// one NUL-separated list.
fn nextIndex(fields: *wire.FieldIterator) !usize {
    const token = fields.next() orelse return error.MissingField;
    return std.fmt.parseInt(usize, token, 10) catch error.BadIndex;
}

/// The token a refused model operation reports. Spelled out rather than
/// taken from `@errorName` so the wire vocabulary is a decision here,
/// not a rename away from changing underneath a client.
fn opErrorReason(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOp => "unknown op",
        error.MissingField, error.MissingId => "missing field",
        error.BadIndex => "bad index",
        error.NoSuchSpace => "no such space",
        error.NoSuchTab => "no such tab",
        error.NoSuchPane => "no such pane",
        error.DuplicateId => "duplicate id",
        error.MissingTarget => "missing target",
        error.NoSuchPosition => "no such position",
        error.HiddenSpace => "space is hidden",
        error.NothingFocused => "nothing focused",
        error.NoSuchWindow => "no such window",
        else => "failed",
    };
}

/// `REQUEST <scope> <op> <body-len>`: a change a layout command asks of the
/// app. Resolved and validated here against the model, so the app only ever
/// carries out a request that names things that exist.
fn handleRequest(
    host: *Host,
    conn: net.Stream,
    reader: *Io.Reader,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    const scope = Scope.parseVerb(it.next() orelse "") orelse return respondErr(host.io, conn, "unknown scope");
    const op = it.next() orelse return respondErr(host.io, conn, "missing op");
    const body_len = parseUsize(it.next()) orelse return respondErr(host.io, conn, "bad body length");
    const body = wire.readBody(host.alloc, reader, body_len) catch
        return respondErr(host.io, conn, "short body");
    defer host.alloc.free(body);

    var fields: wire.FieldIterator = .init(body);
    const target = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const near = fields.next() orelse return respondErr(host.io, conn, "missing field");

    switch (scope) {
        .space => {
            const space_op = std.meta.stringToEnum(wire.SpaceRequestOp, op) orelse return respondErr(host.io, conn, "unknown op");
            switch (space_op) {
                .new => host.requestSpaceNew(conn, near, &fields),
                .close => host.requestClose(conn, .space, target, near, &fields),
                .rename => host.requestSpaceRename(conn, target, near, &fields),
                .move => host.requestSpaceMove(conn, target, near, &fields),
                .focus => host.requestFocus(conn, .space, target, near),
            }
        },
        .tab => {
            const tab_op = std.meta.stringToEnum(wire.TabRequestOp, op) orelse return respondErr(host.io, conn, "unknown op");
            switch (tab_op) {
                .new => host.requestTabNew(conn, target, near, &fields),
                .close => host.requestClose(conn, .tab, target, near, &fields),
                .rename => host.requestTabRename(conn, target, near, &fields),
                .move => host.requestTabMove(conn, target, near, &fields),
                .focus => host.requestFocus(conn, .tab, target, near),
            }
        },
        .pane => {
            const pane_op = std.meta.stringToEnum(wire.PaneRequestOp, op) orelse return respondErr(host.io, conn, "unknown op");
            switch (pane_op) {
                .split => host.requestPaneSplit(conn, target, near, &fields),
                .close => host.requestClose(conn, .pane, target, near, &fields),
                .focus => host.requestFocus(conn, .pane, target, near),
            }
        },
    }
}

/// `REQUEST SPACE new`: a Space with one starter tab, under ids generated
/// here so the caller can wait for them to show up in the model. It joins
/// the window named, else the window showing the caller's own Space.
fn requestSpaceNew(host: *Host, conn: net.Stream, near: []const u8, fields: *wire.FieldIterator) void {
    const name = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const directory = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const focus = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const window = fields.next() orelse "";
    if (directory.len == 0) return respondErr(host.io, conn, "missing directory");
    host.requireWindow(window) catch |err| return respondErr(host.io, conn, opErrorReason(err));

    // Outside coastty there is no Space of the caller's own, and the app picks the frontmost window.
    const beside: []u8 = if (near.len > 0)
        host.resolveSpace("", near) catch |err| return respondErr(host.io, conn, opErrorReason(err))
    else
        &.{};
    defer host.alloc.free(beside);

    const space_id = randomUuid(host.io);
    const tab_id = randomUuid(host.io);
    const delivered = host.events.publishSpaceNew(.{
        .space = &space_id,
        .tab = &tab_id,
        .beside = beside,
        .window = window,
        .name = name,
        .directory = directory,
        .focus = std.mem.eql(u8, focus, "1"),
    });
    if (!delivered) return respondErr(host.io, conn, "app not running");

    var wbuf: [128]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {s} {s}", .{ &space_id, &tab_id }) catch {};
}

/// `REQUEST SPACE rename`: an empty name clears the Space's own name.
fn requestSpaceRename(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const name = fields.next() orelse return respondErr(host.io, conn, "missing field");

    const space_id = host.resolveSpace(target, near) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer host.alloc.free(space_id);

    const delivered = host.events.publishSpaceChange(.{ .space = space_id, .change = .{ .rename = name } });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, space_id);
}

/// Fails with `error.NoSuchWindow` when `window` is given and the app has reported no window by that id.
fn requireWindow(host: *Host, window: []const u8) !void {
    if (window.len == 0) return;
    const body = try host.windows.snapshot(host.alloc);
    defer host.alloc.free(body);
    if (wire.WindowIterator.find(body, window) == null) return error.NoSuchWindow;
}

/// `REQUEST SPACE move`: a 0-based position among the visible Spaces,
/// refused past the last one rather than quietly landing it last. Naming
/// a window moves the Space there instead.
fn requestSpaceMove(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const index_field = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const window = fields.next() orelse "";
    if (window.len > 0) return host.requestSpaceMoveToWindow(conn, target, near, index_field, window);

    const index = std.fmt.parseInt(usize, index_field, 10) catch return respondErr(host.io, conn, opErrorReason(error.BadIndex));

    var moving = host.movingSpace(target, near, index) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer moving.deinit(host.alloc);

    const delivered = host.events.publishSpaceChange(.{
        .space = moving.id,
        .change = .{ .move = .{ .index = index, .after = moving.after.items } },
    });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, moving.id);
}

/// `REQUEST SPACE move` naming a window: the Space moves to that window, at
/// a 0-based position among its visible Spaces or, with `index_field`
/// empty, after the last of them. Answered with the Space's id and the
/// position it lands at.
fn requestSpaceMoveToWindow(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, index_field: []const u8, window: []const u8) void {
    const position: ?usize = if (index_field.len == 0)
        null
    else
        std.fmt.parseInt(usize, index_field, 10) catch return respondErr(host.io, conn, opErrorReason(error.BadIndex));

    const windows_body = host.windows.snapshot(host.alloc) catch return respondErr(host.io, conn, "oom");
    defer host.alloc.free(windows_body);

    var moving = host.movingSpaceToWindow(target, near, position, windows_body, window) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer moving.space.deinit(host.alloc);

    const delivered = host.events.publishSpaceChange(.{
        .space = moving.space.id,
        .change = .{ .move = .{ .index = moving.index, .after = moving.space.after.items, .window = window } },
    });
    if (!delivered) return respondErr(host.io, conn, "app not running");

    var wbuf: [128]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {s} {d}", .{ moving.space.id, moving.position }) catch {};
}

/// A Space about to move to another window: its id and the window's visible Spaces it lands after, its position among them, and its new position among every visible Space.
const MovingToWindow = struct {
    space: MovingSpace,
    /// 0-based among the window's visible Spaces.
    position: usize,
    /// 0-based among every visible Space, which keeps the model's order matching the window's.
    index: usize,
};

/// Resolves a Space moving to the window `window_id` names in `windows_body`, at `position` among that window's visible Spaces or after the last of them.
fn movingSpaceToWindow(host: *Host, target: []const u8, near: []const u8, position: ?usize, windows_body: []const u8, window_id: []const u8) !MovingToWindow {
    const window = wire.WindowIterator.find(windows_body, window_id) orelse return error.NoSuchWindow;

    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const space = try host.findRequestedSpace(target, near);
    // A hidden Space has no visible position to move to.
    if (space.hidden) return error.HiddenSpace;

    // The window's visible Spaces other than the moving one, in the window's order.
    var shown: std.ArrayList([]const u8) = .empty;
    defer shown.deinit(host.alloc);
    var ids = window.spaceIds();
    while (ids.next()) |id| {
        if (std.mem.eql(u8, id, space.id)) continue;
        const other = host.model.findSpace(id) orelse continue;
        if (other.hidden) continue;
        try shown.append(host.alloc, id);
    }

    const landing = position orelse shown.items.len;
    if (landing > shown.items.len) return error.NoSuchPosition;

    var moving: MovingToWindow = .{
        .space = .{ .id = try host.alloc.dupe(u8, space.id) },
        .position = landing,
        .index = 0,
    };
    errdefer moving.space.deinit(host.alloc);

    for (shown.items[0..landing]) |id| {
        const copy = try host.alloc.dupe(u8, id);
        moving.space.after.append(host.alloc, copy) catch |err| {
            host.alloc.free(copy);
            return err;
        };
    }

    // Right after the window's Space it lands after, else right before the window's first, else where it already is.
    if (landing > 0) {
        moving.index = host.visibleIndexWithout(shown.items[landing - 1], space.id) + 1;
    } else if (shown.items.len > 0) {
        moving.index = host.visibleIndexWithout(shown.items[0], space.id);
    } else {
        moving.index = host.visibleIndexWithout(space.id, "");
    }
    return moving;
}

/// Where the Space with this id sits among the visible Spaces once `without` is left out. Caller must hold `model_mutex`.
fn visibleIndexWithout(host: *Host, id: []const u8, without: []const u8) usize {
    var index: usize = 0;
    for (host.model.spaces.items) |space| {
        if (std.mem.eql(u8, space.id, id)) return index;
        // Hidden Spaces hold no position, and the one left out doesn't count.
        if (space.hidden) continue;
        if (std.mem.eql(u8, space.id, without)) continue;
        index += 1;
    }
    return index;
}

/// A Space about to move: its id and the visible Spaces it lands after,
/// all owned by the caller.
const MovingSpace = struct {
    id: []u8,
    after: std.ArrayList([]u8) = .empty,

    fn deinit(self: *MovingSpace, alloc: Allocator) void {
        for (self.after.items) |id| alloc.free(id);
        self.after.deinit(alloc);
        alloc.free(self.id);
    }
};

/// Resolves the Space a move acts on once `index` is known to be a
/// visible position, and lists the visible Spaces that will precede it.
fn movingSpace(host: *Host, target: []const u8, near: []const u8, index: usize) !MovingSpace {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const space = try host.findRequestedSpace(target, near);
    // A hidden Space has no visible position to move to.
    if (space.hidden) return error.HiddenSpace;

    var moving: MovingSpace = .{ .id = try host.alloc.dupe(u8, space.id) };
    errdefer moving.deinit(host.alloc);

    var others: usize = 0;
    for (host.model.spaces.items) |other| {
        // Hidden Spaces hold no position, and the moving one doesn't precede itself.
        if (other.hidden) continue;
        if (std.mem.eql(u8, other.id, moving.id)) continue;

        if (others < index) {
            const id = try host.alloc.dupe(u8, other.id);
            moving.after.append(host.alloc, id) catch |err| {
                host.alloc.free(id);
                return err;
            };
        }
        others += 1;
    }
    if (index > others) return error.NoSuchPosition;
    return moving;
}

/// `REQUEST TAB new`: a tab at the end of the target Space, under an id
/// generated here so the caller can wait for it to show up in the model.
fn requestTabNew(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const name = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const directory = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const focus = fields.next() orelse return respondErr(host.io, conn, "missing field");
    if (directory.len == 0) return respondErr(host.io, conn, "missing directory");

    // Naming neither a Space nor the pane it came from, the tab joins the Space the user was last in.
    const focused: []u8 = if (target.len == 0 and near.len == 0)
        host.focusedId(.space) catch |err| return respondErr(host.io, conn, opErrorReason(err))
    else
        &.{};
    defer host.alloc.free(focused);

    const space_id = host.resolveSpace(if (focused.len > 0) focused else target, near) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer host.alloc.free(space_id);

    const tab_id = randomUuid(host.io);
    const delivered = host.events.publishTabNew(.{
        .space = space_id,
        .tab = &tab_id,
        .near = near,
        .name = name,
        .directory = directory,
        .focus = std.mem.eql(u8, focus, "1"),
    });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, &tab_id);
}

/// The id of the focused Space or pane, as a copy the caller frees.
fn focusedId(host: *Host, part: enum { space, pane }) ![]u8 {
    const held = (try host.focus.snapshot(host.alloc)) orelse return error.NothingFocused;
    defer held.deinit(host.alloc);
    return host.alloc.dupe(u8, switch (part) {
        .space => held.space,
        .pane => held.pane,
    });
}

/// The id of the Space a request acts on, as a copy the caller frees:
/// `target` when given, else the Space holding the pane the request came
/// from.
fn resolveSpace(host: *Host, target: []const u8, near: []const u8) ![]u8 {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const space = try host.findRequestedSpace(target, near);
    return host.alloc.dupe(u8, space.id);
}

/// The Space `target` names, else the one holding `near`. Caller must
/// already hold `model_mutex`.
fn findRequestedSpace(host: *Host, target: []const u8, near: []const u8) !*Model.Space {
    if (target.len > 0) return host.model.findSpace(target) orelse error.NoSuchSpace;
    if (near.len > 0) return host.model.findSpaceOfPane(near) orelse error.NoSuchPane;
    return error.MissingTarget;
}

/// The id of the tab a request acts on, as a copy the caller frees:
/// `target` when given, else the tab holding the pane the request came
/// from.
fn resolveTab(host: *Host, target: []const u8, near: []const u8) ![]u8 {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const tab = try host.findRequestedTab(target, near);
    return host.alloc.dupe(u8, tab.id);
}

/// The tab `target` names, else the one holding `near`. Caller must
/// already hold `model_mutex`.
fn findRequestedTab(host: *Host, target: []const u8, near: []const u8) !*Model.Tab {
    if (target.len > 0) {
        const found = host.model.findTab(target) orelse return error.NoSuchTab;
        return &found.space.tabs.items[found.index];
    }
    if (near.len > 0) return host.model.findTabOfPane(near) orelse error.NoSuchPane;
    return error.MissingTarget;
}

/// The pane a request acts on - `target` when given, else `near` itself - and the tab holding it. Caller must already hold `model_mutex`.
fn findRequestedPane(host: *Host, target: []const u8, near: []const u8) !struct { id: []const u8, tab: *Model.Tab } {
    const id = if (target.len > 0) target else near;
    if (id.len == 0) return error.MissingTarget;
    const tab = host.model.findTabOfPane(id) orelse return error.NoSuchPane;
    return .{ .id = id, .tab = tab };
}

/// A pane about to split, as copies the caller frees: its own id and its tab's.
const SplittingPane = struct {
    id: []u8,
    tab: []u8,

    fn deinit(self: SplittingPane, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.tab);
    }
};

/// Resolves the pane a split acts on.
fn splittingPane(host: *Host, target: []const u8, near: []const u8) !SplittingPane {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const found = try host.findRequestedPane(target, near);
    const id = try host.alloc.dupe(u8, found.id);
    errdefer host.alloc.free(id);
    return .{ .id = id, .tab = try host.alloc.dupe(u8, found.tab.id) };
}

/// `REQUEST PANE split`: a new pane beside the target, under an id
/// generated here so the caller can wait for it to show up in the model.
fn requestPaneSplit(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const direction_field = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const directory = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const focus = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const direction = std.meta.stringToEnum(wire.SplitDirection, direction_field) orelse return respondErr(host.io, conn, "bad direction");
    if (directory.len == 0) return respondErr(host.io, conn, "missing directory");

    // Naming neither a pane nor the one it came from, the split goes beside the pane the user was last in.
    const focused: []u8 = if (target.len == 0 and near.len == 0)
        host.focusedId(.pane) catch |err| return respondErr(host.io, conn, opErrorReason(err))
    else
        &.{};
    defer host.alloc.free(focused);

    const splitting = host.splittingPane(if (focused.len > 0) focused else target, near) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer splitting.deinit(host.alloc);

    // The app hands its surfaces' UUIDs to the daemon prefixed like this, so the new pane shows up in the model under this id.
    const surface = randomUuid(host.io);
    var pane_buf: [64]u8 = undefined;
    const pane_id = std.fmt.bufPrint(&pane_buf, "surface:{s}", .{&surface}) catch unreachable;

    const delivered = host.events.publishPaneSplit(.{
        .pane = splitting.id,
        .tab = splitting.tab,
        .surface = &surface,
        .direction = direction,
        .directory = directory,
        .focus = std.mem.eql(u8, focus, "1"),
    });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, pane_id);
}

/// What a layout command can close.
const Closable = enum { space, tab, pane };

/// A Space or tab about to be closed: its id and what runs in its panes,
/// both owned by the caller.
const Closing = struct {
    id: []u8,
    /// What runs in it, comma-separated, empty when nothing does.
    running: []u8,
    /// The tab a pane close takes with it, being its last pane; empty otherwise.
    whole_tab: []u8 = &.{},

    fn deinit(self: Closing, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.running);
        alloc.free(self.whole_tab);
    }
};

/// Appends a copy of the id of every pane in `tab` to `pane_ids`.
fn appendPaneIds(host: *Host, pane_ids: *std.ArrayList([]u8), tab: *const Model.Tab) !void {
    for (tab.panes.items) |pane| {
        const id = try host.alloc.dupe(u8, pane.id);
        pane_ids.append(host.alloc, id) catch |err| {
            host.alloc.free(id);
            return err;
        };
    }
}

/// Resolves the Space, tab or pane a close acts on and finds what runs in
/// it, leaving out the requesting command's own job.
fn closing(host: *Host, kind: Closable, target: []const u8, near: []const u8, requester_job: ?u32) !Closing {
    var pane_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (pane_ids.items) |id| host.alloc.free(id);
        pane_ids.deinit(host.alloc);
    }
    var whole_tab: []u8 = &.{};
    errdefer host.alloc.free(whole_tab);

    // Copied out so the panes are asked without holding the model lock.
    const id = blk: {
        host.model_mutex.lockUncancelable(host.io);
        defer host.model_mutex.unlock(host.io);

        switch (kind) {
            .space => {
                const space = try host.findRequestedSpace(target, near);
                for (space.tabs.items) |*tab| try host.appendPaneIds(&pane_ids, tab);
                break :blk try host.alloc.dupe(u8, space.id);
            },
            .tab => {
                const tab = try host.findRequestedTab(target, near);
                try host.appendPaneIds(&pane_ids, tab);
                break :blk try host.alloc.dupe(u8, tab.id);
            },
            .pane => {
                const found = try host.findRequestedPane(target, near);
                const pane_id = try host.alloc.dupe(u8, found.id);
                pane_ids.append(host.alloc, pane_id) catch |err| {
                    host.alloc.free(pane_id);
                    return err;
                };
                if (found.tab.panes.items.len == 1) whole_tab = try host.alloc.dupe(u8, found.tab.id);
                break :blk try host.alloc.dupe(u8, found.id);
            },
        }
    };
    errdefer host.alloc.free(id);

    return .{ .id = id, .running = try host.runningIn(pane_ids.items, requester_job), .whole_tab = whole_tab };
}

/// What runs in the panes with these ids, each name once and
/// comma-separated, as a copy the caller frees. A pane the daemon has no
/// process for runs nothing, nor does one whose foreground job is
/// `requester_job`.
fn runningIn(host: *Host, pane_ids: []const []const u8, requester_job: ?u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(host.alloc);

    for (pane_ids) |id| {
        const pane = host.retainPane(id) orelse continue;
        defer pane.release();

        // A command typed at a shell prompt holds the foreground while it runs, and it isn't something the close would end.
        if (requester_job != null and pane.processInfo().pgid == requester_job) continue;

        var name_buf: [256]u8 = undefined;
        const name = pane.runningCommand(&name_buf) orelse continue;
        // Two shells running the same thing say it once.
        if (listsName(out.items, name)) continue;

        if (out.items.len > 0) try out.appendSlice(host.alloc, ", ");
        try out.appendSlice(host.alloc, name);
    }
    return out.toOwnedSlice(host.alloc);
}

/// Whether the comma-separated `list` already holds `name`.
fn listsName(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, list, ", ");
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// `REQUEST SPACE close`, `REQUEST TAB close` and `REQUEST PANE close`:
/// refused while anything runs in it unless forced, and answered with what
/// a forced close ends.
fn requestClose(host: *Host, conn: net.Stream, kind: Closable, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const force_field = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const force = std.mem.eql(u8, force_field, "1");
    const job_field = fields.next() orelse return respondErr(host.io, conn, "missing field");
    const requester_job: ?u32 = std.fmt.parseInt(u32, job_field, 10) catch null;

    const closed = host.closing(kind, target, near, requester_job) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer closed.deinit(host.alloc);

    var wbuf: [512]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    if (!force and closed.running.len > 0) {
        wire.writeHeaderLine(&w.interface, "ERR running {s}", .{closed.running}) catch {};
        return;
    }

    const delivered = switch (kind) {
        .space => host.events.publishSpaceChange(.{ .space = closed.id, .change = .close }),
        .tab => host.events.publishTabChange(.{ .tab = closed.id, .change = .close }),
        // A tab left with no pane closes, as it does when the user closes its last split.
        .pane => if (closed.whole_tab.len > 0)
            host.events.publishTabChange(.{ .tab = closed.whole_tab, .change = .close })
        else
            host.events.publishPaneChange(closed.id, .close),
    };
    if (!delivered) return respondErr(host.io, conn, "app not running");

    if (closed.running.len == 0) {
        wire.writeHeaderLine(&w.interface, "OK {s}", .{closed.id}) catch {};
        return;
    }
    wire.writeHeaderLine(&w.interface, "OK {s} {s}", .{ closed.id, closed.running }) catch {};
}

/// `REQUEST TAB rename`: an empty name clears the tab's own name.
fn requestTabRename(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const name = fields.next() orelse return respondErr(host.io, conn, "missing field");

    const tab_id = host.resolveTab(target, near) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer host.alloc.free(tab_id);

    const delivered = host.events.publishTabChange(.{ .tab = tab_id, .change = .{ .rename = name } });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, tab_id);
}

/// `REQUEST TAB move`: a 0-based position within the tab's own Space,
/// refused past its last tab rather than quietly landing it last.
fn requestTabMove(host: *Host, conn: net.Stream, target: []const u8, near: []const u8, fields: *wire.FieldIterator) void {
    const index = nextIndex(fields) catch |err| return respondErr(host.io, conn, opErrorReason(err));

    const tab_id = host.resolveMovingTab(target, near, index) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer host.alloc.free(tab_id);

    const delivered = host.events.publishTabChange(.{ .tab = tab_id, .change = .{ .move = index } });
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, tab_id);
}

/// The id of the tab a move acts on, as a copy the caller frees, once
/// `index` is known to be a position within its Space.
fn resolveMovingTab(host: *Host, target: []const u8, near: []const u8, index: usize) ![]u8 {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const tab = try host.findRequestedTab(target, near);
    const found = host.model.findTab(tab.id) orelse return error.NoSuchTab;
    if (index >= found.space.tabs.items.len) return error.NoSuchPosition;
    return host.alloc.dupe(u8, tab.id);
}

/// The id of the Space, tab or pane a focus acts on, as a copy the caller frees.
fn resolveFocusing(host: *Host, scope: Scope, target: []const u8, near: []const u8) ![]u8 {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    return host.alloc.dupe(u8, switch (scope) {
        .space => (try host.findRequestedSpace(target, near)).id,
        .tab => (try host.findRequestedTab(target, near)).id,
        .pane => (try host.findRequestedPane(target, near)).id,
    });
}

/// `REQUEST SPACE focus`, `REQUEST TAB focus` and `REQUEST PANE focus`: the
/// app shows it and brings its window to the front. Nothing changes here;
/// the app's focus report that follows is what the caller waits for.
fn requestFocus(host: *Host, conn: net.Stream, scope: Scope, target: []const u8, near: []const u8) void {
    const id = host.resolveFocusing(scope, target, near) catch |err| return respondErr(host.io, conn, opErrorReason(err));
    defer host.alloc.free(id);

    const delivered = switch (scope) {
        .space => host.events.publishSpaceChange(.{ .space = id, .change = .focus }),
        .tab => host.events.publishTabChange(.{ .tab = id, .change = .focus }),
        .pane => host.events.publishPaneChange(id, .focus),
    };
    if (!delivered) return respondErr(host.io, conn, "app not running");
    respondOkRequest(host.io, conn, id);
}

/// Answers a request with `OK <id>`.
fn respondOkRequest(io: Io, conn: net.Stream, id: []const u8) void {
    var wbuf: [128]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {s}", .{id}) catch {};
}

/// Brings the model's per-pane facts up to date from the panes that are
/// actually running: the directory a restored pane reopens in, and the
/// title a client shows next to it. Also settles any Space still waiting
/// on its default name, now that its starter pane has a directory.
fn syncPaneFacts(host: *Host) void {
    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    const revision_before = host.model.file_revision;
    const client_revision_before = host.model.revision;
    for (host.model.spaces.items) |*space| {
        for (space.tabs.items) |*tab| {
            for (tab.panes.items) |*entry| {
                const pane = host.retainPane(entry.id) orelse continue;
                defer pane.release();

                // Both facts live behind the pane's own mutex, and the
                // model copies them, so the copy happens while it is held.
                var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                pane.mutex.lockUncancelable(host.io);
                host.model.setDirectory(entry, pane.directoryLocked(&dir_buf)) catch {};
                host.model.setTitle(entry, pane.titleLocked()) catch {};
                host.model.setAgentFacts(entry, agentFacts(pane.agentReportLocked()));
                pane.mutex.unlock(host.io);
            }
        }
    }

    host.model.deriveDefaultNames(paths.homeDir()) catch {};

    // `file_revision`, not `revision`: a pane's title moves the latter on
    // every spinner frame an agent draws, and none of it is in the file.
    if (host.model.file_revision != revision_before) host.model_dirty.store(true, .release);
    if (host.model.revision != client_revision_before) host.events.publishModelChanged(host.model.revision);
}

fn agentFacts(report: Pane.AgentReport) Model.AgentFacts {
    return .{
        .agent = if (report.agent) |a| a.agentLabel() else null,
        .state = report.state.name(),
        .attention = report.status().name(),
        .seen = report.seen(),
        .state_seq = report.state_seq,
        .recency = report.recency.change_seq,
    };
}

/// The live pane with this id, retained for the caller: a `KILL` for it
/// can land the instant the registry lock drops, and the registry's own
/// reference is the only other one keeping the pane's memory alive.
fn retainPane(host: *Host, id: []const u8) ?*Pane {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);

    const pane = host.panes.get(id) orelse return null;
    pane.retain();
    return pane;
}

/// Takes ended panes out of the model: a pane the daemon just killed is
/// not something to bring back on the next start.
fn forgetPanes(host: *Host, panes: []const *Pane) void {
    if (panes.len == 0) return;

    host.model_mutex.lockUncancelable(host.io);
    defer host.model_mutex.unlock(host.io);

    var removed = false;
    for (panes) |pane| {
        if (host.model.removePane(pane.id)) removed = true;
    }
    if (!removed) return;
    host.model_dirty.store(true, .release);
    host.events.publishModelChanged(host.model.revision);
}

/// Writes the model out if anything changed since the last write. The
/// document is rendered under the model lock and written outside it, so
/// a slow disk never blocks a client asking what exists.
fn flushModel(host: *Host) void {
    const path = host.model_path orelse return;
    if (!host.model_dirty.swap(false, .acq_rel)) return;

    host.model_mutex.lockUncancelable(host.io);
    const rendered = host.model.renderFile(host.alloc);
    host.model_mutex.unlock(host.io);

    const bytes = rendered catch {
        host.model_dirty.store(true, .release);
        return;
    };
    defer host.alloc.free(bytes);

    Model.writeBytes(host.io, path, bytes) catch |err| {
        log.warn("could not write the model to {s}: {t}", .{ path, err });
        host.model_dirty.store(true, .release);
    };
}

/// Collects changes for `model_flush_interval_ms` at a time rather than
/// writing on every mutation: a structural change arrives once per user
/// gesture, but a pane's directory changes on every `cd`.
fn modelFlushLoop(host: *Host) void {
    while (true) {
        var waited: u32 = 0;
        while (waited < model_flush_interval_ms) : (waited += shutdown_poll_ms) {
            if (shutdown_requested.load(.acquire)) {
                host.syncPaneFacts();
                host.flushModel();
                std.process.exit(0);
            }
            std.Io.sleep(host.io, .fromMilliseconds(shutdown_poll_ms), .awake) catch {};
        }

        host.syncPaneFacts();
        host.flushModel();
    }
}

/// Starts checking every pane for agents, on a thread of its own.
pub fn startDetection(host: *Host) !void {
    host.detection_stop.store(false, .release);
    host.detection_thread = try std.Thread.spawn(.{}, detectionLoop, .{host});
}

/// Stops the detection thread and waits for it, if one is running.
fn stopDetection(host: *Host) void {
    const thread = host.detection_thread orelse return;
    host.detection_stop.store(true, .release);
    thread.join();
    host.detection_thread = null;
}

/// Checks each pane whenever its detector says it is due, then sleeps until
/// the soonest next one.
///
/// Detection runs on this timer rather than on output, so a chatty agent
/// cannot storm it and a pane that goes quiet still gets checked - an agent
/// that finishes prints nothing more, and only a timer can notice it has.
/// Output only marks a pane's screen dirty for the next check to read.
///
/// Uses the detection engine directly with its bundled rules. The manifest
/// cache, local overrides and remote updates depend on the GUI's global
/// runtime state, which this process never initialises, so they are not
/// reachable from here - the same rules the GUI's own detector compiles.
fn detectionLoop(host: *Host) void {
    // Kept across rounds, so collecting the panes allocates only when their
    // number outgrows every round before it.
    var due: std.ArrayList(*Pane) = .empty;
    defer due.deinit(host.alloc);

    while (!host.detection_stop.load(.acquire)) {
        due.clearRetainingCapacity();
        host.mutex.lockUncancelable(host.io);
        var it = host.panes.valueIterator();
        while (it.next()) |pane| {
            due.append(host.alloc, pane.*) catch continue;
            pane.*.retain();
        }
        host.mutex.unlock(host.io);

        const now = nowMs(host.io);
        var next = now + detection_max_sleep_ms;
        for (due.items) |pane| {
            next = @min(next, pane.checkAgent(now));
            pane.release();
        }

        const wait = std.math.clamp(next - nowMs(host.io), 1, detection_max_sleep_ms);
        std.Io.sleep(host.io, .fromMilliseconds(wait), .awake) catch {};
    }
}

fn nowMs(io: Io) i64 {
    const now = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}

/// `SUBSCRIBE <version> <kind> [capability ...]`: a long-lived connection
/// the daemon pushes events down. See `wire.zig` for the version rules and
/// the order a client catches up in.
fn handleSubscribe(
    host: *Host,
    conn: net.Stream,
    reader: *Io.Reader,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    const version = parseU32(it.next()) orelse return respondErr(host.io, conn, "missing protocol version");
    const kind = wire.ClientKind.parse(it.next() orelse "") orelse
        return respondErr(host.io, conn, "unknown client kind: expected app or client");

    var reason_buf: [200]u8 = undefined;
    const speaks = switch (wire.negotiate(kind, version, &reason_buf)) {
        .speaks => |v| v,
        .refused => |reason| return respondErr(host.io, conn, reason),
    };

    // Registered before the revision is read, so any change after that
    // read is also an event this client receives.
    const sub = host.events.subscribe(conn, kind) catch return respondErr(host.io, conn, "oom");

    host.model_mutex.lockUncancelable(host.io);
    const revision = host.model.revision;
    host.model_mutex.unlock(host.io);

    var wbuf: [512]u8 = undefined;
    var w = conn.writer(host.io, &wbuf);
    w.interface.print("OK {d} {s} {d} ", .{ speaks, &host.model.run_id, revision }) catch {};
    wire.writeCapabilities(&w.interface, it) catch {};
    w.interface.writeAll("\n") catch {};
    w.interface.flush() catch {};

    host.events.serve(sub, reader, &host.focus, &host.windows);
}

fn handleAttach(
    host: *Host,
    conn: net.Stream,
    reader: *Io.Reader,
    it: *std.mem.TokenIterator(u8, .scalar),
) void {
    const id = it.next() orelse {
        respondErr(host.io, conn, "missing id");
        conn.close(host.io);
        return;
    };

    const p = host.retainPane(id) orelse {
        respondErr(host.io, conn, "no such pane");
        conn.close(host.io);
        return;
    };
    defer p.release();

    const attached = p.attach(conn) catch {
        respondErr(host.io, conn, "attach failed");
        conn.close(host.io);
        return;
    };
    defer host.alloc.free(attached.snapshot);

    {
        var wbuf: [4096]u8 = undefined;
        var w = conn.writer(host.io, &wbuf);
        wire.writeHeaderLine(&w.interface, "OK", .{}) catch {};
        wire.writeHeaderLine(&w.interface, "META {d} {d}", .{
            attached.pgid orelse 0,
            attached.child_pid orelse 0,
        }) catch {};
        wire.writeFrame(&w.interface, "SNAPSHOT", attached.snapshot) catch {};
    }
    // What the pane's agent is doing as of the snapshot, so a client knows
    // from the start rather than from the next change.
    p.writeStatusFrame(attached.sub, attached.report) catch {};
    attached.sub.write_mutex.unlock(host.io);
    host.events.publishAttachment(.attached, p.id, p.subscriberCount());

    // From here on this thread only reads what the client sends; all writes
    // to `conn` happen from the pane's own threads via its broadcasts,
    // except the replays below.
    while (true) {
        const maybe_line = wire.readHeader(host.alloc, reader) catch break;
        const line = maybe_line orelse break;
        defer host.alloc.free(line);

        var lit = std.mem.tokenizeScalar(u8, line, ' ');
        const sub_cmd = lit.next() orelse continue;
        if (std.mem.eql(u8, sub_cmd, "INPUT")) {
            const len = parseUsize(lit.next()) orelse continue;
            const body = wire.readBody(host.alloc, reader, len) catch break;
            defer host.alloc.free(body);
            p.writeInput(body) catch {};
        } else if (std.mem.eql(u8, sub_cmd, "RESIZE")) {
            const cols = parseU16(lit.next()) orelse continue;
            const rows = parseU16(lit.next()) orelse continue;
            p.resize(cols, rows) catch {};

            // A dump is only correct on a screen the size it was made for: it
            // pads to the pane's rows and ends in an absolute cursor position.
            // A client's screen is not that size when the ATTACH snapshot
            // lands - the macOS app's surfaces are born at 800x600 and only
            // learn their real geometry from layout - so the padding scrolls
            // the content off a shorter screen. Right after a RESIZE, though,
            // the pane is exactly the size of the screen that sent it, so a
            // snapshot taken now is built for the screen it lands on.
            if (p.resnapshot(attached.sub)) |snap| {
                defer host.alloc.free(snap);
                var wbuf: [4096]u8 = undefined;
                var w = conn.writer(host.io, &wbuf);
                wire.writeFrame(&w.interface, "SNAPSHOT", snap) catch {};
                attached.sub.write_mutex.unlock(host.io);
            } else |_| {}
        } else if (std.mem.eql(u8, sub_cmd, "VIEW")) {
            const value = lit.next() orelse continue;
            p.setViewing(attached.sub, std.mem.eql(u8, value, "1"));
        } else if (std.mem.eql(u8, sub_cmd, "SEEN")) {
            const state_seq = parseU64(lit.next()) orelse continue;
            p.markSeen(state_seq);
        }
    }

    p.removeSubscriber(conn);
    host.events.publishAttachment(.detached, p.id, p.subscriberCount());
    conn.close(host.io);
}

fn respondErr(io: Io, conn: net.Stream, reason: []const u8) void {
    var wbuf: [512]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "ERR {s}", .{reason}) catch {};
}

fn respondOkId(io: Io, conn: net.Stream, id: []const u8, outcome: wire.CreateOutcome) void {
    var wbuf: [512]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {s} {s}", .{ id, outcome.token() }) catch {};
}

/// `VERSION`: the protocol and daemon versions this daemon was built with.
fn respondOkVersions(io: Io, conn: net.Stream) void {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {d} {d}", .{ wire.protocol_version, wire.daemon_version }) catch {};
}

fn respondOkCount(io: Io, conn: net.Stream, count: usize) void {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {d}", .{count}) catch {};
}

/// A model operation's acknowledgement: the revision it produced, which
/// is what a client checks its own cached copy against.
fn respondOkRevision(io: Io, conn: net.Stream, revision: u64) void {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    wire.writeHeaderLine(&w.interface, "OK {d}", .{revision}) catch {};
}

fn parseU16(tok: ?[]const u8) ?u16 {
    return std.fmt.parseInt(u16, tok orelse return null, 10) catch null;
}

fn parseU32(tok: ?[]const u8) ?u32 {
    const t = tok orelse return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

fn parseU64(tok: ?[]const u8) ?u64 {
    const t = tok orelse return null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

fn parseUsize(tok: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, tok orelse return null, 10) catch null;
}

fn randomId(io: Io) [32]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// A random version 4 UUID in the uppercase form the app gives its own
/// Spaces and tabs, so an id made here reads the same as one made there.
fn randomUuid(io: Io) [36]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = std.fmt.bytesToHex(bytes, .upper);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

const testing = std.testing;

/// Frees every live pane and the registry itself. `Host.run` never does
/// this (a pane outliving every client is the point), so tests own it.
/// Panes are terminated first: `Pane.deinit` joins the reader thread,
/// which only ends once the child's pty hits EOF.
fn deinitTestHost(host: *Host) void {
    host.stopDetection();
    var vit = host.panes.valueIterator();
    while (vit.next()) |p| {
        p.*.terminate();
        p.*.release();
    }
    host.deinit();
}

fn uniqueSocketPath(tag: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    testing.io.random(&rand_bytes);
    return std.fmt.allocPrint(testing.allocator, "/tmp/coastty-host-test-{s}-{s}.sock", .{
        tag,
        std.fmt.bytesToHex(rand_bytes, .lower),
    });
}

/// Runs `handleConnection` against exactly one accepted connection, then
/// returns. A test's server thread body: no long-lived accept loop to
/// stop afterward, since each `TestConn` only ever serves one request.
fn acceptOnceAndHandle(host: *Host, listener: *net.Server) void {
    const conn = listener.accept(testing.io) catch |err| {
        log.warn("test: accept failed: {}", .{err});
        return;
    };
    host.handleConnection(conn);
}

/// One test-only client connection to a `Host`: binds a fresh, uniquely
/// named socket, accepts exactly one connection on a background thread
/// through the real `handleConnection` path, and connects a client to it.
/// Heap-allocated so the listener's address stays stable for the thread
/// regardless of where the caller stores the returned pointer.
const TestConn = struct {
    path: []const u8,
    listener: net.Server,
    thread: std.Thread,
    client: net.Stream,
    /// The host's token, for the requests that need it.
    token: access.Token,

    fn open(host: *Host, tag: []const u8) !*TestConn {
        const path = try uniqueSocketPath(tag);
        errdefer testing.allocator.free(path);

        const addr = try net.UnixAddress.init(path);
        const listener = try addr.listen(testing.io, .{});
        errdefer {
            var l = listener;
            l.deinit(testing.io);
        }

        const self = try testing.allocator.create(TestConn);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .path = path, .listener = listener, .thread = undefined, .client = undefined, .token = host.token };

        self.thread = try std.Thread.spawn(.{}, acceptOnceAndHandle, .{ host, &self.listener });
        self.client = addr.connect(testing.io) catch |err| {
            self.thread.join();
            self.listener.deinit(testing.io);
            testing.allocator.free(path);
            testing.allocator.destroy(self);
            return err;
        };
        return self;
    }

    /// Closes the client end (so a still-open ATTACH loop on the server
    /// side sees EOF and unwinds), joins the server thread, and cleans
    /// up the socket.
    fn finish(self: *TestConn) void {
        self.client.close(testing.io);
        self.thread.join();
        self.listener.deinit(testing.io);
        std.Io.Dir.cwd().deleteFile(testing.io, self.path) catch {};
        testing.allocator.free(self.path);
        testing.allocator.destroy(self);
    }
};

/// A `CREATE` response: the id the daemon settled on, owned by the
/// caller, plus what it did with it.
const Created = struct { id: []u8, outcome: wire.CreateOutcome };

fn sendCreate(
    conn: net.Stream,
    token: *const access.Token,
    id: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    cols: u16,
    rows: u16,
) !Created {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, id);
    try body.append(testing.allocator, 0);
    try body.appendSlice(testing.allocator, cwd);
    for (argv) |a| {
        try body.append(testing.allocator, 0);
        try body.appendSlice(testing.allocator, a);
    }

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    try w.interface.print("CREATE {d} {d} {d} {s}\n", .{ cols, rows, body.items.len, token });
    try w.interface.writeAll(body.items);
    try w.interface.flush();

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(testing.io, &rbuf);
    const resp = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(resp);
    if (!std.mem.startsWith(u8, resp, "OK ")) return error.CreateFailed;

    const tail = resp["OK ".len..];
    var rit = std.mem.tokenizeScalar(u8, tail, ' ');
    const created_id = rit.next() orelse return error.CreateFailed;
    const outcome = wire.parseCreateOutcome(tail) orelse return error.CreateFailed;
    return .{ .id = try testing.allocator.dupe(u8, created_id), .outcome = outcome };
}

/// Sends `verb` (`KILL` or `SWEEP`) with `ids` and returns the count the
/// daemon reports having killed.
fn sendIdCommand(conn: net.Stream, token: *const access.Token, verb: []const u8, ids: []const []const u8) !usize {
    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    const token_arg: access.TokenArg = .init(token);
    try wire.writeIdCommandLine(&w.interface, verb, ids, token_arg.text());

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(testing.io, &rbuf);
    const resp = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(resp);
    if (!std.mem.startsWith(u8, resp, "OK ")) return error.CommandFailed;
    return std.fmt.parseInt(usize, resp["OK ".len..], 10);
}

const ListEntry = struct { id: []u8, cols: u16, rows: u16, alive: bool };

fn sendList(conn: net.Stream) ![]ListEntry {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "LIST", .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(testing.io, &rbuf);
    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    if (!std.mem.startsWith(u8, status, "OK ")) return error.ListFailed;
    const n = try std.fmt.parseInt(usize, status["OK ".len..], 10);

    var entries: std.ArrayList(ListEntry) = .empty;
    errdefer {
        for (entries.items) |e| testing.allocator.free(e.id);
        entries.deinit(testing.allocator);
    }
    for (0..n) |_| {
        const line = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
        defer testing.allocator.free(line);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const id = try testing.allocator.dupe(u8, it.next() orelse return error.BadLine);
        const cols = try std.fmt.parseInt(u16, it.next() orelse return error.BadLine, 10);
        const rows = try std.fmt.parseInt(u16, it.next() orelse return error.BadLine, 10);
        const alive = try std.fmt.parseInt(u1, it.next() orelse return error.BadLine, 10);
        try entries.append(testing.allocator, .{ .id = id, .cols = cols, .rows = rows, .alive = alive == 1 });
    }
    return entries.toOwnedSlice(testing.allocator);
}

fn freeListEntries(entries: []ListEntry) void {
    for (entries) |e| testing.allocator.free(e.id);
    testing.allocator.free(entries);
}

/// Sends one model operation (`SPACE new`, `PANE move`, ...) with its
/// fields as the NUL-separated body the daemon expects, and returns the
/// revision it reports.
fn sendModelOp(conn: net.Stream, verb: []const u8, op: []const u8, fields: []const []const u8) !u64 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (fields, 0..) |field, i| {
        if (i > 0) try body.append(testing.allocator, 0);
        try body.appendSlice(testing.allocator, field);
    }

    var wbuf: [4096]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    try w.interface.print("{s} {s} {d}\n", .{ verb, op, body.items.len });
    try w.interface.writeAll(body.items);
    try w.interface.flush();

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(testing.io, &rbuf);
    const resp = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(resp);
    if (!std.mem.startsWith(u8, resp, "OK ")) return error.OpFailed;
    return std.fmt.parseInt(u64, resp["OK ".len..], 10);
}

/// Fetches the whole model document. Caller owns the bytes.
fn fetchModel(conn: net.Stream) ![]u8 {
    var wbuf: [64]u8 = undefined;
    var w = conn.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "MODEL", .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = conn.reader(testing.io, &rbuf);
    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    if (!std.mem.startsWith(u8, status, "OK ")) return error.ModelFailed;

    const len = try std.fmt.parseInt(usize, status["OK ".len..], 10);
    return wire.readBody(testing.allocator, &r.interface, len);
}

/// A unique path under /tmp for a test that lets a host write a real
/// model file.
fn uniqueModelPath(tag: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    testing.io.random(&rand_bytes);
    return std.fmt.allocPrint(testing.allocator, "/tmp/coastty-host-model-{s}-{s}/model.json", .{
        tag,
        std.fmt.bytesToHex(rand_bytes, .lower),
    });
}

fn removeModelDir(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().deleteTree(testing.io, parent) catch {};
}

/// Builds the same one-Space, one-tab shape through the wire protocol
/// that a GUI reporting a brand new window would.
fn buildTestModel(host: *Host) !void {
    const tc_space = try TestConn.open(host, "model-space");
    defer tc_space.finish();
    _ = try sendModelOp(tc_space.client, "SPACE", "new", &.{ "space-a", "" });

    const tc_tab = try TestConn.open(host, "model-tab");
    defer tc_tab.finish();
    _ = try sendModelOp(tc_tab.client, "TAB", "new", &.{ "space-a", "tab-1", "build" });

    const tc_pane = try TestConn.open(host, "model-pane");
    defer tc_pane.finish();
    _ = try sendModelOp(tc_pane.client, "PANE", "move", &.{ "surface:p1", "tab-1", "0" });
}

/// Stands in for Claude Code: Perl run through a link named `claude`, which
/// the probe identifies by name. It shows a working spinner in its title,
/// switches to Claude's idle title, and then prints nothing more - the case
/// only a timer can resolve.
const fake_agent_argv = [_][]const u8{
    "/bin/sh",
    "-c",
    "d=/tmp/coastty-fake-claude-$$; mkdir -p \"$d\"; ln -sf /usr/bin/perl \"$d/claude\"; (sleep 2; rm -rf \"$d\") & exec \"$d/claude\" -e '$|=1; print \"\\e]0;\\xe2\\xa0\\x82 working\\a\"; select(undef,undef,undef,5); print \"\\e]0;\\xe2\\x9c\\xb3 Claude Code\\a\"; sleep 30'",
};

/// Shuts a connection's reading side if a test is still waiting on it after
/// `ms`, so a status that never arrives fails the test rather than hanging
/// the suite.
const ReadDeadline = struct {
    conn: net.Stream,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *ReadDeadline, ms: u32) !void {
        self.thread = try std.Thread.spawn(.{}, watch, .{ self, ms });
    }

    fn watch(self: *ReadDeadline, ms: u32) void {
        var waited: u32 = 0;
        while (waited < ms) : (waited += shutdown_poll_ms) {
            if (self.stop.load(.acquire)) return;
            std.Io.sleep(testing.io, .fromMilliseconds(shutdown_poll_ms), .awake) catch {};
        }
        self.conn.shutdown(testing.io, .recv) catch {};
    }

    fn finish(self: *ReadDeadline) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
    }
};

/// Attaches to `id`; the reply is left for the caller to read.
fn attachForStatus(host: *Host, tag: []const u8, id: []const u8) !*TestConn {
    const tc = try TestConn.open(host, tag);
    errdefer tc.finish();
    var wbuf: [128]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ id, &tc.token });
    return tc;
}

/// Reads frames until a `STATUS` whose attention state is `want` arrives, and
/// returns its parsed body.
fn awaitStatus(reader: *Io.Reader, want: []const u8) !std.json.Parsed(std.json.Value) {
    while (true) {
        const line = (try wire.readHeader(testing.allocator, reader)) orelse return error.NoResponse;
        defer testing.allocator.free(line);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = it.next() orelse continue;
        if (std.mem.eql(u8, tag, "OK") or std.mem.eql(u8, tag, "META")) continue;

        const len = try std.fmt.parseInt(usize, it.next() orelse return error.ProtocolError, 10);
        const body = try wire.readBody(testing.allocator, reader, len);
        defer testing.allocator.free(body);
        if (!std.mem.eql(u8, tag, "STATUS")) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
        if (std.mem.eql(u8, parsed.value.object.get("attention").?.string, want)) return parsed;
        parsed.deinit();
    }
}

/// Opens `SUBSCRIBE` with `request` and returns the connection with its
/// answer line, which the caller frees.
fn openSubscription(host: *Host, tag: []const u8, request: []const u8) !struct { tc: *TestConn, answer: []u8 } {
    const tc = try TestConn.open(host, tag);
    errdefer tc.finish();
    var wbuf: [256]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "SUBSCRIBE {s}", .{request});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    const answer = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    return .{ .tc = tc, .answer = answer };
}

/// Reads `EVENT` frames until one named `name` arrives, and returns it.
fn awaitEvent(reader: *Io.Reader, name: []const u8) !std.json.Parsed(std.json.Value) {
    while (true) {
        const line = (try wire.readHeader(testing.allocator, reader)) orelse return error.NoResponse;
        defer testing.allocator.free(line);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, it.next() orelse "", "EVENT")) return error.ProtocolError;
        const len = try std.fmt.parseInt(usize, it.next() orelse return error.ProtocolError, 10);
        const body = try wire.readBody(testing.allocator, reader, len);
        defer testing.allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
        if (std.mem.eql(u8, parsed.value.object.get("event").?.string, name)) return parsed;
        parsed.deinit();
    }
}

/// Reads headers until one that is neither `META` nor `STATUS` arrives.
/// Both can show up anywhere in an attached stream - a `META` whenever the
/// foreground process group changes, a `STATUS` after the snapshot and on
/// every status change - including right where a test expects a
/// `SNAPSHOT` or `DATA` frame, so tests that don't care skip past them.
fn readHeaderSkippingMeta(alloc: Allocator, reader: *Io.Reader) !?[]u8 {
    while (true) {
        const line = (try wire.readHeader(alloc, reader)) orelse return null;
        if (std.mem.startsWith(u8, line, "META ")) {
            alloc.free(line);
            continue;
        }
        if (std.mem.startsWith(u8, line, "STATUS ")) {
            const len = std.fmt.parseInt(usize, line["STATUS ".len..], 10) catch {
                alloc.free(line);
                return error.ProtocolError;
            };
            alloc.free(line);
            const body = try wire.readBody(alloc, reader, len);
            alloc.free(body);
            continue;
        }
        return line;
    }
}

test "CREATE assigns a fresh id and LIST reports it" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc1 = try TestConn.open(&host, "create");
    defer tc1.finish();
    const id = (try sendCreate(tc1.client, &tc1.token, "", "/", &.{ "/bin/sh", "-c", "true" }, 80, 24)).id;
    defer testing.allocator.free(id);
    try testing.expect(id.len > 0);

    const tc2 = try TestConn.open(&host, "list");
    defer tc2.finish();
    const entries = try sendList(tc2.client);
    defer freeListEntries(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(id, entries[0].id);
    try testing.expectEqual(@as(u16, 80), entries[0].cols);
    try testing.expectEqual(@as(u16, 24), entries[0].rows);
}

test "CREATE with a missing argv is rejected" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc = try TestConn.open(&host, "noargv");
    defer tc.finish();
    try testing.expectError(error.CreateFailed, sendCreate(tc.client, &tc.token, "", "/", &.{}, 80, 24));
}

test "CREATE reuse hands back the same live pane and leaves its size alone" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc1 = try TestConn.open(&host, "reuse-a");
    defer tc1.finish();
    const id1 = (try sendCreate(tc1.client, &tc1.token, "stable-tab", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id1);

    // A second CREATE naming the same id, as a reattach, should hand back
    // the exact same pane rather than spawn another - and keep the size it
    // already had, since the geometry a reattach arrives with is measured
    // before the caller's window has laid out. Resizing to it would rewrap
    // the scrollback the ATTACH after this is about to replay.
    const tc2 = try TestConn.open(&host, "reuse-b");
    defer tc2.finish();
    const id2 = (try sendCreate(tc2.client, &tc2.token, "stable-tab", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 120, 40)).id;
    defer testing.allocator.free(id2);
    try testing.expectEqualStrings(id1, id2);
    try testing.expectEqual(@as(usize, 1), host.panes.count());

    const tc3 = try TestConn.open(&host, "reuse-list");
    defer tc3.finish();
    const entries = try sendList(tc3.client);
    defer freeListEntries(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u16, 80), entries[0].cols);
    try testing.expectEqual(@as(u16, 24), entries[0].rows);
}

test "ATTACH to an unknown id fails" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc = try TestConn.open(&host, "attach-unknown");
    defer tc.finish();

    var wbuf: [128]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH nope {s}", .{&tc.token});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    try testing.expect(std.mem.startsWith(u8, status, "ERR"));
}

/// Sends `line` and checks it is refused as unauthorized and the connection closed after it.
fn expectUnauthorized(host: *Host, line: []const u8) !void {
    const tc = try TestConn.open(host, "unauthorized");
    defer tc.finish();

    var wbuf: [256]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "{s}", .{line});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    const answer = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("ERR unauthorized", answer);
    try testing.expect(try wire.readHeader(testing.allocator, &r.interface) == null);
}

test "ATTACH with no token or a wrong one is refused as unauthorized and the connection closed" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    try spawnModelPane(&host, "surface:guarded", &.{ "/bin/sh", "-c", "sleep 30" });

    var wrong = host.token;
    wrong[0] = if (wrong[0] == '0') '1' else '0';
    var line_buf: [128]u8 = undefined;
    const wrong_line = try std.fmt.bufPrint(&line_buf, "ATTACH surface:guarded {s}", .{&wrong});

    try expectUnauthorized(&host, "ATTACH surface:guarded");
    try expectUnauthorized(&host, wrong_line);
}

test "CREATE, KILL and SWEEP without the token are refused and leave the panes alone" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    try spawnModelPane(&host, "surface:guarded", &.{ "/bin/sh", "-c", "sleep 30" });

    try expectUnauthorized(&host, "CREATE 80 24 0");
    try expectUnauthorized(&host, "KILL surface:guarded");
    try expectUnauthorized(&host, "SWEEP");

    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    try testing.expectEqual(@as(u32, 1), host.panes.count());
}

test "VERSION answers with this build's protocol and daemon versions and needs no token" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc = try TestConn.open(&host, "version");
    defer tc.finish();
    var wbuf: [64]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "VERSION", .{});

    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    const answer = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(answer);
    const versions = upgrade.parseAnswer(answer) orelse return error.NotParsed;
    try testing.expectEqual(upgrade.ours, versions);
    try testing.expectEqual(upgrade.Action.keep, upgrade.decide(versions, upgrade.ours));
}

test "SUBSCRIBE as the app needs the token" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    var line_buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "SUBSCRIBE {d} app", .{wire.protocol_version});
    try expectUnauthorized(&host, line);
}

test "LIST, MODEL, REQUEST and a client subscription need no token" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_list = try TestConn.open(&host, "open-list");
    defer tc_list.finish();
    const entries = try sendList(tc_list.client);
    freeListEntries(entries);

    const tc_model = try TestConn.open(&host, "open-model");
    defer tc_model.finish();
    const document = try fetchModel(tc_model.client);
    testing.allocator.free(document);

    // Refused for want of a focused Space to put the tab in, not for want of a token.
    const tc_request = try TestConn.open(&host, "open-request");
    defer tc_request.finish();
    var wbuf: [256]u8 = undefined;
    var w = tc_request.client.writer(testing.io, &wbuf);
    try wire.writeRequest(&w.interface, .tab, "new", &.{ "", "", "", "/", "0" });
    var rbuf: [wire.max_header_len]u8 = undefined;
    var r = tc_request.client.reader(testing.io, &rbuf);
    const answer = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("ERR nothing focused", answer);

    const sub = try openSubscription(&host, "open-subscribe", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    try testing.expect(std.mem.startsWith(u8, sub.answer, "OK "));
}

test "a pane's environment never carries the token" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    var path_buf: [96]u8 = undefined;
    const env_path = try std.fmt.bufPrint(&path_buf, "/tmp/coastty-host-env-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(testing.io, env_path) catch {};
    var script_buf: [160]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "env > {s}.part && mv {s}.part {s}; sleep 30", .{ env_path, env_path, env_path });

    try spawnModelPane(&host, "surface:env", &.{ "/bin/sh", "-c", script });

    var env_buf: [64 * 1024]u8 = undefined;
    var waited: u32 = 0;
    const env = while (waited < 5000) : (waited += 20) {
        if (std.Io.Dir.cwd().readFile(testing.io, env_path, &env_buf)) |bytes| break bytes else |_| {}
        std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
    } else return error.NoEnvWritten;

    try testing.expect(env.len > 0);
    try testing.expect(std.mem.indexOf(u8, env, &host.token) == null);
}

test "ATTACH reports the pane's real foreground pgid and child pid via META" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "meta-create");
    defer tc_create.finish();
    const id = (try sendCreate(tc_create.client, &tc_create.token, "", "/", &.{
        "/bin/sh", "-c", "sleep 0.3",
    }, 80, 24)).id;
    defer testing.allocator.free(id);

    const tc = try TestConn.open(&host, "meta-attach");
    defer tc.finish();

    var wbuf: [128]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ id, &tc.token });

    var rbuf: [4096]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);

    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("OK", status);

    const meta = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(meta);
    var mit = std.mem.tokenizeScalar(u8, meta, ' ');
    try testing.expectEqualStrings("META", mit.next().?);
    const pgid = try std.fmt.parseInt(u32, mit.next().?, 10);
    const child_pid = try std.fmt.parseInt(u32, mit.next().?, 10);

    // A GUI client relies on these being the real, global process ids of
    // the pane's own child (see `agent-detection`, which looks up
    // whatever process actually owns a pgid it's handed) - not a
    // sentinel or a value scoped to the host process somehow.
    try testing.expect(pgid > 0);
    try testing.expect(child_pid > 0);
}

test "ATTACH streams a snapshot, then live pty output as it arrives" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "attach-create");
    defer tc_create.finish();
    const id = (try sendCreate(tc_create.client, &tc_create.token, "", "/", &.{
        "/bin/sh", "-c", "sleep 0.2; printf livedata",
    }, 80, 24)).id;
    defer testing.allocator.free(id);

    // Attach immediately: the child hasn't printed anything yet, so the
    // snapshot should catch it with a blank screen and "livedata" should
    // only show up afterward, as a live DATA frame.
    const tc = try TestConn.open(&host, "attach-stream");
    defer tc.finish();

    var wbuf: [128]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ id, &tc.token });

    var rbuf: [4096]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);

    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("OK", status);

    const snapshot_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(snapshot_header);
    var sit = std.mem.tokenizeScalar(u8, snapshot_header, ' ');
    try testing.expectEqualStrings("SNAPSHOT", sit.next().?);
    const snapshot_len = try std.fmt.parseInt(usize, sit.next().?, 10);
    const snapshot = try wire.readBody(testing.allocator, &r.interface, snapshot_len);
    defer testing.allocator.free(snapshot);
    try testing.expect(std.mem.indexOf(u8, snapshot, "livedata") == null);

    const data_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(data_header);
    var dit = std.mem.tokenizeScalar(u8, data_header, ' ');
    try testing.expectEqualStrings("DATA", dit.next().?);
    const data_len = try std.fmt.parseInt(usize, dit.next().?, 10);
    const data = try wire.readBody(testing.allocator, &r.interface, data_len);
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "livedata") != null);
}

test "every RESIZE gets the snapshot replayed at the size it reports" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "replay-create");
    defer tc_create.finish();
    const id = (try sendCreate(tc_create.client, &tc_create.token, "", "/", &.{
        "/bin/sh", "-c", "sleep 5",
    }, 80, 24)).id;
    defer testing.allocator.free(id);

    const tc = try TestConn.open(&host, "replay-attach");
    defer tc.finish();

    var wbuf: [128]u8 = undefined;
    var w = tc.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ id, &tc.token });

    var rbuf: [8192]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);

    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("OK", status);

    const first_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(first_header);
    var fit = std.mem.tokenizeScalar(u8, first_header, ' ');
    try testing.expectEqualStrings("SNAPSHOT", fit.next().?);
    const first_len = try std.fmt.parseInt(usize, fit.next().?, 10);
    const first = try wire.readBody(testing.allocator, &r.interface, first_len);
    defer testing.allocator.free(first);

    // The size a client attaches with is not one it has measured, so the
    // dump it was just handed was built for the wrong screen. Reporting a
    // size has to bring a replay built for that size.
    try wire.writeHeaderLine(&w.interface, "RESIZE 120 40", .{});

    const second_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(second_header);
    var sit = std.mem.tokenizeScalar(u8, second_header, ' ');
    try testing.expectEqualStrings("SNAPSHOT", sit.next().?);
    const second_len = try std.fmt.parseInt(usize, sit.next().?, 10);
    const second = try wire.readBody(testing.allocator, &r.interface, second_len);
    defer testing.allocator.free(second);

    // Replacing, not repeating: it clears what it lands on before drawing.
    try testing.expect(std.mem.startsWith(u8, second, "\x1b[H\x1b[2J\x1b[3J"));

    // The first size a client reports can still be a provisional one, so the
    // next has to bring a replay too.
    try wire.writeHeaderLine(&w.interface, "RESIZE 82 34", .{});

    const third_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(third_header);
    var tit = std.mem.tokenizeScalar(u8, third_header, ' ');
    try testing.expectEqualStrings("SNAPSHOT", tit.next().?);
    const third_len = try std.fmt.parseInt(usize, tit.next().?, 10);
    const third = try wire.readBody(testing.allocator, &r.interface, third_len);
    defer testing.allocator.free(third);
}

test "concurrent CREATE for the same not-yet-live id spawns exactly one pane" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const marker_path = try uniqueSocketPath("marker");
    defer testing.allocator.free(marker_path);
    defer std.Io.Dir.cwd().deleteFile(testing.io, marker_path) catch {};

    // Kept alive afterwards: a racer arriving after a short-lived winner exited would rightly spawn again.
    const cmd = try std.fmt.allocPrint(testing.allocator, "echo raced >> {s}; sleep 30", .{marker_path});
    defer testing.allocator.free(cmd);

    const thread_count = 8;
    const Ctx = struct {
        host: *Host,
        cmd: []const u8,
        index: usize,
    };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(ctx: Ctx) void {
                var buf: [32]u8 = undefined;
                const tag = std.fmt.bufPrint(&buf, "race-{d}", .{ctx.index}) catch return;
                const tc = TestConn.open(ctx.host, tag) catch return;
                defer tc.finish();
                const id = (sendCreate(tc.client, &tc.token, "race-id", "/", &.{
                    "/bin/sh", "-c", ctx.cmd,
                }, 80, 24) catch return).id;
                testing.allocator.free(id);
            }
        }.run, .{Ctx{ .host = &host, .cmd = cmd, .index = i }});
    }
    for (threads) |t| t.join();

    // Every racer should have converged on the one pane the winner
    // spawned, not each spawned its own.
    try testing.expectEqual(@as(usize, 1), host.panes.count());

    // Give the (single) spawned shell a moment to append its marker line,
    // then confirm only one process ever ran it.
    var spins: usize = 0;
    while (spins < 200) : (spins += 1) {
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
        const stat = std.Io.Dir.cwd().statFile(testing.io, marker_path, .{}) catch continue;
        if (stat.size > 0) break;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, marker_path, testing.allocator, .limited(4096));
    defer testing.allocator.free(data);
    var lines: usize = 0;
    for (data) |c| {
        if (c == '\n') lines += 1;
    }
    try testing.expectEqual(@as(usize, 1), lines);
}

test "a pane survives every client disconnecting, and a later CREATE reattaches to it" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "persist-create");
    const id = (try sendCreate(tc_create.client, &tc_create.token, "persist-tab", "/", &.{
        "/bin/sh", "-c", "sleep 5",
    }, 80, 24)).id;
    defer testing.allocator.free(id);
    tc_create.finish();

    // Attach once, like a GUI opening the tab, then disconnect - not
    // just moving on to a different request, but every client gone,
    // same as the GUI quitting entirely.
    const tc_attach = try TestConn.open(&host, "persist-attach");
    var wbuf: [128]u8 = undefined;
    var w = tc_attach.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ id, &tc_attach.token });
    var rbuf: [4096]u8 = undefined;
    var r = tc_attach.client.reader(testing.io, &rbuf);
    const status = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
    testing.allocator.free(status);
    tc_attach.finish();

    // The pane and its real process must still be alive with nobody
    // attached - this is the entire point of #39: the daemon is what
    // survives, not any particular client connection to it.
    host.mutex.lockUncancelable(host.io);
    const pane = host.panes.get(id) orelse return error.PaneGone;
    host.mutex.unlock(host.io);
    try testing.expect(pane.isAlive());

    // A later CREATE for the same id - the GUI reopening - reattaches
    // to this exact pane instead of spawning a new one.
    const tc_reopen = try TestConn.open(&host, "persist-reopen");
    defer tc_reopen.finish();
    const id2 = (try sendCreate(tc_reopen.client, &tc_reopen.token, "persist-tab", "/", &.{
        "/bin/sh", "-c", "sleep 5",
    }, 80, 24)).id;
    defer testing.allocator.free(id2);
    try testing.expectEqualStrings(id, id2);
    try testing.expectEqual(@as(usize, 1), host.panes.count());
}

fn panePid(host: *Host, id: []const u8) !std.posix.pid_t {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    const pane = host.panes.get(id) orelse return error.PaneGone;
    return pane.command.pid orelse error.NoPid;
}

test "KILL terminates the pane's real process and drops it from the registry" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "kill-create");
    const id = (try sendCreate(tc_create.client, &tc_create.token, "kill-tab", "/", &.{
        "/bin/sh", "-c", "sleep 30",
    }, 80, 24)).id;
    defer testing.allocator.free(id);
    tc_create.finish();

    const pid = try panePid(&host, id);
    try testing.expect(access.processExists(pid));

    const tc_kill = try TestConn.open(&host, "kill-send");
    defer tc_kill.finish();
    try testing.expectEqual(@as(usize, 1), try sendIdCommand(tc_kill.client, &tc_kill.token, "KILL", &.{id}));

    try testing.expectEqual(@as(usize, 0), host.panes.count());
    try testing.expect(access.waitForProcessGone(testing.io, pid, 1000));
}

test "KILL takes several ids in one request" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_a = try TestConn.open(&host, "kill-many-a");
    const id_a = (try sendCreate(tc_a.client, &tc_a.token, "kill-a", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id_a);
    tc_a.finish();

    const tc_b = try TestConn.open(&host, "kill-many-b");
    const id_b = (try sendCreate(tc_b.client, &tc_b.token, "kill-b", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id_b);
    tc_b.finish();

    const tc_c = try TestConn.open(&host, "kill-many-c");
    const id_c = (try sendCreate(tc_c.client, &tc_c.token, "kill-c", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id_c);
    tc_c.finish();

    const tc_kill = try TestConn.open(&host, "kill-many-send");
    defer tc_kill.finish();
    try testing.expectEqual(@as(usize, 2), try sendIdCommand(tc_kill.client, &tc_kill.token, "KILL", &.{ id_a, id_c }));

    try testing.expectEqual(@as(usize, 1), host.panes.count());
    try testing.expect(host.panes.get(id_b) != null);
}

test "KILL forces out a process that ignores SIGTERM" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "kill-stubborn-create");
    const id = (try sendCreate(tc_create.client, &tc_create.token, "stubborn-tab", "/", &.{
        "/bin/sh", "-c", "trap '' TERM; while :; do sleep 0.1; done",
    }, 80, 24)).id;
    defer testing.allocator.free(id);
    tc_create.finish();

    // The trap only takes effect once the shell has actually run it.
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    const pid = try panePid(&host, id);

    const tc_kill = try TestConn.open(&host, "kill-stubborn-send");
    defer tc_kill.finish();
    try testing.expectEqual(@as(usize, 1), try sendIdCommand(tc_kill.client, &tc_kill.token, "KILL", &.{id}));

    try testing.expect(!access.processExists(pid));
}

test "SWEEP kills exactly the panes nobody claimed" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_keep = try TestConn.open(&host, "sweep-keep");
    const id_keep = (try sendCreate(tc_keep.client, &tc_keep.token, "sweep-keep", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id_keep);
    tc_keep.finish();

    const tc_drop = try TestConn.open(&host, "sweep-drop");
    const id_drop = (try sendCreate(tc_drop.client, &tc_drop.token, "sweep-drop", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id_drop);
    tc_drop.finish();

    const dropped_pid = try panePid(&host, id_drop);
    const kept_pid = try panePid(&host, id_keep);

    const tc_sweep = try TestConn.open(&host, "sweep-send");
    defer tc_sweep.finish();
    try testing.expectEqual(@as(usize, 1), try sendIdCommand(tc_sweep.client, &tc_sweep.token, "SWEEP", &.{id_keep}));

    try testing.expectEqual(@as(usize, 1), host.panes.count());
    try testing.expect(host.panes.get(id_keep) != null);
    try testing.expect(access.waitForProcessGone(testing.io, dropped_pid, 1000));
    try testing.expect(access.processExists(kept_pid));
}

test "SWEEP with no ids kills every pane" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "sweep-all-create");
    const id = (try sendCreate(tc_create.client, &tc_create.token, "sweep-all", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24)).id;
    defer testing.allocator.free(id);
    tc_create.finish();

    const tc_sweep = try TestConn.open(&host, "sweep-all-send");
    defer tc_sweep.finish();
    try testing.expectEqual(@as(usize, 1), try sendIdCommand(tc_sweep.client, &tc_sweep.token, "SWEEP", &.{}));
    try testing.expectEqual(@as(usize, 0), host.panes.count());
}

test "CREATE spawns fresh instead of reattaching to a pane whose process already exited" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "dead-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "dead-tab", "/", &.{ "/bin/sh", "-c", "true" }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();
    try testing.expectEqual(wire.CreateOutcome.new, created.outcome);

    // Wait for the short-lived shell to exit so the registry is holding a
    // corpse rather than a still-running pane.
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        host.mutex.lockUncancelable(host.io);
        const pane = host.panes.get("dead-tab");
        host.mutex.unlock(host.io);
        if (pane) |p| {
            if (!p.isAlive()) break;
        }
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    }

    const tc_reuse = try TestConn.open(&host, "dead-reuse");
    const respawned = try sendCreate(tc_reuse.client, &tc_reuse.token, "dead-tab", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24);
    defer testing.allocator.free(respawned.id);
    tc_reuse.finish();

    // Reported as `ended` so a reattaching client can show that the
    // session it expected to come back to is gone, not silently swap in
    // the fresh shell it just got instead.
    try testing.expectEqual(wire.CreateOutcome.ended, respawned.outcome);
    try testing.expectEqual(@as(usize, 1), host.panes.count());

    host.mutex.lockUncancelable(host.io);
    const pane = host.panes.get("dead-tab");
    host.mutex.unlock(host.io);
    try testing.expect(pane.?.isAlive());
}

test "CREATE reports a live pane as reused" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "reused-create");
    const first = try sendCreate(tc_create.client, &tc_create.token, "reused-tab", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24);
    defer testing.allocator.free(first.id);
    tc_create.finish();
    try testing.expectEqual(wire.CreateOutcome.new, first.outcome);

    const tc_again = try TestConn.open(&host, "reused-again");
    const second = try sendCreate(tc_again.client, &tc_again.token, "reused-tab", "/", &.{ "/bin/sh", "-c", "sleep 30" }, 80, 24);
    defer testing.allocator.free(second.id);
    tc_again.finish();
    try testing.expectEqual(wire.CreateOutcome.reused, second.outcome);
}

test "MODEL answers with the whole model in one document" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    try buildTestModel(&host);

    const tc = try TestConn.open(&host, "model-read");
    defer tc.finish();
    const document = try fetchModel(tc.client);
    defer testing.allocator.free(document);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, document, .{});
    defer parsed.deinit();

    // The run id and revision are what tell a client whether the copy it
    // is holding is still the daemon's current one.
    try testing.expectEqualStrings(&host.model.run_id, parsed.value.object.get("run_id").?.string);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("revision").?.integer);

    const spaces = parsed.value.object.get("spaces").?.array;
    const tabs = spaces.items[0].object.get("tabs").?.array;
    const panes = tabs.items[0].object.get("panes").?.array;
    try testing.expectEqualStrings("space-a", spaces.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("build", tabs.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("surface:p1", panes.items[0].object.get("id").?.string);

    // Per-pane title and working directory come back with the structure,
    // so a client renders everything from this one answer.
    try testing.expect(panes.items[0].object.get("title") != null);
    try testing.expect(panes.items[0].object.get("directory") != null);
}

test "a pane's real title and directory reach the model document" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "facts-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:p1", "/tmp", &.{
        "/bin/sh", "-c", "printf '\\033]0;from-the-pane\\033\\\\'; sleep 5",
    }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    try buildTestModel(&host);

    // The title arrives as pty output the pane's reader thread still has
    // to parse, so give it a moment rather than racing it.
    var spins: usize = 0;
    while (spins < 200) : (spins += 1) {
        const tc = try TestConn.open(&host, "facts-read");
        defer tc.finish();
        const document = try fetchModel(tc.client);
        defer testing.allocator.free(document);
        if (std.mem.indexOf(u8, document, "from-the-pane") != null) {
            try testing.expect(std.mem.indexOf(u8, document, "/tmp") != null);
            return;
        }
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    return error.TitleNeverArrived;
}

test "an agent that finishes and then prints nothing still resolves to done" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try host.startDetection();

    const tc_create = try TestConn.open(&host, "quiet-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:quiet", "/", &fake_agent_argv, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    const tc = try attachForStatus(&host, "quiet-attach", created.id);
    defer tc.finish();
    var deadline: ReadDeadline = .{ .conn = tc.client };
    try deadline.start(20_000);
    defer deadline.finish();
    var rbuf: [16 * 1024]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);

    const working = try awaitStatus(&r.interface, "working");
    defer working.deinit();
    try testing.expectEqualStrings("claude", working.value.object.get("agent").?.string);

    // Nothing is printed after the idle title, so only the detection timer
    // can notice the finish. Nobody was looking, so it is done, not idle.
    const done = try awaitStatus(&r.interface, "done");
    defer done.deinit();
    try testing.expectEqualStrings("idle", done.value.object.get("state").?.string);
    try testing.expect(!done.value.object.get("seen").?.bool);
    try testing.expect(done.value.object.get("recency").?.integer > working.value.object.get("recency").?.integer);
}

test "a client looking at a pane marks it seen for every client" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try host.startDetection();

    const tc_create = try TestConn.open(&host, "seen-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:seen", "/", &fake_agent_argv, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    const looker = try attachForStatus(&host, "seen-looker", created.id);
    defer looker.finish();
    const other = try attachForStatus(&host, "seen-other", created.id);
    defer other.finish();
    var deadline: ReadDeadline = .{ .conn = other.client };
    try deadline.start(20_000);
    defer deadline.finish();
    var rbuf: [16 * 1024]u8 = undefined;
    var r = other.client.reader(testing.io, &rbuf);

    const done = try awaitStatus(&r.interface, "done");
    done.deinit();

    var wbuf: [32]u8 = undefined;
    var w = looker.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "VIEW 1", .{});

    const seen = try awaitStatus(&r.interface, "idle");
    defer seen.deinit();
    try testing.expect(seen.value.object.get("seen").?.bool);
}

test "a pane's agent status reaches the model document" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "status-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:p1", "/tmp", &.{ "/bin/sh", "-c", "sleep 5" }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    try buildTestModel(&host);

    const tc = try TestConn.open(&host, "status-read");
    defer tc.finish();
    const document = try fetchModel(tc.client);
    defer testing.allocator.free(document);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, document, .{});
    defer parsed.deinit();
    const pane = parsed.value.object.get("spaces").?.array.items[0].object.get("tabs").?.array.items[0]
        .object.get("panes").?.array.items[0].object;
    try testing.expectEqualStrings("unknown", pane.get("attention").?.string);
    try testing.expect(pane.get("agent").? == .null);
    try testing.expect(pane.get("seen").?.bool);
}

test "SUBSCRIBE answers with the version, run id, revision and every capability" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const sub = try openSubscription(&host, "sub-hello", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);

    const expected = try std.fmt.allocPrint(testing.allocator, "OK 1 {s} 0 attention,seen,hide,attachments", .{&host.model.run_id});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, sub.answer);
}

test "an app on another protocol version is refused with the reason" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    var request_buf: [128]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, "3 app {s}", .{&host.token});
    const sub = try openSubscription(&host, "sub-app-mismatch", request);
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    try testing.expect(std.mem.startsWith(u8, sub.answer, "ERR version mismatch: the app speaks protocol 3, this daemon speaks 2"));
}

test "an outside client is held to the floor, and a newer one is answered in the older version" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const old = try openSubscription(&host, "sub-too-old", "0 client");
    defer old.tc.finish();
    defer testing.allocator.free(old.answer);
    try testing.expect(std.mem.startsWith(u8, old.answer, "ERR protocol 0 is older than this daemon supports"));

    const newer = try openSubscription(&host, "sub-newer", "9 client");
    defer newer.tc.finish();
    defer testing.allocator.free(newer.answer);
    try testing.expect(std.mem.startsWith(u8, newer.answer, "OK 2 "));
}

test "a client asking for a capability the daemon lacks loses only that capability" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const sub = try openSubscription(&host, "sub-caps", "1 client attention teleport");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    try testing.expect(std.mem.endsWith(u8, sub.answer, " attention"));

    // Still connected: the next change arrives as an event.
    var deadline: ReadDeadline = .{ .conn = sub.tc.client };
    try deadline.start(10_000);
    defer deadline.finish();
    const tc_op = try TestConn.open(&host, "sub-caps-op");
    _ = try sendModelOp(tc_op.client, "SPACE", "new", &.{ "space-a", "" });
    tc_op.finish();

    var rbuf: [8192]u8 = undefined;
    var r = sub.tc.client.reader(testing.io, &rbuf);
    const changed = try awaitEvent(&r.interface, "model_changed");
    changed.deinit();
}

test "subscribe, then fetch the model, then apply only newer events: nothing is lost" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    // 1. Subscribe first.
    const sub = try openSubscription(&host, "sub-order", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    var deadline: ReadDeadline = .{ .conn = sub.tc.client };
    try deadline.start(10_000);
    defer deadline.finish();

    // A change lands between subscribing and fetching.
    const tc_a = try TestConn.open(&host, "sub-order-a");
    _ = try sendModelOp(tc_a.client, "SPACE", "new", &.{ "space-a", "" });
    tc_a.finish();

    // 2. Then fetch the model.
    const tc_m = try TestConn.open(&host, "sub-order-model");
    const document = try fetchModel(tc_m.client);
    tc_m.finish();
    defer testing.allocator.free(document);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, document, .{});
    defer parsed.deinit();
    const fetched: i64 = parsed.value.object.get("revision").?.integer;

    // A change after the fetch.
    const tc_b = try TestConn.open(&host, "sub-order-b");
    _ = try sendModelOp(tc_b.client, "SPACE", "new", &.{ "space-b", "" });
    tc_b.finish();

    // 3. Apply what arrived: the first change is already in the fetched copy
    // and is skipped by revision; the second is newer and must be there.
    var rbuf: [8192]u8 = undefined;
    var r = sub.tc.client.reader(testing.io, &rbuf);
    const first = try awaitEvent(&r.interface, "model_changed");
    defer first.deinit();
    try testing.expect(first.value.object.get("revision").?.integer <= fetched);
    const second = try awaitEvent(&r.interface, "model_changed");
    defer second.deinit();
    try testing.expect(second.value.object.get("revision").?.integer > fetched);
}

test "a client can tell the daemon restarted from the run id it is answered with" {
    var a: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&a);
    var b: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&b);

    const sub_a = try openSubscription(&a, "sub-run-a", "1 client");
    defer sub_a.tc.finish();
    defer testing.allocator.free(sub_a.answer);
    const sub_b = try openSubscription(&b, "sub-run-b", "1 client");
    defer sub_b.tc.finish();
    defer testing.allocator.free(sub_b.answer);

    // `OK <version> <run_id> ...`: the same field the model carries.
    var it_a = std.mem.tokenizeScalar(u8, sub_a.answer, ' ');
    _ = it_a.next();
    _ = it_a.next();
    var it_b = std.mem.tokenizeScalar(u8, sub_b.answer, ' ');
    _ = it_b.next();
    _ = it_b.next();
    const run_a = it_a.next().?;
    const run_b = it_b.next().?;
    try testing.expectEqualStrings(&a.model.run_id, run_a);
    try testing.expect(!std.mem.eql(u8, run_a, run_b));
}

test "pane, attachment and model events arrive as they happen" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const sub = try openSubscription(&host, "sub-events", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    var deadline: ReadDeadline = .{ .conn = sub.tc.client };
    try deadline.start(15_000);
    defer deadline.finish();
    var rbuf: [8192]u8 = undefined;
    var r = sub.tc.client.reader(testing.io, &rbuf);

    const tc_create = try TestConn.open(&host, "sub-events-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:p1", "/", &.{ "/bin/sh", "-c", "sleep 5" }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();
    const ev_created = try awaitEvent(&r.interface, "pane_created");
    defer ev_created.deinit();
    try testing.expectEqualStrings("surface:p1", ev_created.value.object.get("pane").?.string);

    const tc_attach = try TestConn.open(&host, "sub-events-attach");
    var wbuf: [128]u8 = undefined;
    var w = tc_attach.client.writer(testing.io, &wbuf);
    try wire.writeHeaderLine(&w.interface, "ATTACH {s} {s}", .{ created.id, &tc_attach.token });
    const ev_attached = try awaitEvent(&r.interface, "attached");
    defer ev_attached.deinit();
    try testing.expectEqual(@as(i64, 1), ev_attached.value.object.get("clients").?.integer);
    tc_attach.finish();
    const ev_detached = try awaitEvent(&r.interface, "detached");
    defer ev_detached.deinit();
    try testing.expectEqual(@as(i64, 0), ev_detached.value.object.get("clients").?.integer);

    try buildTestModel(&host);
    const ev_model = try awaitEvent(&r.interface, "model_changed");
    ev_model.deinit();

    const tc_kill = try TestConn.open(&host, "sub-events-kill");
    _ = try sendIdCommand(tc_kill.client, &tc_kill.token, "KILL", &.{created.id});
    tc_kill.finish();
    const ev_killed = try awaitEvent(&r.interface, "pane_killed");
    defer ev_killed.deinit();
    try testing.expectEqualStrings("surface:p1", ev_killed.value.object.get("pane").?.string);
}

test "a pane whose process ends is reported exited" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const sub = try openSubscription(&host, "sub-exit", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    var deadline: ReadDeadline = .{ .conn = sub.tc.client };
    try deadline.start(10_000);
    defer deadline.finish();
    var rbuf: [8192]u8 = undefined;
    var r = sub.tc.client.reader(testing.io, &rbuf);

    const tc_create = try TestConn.open(&host, "sub-exit-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:short", "/", &.{ "/bin/sh", "-c", "exit 0" }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    const exited = try awaitEvent(&r.interface, "pane_exited");
    defer exited.deinit();
    try testing.expectEqualStrings("surface:short", exited.value.object.get("pane").?.string);
}

test "an agent's attention changes reach subscribers" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try host.startDetection();

    const sub = try openSubscription(&host, "sub-attention", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);
    var deadline: ReadDeadline = .{ .conn = sub.tc.client };
    try deadline.start(20_000);
    defer deadline.finish();
    var rbuf: [16 * 1024]u8 = undefined;
    var r = sub.tc.client.reader(testing.io, &rbuf);

    const tc_create = try TestConn.open(&host, "sub-attention-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:agent", "/", &fake_agent_argv, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    while (true) {
        const ev = try awaitEvent(&r.interface, "attention_changed");
        defer ev.deinit();
        if (std.mem.eql(u8, ev.value.object.get("attention").?.string, "working")) {
            try testing.expectEqualStrings("surface:agent", ev.value.object.get("pane").?.string);
            try testing.expectEqualStrings("claude", ev.value.object.get("agent").?.string);
            break;
        }
    }
}

test "fixture: attention_changed" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var report: Pane.AgentReport = .{ .agent = .Claude, .state = .Idle, .state_seq = 4, .seen_seq = 3 };
    report.recency.change_seq = 5;
    try Pane.writeAttentionEvent(&w, "surface:A", report);
    try testing.expectEqualStrings(
        "{\"event\":\"attention_changed\",\"pane\":\"surface:A\",\"agent\":\"claude\",\"state\":\"idle\",\"attention\":\"done\",\"seen\":false,\"state_seq\":4,\"recency\":5}",
        w.buffered(),
    );
}

/// Asks the terminal for the cursor position and prints how many bytes of
/// reply arrived within a second, as `REPLY=<n>.`, then stays alive.
const cursor_query_argv = [_][]const u8{
    "/bin/sh",
    "-c",
    "sleep 0.5; stty -echo -icanon min 0 time 10; printf '\\033[6n'; r=$(dd bs=1 count=16 2>/dev/null); printf 'REPLY=%d.' ${#r}; sleep 5",
};

test "with a client attached, the daemon leaves the program's queries to the client" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "query-attached-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "", "/", &cursor_query_argv, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    // Attached before the query goes out, and never answering it - so any
    // reply the program gets could only have come from the daemon.
    const tc = try attachForStatus(&host, "query-attached", created.id);
    defer tc.finish();
    var deadline: ReadDeadline = .{ .conn = tc.client };
    try deadline.start(10_000);
    defer deadline.finish();

    var rbuf: [16 * 1024]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    while (std.mem.indexOf(u8, seen.items, "REPLY=") == null or
        std.mem.indexOfScalarPos(u8, seen.items, std.mem.indexOf(u8, seen.items, "REPLY=").?, '.') == null)
    {
        const line = (try wire.readHeader(testing.allocator, &r.interface)) orelse return error.NoResponse;
        defer testing.allocator.free(line);
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = it.next() orelse continue;
        if (std.mem.eql(u8, tag, "OK") or std.mem.eql(u8, tag, "META")) continue;
        const len = try std.fmt.parseInt(usize, it.next() orelse return error.ProtocolError, 10);
        const body = try wire.readBody(testing.allocator, &r.interface, len);
        defer testing.allocator.free(body);
        if (std.mem.eql(u8, tag, "DATA") or std.mem.eql(u8, tag, "SNAPSHOT")) try seen.appendSlice(testing.allocator, body);
    }
    try testing.expect(std.mem.indexOf(u8, seen.items, "REPLY=0.") != null);
}

test "with no client attached, the daemon answers the program's queries itself" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "query-alone-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "", "/", &cursor_query_argv, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    // Nobody attached while the query is answered; look afterwards.
    std.Io.sleep(testing.io, .fromMilliseconds(2_500), .awake) catch {};

    const tc = try attachForStatus(&host, "query-alone", created.id);
    defer tc.finish();
    var deadline: ReadDeadline = .{ .conn = tc.client };
    try deadline.start(10_000);
    defer deadline.finish();

    var rbuf: [16 * 1024]u8 = undefined;
    var r = tc.client.reader(testing.io, &rbuf);
    const ok = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("OK", ok);
    const snapshot_header = (try readHeaderSkippingMeta(testing.allocator, &r.interface)) orelse return error.NoResponse;
    defer testing.allocator.free(snapshot_header);
    var sit = std.mem.tokenizeScalar(u8, snapshot_header, ' ');
    try testing.expectEqualStrings("SNAPSHOT", sit.next().?);
    const len = try std.fmt.parseInt(usize, sit.next().?, 10);
    const snapshot = try wire.readBody(testing.allocator, &r.interface, len);
    defer testing.allocator.free(snapshot);

    try testing.expect(std.mem.indexOf(u8, snapshot, "REPLY=") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "REPLY=0.") == null);
}

test "every structural operation lands in the model" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    try buildTestModel(&host);

    const tc = try TestConn.open(&host, "ops-space-b");
    defer tc.finish();
    _ = try sendModelOp(tc.client, "SPACE", "new", &.{ "space-b", "" });

    const tc_rename = try TestConn.open(&host, "ops-rename");
    defer tc_rename.finish();
    _ = try sendModelOp(tc_rename.client, "SPACE", "rename", &.{ "space-a", "work" });

    const tc_move = try TestConn.open(&host, "ops-move");
    defer tc_move.finish();
    _ = try sendModelOp(tc_move.client, "SPACE", "move", &.{ "space-a", "1" });

    const tc_hide = try TestConn.open(&host, "ops-hide");
    defer tc_hide.finish();
    _ = try sendModelOp(tc_hide.client, "SPACE", "hide", &.{"space-b"});

    const tc_tab = try TestConn.open(&host, "ops-tab-rename");
    defer tc_tab.finish();
    _ = try sendModelOp(tc_tab.client, "TAB", "rename", &.{ "tab-1", "tests" });

    try testing.expectEqualStrings("space-b", host.model.spaces.items[0].id);
    try testing.expectEqualStrings("work", host.model.findSpace("space-a").?.name);
    try testing.expect(host.model.findSpace("space-b").?.hidden);
    try testing.expectEqualStrings("tests", host.model.findSpace("space-a").?.tabs.items[0].name);

    const tc_show = try TestConn.open(&host, "ops-show");
    defer tc_show.finish();
    _ = try sendModelOp(tc_show.client, "SPACE", "show", &.{"space-b"});
    try testing.expectEqualStrings("space-b", host.model.spaces.items[0].id);

    const tc_close = try TestConn.open(&host, "ops-close");
    defer tc_close.finish();
    _ = try sendModelOp(tc_close.client, "SPACE", "close", &.{"space-b"});
    try testing.expectEqual(@as(usize, 1), host.model.spaces.items.len);
}

test "an operation naming something nobody knows is refused" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc = try TestConn.open(&host, "ops-unknown-space");
    defer tc.finish();
    try testing.expectError(error.OpFailed, sendModelOp(tc.client, "SPACE", "close", &.{"nope"}));

    const tc_op = try TestConn.open(&host, "ops-unknown-op");
    defer tc_op.finish();
    try testing.expectError(error.OpFailed, sendModelOp(tc_op.client, "SPACE", "sideways", &.{"space-a"}));

    try testing.expectEqual(@as(usize, 0), host.model.spaces.items.len);
}

test "the model survives a daemon restart, read back from its own file" {
    const path = try uniqueModelPath("restart");
    defer testing.allocator.free(path);
    defer removeModelDir(path);

    {
        var host: Host = .init(testing.allocator, testing.io);
        defer deinitTestHost(&host);
        host.openModel(try testing.allocator.dupe(u8, path));

        try buildTestModel(&host);

        const tc = try TestConn.open(&host, "restart-rename");
        defer tc.finish();
        _ = try sendModelOp(tc.client, "SPACE", "rename", &.{ "space-a", "work" });

        host.flushModel();
    }

    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    host.openModel(try testing.allocator.dupe(u8, path));

    const tc = try TestConn.open(&host, "restart-read");
    defer tc.finish();
    const document = try fetchModel(tc.client);
    defer testing.allocator.free(document);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, document, .{});
    defer parsed.deinit();
    const spaces = parsed.value.object.get("spaces").?.array;
    try testing.expectEqualStrings("work", spaces.items[0].object.get("name").?.string);

    const tabs = spaces.items[0].object.get("tabs").?.array;
    try testing.expectEqualStrings("tab-1", tabs.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("surface:p1", tabs.items[0].object.get("panes").?.array.items[0].object.get("id").?.string);

    // A restart is a new run of the daemon: its own id, and a revision
    // counted from this run's own changes rather than the last one's.
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("revision").?.integer);
}

test "a killed pane stops being part of the model" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);

    const tc_create = try TestConn.open(&host, "forget-create");
    const created = try sendCreate(tc_create.client, &tc_create.token, "surface:p1", "/", &.{
        "/bin/sh", "-c", "sleep 30",
    }, 80, 24);
    defer testing.allocator.free(created.id);
    tc_create.finish();

    try buildTestModel(&host);
    try testing.expect(host.model.findPane("surface:p1") != null);

    const tc_kill = try TestConn.open(&host, "forget-kill");
    defer tc_kill.finish();
    try testing.expectEqual(@as(usize, 1), try sendIdCommand(tc_kill.client, &tc_kill.token, "KILL", &.{"surface:p1"}));

    try testing.expect(host.model.findPane("surface:p1") == null);
}

/// A daemon serving every connection on a socket of its own until stopped,
/// for clients that open more than one: a layout command asks, then looks at
/// the model until it shows the change.
const TestServer = struct {
    path: []u8,
    listener: net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// The host's token, for a `FakeApp` to subscribe with.
    token: access.Token,

    /// One per accepted connection, joined by `finish`. Only the accept
    /// loop appends, and `finish` reads it after that loop has ended.
    handlers: std.ArrayList(std.Thread) = .empty,

    /// Listens on a fresh socket and starts accepting on a thread of its own.
    fn start(host: *Host, tag: []const u8) !*TestServer {
        const path = try uniqueSocketPath(tag);
        errdefer testing.allocator.free(path);
        const addr = try net.UnixAddress.init(path);

        const self = try testing.allocator.create(TestServer);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .path = path, .listener = try addr.listen(testing.io, .{}), .thread = undefined, .token = host.token };
        errdefer self.listener.deinit(testing.io);

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, host });
        return self;
    }

    /// Hands each connection to a thread of its own until `finish` stops it.
    fn acceptLoop(self: *TestServer, host: *Host) void {
        while (true) {
            const conn = self.listener.accept(testing.io) catch return;
            if (self.stop.load(.acquire)) {
                conn.close(testing.io);
                return;
            }
            const handler = std.Thread.spawn(.{}, handleConnection, .{ host, conn }) catch {
                conn.close(testing.io);
                continue;
            };
            self.handlers.append(testing.allocator, handler) catch handler.join();
        }
    }

    /// Stops accepting and waits for every connection to finish, so call
    /// it once every client has closed.
    fn finish(self: *TestServer) void {
        self.stop.store(true, .release);
        // Wakes the accept loop so it sees the stop.
        if (net.UnixAddress.init(self.path)) |addr| {
            if (addr.connect(testing.io)) |conn| conn.close(testing.io) else |_| {}
        } else |_| {}
        self.thread.join();
        for (self.handlers.items) |handler| handler.join();
        self.handlers.deinit(testing.allocator);

        self.listener.deinit(testing.io);
        std.Io.Dir.cwd().deleteFile(testing.io, self.path) catch {};
        testing.allocator.free(self.path);
        testing.allocator.destroy(self);
    }
};

/// Stands in for the Mac app: subscribes as the app and, when `applies`,
/// carries out each request with the structural ops the real app reports,
/// as a user's own new tab would be.
const FakeApp = struct {
    socket_path: []const u8,
    token: access.Token,
    applies: bool,
    conn: net.Stream,
    read_buf: [wire.max_header_len]u8 = undefined,
    reader: net.Stream.Reader = undefined,
    thread: std.Thread = undefined,

    /// Guards `last` and `windows`.
    mutex: std.Io.Mutex = .init,
    /// The last request event received, as JSON.
    last: ?[]u8 = null,

    /// The windows this app shows, kept so a Space moving between them is reported as the app would.
    windows: std.ArrayList(FakeWindow) = .empty,
    /// Owns `windows` and the ids in it.
    windows_arena: std.heap.ArenaAllocator = .init(testing.allocator),

    const FakeWindow = struct {
        id: []const u8,
        /// In the window's order; the first is the one showing.
        spaces: std.ArrayList([]const u8) = .empty,
    };

    /// A window as a test sets it up: its id and the Spaces it shows, the first showing.
    const WindowSetup = struct { id: []const u8, spaces: []const []const u8 };

    /// Subscribes as the app and starts serving request events on a thread of its own.
    fn start(server: *const TestServer, applies: bool) !*FakeApp {
        const addr = try net.UnixAddress.init(server.path);
        const conn = try addr.connect(testing.io);
        errdefer conn.close(testing.io);

        const self = try testing.allocator.create(FakeApp);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .socket_path = server.path, .token = server.token, .applies = applies, .conn = conn };
        self.reader = conn.reader(testing.io, &self.read_buf);

        var wbuf: [128]u8 = undefined;
        var w = conn.writer(testing.io, &wbuf);
        try wire.writeHeaderLine(&w.interface, "SUBSCRIBE {d} app {s}", .{ wire.protocol_version, &server.token });

        // Read here, not on the thread, so the subscription is registered
        // before a test goes on to send a request.
        const answer = (try wire.readHeader(testing.allocator, &self.reader.interface)) orelse return error.NoResponse;
        defer testing.allocator.free(answer);
        if (!std.mem.startsWith(u8, answer, "OK ")) return error.Refused;

        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// Records, and when `applies` carries out, each request event until the connection closes.
    fn serve(self: *FakeApp) void {
        while (true) {
            var event = awaitEvent(&self.reader.interface, "request") catch return;
            defer event.deinit();
            self.record(event.value) catch return;
            if (self.applies) self.apply(event.value.object) catch return;
        }
    }

    /// Keeps `event` as the last request received.
    fn record(self: *FakeApp, event: std.json.Value) !void {
        const json = try std.json.Stringify.valueAlloc(testing.allocator, event, .{});
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (self.last) |old| testing.allocator.free(old);
        self.last = json;
    }

    /// Carries out `request` the way the app reports the same change made
    /// by the user: a new Space or tab, then the pane its shell started in;
    /// a close, rename or move as the one op it is.
    fn apply(self: *FakeApp, request: std.json.ObjectMap) !void {
        if (std.mem.eql(u8, request.get("scope").?.string, "space")) return self.applySpace(request);
        if (std.mem.eql(u8, request.get("scope").?.string, "pane")) return self.applyPane(request);

        const op = std.meta.stringToEnum(wire.TabRequestOp, request.get("op").?.string) orelse return error.UnknownOp;
        const tab = request.get("tab").?.string;
        switch (op) {
            .new => {
                try self.send("TAB", "new", &.{ request.get("space").?.string, tab, request.get("name").?.string });

                var pane_buf: [64]u8 = undefined;
                const pane = try std.fmt.bufPrint(&pane_buf, "surface:{s}", .{tab});
                try self.send("PANE", "move", &.{ pane, tab, "0" });
            },
            .close => try self.send("TAB", "close", &.{tab}),
            .rename => try self.send("TAB", "rename", &.{ tab, request.get("name").?.string }),
            .move => {
                var index_buf: [20]u8 = undefined;
                const index = try std.fmt.bufPrint(&index_buf, "{d}", .{request.get("index").?.integer});
                try self.send("TAB", "move", &.{ tab, index });
            },
            .focus => try self.focusOn(.tab, tab),
        }
    }

    /// Carries out a Space `request` as `apply` does a tab's.
    fn applySpace(self: *FakeApp, request: std.json.ObjectMap) !void {
        const op = std.meta.stringToEnum(wire.SpaceRequestOp, request.get("op").?.string) orelse return error.UnknownOp;
        const space = request.get("space").?.string;
        switch (op) {
            .new => {
                const tab = request.get("tab").?.string;
                try self.send("SPACE", "new", &.{ space, request.get("name").?.string });
                try self.send("TAB", "new", &.{ space, tab, "" });

                var pane_buf: [64]u8 = undefined;
                const pane = try std.fmt.bufPrint(&pane_buf, "surface:{s}", .{tab});
                try self.send("PANE", "move", &.{ pane, tab, "0" });
            },
            .close => try self.send("SPACE", "close", &.{space}),
            .rename => try self.send("SPACE", "rename", &.{ space, request.get("name").?.string }),
            .move => {
                if (request.get("window")) |window| try self.moveToWindow(space, window.string, request.get("after").?.array.items);

                var index_buf: [20]u8 = undefined;
                const index = try std.fmt.bufPrint(&index_buf, "{d}", .{request.get("index").?.integer});
                try self.send("SPACE", "move", &.{ space, index });
            },
            .focus => try self.focusOn(.space, space),
        }
    }

    /// Reports `setup` as every window this app shows, as the app does whenever its windows change.
    fn reportWindows(self: *FakeApp, setup: []const WindowSetup) !void {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);

        const arena = self.windows_arena.allocator();
        self.windows = .empty;
        for (setup) |window| {
            var held: FakeWindow = .{ .id = try arena.dupe(u8, window.id) };
            for (window.spaces) |id| try held.spaces.append(arena, try arena.dupe(u8, id));
            try self.windows.append(arena, held);
        }
        try self.sendWindowsLocked();
    }

    /// Takes `space` out of whichever window shows it and into `window_id`, after the last of that window's Spaces in `after`, closing a window left with none, and reports the windows.
    fn moveToWindow(self: *FakeApp, space: []const u8, window_id: []const u8, after: []const std.json.Value) !void {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);

        const arena = self.windows_arena.allocator();
        var index: usize = 0;
        while (index < self.windows.items.len) {
            const window = &self.windows.items[index];
            for (window.spaces.items, 0..) |id, i| {
                if (!std.mem.eql(u8, id, space)) continue;
                _ = window.spaces.orderedRemove(i);
                break;
            }
            // A window left with no Space closes.
            if (window.spaces.items.len == 0) {
                _ = self.windows.orderedRemove(index);
                continue;
            }
            index += 1;
        }

        for (self.windows.items) |*window| {
            if (!std.mem.eql(u8, window.id, window_id)) continue;
            var landing: usize = 0;
            for (window.spaces.items, 0..) |id, i| {
                for (after) |anchor| {
                    if (std.mem.eql(u8, anchor.string, id)) landing = i + 1;
                }
            }
            try window.spaces.insert(arena, landing, try arena.dupe(u8, space));
        }
        try self.sendWindowsLocked();
    }

    /// Writes the held windows as a `WINDOWS` report. Caller must hold `mutex`.
    fn sendWindowsLocked(self: *FakeApp) !void {
        var body: std.Io.Writer.Allocating = .init(testing.allocator);
        defer body.deinit();
        for (self.windows.items, 0..) |window, i| {
            if (i > 0) try body.writer.writeByte('\n');
            try body.writer.writeAll(window.id);
            try body.writer.writeByte(0);
            try body.writer.writeAll(window.spaces.items[0]);
            for (window.spaces.items) |id| {
                try body.writer.writeByte(0);
                try body.writer.writeAll(id);
            }
        }

        var wbuf: [256]u8 = undefined;
        var w = self.conn.writer(testing.io, &wbuf);
        try wire.writeFrame(&w.interface, "WINDOWS", body.written());
    }

    /// Carries out a pane `request`: a split places the new pane after those
    /// its tab holds, and a close ends the pane's process, which takes it
    /// out of the model.
    fn applyPane(self: *FakeApp, request: std.json.ObjectMap) !void {
        const op = std.meta.stringToEnum(wire.PaneRequestOp, request.get("op").?.string) orelse return error.UnknownOp;
        switch (op) {
            .split => {
                var pane_buf: [64]u8 = undefined;
                const pane = try std.fmt.bufPrint(&pane_buf, "surface:{s}", .{request.get("surface").?.string});
                try self.send("PANE", "move", &.{ pane, request.get("tab").?.string, "999" });
            },
            .close => {
                const addr = try net.UnixAddress.init(self.socket_path);
                const conn = try addr.connect(testing.io);
                defer conn.close(testing.io);
                _ = try sendIdCommand(conn, &self.token, "KILL", &.{request.get("pane").?.string});
            },
            .focus => try self.focusOn(.pane, request.get("pane").?.string),
        }
    }

    /// Shows the Space, tab or pane with this id and reports the focus that follows, as the app does: a Space shows its first tab, and a tab its first pane.
    fn focusOn(self: *FakeApp, scope: Scope, id: []const u8) !void {
        const addr = try net.UnixAddress.init(self.socket_path);
        const conn = try addr.connect(testing.io);
        defer conn.close(testing.io);
        const document = try fetchModel(conn);
        defer testing.allocator.free(document);
        var model = try std.json.parseFromSlice(std.json.Value, testing.allocator, document, .{});
        defer model.deinit();

        for (model.value.object.get("spaces").?.array.items) |space| {
            const space_id = space.object.get("id").?.string;
            for (space.object.get("tabs").?.array.items, 0..) |tab, tab_index| {
                const tab_id = tab.object.get("id").?.string;
                for (tab.object.get("panes").?.array.items, 0..) |pane, pane_index| {
                    const pane_id = pane.object.get("id").?.string;
                    const shown = switch (scope) {
                        .space => std.mem.eql(u8, space_id, id) and tab_index == 0 and pane_index == 0,
                        .tab => std.mem.eql(u8, tab_id, id) and pane_index == 0,
                        .pane => std.mem.eql(u8, pane_id, id),
                    };
                    if (shown) return self.reportFocus(space_id, tab_id, pane_id);
                }
            }
        }
        return error.NotInModel;
    }

    /// Reports what the user was last in on the subscription, as the app does; all empty for nothing.
    fn reportFocus(self: *FakeApp, space: []const u8, tab: []const u8, pane: []const u8) !void {
        var wbuf: [256]u8 = undefined;
        var w = self.conn.writer(testing.io, &wbuf);
        try wire.writeFields(&w.interface, "FOCUS", &.{ space, tab, pane });
    }

    /// Reports one structural change on a connection of its own, as the app does.
    fn send(self: *FakeApp, verb: []const u8, op: []const u8, fields: []const []const u8) !void {
        const addr = try net.UnixAddress.init(self.socket_path);
        const conn = try addr.connect(testing.io);
        defer conn.close(testing.io);
        _ = try sendModelOp(conn, verb, op, fields);
    }

    /// The last request received, parsed; the caller deinits it.
    fn lastRequest(self: *FakeApp) !std.json.Parsed(std.json.Value) {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        const json = self.last orelse return error.NoRequest;
        return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    }

    /// Closes the subscription and waits for the serving thread to end.
    fn finish(self: *FakeApp) void {
        self.conn.shutdown(testing.io, .both) catch {};
        self.thread.join();
        self.conn.close(testing.io);
        if (self.last) |json| testing.allocator.free(json);
        self.windows_arena.deinit();
        testing.allocator.destroy(self);
    }
};

/// What a layout command printed and the code it exited with.
const CommandResult = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(self: CommandResult) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.err);
    }
};

/// Runs a layout command against `server` as if from pane `pane_id` (empty:
/// from outside coastty) sitting in `/work`.
fn runLayoutCommand(server: *TestServer, pane_id: []const u8, args: []const []const u8, timeout_ms: u32) !CommandResult {
    return runLayoutCommandAsJob(server, pane_id, null, args, timeout_ms);
}

/// Runs a layout command as `runLayoutCommand` does, as the leader of the process group `job`.
fn runLayoutCommandAsJob(server: *TestServer, pane_id: []const u8, job: ?u32, args: []const []const u8, timeout_ms: u32) !CommandResult {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    errdefer err.deinit();

    const caller: layout_commands.Caller = .{
        .socket_path = server.path,
        .pane_id = pane_id,
        .cwd = "/work",
        .home = "/home",
        .job = job,
    };
    const code = layout_commands.run(testing.allocator, testing.io, caller, args, .{ .out = &out.writer, .err = &err.writer }, timeout_ms);
    return .{ .code = code, .out = try out.toOwnedSlice(), .err = try err.toOwnedSlice() };
}

test "tab new opens a tab at the end of the caller's own Space and prints only its id" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-new");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "tab", "new", "--name", "build" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);

    // One line, holding nothing but the id.
    try testing.expectEqual(@as(usize, 37), result.out.len);
    try testing.expectEqual(@as(u8, '\n'), result.out[36]);
    const tab_id = result.out[0..36];

    // Already in the model by the time the id was printed.
    const space = host.model.findSpace("space-a").?;
    try testing.expectEqual(@as(usize, 2), space.tabs.items.len);
    try testing.expectEqualStrings(tab_id, space.tabs.items[1].id);
    try testing.expectEqualStrings("build", space.tabs.items[1].name);

    var request = try app.lastRequest();
    defer request.deinit();
    const fields = request.value.object;
    try testing.expectEqualStrings("space-a", fields.get("space").?.string);
    try testing.expectEqualStrings("surface:p1", fields.get("near").?.string);
    try testing.expectEqualStrings("/work", fields.get("directory").?.string);
    try testing.expect(!fields.get("focus").?.bool);
}

test "tab new --space targets another Space, carrying --cwd and --focus to the app" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    {
        const tc = try TestConn.open(&host, "tab-new-space-b");
        defer tc.finish();
        _ = try sendModelOp(tc.client, "SPACE", "new", &.{ "space-b", "" });
    }

    const server = try TestServer.start(&host, "tab-new-space");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "", &.{ "tab", "new", "--space", "space-b", "--cwd", "/tmp/elsewhere", "--focus" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqual(@as(usize, 1), host.model.findSpace("space-b").?.tabs.items.len);

    var request = try app.lastRequest();
    defer request.deinit();
    const fields = request.value.object;
    try testing.expectEqualStrings("space-b", fields.get("space").?.string);
    try testing.expectEqualStrings("", fields.get("near").?.string);
    try testing.expectEqualStrings("/tmp/elsewhere", fields.get("directory").?.string);
    try testing.expect(fields.get("focus").?.bool);
}

test "with no app to carry it out, tab new fails saying coastty isn't running" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-new-no-app");
    defer server.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "tab", "new" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_failed, result.code);
    try testing.expectEqualStrings("", result.out);
    try testing.expectEqualStrings(layout_commands.not_running ++ "\n", result.err);
}

test "a tab the model never shows fails as unverified rather than as done" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-new-unverified");
    defer server.finish();
    const app = try FakeApp.start(server, false);
    defer app.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "tab", "new" }, 200);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_failed, result.code);
    try testing.expectEqualStrings("", result.out);
    try testing.expectEqualStrings(layout_commands.unverified ++ "\n", result.err);
}

test "a request naming a Space or pane nobody knows is refused before the app hears of it" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-new-unknown");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const no_space = try runLayoutCommand(server, "", &.{ "tab", "new", "--space", "nope" }, layout_commands.default_verify_timeout_ms);
    defer no_space.deinit();
    try testing.expectEqual(layout_commands.exit_failed, no_space.code);
    try testing.expectEqualStrings("no such space\n", no_space.err);

    const no_pane = try runLayoutCommand(server, "surface:gone", &.{ "tab", "new" }, layout_commands.default_verify_timeout_ms);
    defer no_pane.deinit();
    try testing.expectEqual(layout_commands.exit_failed, no_pane.code);
    try testing.expectEqualStrings("no such pane\n", no_pane.err);

    try testing.expectError(error.NoRequest, app.lastRequest());
}

/// Adds tabs `tab-2` and `tab-3` to `space-a` after `buildTestModel`'s
/// `tab-1`, each holding one pane named after it.
fn addTestTabs(host: *Host) !void {
    try sendTestModelOp(host, "TAB", "new", &.{ "space-a", "tab-2", "" });
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:p2", "tab-2", "0" });
    try sendTestModelOp(host, "TAB", "new", &.{ "space-a", "tab-3", "" });
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:p3", "tab-3", "0" });
}

/// Sends one model op on a connection of its own, which serves just one.
fn sendTestModelOp(host: *Host, verb: []const u8, op: []const u8, fields: []const []const u8) !void {
    const tc = try TestConn.open(host, "model-op");
    defer tc.finish();
    _ = try sendModelOp(tc.client, verb, op, fields);
}

/// Starts a live daemon pane under a model pane's id, running `argv`.
fn spawnModelPane(host: *Host, id: []const u8, argv: []const []const u8) !void {
    const tc = try TestConn.open(host, "spawn-model-pane");
    defer tc.finish();
    const created = try sendCreate(tc.client, &tc.token, id, "/", argv, 80, 24);
    testing.allocator.free(created.id);
}

/// Waits until the running check reports `expected` for the pane with this
/// id (null: running nothing), since a fresh process takes a moment to
/// exec, print or exit.
fn awaitRunning(host: *Host, id: []const u8, expected: ?[]const u8) !void {
    for (0..400) |_| {
        const pane = host.retainPane(id) orelse return error.PaneGone;
        var buf: [256]u8 = undefined;
        const running = pane.runningCommand(&buf);
        const matches = if (expected) |name| (if (running) |got| std.mem.eql(u8, got, name) else false) else running == null;
        pane.release();
        if (matches) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.RunningNeverSettled;
}

/// The ids of `space-a`'s tabs, in order, joined with spaces; the caller frees it.
fn tabOrder(host: *Host) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (host.model.findSpace("space-a").?.tabs.items) |tab| {
        if (out.items.len > 0) try out.append(testing.allocator, ' ');
        try out.appendSlice(testing.allocator, tab.id);
    }
    return out.toOwnedSlice(testing.allocator);
}

test "tab close is refused while the tab runs something, naming it, and --force closes it anyway" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);
    try spawnModelPane(&host, "surface:p1", &.{ "/bin/sleep", "30" });
    try awaitRunning(&host, "surface:p1", "sleep");

    const server = try TestServer.start(&host, "tab-close-running");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const refused = try runLayoutCommand(server, "surface:p1", &.{ "tab", "close" }, layout_commands.default_verify_timeout_ms);
    defer refused.deinit();
    try testing.expectEqual(layout_commands.exit_failed, refused.code);
    try testing.expectEqualStrings("", refused.out);
    try testing.expectEqualStrings("running sleep\n", refused.err);
    try testing.expectError(error.NoRequest, app.lastRequest());
    try testing.expect(host.model.findSpace("space-a").?.tabs.items.len == 3);

    // The caller closing its own tab, as an agent ending itself would.
    const forced = try runLayoutCommand(server, "surface:p1", &.{ "tab", "close", "--force" }, layout_commands.default_verify_timeout_ms);
    defer forced.deinit();
    try testing.expectEqual(layout_commands.exit_ok, forced.code);
    try testing.expectEqualStrings("", forced.err);
    try testing.expectEqualStrings("closed tab tab-1 (ended sleep)\n", forced.out);

    const order = try tabOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("tab-2 tab-3", order);
}

test "a pane at its prompt or whose process exited is not running anything" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);
    try sendTestModelOp(&host, "PANE", "move", &.{ "surface:p2", "tab-1", "1" });

    // A prompt mark is what shell integration prints; the cursor stays on the marked row.
    try spawnModelPane(&host, "surface:p1", &.{ "/bin/sh", "-c", "printf '\\033]133;A\\007'; exec sleep 30" });
    try spawnModelPane(&host, "surface:p2", &.{ "/bin/sh", "-c", "true" });
    try awaitRunning(&host, "surface:p1", null);
    try awaitRunning(&host, "surface:p2", null);

    const server = try TestServer.start(&host, "tab-close-idle");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "", &.{ "tab", "close", "tab-1" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqualStrings("closed tab tab-1\n", result.out);
    try testing.expect(host.model.findSpace("space-a").?.tabs.items.len == 2);
}

test "a plain tab close from the caller's own shell closes it, since the command running there is the request itself" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);

    // A prompt, then the command typed at it starting, as shell integration marks them.
    try spawnModelPane(&host, "surface:p1", &.{ "/bin/sh", "-c", "printf '\\033]133;A\\007$ \\033]133;C\\007\\n'; exec sleep 30" });
    try awaitRunning(&host, "surface:p1", "sleep");

    const job = blk: {
        const pane = host.retainPane("surface:p1") orelse return error.PaneGone;
        defer pane.release();
        break :blk pane.processInfo().pgid orelse return error.NoForegroundJob;
    };

    const server = try TestServer.start(&host, "tab-close-own");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommandAsJob(server, "surface:p1", job, &.{ "tab", "close" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqualStrings("closed tab tab-1\n", result.out);

    const order = try tabOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("tab-2 tab-3", order);
}

test "tab rename names the caller's tab, and an empty name clears it" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-rename");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const renamed = try runLayoutCommand(server, "surface:p1", &.{ "tab", "rename", "tests" }, layout_commands.default_verify_timeout_ms);
    defer renamed.deinit();
    try testing.expectEqual(layout_commands.exit_ok, renamed.code);
    try testing.expectEqualStrings("renamed tab tab-1 to \"tests\"\n", renamed.out);
    try testing.expectEqualStrings("tests", host.model.findSpace("space-a").?.tabs.items[0].name);

    const cleared = try runLayoutCommand(server, "", &.{ "tab", "rename", "tab-1", "" }, layout_commands.default_verify_timeout_ms);
    defer cleared.deinit();
    try testing.expectEqual(layout_commands.exit_ok, cleared.code);
    try testing.expectEqualStrings("renamed tab tab-1 to \"\"\n", cleared.out);
    try testing.expectEqualStrings("", host.model.findSpace("space-a").?.tabs.items[0].name);
}

test "tab move takes a 1-based position and refuses one past the last tab" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);

    const server = try TestServer.start(&host, "tab-move");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const moved = try runLayoutCommand(server, "", &.{ "tab", "move", "tab-3", "1" }, layout_commands.default_verify_timeout_ms);
    defer moved.deinit();
    try testing.expectEqual(layout_commands.exit_ok, moved.code);
    try testing.expectEqualStrings("moved tab tab-3 to 1\n", moved.out);

    var request = try app.lastRequest();
    defer request.deinit();
    try testing.expectEqual(@as(i64, 0), request.value.object.get("index").?.integer);

    const order = try tabOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("tab-3 tab-1 tab-2", order);

    const too_far = try runLayoutCommand(server, "surface:p1", &.{ "tab", "move", "4" }, layout_commands.default_verify_timeout_ms);
    defer too_far.deinit();
    try testing.expectEqual(layout_commands.exit_failed, too_far.code);
    try testing.expectEqualStrings("no such position\n", too_far.err);
}

test "close, rename and move naming a tab nobody knows are refused before the app hears of them" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "tab-change-unknown");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    inline for (.{
        &[_][]const u8{ "tab", "close", "nope", "--force" },
        &[_][]const u8{ "tab", "rename", "nope", "x" },
        &[_][]const u8{ "tab", "move", "nope", "1" },
    }) |args| {
        const result = try runLayoutCommand(server, "surface:p1", args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings("no such tab\n", result.err);
    }
    try testing.expectError(error.NoRequest, app.lastRequest());
}

/// The ids of the model's Spaces, in order, hidden ones in brackets, joined with spaces; the caller frees it.
fn spaceOrder(host: *Host) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (host.model.spaces.items) |space| {
        if (out.items.len > 0) try out.append(testing.allocator, ' ');
        if (space.hidden) try out.append(testing.allocator, '[');
        try out.appendSlice(testing.allocator, space.id);
        if (space.hidden) try out.append(testing.allocator, ']');
    }
    return out.toOwnedSlice(testing.allocator);
}

test "space new names the caller's Space as the window hint and prints the new Space's and starter tab's ids" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "space-new");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "space", "new", "--name", "task", "--cwd", "sub" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);

    // One line: the Space's id, a space, the tab's id.
    try testing.expectEqual(@as(usize, 74), result.out.len);
    try testing.expectEqual(@as(u8, ' '), result.out[36]);
    try testing.expectEqual(@as(u8, '\n'), result.out[73]);
    const space_id = result.out[0..36];
    const tab_id = result.out[37..73];

    const space = host.model.findSpace(space_id) orelse return error.SpaceMissing;
    try testing.expectEqualStrings("task", space.name);
    try testing.expectEqual(@as(usize, 1), space.tabs.items.len);
    try testing.expectEqualStrings(tab_id, space.tabs.items[0].id);

    var request = try app.lastRequest();
    defer request.deinit();
    const fields = request.value.object;
    try testing.expectEqualStrings("space-a", fields.get("beside").?.string);
    try testing.expectEqualStrings("/work/sub", fields.get("directory").?.string);
    try testing.expect(!fields.get("focus").?.bool);
}

test "outside coastty, space new leaves the window to the app and starts in the home folder" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "space-new-outside");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "", &.{ "space", "new", "--focus" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqual(@as(usize, 2), host.model.spaces.items.len);

    var request = try app.lastRequest();
    defer request.deinit();
    const fields = request.value.object;
    try testing.expectEqualStrings("", fields.get("beside").?.string);
    try testing.expectEqualStrings("/home", fields.get("directory").?.string);
    try testing.expect(fields.get("focus").?.bool);
}

test "space close is refused while any of its tabs runs something, and --force closes it anyway" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);
    try sendTestModelOp(&host, "SPACE", "new", &.{ "space-b", "" });
    try spawnModelPane(&host, "surface:p3", &.{ "/bin/sleep", "30" });
    try awaitRunning(&host, "surface:p3", "sleep");

    const server = try TestServer.start(&host, "space-close-running");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const refused = try runLayoutCommand(server, "", &.{ "space", "close", "space-a" }, layout_commands.default_verify_timeout_ms);
    defer refused.deinit();
    try testing.expectEqual(layout_commands.exit_failed, refused.code);
    try testing.expectEqualStrings("", refused.out);
    try testing.expectEqualStrings("running sleep\n", refused.err);
    try testing.expectError(error.NoRequest, app.lastRequest());

    const forced = try runLayoutCommand(server, "surface:p1", &.{ "space", "close", "--force" }, layout_commands.default_verify_timeout_ms);
    defer forced.deinit();
    try testing.expectEqual(layout_commands.exit_ok, forced.code);
    try testing.expectEqualStrings("", forced.err);
    try testing.expectEqualStrings("closed space space-a (ended sleep)\n", forced.out);

    const order = try spaceOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("space-b", order);
}

test "space rename names the caller's Space, and an empty name clears it" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "space-rename");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const renamed = try runLayoutCommand(server, "surface:p1", &.{ "space", "rename", "task" }, layout_commands.default_verify_timeout_ms);
    defer renamed.deinit();
    try testing.expectEqual(layout_commands.exit_ok, renamed.code);
    try testing.expectEqualStrings("renamed space space-a to \"task\"\n", renamed.out);
    try testing.expectEqualStrings("task", host.model.findSpace("space-a").?.name);

    const cleared = try runLayoutCommand(server, "", &.{ "space", "rename", "space-a", "" }, layout_commands.default_verify_timeout_ms);
    defer cleared.deinit();
    try testing.expectEqual(layout_commands.exit_ok, cleared.code);
    try testing.expectEqualStrings("", host.model.findSpace("space-a").?.name);
}

test "space move counts visible Spaces only, from 1, and refuses a hidden Space or a position past the last" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try sendTestModelOp(&host, "SPACE", "new", &.{ "space-h", "" });
    try sendTestModelOp(&host, "SPACE", "new", &.{ "space-b", "" });
    try sendTestModelOp(&host, "SPACE", "new", &.{ "space-c", "" });
    try sendTestModelOp(&host, "SPACE", "hide", &.{"space-h"});

    const server = try TestServer.start(&host, "space-move");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    // Second among a, b and c, past the hidden Space sitting between a and b.
    const moved = try runLayoutCommand(server, "", &.{ "space", "move", "space-c", "2" }, layout_commands.default_verify_timeout_ms);
    defer moved.deinit();
    try testing.expectEqual(layout_commands.exit_ok, moved.code);
    try testing.expectEqualStrings("", moved.err);
    try testing.expectEqualStrings("moved space space-c to 2\n", moved.out);

    {
        var request = try app.lastRequest();
        defer request.deinit();
        const fields = request.value.object;
        try testing.expectEqual(@as(i64, 1), fields.get("index").?.integer);
        const after = fields.get("after").?.array.items;
        try testing.expectEqual(@as(usize, 1), after.len);
        try testing.expectEqualStrings("space-a", after[0].string);
    }

    const order = try spaceOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("space-a [space-h] space-c space-b", order);

    const too_far = try runLayoutCommand(server, "surface:p1", &.{ "space", "move", "4" }, layout_commands.default_verify_timeout_ms);
    defer too_far.deinit();
    try testing.expectEqual(layout_commands.exit_failed, too_far.code);
    try testing.expectEqualStrings("no such position\n", too_far.err);

    const hidden = try runLayoutCommand(server, "", &.{ "space", "move", "space-h", "1" }, layout_commands.default_verify_timeout_ms);
    defer hidden.deinit();
    try testing.expectEqual(layout_commands.exit_failed, hidden.code);
    try testing.expectEqualStrings("space is hidden\n", hidden.err);
}

test "close, rename and move naming a Space nobody knows are refused before the app hears of them" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "space-change-unknown");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    inline for (.{
        &[_][]const u8{ "space", "close", "nope", "--force" },
        &[_][]const u8{ "space", "rename", "nope", "x" },
        &[_][]const u8{ "space", "move", "nope", "1" },
    }) |args| {
        const result = try runLayoutCommand(server, "surface:p1", args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings("no such space\n", result.err);
    }

    const no_pane = try runLayoutCommand(server, "surface:gone", &.{ "space", "new" }, layout_commands.default_verify_timeout_ms);
    defer no_pane.deinit();
    try testing.expectEqual(layout_commands.exit_failed, no_pane.code);
    try testing.expectEqualStrings("no such pane\n", no_pane.err);

    try testing.expectError(error.NoRequest, app.lastRequest());
}

/// The ids of the panes in `tab-1`, in order, joined with spaces; the caller frees it.
fn paneOrder(host: *Host) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    const found = host.model.findTab("tab-1") orelse return error.TabMissing;
    for (found.space.tabs.items[found.index].panes.items) |pane| {
        if (out.items.len > 0) try out.append(testing.allocator, ' ');
        try out.appendSlice(testing.allocator, pane.id);
    }
    return out.toOwnedSlice(testing.allocator);
}

test "pane split opens a pane beside the caller's own, right or down, and prints only its id" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "pane-split");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const right = try runLayoutCommand(server, "surface:p1", &.{ "pane", "split", "--direction", "right" }, layout_commands.default_verify_timeout_ms);
    defer right.deinit();
    try testing.expectEqual(layout_commands.exit_ok, right.code);
    try testing.expectEqualStrings("", right.err);

    // One line, holding nothing but the id the app's surface is known by.
    try testing.expectEqual(@as(usize, "surface:".len + 37), right.out.len);
    try testing.expect(std.mem.startsWith(u8, right.out, "surface:"));
    const right_id = right.out[0 .. right.out.len - 1];

    {
        var request = try app.lastRequest();
        defer request.deinit();
        const fields = request.value.object;
        try testing.expectEqualStrings("surface:p1", fields.get("pane").?.string);
        try testing.expectEqualStrings("tab-1", fields.get("tab").?.string);
        try testing.expectEqualStrings(right_id["surface:".len..], fields.get("surface").?.string);
        try testing.expectEqualStrings("right", fields.get("direction").?.string);
        try testing.expectEqualStrings("/work", fields.get("directory").?.string);
        try testing.expect(!fields.get("focus").?.bool);
    }

    // From outside coastty, naming the pane, as a script would.
    const down = try runLayoutCommand(server, "", &.{ "pane", "split", "surface:p1", "--direction=down", "--cwd", "/tmp", "--focus" }, layout_commands.default_verify_timeout_ms);
    defer down.deinit();
    try testing.expectEqual(layout_commands.exit_ok, down.code);
    const down_id = down.out[0 .. down.out.len - 1];

    {
        var request = try app.lastRequest();
        defer request.deinit();
        const fields = request.value.object;
        try testing.expectEqualStrings("surface:p1", fields.get("pane").?.string);
        try testing.expectEqualStrings("down", fields.get("direction").?.string);
        try testing.expectEqualStrings("/tmp", fields.get("directory").?.string);
        try testing.expect(fields.get("focus").?.bool);
    }

    const order = try paneOrder(&host);
    defer testing.allocator.free(order);
    const expected = try std.fmt.allocPrint(testing.allocator, "surface:p1 {s} {s}", .{ right_id, down_id });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, order);
}

test "pane close is refused while the pane runs something, naming it, and --force closes it anyway" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try sendTestModelOp(&host, "PANE", "move", &.{ "surface:p2", "tab-1", "1" });
    try spawnModelPane(&host, "surface:p2", &.{ "/bin/sleep", "30" });
    try awaitRunning(&host, "surface:p2", "sleep");

    const server = try TestServer.start(&host, "pane-close-running");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const refused = try runLayoutCommand(server, "surface:p1", &.{ "pane", "close", "surface:p2" }, layout_commands.default_verify_timeout_ms);
    defer refused.deinit();
    try testing.expectEqual(layout_commands.exit_failed, refused.code);
    try testing.expectEqualStrings("", refused.out);
    try testing.expectEqualStrings("running sleep\n", refused.err);
    try testing.expectError(error.NoRequest, app.lastRequest());

    // The pane closing itself, as an agent ending its own split would.
    const forced = try runLayoutCommand(server, "surface:p2", &.{ "pane", "close", "--force" }, layout_commands.default_verify_timeout_ms);
    defer forced.deinit();
    try testing.expectEqual(layout_commands.exit_ok, forced.code);
    try testing.expectEqualStrings("", forced.err);
    try testing.expectEqualStrings("closed pane surface:p2 (ended sleep)\n", forced.out);

    {
        var request = try app.lastRequest();
        defer request.deinit();
        try testing.expectEqualStrings("pane", request.value.object.get("scope").?.string);
        try testing.expectEqualStrings("surface:p2", request.value.object.get("pane").?.string);
    }

    const order = try paneOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("surface:p1", order);
}

test "closing a tab's last pane asks the app to close the tab" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addTestTabs(&host);

    const server = try TestServer.start(&host, "pane-close-last");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "pane", "close", "surface:p2" }, layout_commands.default_verify_timeout_ms);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqualStrings("closed pane surface:p2\n", result.out);

    {
        var request = try app.lastRequest();
        defer request.deinit();
        try testing.expectEqualStrings("tab", request.value.object.get("scope").?.string);
        try testing.expectEqualStrings("close", request.value.object.get("op").?.string);
        try testing.expectEqualStrings("tab-2", request.value.object.get("tab").?.string);
    }

    const order = try tabOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("tab-1 tab-3", order);
}

test "pane split and close naming a pane nobody knows are refused before the app hears of them" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "pane-unknown");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    inline for (.{
        &[_][]const u8{ "pane", "split", "surface:nope", "--direction", "right" },
        &[_][]const u8{ "pane", "close", "surface:nope", "--force" },
    }) |args| {
        const result = try runLayoutCommand(server, "surface:p1", args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings("no such pane\n", result.err);
    }

    const from_gone = try runLayoutCommand(server, "surface:gone", &.{ "pane", "split", "--direction", "down" }, layout_commands.default_verify_timeout_ms);
    defer from_gone.deinit();
    try testing.expectEqual(layout_commands.exit_failed, from_gone.code);
    try testing.expectEqualStrings("no such pane\n", from_gone.err);

    try testing.expectError(error.NoRequest, app.lastRequest());
}

/// Builds the model the list tests read: `space-a`, named `work`, holding
/// `tab-1` (named `build`, panes p1 and p4), `tab-2` and `tab-3`, and a
/// hidden, unnamed `space-h` holding `tab-h`.
fn buildListModel(host: *Host) !void {
    try buildTestModel(host);
    try addTestTabs(host);
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:p4", "tab-1", "1" });
    try sendTestModelOp(host, "SPACE", "rename", &.{ "space-a", "work" });
    try sendTestModelOp(host, "SPACE", "new", &.{ "space-h", "" });
    try sendTestModelOp(host, "TAB", "new", &.{ "space-h", "tab-h", "" });
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:ph", "tab-h", "0" });
    try sendTestModelOp(host, "SPACE", "hide", &.{"space-h"});
}

/// Runs a list command expected to succeed, returning what it printed, which the caller frees.
fn runListCommand(server: *TestServer, pane_id: []const u8, args: []const []const u8) ![]u8 {
    const result = try runLayoutCommand(server, pane_id, args, layout_commands.default_verify_timeout_ms);
    defer testing.allocator.free(result.err);
    errdefer testing.allocator.free(result.out);
    try testing.expectEqualStrings("", result.err);
    try testing.expectEqual(layout_commands.exit_ok, result.code);
    return result.out;
}

test "space list shows every Space, hidden ones too, and marks the one holding the caller" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildListModel(&host);

    // Lists read the model alone, so no app is subscribed.
    const server = try TestServer.start(&host, "space-list");
    defer server.finish();

    const table = try runListCommand(server, "surface:p2", &.{ "space", "list" });
    defer testing.allocator.free(table);
    try testing.expectEqualStrings(
        \\   ID       NAME  TABS  WINDOW  HIDDEN
        \\*  space-a  work  3             no
        \\   space-h        1             yes
        \\
    , table);

    const json = try runListCommand(server, "", &.{ "space", "list", "--json" });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "id": "space-a",
        \\    "name": "work",
        \\    "tabs": 3,
        \\    "hidden": false,
        \\    "window": "",
        \\    "caller": false,
        \\    "focused": false
        \\  },
        \\  {
        \\    "id": "space-h",
        \\    "name": "",
        \\    "tabs": 1,
        \\    "hidden": true,
        \\    "window": "",
        \\    "caller": false,
        \\    "focused": false
        \\  }
        \\]
        \\
    , json);
}

test "tab list shows the caller's Space, another with --space, or every tab with --all" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildListModel(&host);

    const server = try TestServer.start(&host, "tab-list");
    defer server.finish();

    const own = try runListCommand(server, "surface:p2", &.{ "tab", "list" });
    defer testing.allocator.free(own);
    try testing.expectEqualStrings(
        \\   ID     NAME   PANES  POSITION
        \\   tab-1  build  2      1
        \\*  tab-2         1      2
        \\   tab-3         1      3
        \\
    , own);

    const all = try runListCommand(server, "", &.{ "tab", "list", "--all" });
    defer testing.allocator.free(all);
    try testing.expectEqualStrings(
        \\  ID     NAME   SPACE    PANES  POSITION
        \\  tab-1  build  space-a  2      1
        \\  tab-2         space-a  1      2
        \\  tab-3         space-a  1      3
        \\  tab-h         space-h  1      1
        \\
    , all);

    const other = try runListCommand(server, "", &.{ "tab", "list", "--space", "space-h", "--json" });
    defer testing.allocator.free(other);
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "id": "tab-h",
        \\    "name": "",
        \\    "space": "space-h",
        \\    "panes": 1,
        \\    "position": 1,
        \\    "caller": false,
        \\    "focused": false
        \\  }
        \\]
        \\
    , other);
}

test "pane list shows the panes of the caller's tab or the one named" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildListModel(&host);

    const server = try TestServer.start(&host, "pane-list");
    defer server.finish();

    const own = try runListCommand(server, "surface:p1", &.{ "pane", "list" });
    defer testing.allocator.free(own);
    try testing.expectEqualStrings(
        \\   ID
        \\*  surface:p1
        \\   surface:p4
        \\
    , own);

    const named = try runListCommand(server, "", &.{ "pane", "list", "tab-2", "--json" });
    defer testing.allocator.free(named);
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "id": "surface:p2",
        \\    "caller": false,
        \\    "focused": false
        \\  }
        \\]
        \\
    , named);
}

test "a list naming a Space, tab or pane nobody knows fails saying so" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildListModel(&host);

    const server = try TestServer.start(&host, "list-unknown");
    defer server.finish();

    const Case = struct { pane_id: []const u8, args: []const []const u8, err: []const u8 };
    for ([_]Case{
        .{ .pane_id = "", .args = &.{ "tab", "list", "--space", "nope" }, .err = "no such space\n" },
        .{ .pane_id = "", .args = &.{ "pane", "list", "nope" }, .err = "no such tab\n" },
        .{ .pane_id = "surface:gone", .args = &.{ "tab", "list" }, .err = "no such pane\n" },
        .{ .pane_id = "surface:gone", .args = &.{ "pane", "list" }, .err = "no such pane\n" },
    }) |case| {
        const result = try runLayoutCommand(server, case.pane_id, case.args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings("", result.out);
        try testing.expectEqualStrings(case.err, result.err);
    }

    // A caller the model doesn't hold has no Space to mark, but every Space still lists.
    const spaces = try runListCommand(server, "surface:gone", &.{ "space", "list" });
    defer testing.allocator.free(spaces);
    try testing.expect(std.mem.indexOf(u8, spaces, "*") == null);
}

test "randomUuid has the shape of the app's own ids" {
    const id = randomUuid(testing.io);
    try testing.expectEqual(@as(u8, '-'), id[8]);
    try testing.expectEqual(@as(u8, '4'), id[14]);
    for (id) |c| try testing.expect(c == '-' or std.ascii.isDigit(c) or std.ascii.isUpper(c));
}

/// Waits until the daemon holds a focus on `space`, or none when `space` is empty, failing after three seconds.
fn awaitFocus(host: *Host, space: []const u8) !void {
    const start = Io.Timestamp.now(testing.io, .awake);
    while (true) {
        const held = try host.focus.snapshot(testing.allocator);
        defer if (held) |focus| focus.deinit(testing.allocator);
        const holding: []const u8 = if (held) |focus| focus.space else "";
        if (std.mem.eql(u8, holding, space)) return;

        const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake));
        if (elapsed.toMilliseconds() >= 3000) return error.Timeout;
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
}

/// Adds `space-b`, holding `tab-b` with pane `surface:pb`, after `buildTestModel`'s `space-a`.
fn addFocusSpace(host: *Host) !void {
    try sendTestModelOp(host, "SPACE", "new", &.{ "space-b", "" });
    try sendTestModelOp(host, "TAB", "new", &.{ "space-b", "tab-b", "" });
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:pb", "tab-b", "0" });
}

test "coastty focused prints what the app reports, never touches the model, and forgets it when the app disconnects" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "focused");
    defer server.finish();
    const app = try FakeApp.start(server, false);
    // Finished by hand below, and here only when a check fails first, so the server never waits on its subscription.
    var app_open = true;
    defer if (app_open) app.finish();

    // Nothing is focused until the app says so.
    const before = try runLayoutCommand(server, "", &.{"focused"}, layout_commands.default_verify_timeout_ms);
    defer before.deinit();
    try testing.expectEqual(layout_commands.exit_failed, before.code);
    try testing.expectEqualStrings(layout_commands.nothing_focused ++ "\n", before.err);

    const revision = host.model.revision;
    try app.reportFocus("space-a", "tab-1", "surface:p1");
    try awaitFocus(&host, "space-a");
    try testing.expectEqual(revision, host.model.revision);

    const line = try runListCommand(server, "", &.{"focused"});
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(
        \\KIND   ID          NAME
        \\space  space-a     
        \\tab    tab-1       build
        \\pane   surface:p1  
        \\
    , line);

    const json = try runListCommand(server, "surface:p1", &.{ "focused", "--json" });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{
        \\  "space": {
        \\    "id": "space-a",
        \\    "name": ""
        \\  },
        \\  "tab": {
        \\    "id": "tab-1",
        \\    "name": "build"
        \\  },
        \\  "pane": {
        \\    "id": "surface:p1",
        \\    "title": "",
        \\    "directory": ""
        \\  }
        \\}
        \\
    , json);

    // A window losing focus to something that isn't coastty reports nothing.
    try app.reportFocus("", "", "");
    try awaitFocus(&host, "");
    try app.reportFocus("space-a", "tab-1", "surface:p1");
    try awaitFocus(&host, "space-a");

    app.finish();
    app_open = false;
    try awaitFocus(&host, "");
    const after = try runLayoutCommand(server, "", &.{"focused"}, layout_commands.default_verify_timeout_ms);
    defer after.deinit();
    try testing.expectEqual(layout_commands.exit_failed, after.code);
    try testing.expectEqualStrings(layout_commands.nothing_focused ++ "\n", after.err);
}

test "only the app's focus counts" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const sub = try openSubscription(&host, "focus-client", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);

    var wbuf: [128]u8 = undefined;
    var w = sub.tc.client.writer(testing.io, &wbuf);
    try wire.writeFields(&w.interface, "FOCUS", &.{ "space-a", "tab-1", "surface:p1" });
    try Io.sleep(testing.io, .fromMilliseconds(100), .awake);
    try testing.expectEqual(@as(?Focus.Snapshot, null), try host.focus.snapshot(testing.allocator));
}

test "outside coastty, tab new joins the focused Space and pane split splits the focused pane" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addFocusSpace(&host);

    const server = try TestServer.start(&host, "focused-default");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportFocus("space-b", "tab-b", "surface:pb");
    try awaitFocus(&host, "space-b");

    const tab = try runLayoutCommand(server, "", &.{ "tab", "new" }, layout_commands.default_verify_timeout_ms);
    defer tab.deinit();
    try testing.expectEqual(layout_commands.exit_ok, tab.code);
    try testing.expectEqual(@as(usize, 2), host.model.findSpace("space-b").?.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), host.model.findSpace("space-a").?.tabs.items.len);

    const split = try runLayoutCommand(server, "", &.{ "pane", "split", "--direction", "down" }, layout_commands.default_verify_timeout_ms);
    defer split.deinit();
    try testing.expectEqual(layout_commands.exit_ok, split.code);

    var request = try app.lastRequest();
    defer request.deinit();
    try testing.expectEqualStrings("surface:pb", request.value.object.get("pane").?.string);
    try testing.expectEqualStrings("tab-b", request.value.object.get("tab").?.string);
    try testing.expectEqualStrings("/home", request.value.object.get("directory").?.string);

    // Lists naming nothing fall back the same way: the focused Space's tabs, the focused tab's panes.
    const tabs = try runListCommand(server, "", &.{ "tab", "list" });
    defer testing.allocator.free(tabs);
    try testing.expect(std.mem.indexOf(u8, tabs, "tab-b") != null);
    try testing.expect(std.mem.indexOf(u8, tabs, "tab-1") == null);
    const panes = try runListCommand(server, "", &.{ "pane", "list" });
    defer testing.allocator.free(panes);
    try testing.expect(std.mem.indexOf(u8, panes, "surface:pb") != null);
}

test "inside coastty, tab new and pane split stay in the caller's own Space while another is focused" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addFocusSpace(&host);

    const server = try TestServer.start(&host, "caller-default");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportFocus("space-b", "tab-b", "surface:pb");
    try awaitFocus(&host, "space-b");

    const tab = try runLayoutCommand(server, "surface:p1", &.{ "tab", "new" }, layout_commands.default_verify_timeout_ms);
    defer tab.deinit();
    try testing.expectEqual(layout_commands.exit_ok, tab.code);
    try testing.expectEqual(@as(usize, 2), host.model.findSpace("space-a").?.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), host.model.findSpace("space-b").?.tabs.items.len);

    const split = try runLayoutCommand(server, "surface:p1", &.{ "pane", "split", "--direction", "right" }, layout_commands.default_verify_timeout_ms);
    defer split.deinit();
    try testing.expectEqual(layout_commands.exit_ok, split.code);

    var request = try app.lastRequest();
    defer request.deinit();
    try testing.expectEqualStrings("surface:p1", request.value.object.get("pane").?.string);
}

test "outside coastty with nothing focused, tab new and pane split fail saying so, and close still needs an id" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "nothing-focused");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();

    inline for (.{
        &[_][]const u8{ "tab", "new" },
        &[_][]const u8{ "pane", "split", "--direction", "right" },
    }) |args| {
        const result = try runLayoutCommand(server, "", args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings(layout_commands.nothing_focused ++ "\n", result.err);
    }
    try testing.expectError(error.NoRequest, app.lastRequest());

    // Focus never stands in for the id of something closed, renamed or moved.
    try app.reportFocus("space-a", "tab-1", "surface:p1");
    try awaitFocus(&host, "space-a");
    inline for (.{
        &[_][]const u8{ "tab", "close", "--force" },
        &[_][]const u8{ "space", "rename", "focused" },
        &[_][]const u8{ "pane", "close" },
    }) |args| {
        const result = try runLayoutCommand(server, "", args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_usage, result.code);
    }
    try testing.expectError(error.NoRequest, app.lastRequest());
}

test "lists mark the focused Space, tab and pane beside the caller's own" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildListModel(&host);

    const server = try TestServer.start(&host, "list-focused");
    defer server.finish();
    const app = try FakeApp.start(server, false);
    defer app.finish();
    try app.reportFocus("space-a", "tab-2", "surface:p2");
    try awaitFocus(&host, "space-a");

    const spaces = try runListCommand(server, "surface:p1", &.{ "space", "list" });
    defer testing.allocator.free(spaces);
    try testing.expectEqualStrings(
        \\    ID       NAME  TABS  WINDOW  HIDDEN
        \\*>  space-a  work  3             no
        \\    space-h        1             yes
        \\
    , spaces);

    const tabs = try runListCommand(server, "surface:p1", &.{ "tab", "list" });
    defer testing.allocator.free(tabs);
    try testing.expectEqualStrings(
        \\   ID     NAME   PANES  POSITION
        \\*  tab-1  build  2      1
        \\>  tab-2         1      2
        \\   tab-3         1      3
        \\
    , tabs);

    const panes = try runListCommand(server, "", &.{ "pane", "list", "tab-2", "--json" });
    defer testing.allocator.free(panes);
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "id": "surface:p2",
        \\    "caller": false,
        \\    "focused": true
        \\  }
        \\]
        \\
    , panes);
}

/// Waits until the daemon holds exactly `body` as the app's windows, failing after three seconds.
fn awaitWindows(host: *Host, body: []const u8) !void {
    const start = Io.Timestamp.now(testing.io, .awake);
    while (true) {
        const held = try host.windows.snapshot(testing.allocator);
        defer testing.allocator.free(held);
        if (std.mem.eql(u8, held, body)) return;

        const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake));
        if (elapsed.toMilliseconds() >= 3000) return error.Timeout;
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
}

/// `space-a` and `space-c` in `win-1`, `space-b` in `win-2`, each with one tab and pane.
fn buildWindowModel(host: *Host) !void {
    try buildTestModel(host);
    try addFocusSpace(host);
    try sendTestModelOp(host, "SPACE", "new", &.{ "space-c", "" });
    try sendTestModelOp(host, "TAB", "new", &.{ "space-c", "tab-c", "" });
    try sendTestModelOp(host, "PANE", "move", &.{ "surface:pc", "tab-c", "0" });
}

const two_windows = [_]FakeApp.WindowSetup{
    .{ .id = "win-1", .spaces = &.{ "space-a", "space-c" } },
    .{ .id = "win-2", .spaces = &.{"space-b"} },
};
const two_windows_body = "win-1\x00space-a\x00space-a\x00space-c\nwin-2\x00space-b\x00space-b";

test "coastty window list prints the windows the app reports, never touches the model, and forgets them when the app disconnects" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildWindowModel(&host);

    const server = try TestServer.start(&host, "window-list");
    defer server.finish();
    const app = try FakeApp.start(server, false);
    // Finished by hand below, and here only when a check fails first, so the server never waits on its subscription.
    var app_open = true;
    defer if (app_open) app.finish();

    const revision = host.model.revision;
    try app.reportWindows(&two_windows);
    try awaitWindows(&host, two_windows_body);
    try testing.expectEqual(revision, host.model.revision);

    const table = try runListCommand(server, "surface:p1", &.{ "window", "list" });
    defer testing.allocator.free(table);
    try testing.expectEqualStrings(
        \\   ID     ACTIVE   SPACES
        \\*  win-1  space-a  space-a,space-c
        \\   win-2  space-b  space-b
        \\
    , table);

    const json = try runListCommand(server, "", &.{ "window", "list", "--json" });
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\[
        \\  {
        \\    "id": "win-1",
        \\    "active": "space-a",
        \\    "spaces": [
        \\      "space-a",
        \\      "space-c"
        \\    ],
        \\    "caller": false,
        \\    "focused": false
        \\  },
        \\  {
        \\    "id": "win-2",
        \\    "active": "space-b",
        \\    "spaces": [
        \\      "space-b"
        \\    ],
        \\    "caller": false,
        \\    "focused": false
        \\  }
        \\]
        \\
    , json);

    const spaces = try runListCommand(server, "", &.{ "space", "list" });
    defer testing.allocator.free(spaces);
    try testing.expectEqualStrings(
        \\  ID       NAME  TABS  WINDOW  HIDDEN
        \\  space-a        1     win-1   no
        \\  space-b        1     win-2   no
        \\  space-c        1     win-1   no
        \\
    , spaces);

    // Nothing about windows ever reaches the model's file.
    const document = try host.model.renderFile(testing.allocator);
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "win-1") == null);

    app.finish();
    app_open = false;
    try awaitWindows(&host, "");
    const after = try runListCommand(server, "", &.{ "window", "list" });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("  ID  ACTIVE  SPACES\n", after);
}

test "only the app's windows count" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const sub = try openSubscription(&host, "windows-client", "1 client");
    defer sub.tc.finish();
    defer testing.allocator.free(sub.answer);

    var wbuf: [128]u8 = undefined;
    var w = sub.tc.client.writer(testing.io, &wbuf);
    try wire.writeFrame(&w.interface, "WINDOWS", "win-1\x00space-a\x00space-a");
    try Io.sleep(testing.io, .fromMilliseconds(100), .awake);

    const held = try host.windows.snapshot(testing.allocator);
    defer testing.allocator.free(held);
    try testing.expectEqualStrings("", held);
}

test "space new --window asks for the Space in that window, and an unknown window is refused" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildWindowModel(&host);

    const server = try TestServer.start(&host, "space-new-window");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportWindows(&two_windows);
    try awaitWindows(&host, two_windows_body);

    const made = try runLayoutCommand(server, "surface:p1", &.{ "space", "new", "--window", "win-2" }, layout_commands.default_verify_timeout_ms);
    defer made.deinit();
    try testing.expectEqualStrings("", made.err);
    try testing.expectEqual(layout_commands.exit_ok, made.code);

    var request = try app.lastRequest();
    defer request.deinit();
    try testing.expectEqualStrings("win-2", request.value.object.get("window").?.string);

    const unknown = try runLayoutCommand(server, "surface:p1", &.{ "space", "new", "--window", "win-9" }, layout_commands.default_verify_timeout_ms);
    defer unknown.deinit();
    try testing.expectEqual(layout_commands.exit_failed, unknown.code);
    try testing.expectEqualStrings("no such window\n", unknown.err);
    try testing.expectEqual(@as(usize, 4), host.model.spaces.items.len);
}

test "space new without --window still names no window" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildWindowModel(&host);

    const server = try TestServer.start(&host, "space-new-default");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportWindows(&two_windows);
    try awaitWindows(&host, two_windows_body);

    const made = try runLayoutCommand(server, "surface:pb", &.{ "space", "new" }, layout_commands.default_verify_timeout_ms);
    defer made.deinit();
    try testing.expectEqual(layout_commands.exit_ok, made.code);

    var request = try app.lastRequest();
    defer request.deinit();
    try testing.expectEqualStrings("", request.value.object.get("window").?.string);
    try testing.expectEqualStrings("space-b", request.value.object.get("beside").?.string);
}

test "space move --window moves a Space between windows, at the end or a given position, keeping the model's order in step" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildWindowModel(&host);

    const server = try TestServer.start(&host, "space-move-window");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportWindows(&two_windows);
    try awaitWindows(&host, two_windows_body);

    // To the end of win-2, after space-b.
    const to_end = try runLayoutCommand(server, "", &.{ "space", "move", "space-c", "--window", "win-2" }, layout_commands.default_verify_timeout_ms);
    defer to_end.deinit();
    try testing.expectEqualStrings("", to_end.err);
    try testing.expectEqual(layout_commands.exit_ok, to_end.code);
    try testing.expectEqualStrings("moved space space-c to window win-2 at 2\n", to_end.out);
    {
        var request = try app.lastRequest();
        defer request.deinit();
        try testing.expectEqualStrings("win-2", request.value.object.get("window").?.string);
        try testing.expectEqual(@as(i64, 2), request.value.object.get("index").?.integer);
        const after = request.value.object.get("after").?.array.items;
        try testing.expectEqual(@as(usize, 1), after.len);
        try testing.expectEqualStrings("space-b", after[0].string);
    }

    // The caller's own Space, first in win-2; win-1 is left with nothing and closes.
    const first = try runLayoutCommand(server, "surface:p1", &.{ "space", "move", "--window=win-2", "1" }, layout_commands.default_verify_timeout_ms);
    defer first.deinit();
    try testing.expectEqualStrings("", first.err);
    try testing.expectEqualStrings("moved space space-a to window win-2 at 1\n", first.out);
    try awaitWindows(&host, "win-2\x00space-a\x00space-a\x00space-b\x00space-c");

    const order = try spaceOrder(&host);
    defer testing.allocator.free(order);
    try testing.expectEqualStrings("space-a space-b space-c", order);

    const windows = try runListCommand(server, "", &.{ "window", "list" });
    defer testing.allocator.free(windows);
    try testing.expectEqualStrings(
        \\  ID     ACTIVE   SPACES
        \\  win-2  space-a  space-a,space-b,space-c
        \\
    , windows);
}

test "space move --window refuses an unknown window, a position past the window's last Space and a hidden Space" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildWindowModel(&host);
    try sendTestModelOp(&host, "SPACE", "hide", &.{"space-c"});

    const server = try TestServer.start(&host, "space-move-window-refused");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportWindows(&two_windows);
    try awaitWindows(&host, two_windows_body);

    const Case = struct { args: []const []const u8, err: []const u8 };
    for ([_]Case{
        .{ .args = &.{ "space", "move", "space-a", "--window", "win-9" }, .err = "no such window\n" },
        // win-2 shows only space-b, so space-a can land first or second.
        .{ .args = &.{ "space", "move", "space-a", "--window", "win-2", "3" }, .err = "no such position\n" },
        .{ .args = &.{ "space", "move", "space-c", "--window", "win-2" }, .err = "space is hidden\n" },
        .{ .args = &.{ "space", "move", "space-z", "--window", "win-2" }, .err = "no such space\n" },
    }) |case| {
        const result = try runLayoutCommand(server, "", case.args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings(case.err, result.err);
    }
    try testing.expectError(error.NoRequest, app.lastRequest());
}

test "space, tab and pane focus reach the app and return once its focus report shows them" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addFocusSpace(&host);

    const server = try TestServer.start(&host, "focus-named");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportFocus("space-a", "tab-1", "surface:p1");
    try awaitFocus(&host, "space-a");

    const revision = host.model.revision;

    const space = try runLayoutCommand(server, "", &.{ "space", "focus", "space-b" }, layout_commands.default_verify_timeout_ms);
    defer space.deinit();
    try testing.expectEqual(layout_commands.exit_ok, space.code);
    try testing.expectEqualStrings("focused space space-b\n", space.out);
    {
        var request = try app.lastRequest();
        defer request.deinit();
        try testing.expectEqualStrings("space", request.value.object.get("scope").?.string);
        try testing.expectEqualStrings("focus", request.value.object.get("op").?.string);
        try testing.expectEqualStrings("space-b", request.value.object.get("space").?.string);
    }

    const tab = try runLayoutCommand(server, "", &.{ "tab", "focus", "tab-1" }, layout_commands.default_verify_timeout_ms);
    defer tab.deinit();
    try testing.expectEqual(layout_commands.exit_ok, tab.code);
    try testing.expectEqualStrings("focused tab tab-1\n", tab.out);

    const pane = try runLayoutCommand(server, "", &.{ "pane", "focus", "surface:pb" }, layout_commands.default_verify_timeout_ms);
    defer pane.deinit();
    try testing.expectEqual(layout_commands.exit_ok, pane.code);
    try testing.expectEqualStrings("focused pane surface:pb\n", pane.out);
    {
        var request = try app.lastRequest();
        defer request.deinit();
        try testing.expectEqualStrings("pane", request.value.object.get("scope").?.string);
        try testing.expectEqualStrings("focus", request.value.object.get("op").?.string);
        try testing.expectEqualStrings("surface:pb", request.value.object.get("pane").?.string);
    }

    // Focus is presentation: the model never changes for it.
    try testing.expectEqual(revision, host.model.revision);
}

test "focus with no id takes the user to the caller's own Space, tab or pane" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);
    try addFocusSpace(&host);

    const server = try TestServer.start(&host, "focus-own");
    defer server.finish();
    const app = try FakeApp.start(server, true);
    defer app.finish();
    try app.reportFocus("space-b", "tab-b", "surface:pb");
    try awaitFocus(&host, "space-b");

    const pane = try runLayoutCommand(server, "surface:p1", &.{ "pane", "focus" }, layout_commands.default_verify_timeout_ms);
    defer pane.deinit();
    try testing.expectEqual(layout_commands.exit_ok, pane.code);
    try testing.expectEqualStrings("focused pane surface:p1\n", pane.out);

    try app.reportFocus("space-b", "tab-b", "surface:pb");
    try awaitFocus(&host, "space-b");
    const space = try runLayoutCommand(server, "surface:p1", &.{ "space", "focus" }, layout_commands.default_verify_timeout_ms);
    defer space.deinit();
    try testing.expectEqual(layout_commands.exit_ok, space.code);
    try testing.expectEqualStrings("focused space space-a\n", space.out);
}

test "focus refuses an unknown id, needs an id outside coastty, and fails without the app" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "focus-refused");
    defer server.finish();

    // No app is subscribed yet, so nothing can be brought to the front.
    const closed = try runLayoutCommand(server, "", &.{ "tab", "focus", "tab-1" }, layout_commands.default_verify_timeout_ms);
    defer closed.deinit();
    try testing.expectEqual(layout_commands.exit_failed, closed.code);
    try testing.expectEqualStrings(layout_commands.not_running ++ "\n", closed.err);

    const app = try FakeApp.start(server, true);
    defer app.finish();

    const Case = struct { args: []const []const u8, err: []const u8 };
    for ([_]Case{
        .{ .args = &.{ "space", "focus", "nope" }, .err = "no such space\n" },
        .{ .args = &.{ "tab", "focus", "nope" }, .err = "no such tab\n" },
        .{ .args = &.{ "pane", "focus", "surface:nope" }, .err = "no such pane\n" },
    }) |case| {
        const result = try runLayoutCommand(server, "", case.args, layout_commands.default_verify_timeout_ms);
        defer result.deinit();
        try testing.expectEqual(layout_commands.exit_failed, result.code);
        try testing.expectEqualStrings(case.err, result.err);
    }

    // Focus never stands in for the id of what to bring forward.
    try app.reportFocus("space-a", "tab-1", "surface:p1");
    try awaitFocus(&host, "space-a");
    const outside = try runLayoutCommand(server, "", &.{ "tab", "focus" }, layout_commands.default_verify_timeout_ms);
    defer outside.deinit();
    try testing.expectEqual(layout_commands.exit_usage, outside.code);
    try testing.expect(std.mem.indexOf(u8, outside.err, "outside coastty, a tab id is required") != null);
    try testing.expectError(error.NoRequest, app.lastRequest());
}

test "focus that the app never reports fails as unverified" {
    var host: Host = .init(testing.allocator, testing.io);
    defer deinitTestHost(&host);
    try buildTestModel(&host);

    const server = try TestServer.start(&host, "focus-unverified");
    defer server.finish();
    const app = try FakeApp.start(server, false);
    defer app.finish();

    const result = try runLayoutCommand(server, "surface:p1", &.{ "tab", "focus" }, 200);
    defer result.deinit();
    try testing.expectEqual(layout_commands.exit_failed, result.code);
    try testing.expectEqualStrings(layout_commands.unverified ++ "\n", result.err);
}
