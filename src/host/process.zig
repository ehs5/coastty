//! Checks on another process by pid: whether it is still there, and
//! waiting for it to be gone after asking it to exit.
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

/// Whether `pid` still names a process this user could signal.
pub fn exists(pid: posix.pid_t) bool {
    // Signal 0 is the "does this process exist and may I signal it" probe;
    // it has no enum name because it isn't a real signal.
    posix.kill(pid, @enumFromInt(0)) catch return false;
    return true;
}

/// Spins until `pid` is gone or `timeout_ms` elapses, so neither a test nor
/// a retiring daemon depends on how fast the process gets around to exiting.
pub fn waitForGone(io: Io, pid: posix.pid_t, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        if (!exists(pid)) return true;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return !exists(pid);
}

test "exists sees this process" {
    try std.testing.expect(exists(std.c.getpid()));
}
