//! Where the headless host's control socket and model file live.
//!
//! One socket per user, at a fixed, deterministic path so a GUI launched
//! after a crash can find the same already-running host without having
//! persisted anything itself. The path lives in a private `coastty-<uid>`
//! directory under the user's temp directory rather than Application
//! Support: `sockaddr_un.sun_path` is capped at 108 bytes (104 on Darwin)
//! and a real home directory can easily blow that budget.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Points a coastty build at a control socket of its own. A daemon is
/// identified by the socket it serves, so this is also what keeps a dev
/// build's panes and model entirely separate from the production one's
/// instead of both talking to a single per-user daemon.
pub const socket_env = "COASTTY_HOST_SOCKET";

/// Returns an allocated path to the coastty host's control socket for the
/// current user. Caller owns the returned memory.
pub fn socketPath(alloc: Allocator) ![]u8 {
    if (env(socket_env)) |override| {
        if (override.len > 0) return alloc.dupe(u8, override);
    }
    return defaultSocketPath(alloc);
}

/// Returns an allocated path to the private directory the default socket
/// lives in, or null when `COASTTY_HOST_SOCKET` puts the socket somewhere
/// of its own choosing. Caller owns the returned memory.
pub fn privateSocketDir(alloc: Allocator) !?[]u8 {
    if (env(socket_env)) |override| {
        if (override.len > 0) return null;
    }
    return try defaultSocketDir(alloc);
}

/// The per-user directory the default socket lives in.
fn defaultSocketDir(alloc: Allocator) ![]u8 {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const tmp = try tmpDir(&buf);
    return std.fmt.allocPrint(alloc, "{s}/coastty-{d}", .{ tmp, uid() });
}

/// The per-user socket a coastty build uses when nothing overrides it.
/// Its file name stays `coastty-host-<uid>.sock`, which also keeps the
/// model file's namespace the same as before the socket had a directory.
fn defaultSocketPath(alloc: Allocator) ![]u8 {
    const dir = try defaultSocketDir(alloc);
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/coastty-host-{d}.sock", .{ dir, uid() });
}

/// Where the daemon serving `socket_path` publishes the app's token: beside the socket, under the same name with `.token` appended.
pub fn tokenPath(buf: []u8, socket_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.token", .{socket_path});
}

/// Where the lock that lets one daemon at a time serve `socket_path` lives: beside the socket, under the same name with `.lock` appended.
pub fn lockPath(buf: []u8, socket_path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.lock", .{socket_path});
}

/// The current user's uid; 0 on Windows, which has none.
pub fn uid() posix.uid_t {
    if (comptime builtin.os.tag == .windows) return 0;
    return posix.system.getuid();
}

/// Returns an allocated path to where the default socket sat before it had
/// a private directory, or null when `COASTTY_HOST_SOCKET` overrides it.
/// A daemon started before an upgrade may still serve it, sharing this
/// one's model file. Caller owns the returned memory.
pub fn legacySocketPath(alloc: Allocator) !?[]u8 {
    if (env(socket_env)) |override| {
        if (override.len > 0) return null;
    }

    var buf: [posix.PATH_MAX]u8 = undefined;
    const tmp = try tmpDir(&buf);
    return try std.fmt.allocPrint(alloc, "{s}/coastty-host-{d}.sock", .{ tmp, uid() });
}

/// Returns an allocated path to the daemon's model file. Caller owns the
/// returned memory.
///
/// Namespaced by the socket this daemon serves, so a dev build pointed
/// at its own socket gets its own model and can never read - or
/// overwrite - the production daemon's.
pub fn modelPath(alloc: Allocator) ![]u8 {
    const socket = try socketPath(alloc);
    defer alloc.free(socket);

    const home = homeDir();
    if (home.len == 0) return error.NoHomeDir;

    return std.fmt.allocPrint(alloc, "{s}/.local/state/coastty-host/{s}/model.json", .{
        home,
        socketNamespace(socket),
    });
}

/// The user's home directory, empty when the environment doesn't say.
pub fn homeDir() []const u8 {
    return env("HOME") orelse "";
}

/// The directory name a socket path maps to: its own basename, minus the
/// extension.
fn socketNamespace(socket_path: []const u8) []const u8 {
    const base = std.fs.path.basename(socket_path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot > 0) base[0..dot] else base;
}

/// The process environment as the daemon sees it. Read straight from libc
/// rather than through a `std.process.Environ.Map` so these two paths stay
/// callable from anywhere, the GUI's own client code included.
fn env(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;
const _CS_DARWIN_USER_TEMP_DIR = 65537;

/// The user's temp directory, trimmed of any trailing slash. Never a
/// shared one like `/tmp`, where another user could claim the socket's
/// predictable path first. When `TMPDIR` is unset, as over SSH, Darwin
/// still knows the per-user directory the GUI's `TMPDIR` points at.
fn tmpDir(buf: *[posix.PATH_MAX]u8) ![]const u8 {
    if (env("TMPDIR")) |t| {
        if (t.len > 0) return trimSlash(t);
    }

    return userTempDir(buf);
}

/// Darwin's own per-user temp directory, which needs no environment.
fn userTempDir(buf: *[posix.PATH_MAX]u8) ![]const u8 {
    if (comptime !builtin.os.tag.isDarwin()) return error.NoTempDir;

    const len = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, buf.len);
    if (len == 0 or len > buf.len) return error.NoTempDir;
    return trimSlash(buf[0 .. len - 1]);
}

/// `path` without a trailing slash, leaving a bare `/` alone.
fn trimSlash(path: []const u8) []const u8 {
    if (path.len > 1 and std.mem.endsWith(u8, path, "/")) return path[0 .. path.len - 1];
    return path;
}

test "socketPath is short enough for sockaddr_un" {
    const alloc = std.testing.allocator;
    const path = try defaultSocketPath(alloc);
    defer alloc.free(path);
    try std.testing.expect(path.len <= 100);
}

test "the default socket sits in a per-user directory and keeps its model namespace" {
    const alloc = std.testing.allocator;
    const path = try defaultSocketPath(alloc);
    defer alloc.free(path);

    var dir_buf: [32]u8 = undefined;
    const dir_name = try std.fmt.bufPrint(&dir_buf, "coastty-{d}", .{uid()});
    try std.testing.expectEqualStrings(dir_name, std.fs.path.basename(std.fs.path.dirname(path) orelse ""));

    var ns_buf: [32]u8 = undefined;
    const namespace = try std.fmt.bufPrint(&ns_buf, "coastty-host-{d}", .{uid()});
    try std.testing.expectEqualStrings(namespace, socketNamespace(path));
}

test "the legacy socket maps to the same model namespace as the current one" {
    const alloc = std.testing.allocator;
    const legacy = try legacySocketPath(alloc) orelse return error.SkipZigTest;
    defer alloc.free(legacy);
    const current = try defaultSocketPath(alloc);
    defer alloc.free(current);

    try std.testing.expectEqualStrings(socketNamespace(current), socketNamespace(legacy));
    try std.testing.expect(!std.mem.eql(u8, current, legacy));
}

test "without TMPDIR the temp directory is the user's own, not the shared /tmp" {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const tmp = try userTempDir(&buf);
    try std.testing.expect(!std.mem.eql(u8, tmp, "/tmp"));
    try std.testing.expect(!std.mem.endsWith(u8, tmp, "/"));
}

test "the model file is namespaced by the socket the daemon serves" {
    try std.testing.expectEqualStrings("coastty-host-501", socketNamespace("/tmp/coastty-host-501.sock"));
    try std.testing.expectEqualStrings("coastty-dev-host", socketNamespace("/tmp/coastty-dev-host.sock"));

    // A dotfile-shaped socket name is a name, not an extension.
    try std.testing.expectEqualStrings(".sock", socketNamespace("/tmp/.sock"));
}
