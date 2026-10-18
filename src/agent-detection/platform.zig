// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Presence identification: is Claude Code the foreground process (or a
//! member of the foreground process group) attached to a pane's PTY?
//! Resolved from the PTY's foreground process-group id via platform
//! process introspection, never by reading terminal content.
//!
//! ported-from: the `ForegroundJob`/`ForegroundProcess` shapes in
//! https://github.com/herdrdev/herdr/blob/master/src/platform/mod.rs
//! (`identify_agent_in_job`/`normalized_process_name` themselves are
//! ported in `main.zig`, matching herdr's `src/detect/mod.rs`)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const macos = @import("platform/macos.zig");
const detection = @import("main.zig");

/// A single process in a pane's foreground process group.
///
/// ported-from: `ForegroundProcess` in herdr's `src/platform/mod.rs`
pub const ForegroundProcess = struct {
    pid: u32,
    /// The kernel-reported process name (`comm`), truncated to 16 bytes on
    /// macOS like the rest of the BSD process table.
    name: []const u8,
    /// The runtime-corrected `argv[0]` basename, when resolvable. Reflects
    /// things like Node.js's `process.title = "..."` reassignment, which
    /// `name` alone won't.
    argv0: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    cmdline: ?[]const u8 = null,
};

/// A pane's live foreground process group: every process sharing its
/// foreground pgid, not just the immediate child - so a shell wrapping an
/// agent, or an agent wrapping a runtime, is still visible as a whole.
///
/// ported-from: `ForegroundJob` in herdr's `src/platform/mod.rs`
pub const ForegroundJob = struct {
    process_group_id: u32,
    processes: []const ForegroundProcess,
};

/// Returns true if `pgid` - a pane's foreground process-group id, as
/// returned by `Pty.getProcessInfo(.foreground_pid)` (itself a
/// `tcgetpgrp` on the pty master, so it's already a process-group id, not
/// a single pid) - is, or contains, a Claude Code process. Returns false
/// if that can't be determined, including on platforms this isn't
/// implemented for yet.
pub fn identifyClaude(pgid: u64) bool {
    return switch (builtin.os.tag) {
        .macos => macos.identifyClaude(pgid),
        else => false,
    };
}

// The single platform seam. Every OS call in agent detection reaches the
// kernel through one of these; adding a frontend on another OS means adding
// one `platform/<os>.zig` and one arm to each switch below.

/// A process identifier as the platform's spawn/wait calls take it.
pub const Pid = std.c.pid_t;

/// Whether this build has a process-introspection backend at all. Detection
/// still compiles without one; presence identification just always misses.
pub const supported = builtin.os.tag == .macos;

/// Every process sharing `child_pid`'s controlling-terminal foreground group.
pub fn foregroundJob(alloc: Allocator, child_pid: u32) ?ForegroundJob {
    if (child_pid == 0) return null;
    const pgid = foregroundProcessGroupId(child_pid) orelse return null;
    return foregroundJobForProcessGroup(alloc, pgid);
}

/// The same enumeration as `foregroundJob`, for callers that already hold
/// the pgid - which is where coastty starts, since `Pty.getProcessInfo`
/// hands back a `tcgetpgrp` result directly.
pub fn foregroundJobForProcessGroup(alloc: Allocator, pgid: u64) ?ForegroundJob {
    return switch (builtin.os.tag) {
        .macos => macos.foregroundJob(alloc, pgid),
        else => null,
    };
}

/// Just the group leader of `process_group_id`, as a one-process job.
pub fn foregroundGroupLeaderJob(alloc: Allocator, process_group_id: u32) ?ForegroundJob {
    return switch (builtin.os.tag) {
        .macos => macos.foregroundGroupLeaderJob(alloc, process_group_id),
        else => null,
    };
}

/// The foreground process group of `pid`'s controlling terminal.
pub fn foregroundProcessGroupId(pid: u32) ?u32 {
    return switch (builtin.os.tag) {
        .macos => macos.foregroundProcessGroupId(pid),
        else => null,
    };
}

/// The foreground process group of an already-open tty fd.
pub fn foregroundProcessGroupIdForTtyFd(fd: std.posix.fd_t) ?u32 {
    return switch (builtin.os.tag) {
        .macos => macos.foregroundProcessGroupIdForTtyFd(fd),
        else => null,
    };
}

/// A process's current working directory.
pub fn processCwd(alloc: Allocator, pid: u32) ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => macos.processCwd(alloc, pid),
        else => null,
    };
}

/// The agent identity a pane was launched with, read back from the
/// process's own environment.
pub fn processAgentHint(alloc: Allocator, pid: u32) ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => macos.processAgentHint(alloc, pid),
        else => null,
    };
}

pub fn processExists(pid: u32) bool {
    return switch (builtin.os.tag) {
        .macos => macos.processExists(pid),
        else => false,
    };
}

/// The pane's shell, when the pane is sitting at its shell prompt.
pub fn availablePaneShell(alloc: Allocator, child_pid: u32) ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => macos.availablePaneShell(alloc, child_pid),
        else => null,
    };
}

/// The pane's own shell, when the foreground job is nothing but that shell.
/// A job containing anything besides `child_pid` means something was
/// `exec`'d or spawned into the pane, so there's no idle shell to report.
pub fn availablePaneShellFromJob(child_pid: u32, job: ForegroundJob) ?[]const u8 {
    if (job.process_group_id != child_pid) return null;
    for (job.processes) |process| {
        if (process.pid != child_pid) return null;
    }
    for (job.processes) |process| {
        if (process.pid != child_pid) continue;
        return if (isPaneShellProcessName(process.name)) process.name else null;
    }
    return null;
}

/// Basename, minus a leading '-' (login shells show as "-zsh") and a
/// trailing ".exe", lowercased. Written into `buf`, which must be at least
/// `name.len` bytes.
fn normalizedProcessNameBuf(buf: []u8, name: []const u8) []const u8 {
    var basename = name;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |sep| basename = name[sep + 1 ..];
    basename = std.mem.trimStart(u8, basename, "-");
    while (std.mem.endsWith(u8, basename, ".exe")) basename = basename[0 .. basename.len - ".exe".len];
    return std.ascii.lowerString(buf[0..basename.len], basename);
}

fn normalizedProcessName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, name.len);
    return normalizedProcessNameBuf(buf, name);
}

pub fn isPowershellProcessName(name: []const u8) bool {
    var buf: [max_process_name]u8 = undefined;
    if (name.len > buf.len) return false;
    const normalized = normalizedProcessNameBuf(&buf, name);
    for ([_][]const u8{ "pwsh", "powershell" }) |candidate| {
        if (std.mem.eql(u8, normalized, candidate)) return true;
    }
    return false;
}

pub fn isPaneShellProcessName(name: []const u8) bool {
    var buf: [max_process_name]u8 = undefined;
    if (name.len > buf.len) return false;
    const normalized = normalizedProcessNameBuf(&buf, name);
    for (pane_shell_names) |candidate| {
        if (std.mem.eql(u8, normalized, candidate)) return true;
    }
    return false;
}

const pane_shell_names = [_][]const u8{
    "sh",   "bash",       "dash",  "zsh",
    "fish", "ksh",        "mksh",  "csh",
    "tcsh", "elvish",     "xonsh", "nu",
    "pwsh", "powershell", "cmd",
};

/// Upper bound for a process name we're willing to normalize on the stack.
/// macOS `comm` is capped at 16 bytes; argv[0] can be a full path, and
/// anything longer than this is not a shell name.
const max_process_name = 256;

/// The environment variable coastty sets on a pane it launches an agent
/// into, letting detection skip process introspection entirely.
///
/// ported-from: `HERDR_AGENT` in herdr's `src/platform/mod.rs`
pub const agent_env_hint = "COASTTY_AGENT=";

/// Read the agent identity hint out of a NUL-separated environment block.
pub fn parseAgentEnvHint(alloc: std.mem.Allocator, environ: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, environ, 0);
    while (it.next()) |record| {
        if (!std.mem.startsWith(u8, record, agent_env_hint)) continue;
        return detection.parseAgentLabel(alloc, record[agent_env_hint.len..]) catch null;
    }
    return null;
}

/// Test-only process control, used by detection tests that need a real
/// foreground job on a real pty to introspect. Kept behind the same seam as
/// production process introspection so no OS call escapes `platform/`.
pub const testing_support = struct {
    pub fn spawnSessionLeader(
        slave_fd: std.posix.fd_t,
        argv: [*:null]const ?[*:0]const u8,
    ) !Pid {
        return switch (builtin.os.tag) {
            .macos => macos.spawnSessionLeader(slave_fd, argv),
            else => error.SpawnUnsupported,
        };
    }

    pub fn killAndReap(pid: Pid) void {
        switch (builtin.os.tag) {
            .macos => macos.killAndReap(pid),
            else => {},
        }
    }

    pub fn killProcessGroup(pgid: u32) void {
        switch (builtin.os.tag) {
            .macos => macos.killProcessGroup(pgid),
            else => {},
        }
    }

    pub fn currentPid() u32 {
        return switch (builtin.os.tag) {
            .macos => macos.currentPid(),
            else => 0,
        };
    }

    pub fn sleepMs(ms: u64) void {
        switch (builtin.os.tag) {
            .macos => macos.sleepMs(ms),
            else => {},
        }
    }
};

test "pane_shell_process_names_reject_exec_replacement_programs" {
    for ([_][]const u8{ "bash", "-zsh", "/bin/fish", "pwsh", "powershell.exe" }) |shell| {
        try std.testing.expect(isPaneShellProcessName(shell));
    }
    for ([_][]const u8{ "vim", "nvim", "cargo", "test-runner", "opencode" }) |program| {
        try std.testing.expect(!isPaneShellProcessName(program));
    }
}

test "parse_agent_env_hint_accepts_known_agents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "claude",
        parseAgentEnvHint(alloc, "PATH=/bin\x00COASTTY_AGENT=claude\x00TERM=xterm\x00").?,
    );
    try std.testing.expectEqualStrings(
        "claude",
        parseAgentEnvHint(alloc, "COASTTY_AGENT=claude").?,
    );
}

test "parse_agent_env_hint_ignores_missing_or_unknown_agents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqual(
        @as(?[]const u8, null),
        parseAgentEnvHint(alloc, "PATH=/bin\x00TERM=xterm\x00"),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        parseAgentEnvHint(alloc, "COASTTY_AGENT=not-an-agent\x00"),
    );
}

test "normalized_process_name strips path, leading dash, and .exe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("zsh", try normalizedProcessName(alloc, "-zsh"));
    try std.testing.expectEqualStrings("fish", try normalizedProcessName(alloc, "/bin/fish"));
    try std.testing.expectEqualStrings("powershell", try normalizedProcessName(alloc, "PowerShell.exe"));
    try std.testing.expectEqualStrings("cmd", try normalizedProcessName(alloc, "C:\\Windows\\System32\\cmd.exe"));
}

test "is_powershell_process_name matches only the two powershell binaries" {
    try std.testing.expect(isPowershellProcessName("pwsh"));
    try std.testing.expect(isPowershellProcessName("powershell.exe"));
    try std.testing.expect(!isPowershellProcessName("bash"));
}

test {
    if (builtin.os.tag == .macos) _ = macos;
}
