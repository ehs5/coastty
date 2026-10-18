//! Which Space, tab and pane the user was last in: the active Space, tab
//! and focused pane of the coastty window they used last, as the app
//! reported them over its event subscription (`FOCUS` in `wire.zig`). The
//! app keeps reporting while it is in the background, so a command run from
//! another terminal still finds them; the report goes when that window closes.
//!
//! Focus is presentation, not model. It lives in memory only, is never
//! written to model.json, and is gone once the app that reported it
//! disconnects. The daemon learns ids, never windows.
const Focus = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("wire.zig");

alloc: Allocator,
io: Io,

/// Guards everything below.
mutex: Io.Mutex = .init,

/// The subscription that reported the focus, so only that one leaving clears it.
owner: ?*const anyopaque = null,

/// All three set, or all three empty when nothing is focused.
space: []u8 = &.{},
tab: []u8 = &.{},
pane: []u8 = &.{},

pub fn init(alloc: Allocator, io: Io) Focus {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(focus: *Focus) void {
    focus.freeIdsLocked();
}

/// A copy of the focus, owned by whoever asked for it.
pub const Snapshot = struct {
    space: []u8,
    tab: []u8,
    pane: []u8,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.space);
        alloc.free(self.tab);
        alloc.free(self.pane);
    }
};

/// Frees the held ids and forgets them. Caller must hold `mutex`, or be the only one left using it.
fn freeIdsLocked(focus: *Focus) void {
    focus.alloc.free(focus.space);
    focus.alloc.free(focus.tab);
    focus.alloc.free(focus.pane);
    focus.space = &.{};
    focus.tab = &.{};
    focus.pane = &.{};
}

/// Takes `body` - a `FOCUS` body, `<space>\0<tab>\0<pane>` - as the focus
/// `owner` reports. A body missing any of the three means nothing is
/// focused.
pub fn report(focus: *Focus, owner: *const anyopaque, body: []const u8) Allocator.Error!void {
    var fields: wire.FieldIterator = .init(body);
    const space = fields.next() orelse "";
    const tab = fields.next() orelse "";
    const pane = fields.next() orelse "";

    focus.mutex.lockUncancelable(focus.io);
    defer focus.mutex.unlock(focus.io);

    focus.freeIdsLocked();
    focus.owner = owner;

    // A window with no tab or no pane to show has nothing a command could target.
    if (space.len == 0 or tab.len == 0 or pane.len == 0) return;

    const space_copy = try focus.alloc.dupe(u8, space);
    errdefer focus.alloc.free(space_copy);
    const tab_copy = try focus.alloc.dupe(u8, tab);
    errdefer focus.alloc.free(tab_copy);
    const pane_copy = try focus.alloc.dupe(u8, pane);

    focus.space = space_copy;
    focus.tab = tab_copy;
    focus.pane = pane_copy;
}

/// Forgets the focus when `owner` reported it. A focus another app connection reported since stays.
pub fn release(focus: *Focus, owner: *const anyopaque) void {
    focus.mutex.lockUncancelable(focus.io);
    defer focus.mutex.unlock(focus.io);

    if (focus.owner != owner) return;
    focus.freeIdsLocked();
    focus.owner = null;
}

/// A copy of the focus, or null when nothing is focused.
pub fn snapshot(focus: *Focus, alloc: Allocator) Allocator.Error!?Snapshot {
    focus.mutex.lockUncancelable(focus.io);
    defer focus.mutex.unlock(focus.io);

    if (focus.space.len == 0) return null;

    const space = try alloc.dupe(u8, focus.space);
    errdefer alloc.free(space);
    const tab = try alloc.dupe(u8, focus.tab);
    errdefer alloc.free(tab);
    return .{ .space = space, .tab = tab, .pane = try alloc.dupe(u8, focus.pane) };
}

const testing = std.testing;

test "a reported focus reads back, and one missing a field counts as none" {
    var focus: Focus = .init(testing.allocator, testing.io);
    defer focus.deinit();
    const app: u8 = 0;

    try testing.expectEqual(@as(?Snapshot, null), try focus.snapshot(testing.allocator));

    try focus.report(&app, "space-a\x00tab-1\x00surface:p1");
    const held = (try focus.snapshot(testing.allocator)).?;
    defer held.deinit(testing.allocator);
    try testing.expectEqualStrings("space-a", held.space);
    try testing.expectEqualStrings("tab-1", held.tab);
    try testing.expectEqualStrings("surface:p1", held.pane);

    try focus.report(&app, "space-a\x00tab-1\x00");
    try testing.expectEqual(@as(?Snapshot, null), try focus.snapshot(testing.allocator));

    try focus.report(&app, "");
    try testing.expectEqual(@as(?Snapshot, null), try focus.snapshot(testing.allocator));
}

test "only the connection that reported the focus clears it by leaving" {
    var focus: Focus = .init(testing.allocator, testing.io);
    defer focus.deinit();
    // Two elements of one array, so the owners have distinct addresses.
    const apps = [2]u8{ 0, 0 };
    const old_app = &apps[0];
    const new_app = &apps[1];

    try focus.report(old_app, "space-a\x00tab-1\x00surface:p1");
    try focus.report(new_app, "space-b\x00tab-2\x00surface:p2");

    // An app reconnecting reports before its old connection is noticed gone.
    focus.release(old_app);
    const held = (try focus.snapshot(testing.allocator)).?;
    defer held.deinit(testing.allocator);
    try testing.expectEqualStrings("space-b", held.space);

    focus.release(new_app);
    try testing.expectEqual(@as(?Snapshot, null), try focus.snapshot(testing.allocator));
}
