//! Who may reach the daemon's control socket, and who may reach inside a
//! pane through it. Only processes running as this user connect at all: the
//! socket sits in a private directory, is bound owner-only, and both ends
//! check the uid on the other side. Of those, only the app may read or type
//! into a pane, start one or end one: those requests carry a token the
//! daemon writes beside its socket on every start, owner-only, for the app
//! to read and send. It is never put in a pane's environment or on a
//! command line, so nothing running in a pane is handed it.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Io = std.Io;
const net = std.Io.net;
const paths = @import("paths.zig");

const log = std.log.scoped(.coastty_host_access);

extern "c" fn getpeereid(fd: c.fd_t, euid: *c.uid_t, egid: *c.gid_t) c_int;

pub const PrivateDirError = error{
    /// Something other than a real directory is there, a symlink included.
    NotADirectory,
    WrongOwner,
    /// Group or others have some access to it.
    OpenToOthers,
    NameTooLong,
    Unexpected,
};

/// Creates `dir` with mode 0700 when it's missing, then makes sure it is a
/// real directory, owned by this user and closed to everyone else. A
/// directory someone else prepared is refused rather than fixed up, since
/// whoever made it may already have a foot in it.
pub fn ensurePrivateDir(dir: []const u8) PrivateDirError!void {
    const dir_z = try posix.toPosixPath(dir);

    const rc = c.mkdir(&dir_z, 0o700);
    switch (posix.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    var st: c.Stat = undefined;
    switch (posix.errno(c.fstatat(c.AT.FDCWD, &dir_z, &st, c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    if (!c.S.ISDIR(st.mode)) return error.NotADirectory;
    if (st.uid != paths.uid()) return error.WrongOwner;
    if (st.mode & 0o077 != 0) return error.OpenToOthers;
}

/// Binds and listens on `addr` with the socket file readable and writable
/// by this user only. Done under a restrictive umask rather than a chmod
/// afterwards so there's no moment the socket is open to others. The umask
/// is process-wide, so call this before starting any other threads.
pub fn listenOwnerOnly(io: Io, addr: *const net.UnixAddress) net.UnixAddress.ListenError!net.Server {
    const old_mask = c.umask(0o177);
    defer _ = c.umask(old_mask);
    return addr.listen(io, .{});
}

/// Whether the process on the other end of `stream` runs as this user.
/// Fails closed: an unanswerable question counts as a stranger.
pub fn peerIsUser(stream: net.Stream) bool {
    // Only Darwin's peer-credential call is wired up; coastty runs the daemon nowhere else.
    if (comptime !builtin.os.tag.isDarwin()) return false;

    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    if (getpeereid(stream.socket.handle, &uid, &gid) != 0) return false;
    return uid == paths.uid();
}

/// The pid of the process on the other end of `stream`, or null when the
/// system won't say.
pub fn peerPid(stream: net.Stream) ?posix.pid_t {
    // Darwin's SOL_LOCAL and LOCAL_PEERPID, which std doesn't declare.
    if (comptime !builtin.os.tag.isDarwin()) return null;
    const sol_local = 0;
    const local_peerpid = 2;

    var pid: posix.pid_t = undefined;
    var len: posix.socklen_t = @sizeOf(posix.pid_t);
    if (c.getsockopt(stream.socket.handle, sol_local, local_peerpid, &pid, &len) != 0) return null;
    return pid;
}

/// Connects to the daemon at `path`, or null when nothing answers there or
/// what answers isn't running as this user. Nothing is sent before the
/// check, so a socket someone else planted never sees a request.
pub fn connect(io: Io, path: []const u8) ?net.Stream {
    const addr = net.UnixAddress.init(path) catch return null;
    const stream = addr.connect(io) catch return null;

    if (!peerIsUser(stream)) {
        log.err("refusing {s}: whoever serves it is not running as this user", .{path});
        stream.close(io);
        return null;
    }
    return stream;
}

/// How many characters a token is: 32 random bytes, as lowercase hex.
pub const token_len = 64;

/// The secret the app proves itself with on a request that reaches inside a pane.
pub const Token = [token_len]u8;

/// A fresh random token.
pub fn newToken(io: Io) Token {
    var bytes: [token_len / 2]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Takes the lock that lets one daemon at a time start on `socket_path`, held until the process exits. Null when another daemon holds it, so two started at once never both publish a token or bind.
pub fn lockSocket(io: Io, socket_path: []const u8) !?std.Io.File {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path = try paths.lockPath(&path_buf, socket_path);

    return std.Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => err,
    };
}

/// Publishes `token` at `path`, readable and writable by this user only. Whatever was there is removed and the file created afresh rather than truncated, so a symlink or a file someone else made is never written through.
pub fn writeToken(io: Io, path: []const u8, token: *const Token) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = token,
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
    });
}

/// Whether `given` is `expected`, compared in constant time so how long a refusal takes says nothing about how close a guess came.
pub fn tokenMatches(expected: *const Token, given: []const u8) bool {
    if (given.len != token_len) return false;
    return std.crypto.timing_safe.eql(Token, expected.*, given[0..token_len].*);
}

/// The token as the last argument of a request line: a space and the token, or nothing when the daemon published none.
pub const TokenArg = struct {
    buf: [1 + token_len]u8 = undefined,
    len: usize = 0,

    /// The argument carrying `token`.
    pub fn init(token: *const Token) TokenArg {
        var arg: TokenArg = .{ .len = 1 + token_len };
        arg.buf[0] = ' ';
        @memcpy(arg.buf[1..], token);
        return arg;
    }

    /// The text to append to the request line.
    pub fn text(self: *const TokenArg) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Reads the token the daemon serving `socket_path` published. A daemon predating tokens publishes none and asks for none, so a missing or unreadable file yields an empty argument rather than an error.
pub fn tokenArg(io: Io, socket_path: []const u8) TokenArg {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path = paths.tokenPath(&path_buf, socket_path) catch return .{};

    var token: Token = undefined;
    const read = std.Io.Dir.cwd().readFile(io, path, &token) catch return .{};
    if (read.len != token_len) return .{};
    return .init(&token);
}

/// `tokenArg` for the daemon on this build's own socket.
pub fn socketTokenArg(alloc: std.mem.Allocator, io: Io) TokenArg {
    const path = paths.socketPath(alloc) catch return .{};
    defer alloc.free(path);
    return tokenArg(io, path);
}

/// A fresh path under /tmp for one test, unique to this process.
fn testPath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/coastty-access-test-{d}-{s}", .{ c.getpid(), name }) catch unreachable;
}

test "ensurePrivateDir creates a missing directory closed to everyone else" {
    var buf: [128]u8 = undefined;
    const dir = testPath(&buf, "create");
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir) catch {};

    try ensurePrivateDir(dir);

    const dir_z = try posix.toPosixPath(dir);
    var st: c.Stat = undefined;
    try std.testing.expectEqual(0, c.fstatat(c.AT.FDCWD, &dir_z, &st, c.AT.SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(0o700, st.mode & 0o777);

    // A second start finds it already in place and accepts it.
    try ensurePrivateDir(dir);
}

test "ensurePrivateDir refuses an existing directory open to others" {
    var buf: [128]u8 = undefined;
    const dir = testPath(&buf, "open");
    const dir_z = try posix.toPosixPath(dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir) catch {};

    try std.testing.expectEqual(0, c.mkdir(&dir_z, 0o700));
    try std.testing.expectEqual(0, c.chmod(&dir_z, 0o755));

    try std.testing.expectError(error.OpenToOthers, ensurePrivateDir(dir));
}

test "ensurePrivateDir refuses a symlink, even to a private directory" {
    var target_buf: [128]u8 = undefined;
    const target = testPath(&target_buf, "target");
    var link_buf: [128]u8 = undefined;
    const link = testPath(&link_buf, "link");
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, target) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, link) catch {};

    try ensurePrivateDir(target);
    const target_z = try posix.toPosixPath(target);
    const link_z = try posix.toPosixPath(link);
    try std.testing.expectEqual(0, c.symlink(&target_z, &link_z));

    try std.testing.expectError(error.NotADirectory, ensurePrivateDir(link));
}

test "listenOwnerOnly binds a socket only this user can open" {
    var buf: [128]u8 = undefined;
    const path = testPath(&buf, "owner-only.sock");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var server = try listenOwnerOnly(std.testing.io, &addr);
    defer server.deinit(std.testing.io);

    const path_z = try posix.toPosixPath(path);
    var st: c.Stat = undefined;
    try std.testing.expectEqual(0, c.fstatat(c.AT.FDCWD, &path_z, &st, c.AT.SYMLINK_NOFOLLOW));
    try std.testing.expect(c.S.ISSOCK(st.mode));
    try std.testing.expectEqual(0o600, st.mode & 0o777);
}

test "both ends of a connection within this user see a peer running as this user" {
    var buf: [128]u8 = undefined;
    const path = testPath(&buf, "peer.sock");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var server = try listenOwnerOnly(std.testing.io, &addr);
    defer server.deinit(std.testing.io);

    const client = connect(std.testing.io, path) orelse return error.ConnectRefused;
    defer client.close(std.testing.io);
    const accepted = try server.accept(std.testing.io);
    defer accepted.close(std.testing.io);

    try std.testing.expect(peerIsUser(accepted));
}

test "connect answers null when nothing is listening" {
    var buf: [128]u8 = undefined;
    const path = testPath(&buf, "nobody.sock");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try std.testing.expect(connect(std.testing.io, path) == null);
}

test "peerPid names the process on the other end" {
    var buf: [128]u8 = undefined;
    const path = testPath(&buf, "pid.sock");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const addr = try net.UnixAddress.init(path);
    var server = try listenOwnerOnly(std.testing.io, &addr);
    defer server.deinit(std.testing.io);

    const client = connect(std.testing.io, path) orelse return error.ConnectRefused;
    defer client.close(std.testing.io);
    const accepted = try server.accept(std.testing.io);
    defer accepted.close(std.testing.io);

    try std.testing.expectEqual(c.getpid(), peerPid(client));
}

test "writeToken publishes the token owner-only, and a restart replaces it" {
    var buf: [128]u8 = undefined;
    const socket = testPath(&buf, "token.sock");
    var token_buf: [160]u8 = undefined;
    const path = try paths.tokenPath(&token_buf, socket);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const first = newToken(std.testing.io);
    try writeToken(std.testing.io, path, &first);

    const path_z = try posix.toPosixPath(path);
    var st: c.Stat = undefined;
    try std.testing.expectEqual(0, c.fstatat(c.AT.FDCWD, &path_z, &st, c.AT.SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(0o600, st.mode & 0o777);
    const first_sent: TokenArg = .init(&first);
    const first_read = tokenArg(std.testing.io, socket);
    try std.testing.expectEqualStrings(first_sent.text(), first_read.text());

    const second = newToken(std.testing.io);
    try writeToken(std.testing.io, path, &second);
    const second_sent: TokenArg = .init(&second);
    const second_read = tokenArg(std.testing.io, socket);
    try std.testing.expectEqualStrings(second_sent.text(), second_read.text());
}

test "writeToken replaces a symlink instead of writing through it" {
    var target_buf: [128]u8 = undefined;
    const target = testPath(&target_buf, "token-target");
    var link_buf: [128]u8 = undefined;
    const link = testPath(&link_buf, "token-link");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, target) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, link) catch {};

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = target, .data = "untouched" });
    const target_z = try posix.toPosixPath(target);
    const link_z = try posix.toPosixPath(link);
    try std.testing.expectEqual(0, c.symlink(&target_z, &link_z));

    const token = newToken(std.testing.io);
    try writeToken(std.testing.io, link, &token);

    var read_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("untouched", try std.Io.Dir.cwd().readFile(std.testing.io, target, &read_buf));
}

test "with no token file the token argument is empty" {
    var buf: [128]u8 = undefined;
    const socket = testPath(&buf, "no-token.sock");
    const read = tokenArg(std.testing.io, socket);
    try std.testing.expectEqualStrings("", read.text());
}

test "tokenMatches accepts only the exact token" {
    const token = newToken(std.testing.io);
    var wrong = token;
    wrong[token_len - 1] = if (wrong[token_len - 1] == '0') '1' else '0';

    try std.testing.expect(tokenMatches(&token, &token));
    try std.testing.expect(!tokenMatches(&token, &wrong));
    try std.testing.expect(!tokenMatches(&token, token[0 .. token_len - 1]));
    try std.testing.expect(!tokenMatches(&token, ""));
}

test "lockSocket lets only one holder in at a time, and frees the lock when it closes" {
    var buf: [128]u8 = undefined;
    const socket = testPath(&buf, "lock.sock");
    var lock_buf: [160]u8 = undefined;
    const path = try paths.lockPath(&lock_buf, socket);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const first = (try lockSocket(std.testing.io, socket)) orelse return error.LockHeld;
    try std.testing.expect((try lockSocket(std.testing.io, socket)) == null);

    first.close(std.testing.io);
    const second = (try lockSocket(std.testing.io, socket)) orelse return error.LockHeld;
    second.close(std.testing.io);
}
