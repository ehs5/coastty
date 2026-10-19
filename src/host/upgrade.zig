//! What the app does with a coastty-host it finds already running, such as
//! one left over from before an upgrade: keep it, keep it and ask before
//! restarting it, or restart it because the two cannot talk. Restarting the
//! daemon ends every pane's process, so only a protocol the app cannot
//! speak forces one. See `docs/adr/0003-two-version-numbers-for-the-daemon.md`.
const std = @import("std");
const wire = @import("wire.zig");

/// The two numbers a daemon answers `VERSION` with.
pub const Versions = struct {
    protocol: u32,
    daemon: u32,
};

/// This build's numbers, which a running daemon is compared against.
pub const ours: Versions = .{ .protocol = wire.protocol_version, .daemon = wire.daemon_version };

/// What to do with the daemon that is running.
pub const Action = enum {
    /// Same protocol and the same or a newer daemon version: use it as it is.
    keep,
    /// Same protocol but an older daemon version: keep using it, and ask the user before restarting it.
    ask,
    /// Another protocol: the app cannot talk to it, so it is restarted and the user is told afterwards.
    restart,
};

/// Reads a daemon's answer to `VERSION`, or null when it is not one.
/// A daemon from before `VERSION` existed answers `ERR unknown command`. It predates daemon versions, so it counts as version 0; every release answers `VERSION`, so it is a dev build and its protocol is taken to be this one.
pub fn parseAnswer(answer: []const u8) ?Versions {
    if (std.mem.eql(u8, answer, "ERR unknown command")) return .{ .protocol = wire.protocol_version, .daemon = 0 };
    if (!std.mem.startsWith(u8, answer, "OK ")) return null;

    var it = std.mem.tokenizeScalar(u8, answer["OK ".len..], ' ');
    const protocol = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const daemon = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    return .{ .protocol = protocol, .daemon = daemon };
}

/// Decides what an app with versions `app` does with a running daemon that reported `found`.
pub fn decide(found: Versions, app: Versions) Action {
    // Either side being newer leaves them unable to talk, and the app cannot work without the daemon
    if (found.protocol != app.protocol) return .restart;
    if (found.daemon < app.daemon) return .ask;
    return .keep;
}

test "a daemon of the same versions is kept" {
    try std.testing.expectEqual(Action.keep, decide(.{ .protocol = 2, .daemon = 3 }, .{ .protocol = 2, .daemon = 3 }));
}

test "a daemon with a newer daemon version is kept, as after going back to an older app" {
    try std.testing.expectEqual(Action.keep, decide(.{ .protocol = 2, .daemon = 4 }, .{ .protocol = 2, .daemon = 3 }));
}

test "a daemon with an older daemon version is kept until the user asks for a restart" {
    try std.testing.expectEqual(Action.ask, decide(.{ .protocol = 2, .daemon = 2 }, .{ .protocol = 2, .daemon = 3 }));
}

test "a daemon with an older protocol is restarted, whatever its daemon version" {
    try std.testing.expectEqual(Action.restart, decide(.{ .protocol = 1, .daemon = 3 }, .{ .protocol = 2, .daemon = 3 }));
    try std.testing.expectEqual(Action.restart, decide(.{ .protocol = 1, .daemon = 9 }, .{ .protocol = 2, .daemon = 3 }));
}

test "a daemon with a newer protocol is restarted too" {
    try std.testing.expectEqual(Action.restart, decide(.{ .protocol = 3, .daemon = 3 }, .{ .protocol = 2, .daemon = 3 }));
}

test "parseAnswer reads both numbers" {
    const versions = parseAnswer("OK 2 5") orelse return error.NotParsed;
    try std.testing.expectEqual(@as(u32, 2), versions.protocol);
    try std.testing.expectEqual(@as(u32, 5), versions.daemon);
}

test "a daemon from before VERSION counts as daemon version 0, so the app asks" {
    const versions = parseAnswer("ERR unknown command") orelse return error.NotParsed;
    try std.testing.expectEqual(@as(u32, 0), versions.daemon);
    try std.testing.expectEqual(Action.ask, decide(versions, ours));
}

test "parseAnswer rejects anything else" {
    try std.testing.expect(parseAnswer("OK 2") == null);
    try std.testing.expect(parseAnswer("OK two 5") == null);
    try std.testing.expect(parseAnswer("ERR unauthorized") == null);
    try std.testing.expect(parseAnswer("") == null);
}
