//! What changed in the daemon, pushed to every client that subscribed: a
//! pane created, exited or killed, the model moving on, a pane's attention
//! state changing, a client attaching or detaching - and, to the app alone,
//! the changes a layout command asks it to make. `wire.zig` documents the
//! protocol, including the order a client catches up in.
//!
//! Each event is serialised once and the same bytes are queued for every
//! subscriber. A subscriber that falls too far behind loses its queue and
//! is told to re-fetch, so it never misses an event without knowing.
const Events = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;
const wire = @import("wire.zig");
const Focus = @import("Focus.zig");
const Windows = @import("Windows.zig");

const log = std.log.scoped(.coastty_host_events);

/// How many events a subscriber may be behind before it is told to re-fetch
/// instead. A burst far larger than any real one: a client this far behind
/// is better served by a fresh model than by the backlog.
const queue_capacity = 256;

alloc: Allocator,
io: Io,

/// Guards `subscribers`.
mutex: Io.Mutex = .init,
subscribers: std.ArrayList(*Subscriber) = .empty,

/// How many subscribers there are, readable without the lock, so a change
/// nobody is listening for costs nothing to report.
count: std.atomic.Value(usize) = .init(0),

pub fn init(alloc: Allocator, io: Io) Events {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(events: *Events) void {
    events.subscribers.deinit(events.alloc);
}

/// One event, serialised once and shared by every queue it is in.
const Shared = struct {
    refs: std.atomic.Value(u32),
    json: []u8,

    fn release(self: *Shared, alloc: Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        alloc.free(self.json);
        alloc.destroy(self);
    }
};

const Subscriber = struct {
    socket: net.Stream,

    /// Whether this is the Mac app, the only client a request is for.
    app: bool,

    /// Guards everything below.
    mutex: Io.Mutex = .init,
    ready: Io.Condition = .init,
    queue: [queue_capacity]*Shared = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Set when the queue overflowed: what was in it is gone, so the next
    /// thing this subscriber is sent tells it to re-fetch.
    behind: bool = false,

    /// Set once the client has gone away; the writer stops at the next turn.
    closed: bool = false,
};

/// Whether anybody would receive an event. Callers check this before
/// building one, so a daemon with no subscribers does no work for them.
pub fn listening(events: *Events) bool {
    return events.count.load(.acquire) > 0;
}

/// Sends `json` - one event object - to every subscriber.
pub fn publish(events: *Events, json: []const u8) void {
    _ = events.publishTo(json, .everyone);
}

const Audience = enum { everyone, app };

/// Queues `json` for every subscriber in `audience`, returning whether there
/// was one.
fn publishTo(events: *Events, json: []const u8, audience: Audience) bool {
    events.mutex.lockUncancelable(events.io);
    defer events.mutex.unlock(events.io);

    var n: usize = 0;
    for (events.subscribers.items) |sub| {
        if (audience == .app and !sub.app) continue;
        n += 1;
    }
    if (n == 0) return false;

    const shared = events.share(json) catch {
        // Nothing to queue, so every subscriber meant to get this has missed it.
        for (events.subscribers.items) |sub| {
            if (audience == .app and !sub.app) continue;
            events.markBehind(sub);
        }
        return true;
    };
    shared.refs.store(@intCast(n), .release);
    for (events.subscribers.items) |sub| {
        if (audience == .app and !sub.app) continue;
        events.enqueue(sub, shared);
    }
    return true;
}

fn share(events: *Events, json: []const u8) !*Shared {
    const shared = try events.alloc.create(Shared);
    errdefer events.alloc.destroy(shared);
    shared.* = .{ .refs = .init(0), .json = try events.alloc.dupe(u8, json) };
    return shared;
}

fn enqueue(events: *Events, sub: *Subscriber, shared: *Shared) void {
    sub.mutex.lockUncancelable(events.io);
    defer sub.mutex.unlock(events.io);

    if (sub.closed or sub.behind) {
        shared.release(events.alloc);
        return;
    }
    if (sub.len == queue_capacity) {
        shared.release(events.alloc);
        events.dropQueueLocked(sub);
        sub.behind = true;
    } else {
        sub.queue[(sub.head + sub.len) % queue_capacity] = shared;
        sub.len += 1;
    }
    sub.ready.signal(events.io);
}

fn markBehind(events: *Events, sub: *Subscriber) void {
    sub.mutex.lockUncancelable(events.io);
    defer sub.mutex.unlock(events.io);
    events.dropQueueLocked(sub);
    sub.behind = true;
    sub.ready.signal(events.io);
}

fn dropQueueLocked(events: *Events, sub: *Subscriber) void {
    while (sub.len > 0) {
        sub.queue[sub.head].release(events.alloc);
        sub.head = (sub.head + 1) % queue_capacity;
        sub.len -= 1;
    }
    sub.head = 0;
}

/// Registers a subscriber on `conn`. From the moment this returns, every
/// event published is queued for it - which is what lets a client
/// subscribe first and fetch the model second without losing anything in
/// between. Nothing is written until `serve` starts the writer.
pub fn subscribe(events: *Events, conn: net.Stream, kind: wire.ClientKind) !*Subscriber {
    const sub = try events.alloc.create(Subscriber);
    errdefer events.alloc.destroy(sub);
    sub.* = .{ .socket = conn, .app = kind == .app };

    events.mutex.lockUncancelable(events.io);
    defer events.mutex.unlock(events.io);
    try events.subscribers.append(events.alloc, sub);
    _ = events.count.fetchAdd(1, .release);
    return sub;
}

/// Streams `sub`'s events until its client goes away, then unregisters it,
/// taking with it any focus and windows it reported.
///
/// The only things a client sends on this connection are the app's `FOCUS`
/// and `WINDOWS`, so this thread reads for those and to notice the client
/// leaving, and a writer thread of its own sends the events - publishing
/// never waits on a slow client.
pub fn serve(events: *Events, sub: *Subscriber, reader: *Io.Reader, focus: *Focus, windows: *Windows) void {
    const writer = std.Thread.spawn(.{}, writeLoop, .{ events, sub }) catch |err| {
        log.warn("no writer for a subscriber, dropping it: {t}", .{err});
        events.unsubscribe(sub);
        return;
    };

    while (true) {
        const line = (wire.readHeader(events.alloc, reader) catch break) orelse break;
        defer events.alloc.free(line);
        events.readReport(sub, reader, line, focus, windows) catch break;
    }
    focus.release(sub);
    windows.release(sub);

    sub.mutex.lockUncancelable(events.io);
    sub.closed = true;
    sub.ready.signal(events.io);
    sub.mutex.unlock(events.io);
    writer.join();
    events.unsubscribe(sub);
}

/// Takes a `FOCUS <len>` or `WINDOWS <len>` line and its body as what the app reports. Anything else a client sends is ignored, and only the app's reports count.
fn readReport(events: *Events, sub: *Subscriber, reader: *Io.Reader, line: []const u8, focus: *Focus, windows: *Windows) !void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse "";
    const is_focus = std.mem.eql(u8, tag, "FOCUS");
    if (!is_focus and !std.mem.eql(u8, tag, "WINDOWS")) return;
    const len = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return error.BadReport;

    const body = try wire.readBody(events.alloc, reader, len);
    defer events.alloc.free(body);
    if (!sub.app) return;

    if (is_focus) return focus.report(sub, body);
    try windows.report(sub, body);
}

fn unsubscribe(events: *Events, sub: *Subscriber) void {
    events.mutex.lockUncancelable(events.io);
    for (events.subscribers.items, 0..) |s, i| {
        if (s != sub) continue;
        _ = events.subscribers.swapRemove(i);
        _ = events.count.fetchSub(1, .release);
        break;
    }
    events.mutex.unlock(events.io);

    sub.mutex.lockUncancelable(events.io);
    events.dropQueueLocked(sub);
    sub.mutex.unlock(events.io);
    events.alloc.destroy(sub);
}

fn writeLoop(events: *Events, sub: *Subscriber) void {
    var wbuf: [4096]u8 = undefined;
    var w = sub.socket.writer(events.io, &wbuf);

    while (true) {
        sub.mutex.lockUncancelable(events.io);
        while (sub.len == 0 and !sub.behind and !sub.closed) sub.ready.waitUncancelable(events.io, &sub.mutex);
        if (sub.closed) {
            sub.mutex.unlock(events.io);
            return;
        }
        if (sub.behind) {
            sub.behind = false;
            sub.mutex.unlock(events.io);
            wire.writeFrame(&w.interface, "EVENT", resync) catch return;
            continue;
        }
        const shared = sub.queue[sub.head];
        sub.head = (sub.head + 1) % queue_capacity;
        sub.len -= 1;
        sub.mutex.unlock(events.io);

        const ok = if (wire.writeFrame(&w.interface, "EVENT", shared.json)) |_| true else |_| false;
        shared.release(events.alloc);
        if (!ok) return;
    }
}

// Event shapes. Outside clients depend on these exact names and fields;
// the fixtures in this file's tests are what keep them from drifting.

/// Tells a subscriber it has missed events and should fetch the model again.
pub const resync = "{\"event\":\"resync\"}";

pub const PaneEvent = enum { pane_created, pane_exited, pane_killed };

/// A pane appearing, its process exiting, or the pane being ended.
pub fn publishPane(events: *Events, kind: PaneEvent, pane_id: []const u8) void {
    if (!events.listening()) return;
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var json: std.json.Stringify = .{ .writer = &w };
    writePaneEvent(&json, kind, pane_id) catch return;
    events.publish(w.buffered());
}

fn writePaneEvent(json: *std.json.Stringify, kind: PaneEvent, pane_id: []const u8) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write(@tagName(kind));
    try json.objectField("pane");
    try json.write(pane_id);
    try json.endObject();
}

/// The model moved on to `revision`. Carries no contents: a client that
/// cares fetches the model, and skips this if its copy is already at least
/// this new.
pub fn publishModelChanged(events: *Events, revision: u64) void {
    if (!events.listening()) return;
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var json: std.json.Stringify = .{ .writer = &w };
    writeModelChanged(&json, revision) catch return;
    events.publish(w.buffered());
}

fn writeModelChanged(json: *std.json.Stringify, revision: u64) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("model_changed");
    try json.objectField("revision");
    try json.write(revision);
    try json.endObject();
}

/// A new tab asked of the app; see `REQUEST` in `wire.zig`.
pub const TabNewRequest = struct {
    space: []const u8,
    tab: []const u8,
    /// The pane the request came from, empty if none.
    near: []const u8,
    name: []const u8,
    directory: []const u8,
    focus: bool,
};

/// Hands `request` to the app, returning whether one was subscribed to
/// carry it out.
pub fn publishTabNew(events: *Events, request: TabNewRequest) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writeTabNew(&json, request) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes `request` as the `request` event the app decodes.
fn writeTabNew(json: *std.json.Stringify, request: TabNewRequest) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("tab");
    try json.objectField("op");
    try json.write("new");
    try json.objectField("near");
    try json.write(request.near);
    try json.objectField("space");
    try json.write(request.space);
    try json.objectField("tab");
    try json.write(request.tab);
    try json.objectField("name");
    try json.write(request.name);
    try json.objectField("directory");
    try json.write(request.directory);
    try json.objectField("focus");
    try json.write(request.focus);
    try json.endObject();
}

/// A change to an existing tab asked of the app; see `REQUEST` in `wire.zig`.
pub const TabChangeRequest = struct {
    tab: []const u8,
    change: Change,

    pub const Change = union(enum) {
        close,
        rename: []const u8,
        /// The tab's 0-based position within its Space.
        move: usize,
        /// Shows the tab and brings its window to the front.
        focus,
    };
};

/// Hands `request` to the app, returning whether one was subscribed to
/// carry it out.
pub fn publishTabChange(events: *Events, request: TabChangeRequest) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writeTabChange(&json, request) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes `request` as the `request` event the app decodes.
fn writeTabChange(json: *std.json.Stringify, request: TabChangeRequest) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("tab");
    try json.objectField("op");
    try json.write(@tagName(request.change));
    try json.objectField("tab");
    try json.write(request.tab);
    switch (request.change) {
        .close, .focus => {},
        .rename => |name| {
            try json.objectField("name");
            try json.write(name);
        },
        .move => |index| {
            try json.objectField("index");
            try json.write(index);
        },
    }
    try json.endObject();
}

/// A new Space asked of the app; see `REQUEST` in `wire.zig`.
pub const SpaceNewRequest = struct {
    space: []const u8,
    /// The starter tab's id.
    tab: []const u8,
    /// The Space holding the pane the request came from, whose window the new Space joins; empty if none.
    beside: []const u8,
    /// The window the new Space joins instead, as the app reported it; empty to leave it to `beside`.
    window: []const u8 = "",
    name: []const u8,
    directory: []const u8,
    focus: bool,
};

/// Hands `request` to the app, returning whether one was subscribed to
/// carry it out.
pub fn publishSpaceNew(events: *Events, request: SpaceNewRequest) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writeSpaceNew(&json, request) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes `request` as the `request` event the app decodes.
fn writeSpaceNew(json: *std.json.Stringify, request: SpaceNewRequest) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("space");
    try json.objectField("op");
    try json.write("new");
    try json.objectField("beside");
    try json.write(request.beside);
    try json.objectField("window");
    try json.write(request.window);
    try json.objectField("space");
    try json.write(request.space);
    try json.objectField("tab");
    try json.write(request.tab);
    try json.objectField("name");
    try json.write(request.name);
    try json.objectField("directory");
    try json.write(request.directory);
    try json.objectField("focus");
    try json.write(request.focus);
    try json.endObject();
}

/// A change to an existing Space asked of the app; see `REQUEST` in `wire.zig`.
pub const SpaceChangeRequest = struct {
    space: []const u8,
    change: Change,

    pub const Change = union(enum) {
        close,
        rename: []const u8,
        move: Move,
        /// Shows the Space and brings its window to the front.
        focus,
    };

    pub const Move = struct {
        /// The Space's 0-based position among visible Spaces.
        index: usize,
        /// The visible Spaces it lands after, in order, so a window showing only some of them can place it among its own.
        after: []const []const u8,
        /// The window it moves to, empty to stay in its own; `after` then names only that window's Spaces.
        window: []const u8 = "",
    };
};

/// Hands `request` to the app, returning whether one was subscribed to
/// carry it out.
pub fn publishSpaceChange(events: *Events, request: SpaceChangeRequest) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writeSpaceChange(&json, request) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes `request` as the `request` event the app decodes.
fn writeSpaceChange(json: *std.json.Stringify, request: SpaceChangeRequest) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("space");
    try json.objectField("op");
    try json.write(@tagName(request.change));
    try json.objectField("space");
    try json.write(request.space);
    switch (request.change) {
        .close, .focus => {},
        .rename => |name| {
            try json.objectField("name");
            try json.write(name);
        },
        .move => |move| {
            try json.objectField("index");
            try json.write(move.index);
            try json.objectField("after");
            try json.write(move.after);
            if (move.window.len > 0) {
                try json.objectField("window");
                try json.write(move.window);
            }
        },
    }
    try json.endObject();
}

/// A new pane asked of the app, split off an existing one; see `REQUEST` in `wire.zig`.
pub const PaneSplitRequest = struct {
    /// The pane being split.
    pane: []const u8,
    /// The tab holding it.
    tab: []const u8,
    /// The UUID the new pane's surface takes; the daemon knows the pane as `surface:<uuid>`.
    surface: []const u8,
    direction: wire.SplitDirection,
    directory: []const u8,
    focus: bool,
};

/// Hands `request` to the app, returning whether one was subscribed to
/// carry it out.
pub fn publishPaneSplit(events: *Events, request: PaneSplitRequest) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writePaneSplit(&json, request) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes `request` as the `request` event the app decodes.
fn writePaneSplit(json: *std.json.Stringify, request: PaneSplitRequest) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("pane");
    try json.objectField("op");
    try json.write("split");
    try json.objectField("pane");
    try json.write(request.pane);
    try json.objectField("tab");
    try json.write(request.tab);
    try json.objectField("surface");
    try json.write(request.surface);
    try json.objectField("direction");
    try json.write(@tagName(request.direction));
    try json.objectField("directory");
    try json.write(request.directory);
    try json.objectField("focus");
    try json.write(request.focus);
    try json.endObject();
}

/// A change to an existing pane asked of the app that needs nothing but the pane's id; see `REQUEST` in `wire.zig`.
pub const PaneChange = enum {
    close,
    /// Shows the pane's tab, brings its window to the front and moves keyboard focus to the pane.
    focus,
};

/// Hands the app a request to change the pane with this id, returning
/// whether one was subscribed to carry it out.
pub fn publishPaneChange(events: *Events, pane_id: []const u8, change: PaneChange) bool {
    var w: Io.Writer.Allocating = .init(events.alloc);
    defer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    writePaneChange(&json, pane_id, change) catch return false;
    return events.publishTo(w.written(), .app);
}

/// Writes a pane change as the `request` event the app decodes.
fn writePaneChange(json: *std.json.Stringify, pane_id: []const u8, change: PaneChange) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write("request");
    try json.objectField("scope");
    try json.write("pane");
    try json.objectField("op");
    try json.write(@tagName(change));
    try json.objectField("pane");
    try json.write(pane_id);
    try json.endObject();
}

pub const AttachmentEvent = enum { attached, detached };

/// A client attaching to or detaching from a pane, with how many are
/// attached to it now.
pub fn publishAttachment(events: *Events, kind: AttachmentEvent, pane_id: []const u8, clients: usize) void {
    if (!events.listening()) return;
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var json: std.json.Stringify = .{ .writer = &w };
    writeAttachmentEvent(&json, kind, pane_id, clients) catch return;
    events.publish(w.buffered());
}

fn writeAttachmentEvent(json: *std.json.Stringify, kind: AttachmentEvent, pane_id: []const u8, clients: usize) !void {
    try json.beginObject();
    try json.objectField("event");
    try json.write(@tagName(kind));
    try json.objectField("pane");
    try json.write(pane_id);
    try json.objectField("clients");
    try json.write(clients);
    try json.endObject();
}

const testing = std.testing;

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var w: Io.Writer.Allocating = .init(testing.allocator);
    errdefer w.deinit();
    var json: std.json.Stringify = .{ .writer = &w.writer };
    try @call(.auto, f, .{&json} ++ args);
    return w.toOwnedSlice();
}

test "fixture: pane events" {
    inline for (.{
        .{ PaneEvent.pane_created, "{\"event\":\"pane_created\",\"pane\":\"surface:A\"}" },
        .{ PaneEvent.pane_exited, "{\"event\":\"pane_exited\",\"pane\":\"surface:A\"}" },
        .{ PaneEvent.pane_killed, "{\"event\":\"pane_killed\",\"pane\":\"surface:A\"}" },
    }) |case| {
        const got = try render(writePaneEvent, .{ case[0], "surface:A" });
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "fixture: attachment events" {
    const attached = try render(writeAttachmentEvent, .{ AttachmentEvent.attached, "surface:A", @as(usize, 2) });
    defer testing.allocator.free(attached);
    try testing.expectEqualStrings("{\"event\":\"attached\",\"pane\":\"surface:A\",\"clients\":2}", attached);

    const detached = try render(writeAttachmentEvent, .{ AttachmentEvent.detached, "surface:A", @as(usize, 0) });
    defer testing.allocator.free(detached);
    try testing.expectEqualStrings("{\"event\":\"detached\",\"pane\":\"surface:A\",\"clients\":0}", detached);
}

test "fixture: model_changed" {
    const got = try render(writeModelChanged, .{@as(u64, 42)});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"event\":\"model_changed\",\"revision\":42}", got);
}

test "fixture: request" {
    const got = try render(writeTabNew, .{TabNewRequest{
        .space = "S",
        .tab = "T",
        .near = "surface:A",
        .name = "build",
        .directory = "/tmp",
        .focus = false,
    }});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"tab\",\"op\":\"new\",\"near\":\"surface:A\",\"space\":\"S\",\"tab\":\"T\",\"name\":\"build\",\"directory\":\"/tmp\",\"focus\":false}",
        got,
    );
}

test "fixture: tab change requests" {
    const close = try render(writeTabChange, .{TabChangeRequest{ .tab = "T", .change = .close }});
    defer testing.allocator.free(close);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"tab\",\"op\":\"close\",\"tab\":\"T\"}",
        close,
    );

    const rename = try render(writeTabChange, .{TabChangeRequest{ .tab = "T", .change = .{ .rename = "build" } }});
    defer testing.allocator.free(rename);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"tab\",\"op\":\"rename\",\"tab\":\"T\",\"name\":\"build\"}",
        rename,
    );

    const move = try render(writeTabChange, .{TabChangeRequest{ .tab = "T", .change = .{ .move = 2 } }});
    defer testing.allocator.free(move);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"tab\",\"op\":\"move\",\"tab\":\"T\",\"index\":2}",
        move,
    );

    const focus = try render(writeTabChange, .{TabChangeRequest{ .tab = "T", .change = .focus }});
    defer testing.allocator.free(focus);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"tab\",\"op\":\"focus\",\"tab\":\"T\"}", focus);
}

test "fixture: space requests" {
    const new = try render(writeSpaceNew, .{SpaceNewRequest{
        .space = "S",
        .tab = "T",
        .beside = "R",
        .name = "task",
        .directory = "/tmp",
        .focus = true,
    }});
    defer testing.allocator.free(new);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"space\",\"op\":\"new\",\"beside\":\"R\",\"window\":\"\",\"space\":\"S\",\"tab\":\"T\",\"name\":\"task\",\"directory\":\"/tmp\",\"focus\":true}",
        new,
    );

    const close = try render(writeSpaceChange, .{SpaceChangeRequest{ .space = "S", .change = .close }});
    defer testing.allocator.free(close);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"space\",\"op\":\"close\",\"space\":\"S\"}", close);

    const rename = try render(writeSpaceChange, .{SpaceChangeRequest{ .space = "S", .change = .{ .rename = "task" } }});
    defer testing.allocator.free(rename);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"space\",\"op\":\"rename\",\"space\":\"S\",\"name\":\"task\"}", rename);

    const after = [_][]const u8{ "A", "B" };
    const move = try render(writeSpaceChange, .{SpaceChangeRequest{ .space = "S", .change = .{ .move = .{ .index = 2, .after = &after } } }});
    defer testing.allocator.free(move);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"space\",\"op\":\"move\",\"space\":\"S\",\"index\":2,\"after\":[\"A\",\"B\"]}", move);

    const to_window = try render(writeSpaceChange, .{SpaceChangeRequest{ .space = "S", .change = .{ .move = .{ .index = 1, .after = &after, .window = "W" } } }});
    defer testing.allocator.free(to_window);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"space\",\"op\":\"move\",\"space\":\"S\",\"index\":1,\"after\":[\"A\",\"B\"],\"window\":\"W\"}", to_window);

    const focus = try render(writeSpaceChange, .{SpaceChangeRequest{ .space = "S", .change = .focus }});
    defer testing.allocator.free(focus);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"space\",\"op\":\"focus\",\"space\":\"S\"}", focus);
}

test "fixture: pane requests" {
    const split = try render(writePaneSplit, .{PaneSplitRequest{
        .pane = "surface:P",
        .tab = "T",
        .surface = "N",
        .direction = .down,
        .directory = "/tmp",
        .focus = false,
    }});
    defer testing.allocator.free(split);
    try testing.expectEqualStrings(
        "{\"event\":\"request\",\"scope\":\"pane\",\"op\":\"split\",\"pane\":\"surface:P\",\"tab\":\"T\",\"surface\":\"N\",\"direction\":\"down\",\"directory\":\"/tmp\",\"focus\":false}",
        split,
    );

    const close = try render(writePaneChange, .{ "surface:P", PaneChange.close });
    defer testing.allocator.free(close);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"pane\",\"op\":\"close\",\"pane\":\"surface:P\"}", close);

    const focus = try render(writePaneChange, .{ "surface:P", PaneChange.focus });
    defer testing.allocator.free(focus);
    try testing.expectEqualStrings("{\"event\":\"request\",\"scope\":\"pane\",\"op\":\"focus\",\"pane\":\"surface:P\"}", focus);
}

test "a request reaches the app and no other client" {
    var events: Events = .init(testing.allocator, testing.io);
    defer events.deinit();
    const request: TabNewRequest = .{ .space = "S", .tab = "T", .near = "", .name = "", .directory = "/", .focus = false };

    const client = try events.subscribe(undefined, .client);
    try testing.expect(!events.publishTabNew(request));

    const app = try events.subscribe(undefined, .app);
    try testing.expect(events.publishTabNew(request));
    try testing.expectEqual(@as(usize, 1), app.len);
    try testing.expectEqual(@as(usize, 0), client.len);

    events.unsubscribe(app);
    events.unsubscribe(client);
}

test "fixture: resync" {
    try testing.expectEqualStrings("{\"event\":\"resync\"}", resync);
}

test "nothing is built or queued when nobody is subscribed" {
    var events: Events = .init(testing.allocator, testing.io);
    defer events.deinit();
    try testing.expect(!events.listening());
    events.publishPane(.pane_created, "surface:A");
    events.publishModelChanged(3);
}

test "a subscriber that falls behind loses its backlog and is told to re-fetch" {
    var events: Events = .init(testing.allocator, testing.io);
    defer events.deinit();

    // Never served, so nothing drains the queue: every publish past the
    // capacity has to land as "behind", not as an unbounded backlog.
    const sub = try events.subscribe(undefined, .client);
    for (0..queue_capacity + 10) |i| events.publishModelChanged(i);

    sub.mutex.lockUncancelable(testing.io);
    const behind = sub.behind;
    const len = sub.len;
    sub.mutex.unlock(testing.io);
    try testing.expect(behind);
    try testing.expectEqual(@as(usize, 0), len);

    events.unsubscribe(sub);
    try testing.expect(!events.listening());
}
