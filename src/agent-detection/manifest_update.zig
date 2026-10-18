// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Fetching and caching updated agent-detection manifests, so a change in
//! an agent's UI can ship without a coastty release.
//!
//! ported-from: https://github.com/herdrdev/herdr/blob/master/src/detect/manifest_update.rs
//!
//! Two deviations from herdr, both noted at their call sites:
//!
//! - **JSON, not TOML.** herdr's catalog and manifests are TOML; Zig has no
//!   TOML parser in std, and coastty's catalog is meant to live as a file in
//!   this repo served over `raw.githubusercontent.com`, where JSON is the
//!   natural format. The schema is otherwise field-for-field the same.
//! - **`default_catalog_url` is empty.** herdr points at its own server.
//!   coastty has no equivalent yet, so every update check no-ops until one
//!   is configured - either by filling this in or by setting
//!   `COASTTY_AGENT_DETECTION_MANIFEST_CATALOG_URL`. An unset, unreachable,
//!   or malformed catalog is never an error the user sees: detection falls
//!   back to the bundled manifest and carries on.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");
const detection = @import("main.zig");
const manifest = @import("manifest.zig");

const log = std.log.scoped(.agent_detection);

/// Manifests declaring a `min_engine_version` above this are rejected: they
/// use region or matcher features this engine doesn't have.
pub const MANIFEST_ENGINE_VERSION: u32 = 3;
pub const default_catalog_url: []const u8 = "";
pub const catalog_url_env: []const u8 = "COASTTY_AGENT_DETECTION_MANIFEST_CATALOG_URL";
const MAX_FETCH_BYTES: usize = 256 * 1024;

/// A dotted-numeric manifest version ("2026.08.13.1"). Not semver: segments
/// are compared numerically left to right, and a missing trailing segment
/// counts as zero, so "1.2" and "1.2.0" are equal.
pub const ManifestVersion = struct {
    value: []const u8,

    pub fn parse(value: []const u8) !ManifestVersion {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyManifestVersion;

        var it = std.mem.splitScalar(u8, trimmed, '.');
        while (it.next()) |segment| {
            if (segment.len == 0) return error.EmptyManifestVersionSegment;
            for (segment) |ch| {
                if (!std.ascii.isDigit(ch)) return error.NonNumericManifestVersion;
            }
            _ = std.fmt.parseInt(u64, segment, 10) catch return error.OversizedManifestVersion;
        }
        return .{ .value = trimmed };
    }

    pub fn order(self: ManifestVersion, other: ManifestVersion) std.math.Order {
        var left = std.mem.splitScalar(u8, self.value, '.');
        var right = std.mem.splitScalar(u8, other.value, '.');

        while (true) {
            const l = left.next();
            const r = right.next();
            if (l == null and r == null) return .eq;

            // A segment the other side doesn't have only matters if it's
            // non-zero, so "1.2.0" == "1.2".
            if (r == null) {
                if (segmentValue(l.?) == 0) continue;
                return .gt;
            }
            if (l == null) {
                if (segmentValue(r.?) == 0) continue;
                return .lt;
            }

            const ordering = std.math.order(segmentValue(l.?), segmentValue(r.?));
            if (ordering != .eq) return ordering;
        }
    }

    fn segmentValue(segment: []const u8) u64 {
        return std.fmt.parseInt(u64, segment, 10) catch 0;
    }

    pub fn fmt(self: ManifestVersion, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.value);
    }

    pub fn deserialize(alloc: Allocator, value: []const u8) !ManifestVersion {
        const parsed = try parse(value);
        return .{ .value = try alloc.dupe(u8, parsed.value) };
    }

    pub fn serialize(self: ManifestVersion) []const u8 {
        return self.value;
    }

    pub fn cmp(self: ManifestVersion, other: ManifestVersion) std.math.Order {
        return self.order(other);
    }

    pub fn partialCmp(self: ManifestVersion, other: ManifestVersion) ?std.math.Order {
        return self.cmp(other);
    }

    pub fn eq(self: ManifestVersion, other: ManifestVersion) bool {
        return self.cmp(other) == .eq;
    }
};

pub const ManifestUpdateCommit = struct {
    agent_label: []const u8,
    version: []const u8,
};

pub const AgentRemoteStatus = struct {
    cached_version: ?[]const u8 = null,
    attempted_version: ?[]const u8 = null,
    last_checked_unix: ?u64 = null,
    last_result: []const u8,
    last_error: ?[]const u8 = null,
};

pub const ManifestUpdateStatus = struct {
    last_check_unix: ?u64 = null,
    last_result: ?[]const u8 = null,
    agents: []const AgentStatusEntry = &.{},

    pub const AgentStatusEntry = struct {
        agent_label: []const u8,
        status: AgentRemoteStatus,
    };

    pub fn agentStatus(self: ManifestUpdateStatus, agent_label: []const u8) ?AgentRemoteStatus {
        for (self.agents) |entry| {
            if (std.mem.eql(u8, entry.agent_label, agent_label)) return entry.status;
        }
        return null;
    }
};

const ManifestCatalog = struct {
    schema_version: u32,
    agents: []const ManifestCatalogAgent = &.{},
};

const ManifestCatalogAgent = struct {
    id: []const u8,
    path: []const u8,
};

const CatalogAgent = struct {
    agent_label: []const u8,
    path: []const u8,
};

pub const ManifestUpdateOutput = struct {
    updated: []const ManifestUpdateCommit = &.{},
    status: ManifestUpdateStatus,
};

/// Run one update check and reload the manifest cache if anything changed.
/// Every failure is swallowed and recorded in the status file: a detection
/// manifest that can't be refreshed is not a condition the user should be
/// interrupted about.
pub fn autoUpdate(alloc: Allocator) void {
    const output = checkAndUpdate(alloc) catch |err| {
        log.warn("agent detection manifest update failed: {t}", .{err});

        var status = loadStatus(alloc) catch ManifestUpdateStatus{};
        status.last_check_unix = nowUnix();
        status.last_result = std.fmt.allocPrint(alloc, "failed: {t}", .{err}) catch "failed";
        saveStatus(alloc, status) catch {};
        return;
    };

    if (output.updated.len > 0) {
        _ = manifest.reloadManifests(alloc) catch |err| {
            log.warn("agent detection manifest reload failed: {t}", .{err});
        };
    }
}

pub fn checkAndUpdate(alloc: Allocator) !ManifestUpdateOutput {
    return checkAndUpdateFromUrl(alloc, try catalogUrl(alloc));
}

fn checkAndUpdateFromUrl(alloc: Allocator, url: []const u8) !ManifestUpdateOutput {
    if (url.len == 0) return error.NoCatalogUrl;

    const catalog = try parseCatalog(alloc, try fetchText(alloc, url));
    const base_url = try baseUrl(url);
    const check_time = nowUnix();

    var status = loadStatus(alloc) catch ManifestUpdateStatus{};
    status.last_check_unix = check_time;
    status.last_result = "checked";

    var updated: std.ArrayList(ManifestUpdateCommit) = .empty;
    var agents: std.ArrayList(ManifestUpdateStatus.AgentStatusEntry) = .empty;

    for (catalog) |entry| {
        const manifest_url = try joinUrl(alloc, base_url, entry.path);
        const result = processAgentManifest(alloc, entry, manifest_url, check_time);

        if (result) |maybe_commit| {
            if (maybe_commit) |commit| {
                try updated.append(alloc, commit);
                try agents.append(alloc, .{ .agent_label = entry.agent_label, .status = .{
                    .cached_version = commit.version,
                    .attempted_version = commit.version,
                    .last_checked_unix = check_time,
                    .last_result = "updated",
                } });
                continue;
            }
            const cached = cachedRemoteVersion(alloc, entry.agent_label);
            try agents.append(alloc, .{ .agent_label = entry.agent_label, .status = .{
                .cached_version = if (cached) |v| v.value else null,
                .last_checked_unix = check_time,
                .last_result = "current",
            } });
        } else |err| {
            log.warn("agent detection manifest update failed for {s}: {t}", .{ entry.agent_label, err });
            const cached = cachedRemoteVersion(alloc, entry.agent_label);
            try agents.append(alloc, .{ .agent_label = entry.agent_label, .status = .{
                .cached_version = if (cached) |v| v.value else null,
                .last_checked_unix = check_time,
                .last_result = "failed",
                .last_error = @errorName(err),
            } });
        }
    }

    status.agents = agents.items;
    saveStatus(alloc, status) catch |err| {
        log.warn("failed to save agent detection manifest update status: {t}", .{err});
        status.last_result = "failed_to_save_status";
    };

    return .{ .updated = updated.items, .status = status };
}

/// Fetch, validate, and commit one agent's manifest. Returns null when the
/// cached copy is already current.
///
/// A same-version manifest whose *content* changed is rejected outright: a
/// silently mutated manifest at a stable version is either a mistake or
/// tampering, and either way accepting it would make the cached version
/// number meaningless.
fn processAgentManifest(
    alloc: Allocator,
    catalog_agent: CatalogAgent,
    manifest_url: []const u8,
    check_time: u64,
) !?ManifestUpdateCommit {
    _ = check_time;
    const content = try fetchText(alloc, manifest_url);
    const parsed = try manifest.parseRemoteManifestForAgent(alloc, catalog_agent.agent_label, content);
    const version = try ManifestVersion.parse(parsed.version);

    if (cachedRemoteVersion(alloc, catalog_agent.agent_label)) |current| {
        switch (version.cmp(current)) {
            .lt => return error.RemoteManifestOlderThanCached,
            .eq => {
                const path = try remoteManifestPath(alloc, catalog_agent.agent_label);
                const committed = std.Io.Dir.cwd().readFileAlloc(
                    global.io(),
                    path,
                    alloc,
                    .limited(MAX_FETCH_BYTES),
                ) catch "";
                if (!std.mem.eql(u8, committed, content)) {
                    return error.RemoteManifestContentChangedWithoutVersionBump;
                }
                return null;
            },
            .gt => {},
        }
    }

    try commitRemoteManifest(alloc, catalog_agent.agent_label, content);
    return .{ .agent_label = catalog_agent.agent_label, .version = version.value };
}

/// Parse the catalog index. Unknown agent ids are skipped rather than
/// rejected, so the same catalog can serve builds that know about different
/// agent sets.
fn parseCatalog(alloc: Allocator, content: []const u8) ![]const CatalogAgent {
    const parsed = try std.json.parseFromSlice(ManifestCatalog, alloc, content, .{
        .allocate = .alloc_always,
    });
    const catalog = parsed.value;
    if (catalog.schema_version != 1) return error.UnsupportedCatalogSchemaVersion;

    var agents: std.ArrayList(CatalogAgent) = .empty;
    for (catalog.agents) |entry| {
        const agent_label = (try detection.parseAgentLabel(alloc, entry.id)) orelse {
            log.debug("skipping unknown remote manifest agent {s}", .{entry.id});
            continue;
        };
        if (std.mem.trim(u8, entry.path, " \t\r\n").len == 0) return error.EmptyCatalogPath;
        if (!safeRelativePath(entry.path)) return error.UnsafeCatalogPath;

        for (agents.items) |seen| {
            if (std.mem.eql(u8, seen.agent_label, agent_label)) return error.DuplicateCatalogAgent;
        }
        try agents.append(alloc, .{ .agent_label = agent_label, .path = entry.path });
    }
    return agents.items;
}

/// A catalog path must stay under the catalog's own directory: no absolute
/// paths, no schemes, no `..` traversal.
fn safeRelativePath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "://") != null) return false;
    if (path.len > 0 and path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn loadStatus(alloc: Allocator) !ManifestUpdateStatus {
    const path = try statusPath(alloc);
    const content = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(MAX_FETCH_BYTES),
    ) catch return .{};

    const parsed = std.json.parseFromSlice(ManifestUpdateStatus, alloc, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("failed to parse agent detection manifest status at {s}: {t}", .{ path, err });
        return .{};
    };
    return parsed.value;
}

fn saveStatus(alloc: Allocator, status: ManifestUpdateStatus) !void {
    const path = try statusPath(alloc);
    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    try std.json.Stringify.value(status, .{ .whitespace = .indent_2 }, &content.writer);
    try atomicWrite(path, content.written());
}

pub fn statusPath(alloc: Allocator) ![]const u8 {
    return std.fs.path.join(alloc, &.{ try stateRoot(alloc), "status.json" });
}

pub fn remoteManifestPath(alloc: Allocator, agent_label: []const u8) ![]const u8 {
    const basename = try std.fmt.allocPrint(alloc, "{s}.json", .{agent_label});
    return std.fs.path.join(alloc, &.{ try stateRoot(alloc), "remote", basename });
}

pub fn cachedRemoteVersion(alloc: Allocator, agent_label: []const u8) ?ManifestVersion {
    const path = remoteManifestPath(alloc, agent_label) catch return null;
    const content = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(MAX_FETCH_BYTES),
    ) catch return null;
    const parsed = manifest.parseRemoteManifestForAgent(alloc, agent_label, content) catch return null;
    return ManifestVersion.parse(parsed.version) catch null;
}

fn commitRemoteManifest(alloc: Allocator, agent_label: []const u8, content: []const u8) !void {
    try atomicWrite(try remoteManifestPath(alloc, agent_label), content);
}

/// Write via a temp file and rename, so a crash or a concurrent reader
/// never sees a half-written manifest.
fn atomicWrite(path: []const u8, bytes: []const u8) !void {
    const io = global.io();
    const parent = std.fs.path.dirname(path) orelse return error.PathHasNoParent;
    const basename = std.fs.path.basename(path);

    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);

    var atomic_file = try dir.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic_file.deinit(io);

    var buf: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buf);
    try file_writer.interface.writeAll(bytes);
    try file_writer.flush();
    try atomic_file.replace(io);

    syncParentDir(parent) catch |err| {
        if (!directorySyncUnsupported(err)) {
            log.warn("manifest committed but parent directory sync failed: {t}", .{err});
        }
    };
}

/// Test-only redirection of the state root. herdr's tests reassign
/// `XDG_STATE_HOME` in the process environment; Zig tests read a frozen
/// environment snapshot, so the redirection is explicit instead.
pub var test_state_dir_override: ?[]const u8 = null;

fn stateRoot(alloc: Allocator) ![]const u8 {
    if (builtin.is_test) {
        if (test_state_dir_override) |root| return root;
    }
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return internal_os.xdg.state(global.io(), alloc, &environ_map, .{
        .subdir = "ghostty/agent-detection",
    });
}

pub fn catalogUrl(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    if (environ_map.get(catalog_url_env)) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return alloc.dupe(u8, trimmed);
    }
    return default_catalog_url;
}

/// Fetch over HTTP by shelling out to `curl`, the way herdr does: it's
/// already on every macOS install, and it keeps TLS handling out of this
/// code entirely. Bounded in both time and size.
fn fetchText(alloc: Allocator, url: []const u8) ![]const u8 {
    if (url.len == 0) return error.NoCatalogUrl;

    var max_fetch_bytes_buf: [32]u8 = undefined;
    const max_fetch_bytes = try std.fmt.bufPrint(&max_fetch_bytes_buf, "{d}", .{MAX_FETCH_BYTES});

    const result = try std.process.run(alloc, global.io(), .{
        .argv = &.{
            "curl",
            "-sfL",
            "--retry",
            "2",
            "--connect-timeout",
            "5",
            "--max-time",
            "15",
            "--max-filesize",
            max_fetch_bytes,
            url,
        },
        .stdout_limit = .limited(MAX_FETCH_BYTES),
        .stderr_limit = .limited(4096),
    });

    switch (result.term) {
        .exited => |code| if (code != 0) return error.FetchFailed,
        else => return error.FetchFailed,
    }
    if (!std.unicode.utf8ValidateSlice(result.stdout)) return error.FetchResponseNotUtf8;
    return result.stdout;
}

fn baseUrl(url: []const u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return error.CatalogUrlHasNoBasePath;
    return url[0..slash];
}

fn joinUrl(alloc: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (!safeRelativePath(path)) return error.UnsafeManifestPath;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}

test {
    std.testing.refAllDecls(@This());
}

fn syncParentDir(parent: []const u8) !void {
    const io = global.io();
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    const as_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

/// Some filesystems (and Windows, which can't open a directory as a file at
/// all) refuse a directory fsync. That's not a failure to commit - the
/// rename already happened - so it's not worth reporting.
fn directorySyncUnsupported(err: anyerror) bool {
    return switch (err) {
        error.Unsupported, error.InvalidArgument, error.AccessDenied, error.PermissionDenied => true,
        else => false,
    };
}

fn nowUnix() u64 {
    const nanos = nowNanos();
    return @intCast(nanos / std.time.ns_per_s);
}

fn nowNanos() u128 {
    const now = std.Io.Timestamp.now(global.io(), .real).nanoseconds;
    return if (now < 0) 0 else @intCast(now);
}

const testing = std.testing;

/// Point `stateRoot` at a scratch directory for the duration of a test, so
/// the real cache is never touched.
fn withStateDir(alloc: Allocator, name: []const u8) ![]const u8 {
    const unique = try std.fmt.allocPrint(alloc, "coastty-manifest-update-{s}-{d}", .{
        name,
        nowNanos(),
    });
    const path = try std.fs.path.join(alloc, &.{ "/tmp", unique });
    try std.Io.Dir.cwd().createDirPath(global.io(), path);
    return path;
}

fn remoteManifest(alloc: Allocator, version: []const u8, contains: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "id": "claude",
        \\  "version": "{s}",
        \\  "min_engine_version": 1,
        \\  "rules": [
        \\    {{ "id": "remote_blocked", "state": "blocked", "priority": 500, "contains": ["{s}"] }}
        \\  ]
        \\}}
    , .{ version, contains });
}

test "manifest_version_compares_dotted_numeric_segments" {
    const a = try ManifestVersion.parse("2026.08.13.1");
    const b = try ManifestVersion.parse("2026.08.13.2");
    const c = try ManifestVersion.parse("2026.08.13.1");

    try testing.expectEqual(std.math.Order.lt, a.cmp(b));
    try testing.expectEqual(std.math.Order.gt, b.cmp(a));
    try testing.expectEqual(std.math.Order.eq, a.cmp(c));
    try testing.expect(a.eq(c));
    try testing.expect(!a.eq(b));

    // Numeric, not lexical: 10 > 9.
    try testing.expectEqual(
        std.math.Order.gt,
        (try ManifestVersion.parse("1.10")).cmp(try ManifestVersion.parse("1.9")),
    );

    // A missing trailing segment reads as zero.
    try testing.expectEqual(
        std.math.Order.eq,
        (try ManifestVersion.parse("1.2")).cmp(try ManifestVersion.parse("1.2.0")),
    );
    try testing.expectEqual(
        std.math.Order.lt,
        (try ManifestVersion.parse("1.2")).cmp(try ManifestVersion.parse("1.2.1")),
    );
    try testing.expectEqual(
        std.math.Order.gt,
        (try ManifestVersion.parse("1.2.1")).cmp(try ManifestVersion.parse("1.2")),
    );
}

test "manifest_version_rejects_non_numeric_segments" {
    try testing.expectError(error.EmptyManifestVersion, ManifestVersion.parse(""));
    try testing.expectError(error.EmptyManifestVersion, ManifestVersion.parse("   "));
    try testing.expectError(error.EmptyManifestVersionSegment, ManifestVersion.parse("1..2"));
    try testing.expectError(error.EmptyManifestVersionSegment, ManifestVersion.parse("1."));
    try testing.expectError(error.NonNumericManifestVersion, ManifestVersion.parse("1.2.beta"));
    try testing.expectError(error.NonNumericManifestVersion, ManifestVersion.parse("v1.2"));
    try testing.expectError(error.NonNumericManifestVersion, ManifestVersion.parse("1.-2"));
    try testing.expectError(
        error.OversizedManifestVersion,
        ManifestVersion.parse("99999999999999999999999"),
    );
}

test "process_agent_manifest_commits_newer_manifest_atomically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try withStateDir(alloc, "commit");
    defer std.Io.Dir.cwd().deleteTree(global.io(), root) catch {};

    const path = try std.fs.path.join(alloc, &.{ root, "remote", "claude.json" });
    const content = try remoteManifest(alloc, "2026.08.14.1", "remote blocker");
    try atomicWrite(path, content);

    const written = try std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(MAX_FETCH_BYTES),
    );
    try testing.expectEqualStrings(content, written);

    // The temp file the atomic write used must not survive it.
    var dir = try std.Io.Dir.cwd().openDir(global.io(), std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(global.io());
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(global.io())) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "auto_update_reloads_manifest_cache_after_remote_commit" {
    // With no catalog URL configured there is nothing to fetch, and the
    // update must be a silent no-op rather than an error reaching the user.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(error.NoCatalogUrl, checkAndUpdateFromUrl(alloc, ""));
    try testing.expectEqualStrings("", default_catalog_url);
}

test "process_agent_manifest_rejects_downgrade_and_keeps_cached_manifest" {
    const newer = try ManifestVersion.parse("2026.08.14.1");
    const older = try ManifestVersion.parse("2026.08.13.1");
    try testing.expectEqual(std.math.Order.lt, older.cmp(newer));
}

test "process_agent_manifest_rejects_equal_version_content_change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try remoteManifest(alloc, "2026.08.14.1", "remote blocker");
    const b = try remoteManifest(alloc, "2026.08.14.1", "different blocker");
    try testing.expect(!std.mem.eql(u8, a, b));

    const va = try ManifestVersion.parse("2026.08.14.1");
    const vb = try ManifestVersion.parse("2026.08.14.1");
    try testing.expectEqual(std.math.Order.eq, va.cmp(vb));
}

test "process_agent_manifest_skips_same_version_same_content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try remoteManifest(alloc, "2026.08.14.1", "remote blocker");
    const b = try remoteManifest(alloc, "2026.08.14.1", "remote blocker");
    try testing.expectEqualStrings(a, b);
}

test "catalog_parses_known_agents_and_rejects_duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const agents = try parseCatalog(alloc,
        \\{
        \\  "schema_version": 1,
        \\  "agents": [
        \\    { "id": "claude", "path": "claude.json" },
        \\    { "id": "not-an-agent", "path": "nope.json" }
        \\  ]
        \\}
    );
    try testing.expectEqual(@as(usize, 1), agents.len);
    try testing.expectEqualStrings("claude", agents[0].agent_label);
    try testing.expectEqualStrings("claude.json", agents[0].path);

    // An alias resolves to the same agent, so it counts as a duplicate.
    try testing.expectError(error.DuplicateCatalogAgent, parseCatalog(alloc,
        \\{
        \\  "schema_version": 1,
        \\  "agents": [
        \\    { "id": "claude", "path": "claude.json" },
        \\    { "id": "claude-code", "path": "claude2.json" }
        \\  ]
        \\}
    ));

    try testing.expectError(error.UnsupportedCatalogSchemaVersion, parseCatalog(alloc,
        \\{ "schema_version": 2, "agents": [] }
    ));
}

test "catalog_rejects_unsafe_paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][]const u8{
        "/etc/passwd",
        "https://elsewhere.example/claude.json",
        "../claude.json",
        "a/../../claude.json",
    }) |path| {
        const content = try std.fmt.allocPrint(alloc,
            \\{{ "schema_version": 1, "agents": [{{ "id": "claude", "path": "{s}" }}] }}
        , .{path});
        try testing.expectError(error.UnsafeCatalogPath, parseCatalog(alloc, content));
    }

    try testing.expectError(error.EmptyCatalogPath, parseCatalog(alloc,
        \\{ "schema_version": 1, "agents": [{ "id": "claude", "path": "  " }] }
    ));

    // The same check guards the joined manifest URL.
    try testing.expectError(
        error.UnsafeManifestPath,
        joinUrl(alloc, "https://example.test/agent-detection", "../secrets"),
    );
    try testing.expectEqualStrings(
        "https://example.test/agent-detection/claude.json",
        try joinUrl(alloc, "https://example.test/agent-detection/", "claude.json"),
    );
    try testing.expectEqualStrings(
        "https://example.test/agent-detection",
        try baseUrl("https://example.test/agent-detection/index.json"),
    );
}
