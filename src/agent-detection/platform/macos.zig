// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! macOS process-group enumeration and argv/comm introspection, backing
//! Claude Code presence detection.
//!
//! ported-from: `foreground_job`, `process_group_pids`, `process_bsdinfo`,
//! `comm_from_bsdinfo`, `process_argv`, `process_argv0_name`, and
//! `kern_procargs2` in
//! https://github.com/herdrdev/herdr/blob/master/src/platform/macos.rs
//!
//! coastty already has the pane's foreground process-group id in hand
//! (`Pty.getProcessInfo(.foreground_pid)` is a `tcgetpgrp` on the pty
//! master), so this starts one step later than herdr's `foreground_job`,
//! which first has to resolve that pgid from a plain child pid via
//! `e_tpgid`.
//!
//! `libproc.h`/`sys/proc_info.h` are declared by hand here rather than via
//! `@cImport`: those headers transitively pull in Mach message headers
//! that Zig's C translator currently can't lower on this target, so the
//! handful of externs and the one struct this file actually needs are
//! reproduced directly instead (a stable, decades-old kernel ABI).

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const Pid = platform.Pid;
const detection = @import("../main.zig");
const ForegroundProcess = platform.ForegroundProcess;
const ForegroundJob = platform.ForegroundJob;

const CTL_KERN: c_int = 1;
const KERN_PROCARGS2: c_int = 49;

/// `proc_listpids` selector: pids belonging to a given process group.
const PROC_PGRP_ONLY: u32 = 2;
/// `proc_pidinfo` flavor: the `proc_bsdinfo` struct.
const PROC_PIDTBSDINFO: c_int = 3;
/// `proc_pidinfo` flavor: the `proc_vnodepathinfo` struct.
const PROC_PIDVNODEPATHINFO: c_int = 9;
/// `MAXCOMLEN`, per <sys/param.h>.
const max_comlen = 16;
/// `MAXPATHLEN`, per <sys/param.h>.
const max_pathlen = 1024;

extern "c" fn proc_listpids(kind: u32, arg: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// <sys/proc_info.h> `struct proc_bsdinfo`, trimmed of nothing (its full
/// layout must be reproduced for `proc_pidinfo` to write into it
/// correctly), but only `pbi_comm` and `pbi_pgid` are actually read.
const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [max_comlen]u8,
    pbi_name: [2 * max_comlen]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

/// <sys/proc_info.h> `struct vinfo_stat`. Reproduced in full so
/// `ProcVnodePathInfo` reaches the size `proc_pidinfo` demands; no field is
/// read directly.
const VinfoStat = extern struct {
    vst_dev: u32,
    vst_mode: u16,
    vst_nlink: u16,
    vst_ino: u64,
    vst_uid: u32,
    vst_gid: u32,
    vst_atime: i64,
    vst_atimensec: i64,
    vst_mtime: i64,
    vst_mtimensec: i64,
    vst_ctime: i64,
    vst_ctimensec: i64,
    vst_birthtime: i64,
    vst_birthtimensec: i64,
    vst_size: i64,
    vst_blocks: i64,
    vst_blksize: i32,
    vst_flags: u32,
    vst_gen: u32,
    vst_rdev: u32,
    vst_qspare: [2]i64,
};

/// <sys/proc_info.h> `struct vnode_info`.
const VnodeInfo = extern struct {
    vi_stat: VinfoStat,
    vi_type: i32,
    vi_pad: i32,
    vi_fsid: [2]i32,
};

/// <sys/proc_info.h> `struct vnode_info_path`.
const VnodeInfoPath = extern struct {
    vip_vi: VnodeInfo,
    vip_path: [max_pathlen]u8,
};

/// <sys/proc_info.h> `struct proc_vnodepathinfo`. Only `pvi_cdir.vip_path` is
/// read, but `proc_pidinfo` only fills the buffer when handed the full size.
const ProcVnodePathInfo = extern struct {
    pvi_cdir: VnodeInfoPath,
    pvi_rdir: VnodeInfoPath,
};

comptime {
    // These are hand-written reproductions of a C ABI; if they don't match the
    // kernel's own layout `proc_pidinfo` silently refuses every call.
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@sizeOf(ProcVnodePathInfo) == 2352);
    std.debug.assert(@offsetOf(VnodeInfoPath, "vip_path") == 152);
}

/// Returns true if `pgid` is, or contains, a Claude Code process.
pub fn identifyClaude(pgid: u64) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const job = foregroundJob(alloc, pgid) orelse return false;
    return detection.identifyClaude(alloc, job) catch false;
}

/// Read `e_tpgid` - the foreground process group of `pid`'s controlling
/// terminal.
pub fn foregroundProcessGroupId(pid: u32) ?u32 {
    const info = processBsdInfo(pid) orelse return null;
    return if (info.e_tpgid > 0) info.e_tpgid else null;
}

/// The single-process job for a group leader, used when the full group
/// enumeration isn't wanted - only the leader's own identity matters.
pub fn foregroundGroupLeaderJob(alloc: Allocator, process_group_id: u32) ?ForegroundJob {
    const info = processBsdInfo(process_group_id) orelse return null;
    if (info.pbi_pgid != process_group_id) return null;

    const name = commFromBsdInfo(alloc, &info) orelse return null;
    const argv = processArgv(alloc, process_group_id);
    const processes = alloc.alloc(ForegroundProcess, 1) catch return null;
    processes[0] = .{
        .pid = process_group_id,
        .name = name,
        .argv0 = processArgv0Name(alloc, argv),
        .argv = argv,
        .cmdline = if (argv) |a| (std.mem.join(alloc, " ", a) catch null) else null,
    };
    return .{ .process_group_id = process_group_id, .processes = processes };
}

/// Read a coastty agent identity hint out of a process's environment block.
pub fn processAgentHint(alloc: Allocator, pid: u32) ?[]const u8 {
    if (pid == 0) return null;
    const buf = kernProcArgs2(alloc, pid) orelse return null;
    return parseAgentEnvHint(alloc, procargs2Env(buf) orelse return null);
}

fn parseAgentEnvHint(alloc: Allocator, environ: []const u8) ?[]const u8 {
    return platform.parseAgentEnvHint(alloc, environ);
}

/// Enumerate every process sharing `pgid`, the way herdr's
/// `foreground_job` does past the point where it already has the pgid.
pub fn foregroundJob(alloc: Allocator, pgid: u64) ?ForegroundJob {
    const group_id: u32 = std.math.cast(u32, pgid) orelse return null;
    if (group_id == 0) return null;

    var processes: std.ArrayList(ForegroundProcess) = .empty;
    for (processGroupPids(alloc, group_id)) |pid| {
        const info = processBsdInfo(pid) orelse continue;
        if (info.pbi_pgid != group_id) continue;

        const name = commFromBsdInfo(alloc, &info) orelse continue;
        const argv = processArgv(alloc, pid);
        processes.append(alloc, .{
            .pid = pid,
            .name = name,
            .argv0 = processArgv0Name(alloc, argv),
            .argv = argv,
            .cmdline = if (argv) |a| (std.mem.join(alloc, " ", a) catch null) else null,
        }) catch continue;
    }

    if (processes.items.len == 0) return null;
    return .{ .process_group_id = group_id, .processes = processes.items };
}

/// All PIDs in process group `pgid`, via `proc_listpids(PROC_PGRP_ONLY)`.
/// Retries with a doubled buffer if the group didn't fit, matching
/// herdr's own retry loop (macOS gives no direct way to size the buffer
/// up front).
fn processGroupPids(alloc: Allocator, pgid: u32) []const u32 {
    var capacity: usize = 16;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const pids = alloc.alloc(i32, capacity) catch return &.{};
        const buffer_bytes: c_int = @intCast(pids.len * @sizeOf(i32));
        const returned_bytes = proc_listpids(PROC_PGRP_ONLY, pgid, pids.ptr, buffer_bytes);
        if (returned_bytes <= 0) return &.{};

        const returned: usize = @intCast(returned_bytes);
        const count = returned / @sizeOf(i32);
        if (returned < @as(usize, @intCast(buffer_bytes))) return collectPositivePids(alloc, pids[0..count]);
        capacity = capacity * 2;
    }
    return &.{};
}

fn collectPositivePids(alloc: Allocator, pids: []const i32) []const u32 {
    var list: std.ArrayList(u32) = .empty;
    for (pids) |pid| {
        if (pid > 0) list.append(alloc, @intCast(pid)) catch continue;
    }
    return list.items;
}

fn processBsdInfo(pid: u32) ?ProcBsdInfo {
    var info: ProcBsdInfo = std.mem.zeroes(ProcBsdInfo);
    const size: c_int = @intCast(@sizeOf(ProcBsdInfo));
    const ret = proc_pidinfo(@intCast(pid), PROC_PIDTBSDINFO, 0, &info, size);
    return if (ret == size) info else null;
}

fn commFromBsdInfo(alloc: Allocator, info: *const ProcBsdInfo) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, &info.pbi_comm, 0) orelse info.pbi_comm.len;
    if (end == 0) return null;
    return alloc.dupe(u8, info.pbi_comm[0..end]) catch null;
}

fn processArgv(alloc: Allocator, pid: u32) ?[]const []const u8 {
    const buf = kernProcArgs2(alloc, pid) orelse return null;
    return procargs2Argv(alloc, buf);
}

/// `argv[0]`'s basename with a leading '-' stripped (login shells show as
/// "-zsh"). Reflects runtime title changes like Node.js's
/// `process.title = "..."` reassignment, which the kernel-level `comm`
/// name alone won't.
fn processArgv0Name(alloc: Allocator, argv: ?[]const []const u8) ?[]const u8 {
    const av = argv orelse return null;
    if (av.len == 0) return null;
    const basename = std.fs.path.basename(av[0]);
    const name = if (basename.len > 0 and basename[0] == '-') basename[1..] else basename;
    if (name.len == 0) return null;
    return alloc.dupe(u8, name) catch null;
}

/// Raw `sysctl(KERN_PROCARGS2)` call. Returns the full buffer: `[argc: i32]
/// [exec_path\0] [padding\0...] [argv[0]\0] [argv[1]\0] ... [env...]`.
fn kernProcArgs2(alloc: Allocator, pid: u32) ?[]const u8 {
    var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, @intCast(pid) };

    var size: usize = 0;
    if (std.c.sysctl(&mib, mib.len, null, &size, null, 0) != 0 or size == 0) return null;

    const buf = alloc.alloc(u8, size) catch return null;
    var actual_size: usize = size;
    if (std.c.sysctl(&mib, mib.len, buf.ptr, &actual_size, null, 0) != 0) return null;
    return buf[0..actual_size];
}

fn procargs2ArgvStart(rest: []const u8) ?usize {
    const exec_end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    var pos = exec_end;
    while (pos < rest.len and rest[pos] == 0) pos += 1;
    return if (pos < rest.len) pos else null;
}

fn procargs2Argv(alloc: Allocator, buf: []const u8) ?[]const []const u8 {
    if (buf.len < 4) return null;
    const argc = std.mem.readInt(i32, buf[0..4], .little);
    if (argc < 1) return null;

    const rest = buf[4..];
    var current = procargs2ArgvStart(rest) orelse return null;

    var argv: std.ArrayList([]const u8) = .empty;
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        if (current >= rest.len) return null;
        const end = std.mem.indexOfScalarPos(u8, rest, current, 0) orelse rest.len;
        if (end == current) return null;
        argv.append(alloc, rest[current..end]) catch return null;
        current = end + 1;
    }

    return argv.toOwnedSlice(alloc) catch null;
}

test "processGroupPids includes the current process's own group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const own_pid: u32 = @intCast(std.c.getpid());
    const info = processBsdInfo(own_pid) orelse return error.SkipZigTest;
    const pids = processGroupPids(alloc, info.pbi_pgid);
    try std.testing.expect(std.mem.indexOfScalar(u32, pids, own_pid) != null);
}

test "kernProcArgs2 reads the current test process's own argv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const own_pid: u32 = @intCast(std.c.getpid());
    const argv = processArgv(alloc, own_pid) orelse return error.SkipZigTest;
    try std.testing.expect(argv.len > 0);
}

test "identifyClaude returns false for a bogus process group" {
    try std.testing.expect(!identifyClaude(std.math.maxInt(u32)));
}

test "identifyClaude returns false for pgid 0" {
    try std.testing.expect(!identifyClaude(0));
}

// ported-from: `foreground_job_detects_sleep` in
// https://github.com/herdrdev/herdr/blob/master/src/detect/mod.rs
//
// herdr's version spawns `sleep` under a fresh pty so it lands in its own
// process group; there's no pty here, so the spawned `sleep` shares this
// test process's own group instead. That still exercises the full
// `foregroundJob` -> `identifyClaude` pipeline against a real, independently
// spawned process rather than only the test binary's own argv.
test "foregroundJob and identifyClaude against a real spawned sleep process" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var argv = [_:null]?[*:0]const u8{ "sleep", "999" };
    var child_pid: std.c.pid_t = undefined;
    const spawn_ret = std.c.posix_spawnp(&child_pid, "sleep", null, null, &argv, @ptrCast(std.c.environ));
    if (spawn_ret != 0) return error.SkipZigTest;
    defer {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
        var status: c_int = undefined;
        _ = std.c.waitpid(child_pid, &status, 0);
    }

    const delay = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);

    const own_pid: u32 = @intCast(std.c.getpid());
    const info = processBsdInfo(own_pid) orelse return error.SkipZigTest;
    const job = foregroundJob(alloc, info.pbi_pgid) orelse return error.SkipZigTest;

    const found_sleep = for (job.processes) |p| {
        if (std.mem.eql(u8, p.name, "sleep")) break true;
    } else false;
    try std.testing.expect(found_sleep);
    try std.testing.expect(!identifyClaude(info.pbi_pgid));
}

/// The environment block that follows argv in a `KERN_PROCARGS2` buffer.
/// Returns a slice into `buf`, so it borrows rather than copies.
fn procargs2Env(buf: []const u8) ?[]const u8 {
    if (buf.len < 4) return null;
    const argc = std.mem.readInt(i32, buf[0..4], .little);
    if (argc < 1) return null;

    const rest = buf[4..];
    const argv_start = procargs2ArgvStart(rest) orelse return null;
    const env_start = skipNulStrings(rest, argv_start, @intCast(argc)) orelse return null;
    if (env_start > rest.len) return null;
    return rest[env_start..];
}

fn allPids(alloc: Allocator) []const u32 {
    const initial_count = proc_listallpids(null, 0);
    var capacity: usize = if (initial_count > 0) @as(usize, @intCast(initial_count)) + 128 else 4096;

    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const pids = alloc.alloc(i32, capacity) catch return &.{};
        const buffer_bytes: c_int = @intCast(pids.len * @sizeOf(i32));
        const returned = proc_listallpids(pids.ptr, buffer_bytes);
        if (returned <= 0) return &.{};

        const count: usize = @intCast(returned);
        if (count < capacity) return collectPositivePids(alloc, pids[0..count]);
        capacity = capacity * 2;
    }
    return &.{};
}

fn buildProcargs2(
    alloc: Allocator,
    exec_path: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var argc_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &argc_bytes, @intCast(argv.len), .little);
    try buf.appendSlice(alloc, &argc_bytes);
    try buf.appendSlice(alloc, exec_path);
    try buf.append(alloc, 0);
    try buf.append(alloc, 0);
    for (argv) |arg| {
        try buf.appendSlice(alloc, arg);
        try buf.append(alloc, 0);
    }
    for (env) |entry| {
        try buf.appendSlice(alloc, entry);
        try buf.append(alloc, 0);
    }
    return buf.toOwnedSlice(alloc);
}

test "procargs2_argv_excludes_environment_entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = try buildProcargs2(
        alloc,
        "/usr/bin/node",
        &.{ "node", "/Users/can/.local/bin/claude" },
        &.{
            "PATH=/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin",
            "TERM=tmux-256color",
        },
    );

    const argv = procargs2Argv(alloc, buf) orelse return error.TestExpectedArgv;
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("node", argv[0]);
    try std.testing.expectEqualStrings("/Users/can/.local/bin/claude", argv[1]);

    const joined = try std.mem.join(alloc, " ", argv);
    try std.testing.expectEqualStrings("node /Users/can/.local/bin/claude", joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "codex.system") == null);
}

test "procargs2_env_reads_agent_hint_after_argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = try buildProcargs2(
        alloc,
        "/opt/homebrew/bin/nono",
        &.{ "nono", "run", "COASTTY_AGENT=codex", "--", "claude" },
        &.{ "PATH=/usr/bin", "COASTTY_AGENT=claude", "TERM=xterm-256color" },
    );

    const env = procargs2Env(buf) orelse return error.TestExpectedEnvBlock;
    try std.testing.expectEqualStrings("claude", parseAgentEnvHint(alloc, env).?);
}

test "procargs2_env_does_not_treat_argv_as_environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = try buildProcargs2(
        alloc,
        "/opt/homebrew/bin/nono",
        &.{ "nono", "run", "COASTTY_AGENT=claude" },
        &.{"PATH=/usr/bin"},
    );

    const env = procargs2Env(buf) orelse return error.TestExpectedEnvBlock;
    try std.testing.expectEqual(@as(?[]const u8, null), parseAgentEnvHint(alloc, env));
}

/// Advance past `count` NUL-terminated strings starting at `start`. Returns
/// null if the buffer runs out first, so a truncated `KERN_PROCARGS2` read
/// can't be mistaken for an environment block.
fn skipNulStrings(rest: []const u8, start: usize, count: usize) ?usize {
    var current = start;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (current > rest.len) return null;
        const end = std.mem.indexOfScalarPos(u8, rest, current, 0) orelse return null;
        current = end + 1;
    }
    return current;
}

/// A process's current working directory, via
/// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
pub fn processCwd(alloc: Allocator, pid: u32) ?[]const u8 {
    if (pid == 0) return null;

    var pathinfo: ProcVnodePathInfo = std.mem.zeroes(ProcVnodePathInfo);
    const size: c_int = @intCast(@sizeOf(ProcVnodePathInfo));
    const ret = proc_pidinfo(@intCast(pid), PROC_PIDVNODEPATHINFO, 0, &pathinfo, size);
    if (ret != size) return null;

    const path = &pathinfo.pvi_cdir.vip_path;
    const nul = std.mem.indexOfScalar(u8, path, 0) orelse return null;
    if (nul == 0) return null;
    return alloc.dupe(u8, path[0..nul]) catch null;
}

pub fn foregroundProcessGroupIdForTtyFd(fd: std.posix.fd_t) ?u32 {
    const pgid = std.c.tcgetpgrp(fd);
    return if (pgid > 0) @intCast(pgid) else null;
}

pub fn availablePaneShell(alloc: Allocator, child_pid: u32) ?[]const u8 {
    const job = platform.foregroundJob(alloc, child_pid) orelse return null;
    return platform.availablePaneShellFromJob(child_pid, job);
}

pub fn processExists(pid: u32) bool {
    if (pid == 0) return false;
    std.posix.kill(@intCast(pid), 0) catch |err| return err == error.PermissionDenied;
    return true;
}

/// Spawn `argv` on `slave_fd` in a new session, so the child owns the pty's
/// foreground process group the way a real pane's child does. Detection tests
/// need a genuine foreground job to introspect; `std.process.Child` can't set
/// `SETSID`, so the spawn is done directly here rather than in the test.
pub fn spawnSessionLeader(slave_fd: std.posix.fd_t, argv: [*:null]const ?[*:0]const u8) !Pid {
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    _ = std.c.posix_spawn_file_actions_adddup2(&actions, slave_fd, 0);
    _ = std.c.posix_spawn_file_actions_adddup2(&actions, slave_fd, 1);
    _ = std.c.posix_spawn_file_actions_adddup2(&actions, slave_fd, 2);

    var attr: std.c.posix_spawnattr_t = undefined;
    if (std.c.posix_spawnattr_init(&attr) != 0) return error.SpawnFailed;
    defer _ = std.c.posix_spawnattr_destroy(&attr);
    // The child becomes a session leader, so the pty becomes its controlling
    // terminal and `tcgetpgrp` reports its process group.
    _ = std.c.posix_spawnattr_setflags(&attr, .{ .SETSID = true });

    var pid: std.c.pid_t = undefined;
    const program = argv[0].?;
    if (std.c.posix_spawnp(&pid, program, &actions, &attr, argv, @ptrCast(std.c.environ)) != 0) {
        return error.SpawnFailed;
    }
    return pid;
}

pub fn killAndReap(pid: Pid) void {
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

pub fn killProcessGroup(pgid: u32) void {
    std.posix.kill(-@as(std.c.pid_t, @intCast(pgid)), std.posix.SIG.KILL) catch {};
}

pub fn currentPid() u32 {
    return @intCast(std.c.getpid());
}

pub fn sleepMs(ms: u64) void {
    const delay = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&delay, null);
}
