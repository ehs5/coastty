//! Putting the `coastty` command on `PATH` for terminals other than coastty: a symlink (normally `/usr/local/bin/coastty`) pointing at the executable inside the running app's bundle.
//! The app's menu items call into this; when the link's folder needs admin rights the app performs the same change with elevated privileges.
const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;

const log = std.log.scoped(.command_link);

/// The outcome of an install or uninstall. Matches `ghostty_command_link_result_e`.
pub const Result = enum(c_int) {
    /// The link now points where it should (install) or is gone (uninstall).
    ok,
    /// The change is allowed, but the link's folder is not writable by this user.
    needs_admin,
    /// Something other than a coastty link sits at the link path; it is left alone.
    foreign,
    /// Uninstall found nothing at the link path.
    not_installed,
    /// The app runs from a translocated (quarantined) copy whose path does not last.
    translocated,
    /// Any other filesystem error.
    failed,
};

/// True if `path` is the `coastty` executable inside some app bundle.
fn isCoasttyExecutable(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".app/Contents/MacOS/coastty");
}

/// True if `path` resolves to an existing file, following symlinks.
fn exists(io: Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Logs why a step failed and returns `failed`.
fn failed(step: []const u8, err: anyerror) Result {
    log.warn("could not {s} the coastty command link err={}", .{ step, err });
    return .failed;
}

/// Creates the link, and its folder when that is missing too (a fresh Mac has no `/usr/local/bin`).
fn create(io: Io, link_path: []const u8, target: []const u8) Result {
    if (std.fs.path.dirname(link_path)) |dir| {
        Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return .needs_admin,
            else => return failed("create folder", err),
        };
    }

    Dir.symLinkAbsolute(io, target, link_path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return .needs_admin,
        else => return failed("create", err),
    };
    return .ok;
}

/// What sits at the link path: nothing, a symlink and its raw target, or something that ends the operation.
const Existing = union(enum) {
    missing,
    link: []const u8,
    done: Result,
};

/// Reads what sits at `link_path`, using `buf` for the link's target.
/// An unreadable link fails rather than asking for admin rights, since an admin change would skip the check of what sits there.
fn readExisting(io: Io, link_path: []const u8, buf: []u8) Existing {
    const len = Dir.readLinkAbsolute(io, link_path, buf) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotLink => return .{ .done = .foreign },
        else => return .{ .done = failed("read", err) },
    };
    return .{ .link = buf[0..len] };
}

/// True if the symlink at `link_path` with raw target `target` leads to an existing file; a relative target resolves against the link's folder.
fn linkResolves(io: Io, link_path: []const u8, target: []const u8) bool {
    if (std.fs.path.isAbsolute(target)) return exists(io, target);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(link_path) orelse "/";
    const resolved = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, target }) catch return false;
    return exists(io, resolved);
}

/// Points `link_path` at `target`.
/// A missing link is created, a link to another coastty bundle or to nothing at all is replaced, and anything else is reported as `foreign` without being touched.
pub fn install(io: Io, link_path: []const u8, target: []const u8) Result {
    // A translocated copy lives under a random path that macOS discards.
    if (std.mem.indexOf(u8, target, "/AppTranslocation/") != null) return .translocated;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const current = switch (readExisting(io, link_path, &buf)) {
        .missing => return create(io, link_path, target),
        .done => |result| return result,
        .link => |raw| raw,
    };

    if (std.mem.eql(u8, current, target)) return .ok;

    // A live link to another program is the user's, not ours to replace.
    if (!isCoasttyExecutable(current) and linkResolves(io, link_path, current)) return .foreign;

    Dir.cwd().symLinkAtomic(io, target, link_path, .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return .needs_admin,
        else => return failed("replace", err),
    };
    return .ok;
}

/// Removes `link_path`, but only when it is a symlink into a coastty bundle.
pub fn uninstall(io: Io, link_path: []const u8) Result {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const current = switch (readExisting(io, link_path, &buf)) {
        .missing => return .not_installed,
        .done => |result| return result,
        .link => |raw| raw,
    };
    if (!isCoasttyExecutable(current)) return .foreign;

    Dir.deleteFileAbsolute(io, link_path) catch |err| switch (err) {
        error.FileNotFound => return .not_installed,
        error.AccessDenied, error.PermissionDenied => return .needs_admin,
        else => return failed("remove", err),
    };
    return .ok;
}

const testing = std.testing;

/// A temp folder holding two fake app bundles, plus the absolute paths a test needs.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    link: []u8,
    current: []u8,
    old: []u8,

    /// Creates the temp folder and both fake bundles.
    fn init() !Fixture {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.createDirPath(testing.io, "Current.app/Contents/MacOS");
        try tmp.dir.createDirPath(testing.io, "Old.app/Contents/MacOS");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "Current.app/Contents/MacOS/coastty", .data = "" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "Old.app/Contents/MacOS/coastty", .data = "" });

        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
        return .{
            .tmp = tmp,
            .root = root,
            .link = try std.fs.path.join(alloc, &.{ root, "bin", "coastty" }),
            .current = try std.fs.path.join(alloc, &.{ root, "Current.app/Contents/MacOS/coastty" }),
            .old = try std.fs.path.join(alloc, &.{ root, "Old.app/Contents/MacOS/coastty" }),
        };
    }

    /// Frees the paths and removes the temp folder.
    fn deinit(self: *Fixture) void {
        const alloc = testing.allocator;
        alloc.free(self.root);
        alloc.free(self.link);
        alloc.free(self.current);
        alloc.free(self.old);
        self.tmp.cleanup();
    }

    /// The raw target of the link at `link`.
    fn linkTarget(self: *const Fixture, buf: []u8) ![]const u8 {
        return buf[0..try Dir.readLinkAbsolute(testing.io, self.link, buf)];
    }
};

test "isCoasttyExecutable" {
    try testing.expect(isCoasttyExecutable("/Applications/Coastty.app/Contents/MacOS/coastty"));
    try testing.expect(!isCoasttyExecutable("/Applications/Coastty.app/Contents/MacOS/coastty-host"));
    try testing.expect(!isCoasttyExecutable("/opt/homebrew/bin/coastty"));
}

test "install creates the link and its missing folder" {
    var f: Fixture = try .init();
    defer f.deinit();

    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(f.current, try f.linkTarget(&buf));
}

test "install again is harmless" {
    var f: Fixture = try .init();
    defer f.deinit();

    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));
    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(f.current, try f.linkTarget(&buf));
}

test "install replaces a link to another coastty bundle" {
    var f: Fixture = try .init();
    defer f.deinit();

    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.old));
    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(f.current, try f.linkTarget(&buf));
}

test "install replaces a dangling link" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try Dir.symLinkAbsolute(testing.io, "/nonexistent/coastty", f.link, .{});
    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(f.current, try f.linkTarget(&buf));
}

test "install leaves a link to another program alone" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "other", .data = "" });
    const other = try std.fs.path.join(testing.allocator, &.{ f.root, "other" });
    defer testing.allocator.free(other);
    try Dir.symLinkAbsolute(testing.io, other, f.link, .{});

    try testing.expectEqual(Result.foreign, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(other, try f.linkTarget(&buf));
}

test "install leaves a relative link to another program alone" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try f.tmp.dir.createDirPath(testing.io, "Cellar/foo/1.0/bin");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "Cellar/foo/1.0/bin/coastty", .data = "" });
    try f.tmp.dir.symLink(testing.io, "../Cellar/foo/1.0/bin/coastty", "bin/coastty", .{});

    try testing.expectEqual(Result.foreign, install(testing.io, f.link, f.current));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("../Cellar/foo/1.0/bin/coastty", try f.linkTarget(&buf));
}

test "install leaves a regular file alone" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/coastty", .data = "#!/bin/sh\n" });

    try testing.expectEqual(Result.foreign, install(testing.io, f.link, f.current));
}

test "install refuses a translocated app" {
    var f: Fixture = try .init();
    defer f.deinit();

    const translocated = "/private/var/folders/xy/AppTranslocation/ABC/d/Coastty.app/Contents/MacOS/coastty";
    try testing.expectEqual(Result.translocated, install(testing.io, f.link, translocated));
}

test "uninstall removes a coastty link" {
    var f: Fixture = try .init();
    defer f.deinit();

    try testing.expectEqual(Result.ok, install(testing.io, f.link, f.current));
    try testing.expectEqual(Result.ok, uninstall(testing.io, f.link));
    try testing.expectEqual(Result.not_installed, uninstall(testing.io, f.link));
}

test "uninstall leaves a link to another program alone" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try Dir.symLinkAbsolute(testing.io, "/usr/bin/true", f.link, .{});

    try testing.expectEqual(Result.foreign, uninstall(testing.io, f.link));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/usr/bin/true", try f.linkTarget(&buf));
}

test "uninstall leaves a regular file alone" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/coastty", .data = "" });

    try testing.expectEqual(Result.foreign, uninstall(testing.io, f.link));
}

test "an unreadable link fails instead of asking for admin rights" {
    var f: Fixture = try .init();
    defer f.deinit();

    try f.tmp.dir.createDirPath(testing.io, "bin");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/coastty", .data = "" });

    // A folder the user cannot search hides what sits in it.
    try f.tmp.dir.setFilePermissions(testing.io, "bin", .fromMode(0o600), .{});
    defer f.tmp.dir.setFilePermissions(testing.io, "bin", .fromMode(0o755), .{}) catch {};

    try testing.expectEqual(Result.failed, install(testing.io, f.link, f.current));
    try testing.expectEqual(Result.failed, uninstall(testing.io, f.link));
}
