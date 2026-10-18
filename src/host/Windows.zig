//! The coastty windows and the Spaces each shows, as the app last reported
//! them over its event subscription (`WINDOWS` in `wire.zig`).
//!
//! Windows are presentation, not model. The daemon owns nothing about them:
//! it holds what the app reports, in memory only, never writes it to
//! model.json, and forgets it once the app that reported it disconnects.
const Windows = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

alloc: Allocator,
io: Io,

/// Guards everything below.
mutex: Io.Mutex = .init,

/// The subscription that reported the windows, so only that one leaving clears them.
owner: ?*const anyopaque = null,

/// The last `WINDOWS` body reported, empty when no window is open or no app is connected.
body: []u8 = &.{},

pub fn init(alloc: Allocator, io: Io) Windows {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(windows: *Windows) void {
    windows.alloc.free(windows.body);
}

/// Takes `body` - a `WINDOWS` body, one line per window - as every window `owner` has open, replacing what it reported before.
pub fn report(windows: *Windows, owner: *const anyopaque, body: []const u8) Allocator.Error!void {
    const copy = try windows.alloc.dupe(u8, body);

    windows.mutex.lockUncancelable(windows.io);
    defer windows.mutex.unlock(windows.io);

    windows.alloc.free(windows.body);
    windows.body = copy;
    windows.owner = owner;
}

/// Forgets the windows when `owner` reported them. Windows another app connection reported since stay.
pub fn release(windows: *Windows, owner: *const anyopaque) void {
    windows.mutex.lockUncancelable(windows.io);
    defer windows.mutex.unlock(windows.io);

    if (windows.owner != owner) return;
    windows.alloc.free(windows.body);
    windows.body = &.{};
    windows.owner = null;
}

/// A copy of the last `WINDOWS` body, owned by the caller; empty when no window is known.
pub fn snapshot(windows: *Windows, alloc: Allocator) Allocator.Error![]u8 {
    windows.mutex.lockUncancelable(windows.io);
    defer windows.mutex.unlock(windows.io);

    return alloc.dupe(u8, windows.body);
}

const testing = std.testing;

test "reported windows read back, and only the connection that reported them clears them by leaving" {
    var windows: Windows = .init(testing.allocator, testing.io);
    defer windows.deinit();
    // Two elements of one array, so the owners have distinct addresses.
    const apps = [2]u8{ 0, 0 };
    const old_app = &apps[0];
    const new_app = &apps[1];

    const none = try windows.snapshot(testing.allocator);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", none);

    try windows.report(old_app, "win-1\x00space-a\x00space-a");
    try windows.report(new_app, "win-2\x00space-b\x00space-b");

    // An app reconnecting reports before its old connection is noticed gone.
    windows.release(old_app);
    const held = try windows.snapshot(testing.allocator);
    defer testing.allocator.free(held);
    try testing.expectEqualStrings("win-2\x00space-b\x00space-b", held);

    windows.release(new_app);
    const after = try windows.snapshot(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("", after);
}
