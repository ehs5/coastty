// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

// ported-from: https://github.com/herdrdev/herdr/blob/master/src/detect/mod.rs
//
// This module is coastty's single import surface for agent detection:
// the generic rule engine (`manifest.zig`), Claude's rule set
// (`manifests/claude.zig`), presence identification (`platform.zig`), the
// idle-transition debounce (`pane/agent_detection.zig`), and the per-surface
// `Detector` that ties them together (`pane.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("../lib/main.zig");
const global = @import("../global.zig");
const Pty = @import("../pty.zig").Pty;
const terminal = @import("../terminal/main.zig");

pub const manifest = @import("manifest.zig");
pub const platform = @import("platform.zig");
pub const agent_detection = @import("pane/agent_detection.zig");
const pane_mod = @import("pane.zig");
pub const Detector = pane_mod.Detector;
const ForegroundJob = platform.ForegroundJob;
const ForegroundProcess = platform.ForegroundProcess;

/// The detected state of a terminal pane.
///
/// Sync with: ghostty_agent_state_e
pub const AgentState = enum(c_int) {
    /// Agent finished, prompt visible, nothing happening.
    Idle,
    /// Agent is actively working/processing.
    Working,
    /// Agent needs human input and is blocked on a response.
    Blocked,
    /// Plain shell or unrecognized program.
    Unknown,

    /// The state's name on the wire.
    pub fn name(self: AgentState) []const u8 {
        return switch (self) {
            .Idle => "idle",
            .Working => "working",
            .Blocked => "blocked",
            .Unknown => "unknown",
        };
    }

    pub fn fromName(text: []const u8) ?AgentState {
        for (std.enums.values(AgentState)) |state| {
            if (std.mem.eql(u8, state.name(), text)) return state;
        }
        return null;
    }

    test "ghostty.h AgentState" {
        try lib.checkGhosttyHEnum(AgentState, "GHOSTTY_AGENT_STATE_");
    }
};

/// Screen-derived agent state plus confidence metadata used for source arbitration.
pub const AgentDetection = struct {
    state: AgentState,
    /// Which agent the process probe currently identifies in this pane, if
    /// any. Deliberately separate from `state`: a pane can hold a known
    /// agent whose state is still `Unknown` (the whole startup grace
    /// window), and callers need to show the agent for that entire period.
    ///
    /// ported-from: `detected_agent` on herdr's `TerminalState`, which its
    /// `AgentProcessDetected` event sets independently of the state
    /// (`src/terminal/state.rs`)
    agent: ?Agent = null,
    /// True when the current screen is an agent-owned viewer that shows
    /// transcript/history instead of the live prompt state.
    skip_state_update: bool = false,
    /// True when the current screen visibly shows live idle chrome.
    visible_idle: bool = false,
    /// True when the current screen visibly shows live UI chrome that needs
    /// human input. This is stronger than arbitrary prompt-like text in the
    /// scrollback and may override a non-blocked integration state.
    visible_blocker: bool = false,
    /// True when the current screen visibly shows live working chrome. PTY
    /// activity is the normal working authority; this remains diagnostic
    /// metadata and for non-PTY fallback paths.
    visible_working: bool = false,

    /// The daemon's verdict for a pane it owns, which already folds in
    /// whether the pane has been seen. Set only for those panes, where it
    /// takes the place of the apprt's own seen tracking and recency.
    host: ?HostAttention = null,

    pub const HostAttention = struct {
        attention: AgentStatus,
        recency: u64,
    };

    /// Sync with: ghostty_action_agent_state_change_s
    pub const C = extern struct {
        state: AgentState,
        /// Whether `agent` below holds anything; C has no optional enum.
        has_agent: bool,
        agent: CAgent,
        visible_idle: bool,
        visible_blocker: bool,
        visible_working: bool,
        /// Whether `host_attention` holds the daemon's verdict. Its recency
        /// stays behind on the surface, which answers for it there, so the
        /// action union keeps its size.
        has_host: bool,
        host_attention: AgentStatus,
    };

    pub fn cval(self: AgentDetection) C {
        return .{
            .state = self.state,
            .has_agent = self.agent != null,
            .agent = if (self.agent) |a| a.cval() else .Claude,
            .visible_idle = self.visible_idle,
            .visible_blocker = self.visible_blocker,
            .visible_working = self.visible_working,
            .has_host = self.host != null,
            .host_attention = if (self.host) |h| h.attention else .Unknown,
        };
    }
};

/// `Agent` as it crosses the C API.
///
/// Sync with: ghostty_agent_e
pub const CAgent = enum(c_int) {
    Claude,

    test "ghostty.h CAgent" {
        try lib.checkGhosttyHEnum(CAgent, "GHOSTTY_AGENT_");
    }
};

/// The sidebar/tab-bar's status vocabulary - `AgentState` above folded
/// together with whether the pane has been seen. Only the apprt knows a
/// pane's seen state, so this module never derives `AgentStatus` itself; a
/// caller reports the status it already computed via `StatusRecency.note`
/// and reads its ranking back via `priority`.
///
/// ported-from: `AgentStatus` in herdr's `src/api/schema/common.rs`
///
/// Sync with: ghostty_agent_status_e
pub const AgentStatus = enum(c_int) {
    Idle,
    Working,
    Blocked,
    Done,
    Unknown,

    test "ghostty.h AgentStatus" {
        try lib.checkGhosttyHEnum(AgentStatus, "GHOSTTY_AGENT_STATUS_");
    }

    /// How pressing this status is for picking which one to show or sort
    /// first - higher is more pressing.
    ///
    /// ported-from: `status_priority` in
    /// https://github.com/herdrdev/herdr/blob/master/src/client/shell.rs
    pub fn priority(self: AgentStatus) u8 {
        return switch (self) {
            .Blocked => 4,
            .Done => 3,
            .Working => 2,
            .Idle => 1,
            .Unknown => 0,
        };
    }

    /// The attention state's name on the wire, in CONTEXT.md's vocabulary.
    pub fn name(self: AgentStatus) []const u8 {
        return switch (self) {
            .Idle => "idle",
            .Working => "working",
            .Blocked => "blocked",
            .Done => "done",
            .Unknown => "unknown",
        };
    }

    pub fn fromName(text: []const u8) ?AgentStatus {
        for (std.enums.values(AgentStatus)) |status| {
            if (std.mem.eql(u8, status.name(), text)) return status;
        }
        return null;
    }

    /// Folds a detected state with whether the pane has been seen: idle and
    /// not yet looked at is "done", idle and seen is plain idle, and the
    /// rest do not depend on it.
    ///
    /// ported-from: `pane_agent_status` in
    /// https://github.com/herdrdev/herdr/blob/master/src/app/api_helpers.rs
    pub fn fromState(state: AgentState, seen: bool) AgentStatus {
        return switch (state) {
            .Blocked => .Blocked,
            .Working => .Working,
            .Idle => if (seen) .Idle else .Done,
            .Unknown => .Unknown,
        };
    }
};

/// Whether a pane counts as seen once its state has moved from `previous`
/// to `next`.
///
/// Anything but idle leaves nothing to acknowledge, so it is seen. A finish
/// - working or blocked settling to idle - is seen only if someone was
/// looking at the pane when it happened. Any other move keeps what was
/// there before.
///
/// ported-from: the seen handling in `apply_pane_state_change`,
/// https://github.com/herdrdev/herdr/blob/master/src/app/actions.rs
pub fn seenAfterStateChange(previous: AgentState, next: AgentState, was_seen: bool, viewed: bool) bool {
    if (next != .Idle) return true;
    if (previous == .Working or previous == .Blocked) return viewed;
    return was_seen;
}

/// The OSC 9;4 progress state in the raw ConEmu form (`4;<state>[;<percent>]`)
/// Claude's rules match against. The terminal parses it into a structured
/// report and keeps no original string, so it is rebuilt here into `buf`.
pub fn formatOscProgress(buf: []u8, report: ?terminal.osc.Command.ProgressReport) []const u8 {
    const r = report orelse return "";
    var writer: std.Io.Writer = .fixed(buf);
    writer.print("4;{d}", .{@intFromEnum(r.state)}) catch return "";
    if (r.progress) |p| writer.print(";{d}", .{p}) catch return "";
    return writer.buffered();
}

/// Per-pane recency bookkeeping for `AgentStatus`. `change_seq` only
/// advances on a genuine change from what was last recorded, stamped from a
/// sequence shared across every pane so recency compares meaningfully
/// across them.
///
/// ported-from: the `next_agent_state_change_seq` bump in
/// `apply_pane_state_change`, https://github.com/herdrdev/herdr/blob/master/src/app/actions.rs
pub const StatusRecency = struct {
    // Shared across every pane, mirroring herdr's single
    // `next_agent_state_change_seq` field on `AppState`.
    var next_seq = std.atomic.Value(u64).init(0);

    last_status: ?AgentStatus = null,
    change_seq: u64 = 0,

    pub fn note(self: *StatusRecency, status: AgentStatus) void {
        if (self.last_status) |last| {
            if (last == status) return;
        }
        self.last_status = status;
        self.change_seq = next();
    }

    /// The next value of the shared counter. For anything else that has to
    /// order against recency on the same scale, such as when a pane's
    /// state last changed.
    pub fn next() u64 {
        return next_seq.fetchAdd(1, .monotonic) + 1;
    }
};

test "AgentStatus: priority matches herdr's status_priority ordering" {
    try testing.expect(AgentStatus.Blocked.priority() > AgentStatus.Done.priority());
    try testing.expect(AgentStatus.Done.priority() > AgentStatus.Working.priority());
    try testing.expect(AgentStatus.Working.priority() > AgentStatus.Idle.priority());
    try testing.expect(AgentStatus.Idle.priority() > AgentStatus.Unknown.priority());
}

test "StatusRecency: only a genuine change advances the recency stamp" {
    var r: StatusRecency = .{};
    try testing.expectEqual(@as(u64, 0), r.change_seq);

    r.note(.Working);
    const first = r.change_seq;
    try testing.expect(first != 0);

    // Same status reported again: no-op.
    r.note(.Working);
    try testing.expectEqual(first, r.change_seq);

    // A genuine change bumps forward.
    r.note(.Idle);
    try testing.expect(r.change_seq > first);
}

test "AgentStatus.fromState: idle is done until seen" {
    try testing.expectEqual(AgentStatus.Done, AgentStatus.fromState(.Idle, false));
    try testing.expectEqual(AgentStatus.Idle, AgentStatus.fromState(.Idle, true));
    try testing.expectEqual(AgentStatus.Working, AgentStatus.fromState(.Working, false));
    try testing.expectEqual(AgentStatus.Blocked, AgentStatus.fromState(.Blocked, false));
    try testing.expectEqual(AgentStatus.Unknown, AgentStatus.fromState(.Unknown, false));
}

test "names round-trip, so the daemon and the app agree on every wire word" {
    for (std.enums.values(AgentState)) |state| try testing.expectEqual(state, AgentState.fromName(state.name()).?);
    for (std.enums.values(AgentStatus)) |status| try testing.expectEqual(status, AgentStatus.fromName(status.name()).?);
    for (Agent.ALL) |agent| try testing.expectEqual(agent, Agent.fromLabel(agent.agentLabel()).?);
}

test "seenAfterStateChange: a finish is seen only if someone was looking" {
    try testing.expect(!seenAfterStateChange(.Working, .Idle, true, false));
    try testing.expect(seenAfterStateChange(.Working, .Idle, false, true));
    try testing.expect(!seenAfterStateChange(.Blocked, .Idle, true, false));
}

test "seenAfterStateChange: anything but idle is seen, other moves keep what was there" {
    try testing.expect(seenAfterStateChange(.Idle, .Working, false, false));
    try testing.expect(seenAfterStateChange(.Unknown, .Blocked, false, false));
    try testing.expect(seenAfterStateChange(.Unknown, .Idle, true, false));
    try testing.expect(!seenAfterStateChange(.Unknown, .Idle, false, false));
}

test "formatOscProgress: rebuilds the raw form the rules match against" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("", formatOscProgress(&buf, null));
    try testing.expectEqualStrings("4;1;40", formatOscProgress(&buf, .{ .state = .set, .progress = 40 }));
    try testing.expectEqualStrings("4;0", formatOscProgress(&buf, .{ .state = .remove, .progress = null }));
}

test "StatusRecency: the sequence is shared across panes" {
    var a: StatusRecency = .{};
    var b: StatusRecency = .{};

    a.note(.Working);
    b.note(.Blocked);
    try testing.expect(b.change_seq > a.change_seq);
}

/// Which agent we detected running in a pane.
pub const Agent = enum {
    //Pi,
    Claude,
    //Codex,
    //Gemini,
    //Cursor,
    //Devin,
    //Antigravity,
    //Cline,
    //Omp,
    //Mastracode,
    //OpenCode,
    //GithubCopilot,
    //Kimi,
    //Kiro,
    //Droid,
    //Amp,
    //Grok,
    //Hermes,
    //Kilo,
    //Qodercli,
    //Qwen,
    //Maki,

    const Self = @This();

    // Grabs all the defined variants and puts them in a list
    pub const ALL = std.enums.values(Self);

    pub const SCREEN_MANIFEST_AGENTS = [_]Self{
        //.Pi,
        .Claude,
        //.Codex,
        //.Gemini,
        //.Cursor,
        //.Devin,
        //.Antigravity,
        //.Cline,
        //.OpenCode,
        //.GithubCopilot,
        //.Kimi,
        //.Kiro,
        //.Droid,
        //.Amp,
        //.Grok,
        //.Hermes,
        //.Kilo,
        //.Qodercli,
        //.Qwen,
        //.Maki,
    };

    pub fn agentLabel(self: Agent) []const u8 {
        return switch (self) {
            //.pi => "pi",
            .Claude => "claude",
            //.codex => "codex",
            //.gemini => "gemini",
            //.cursor => "cursor",
            //.devin => "devin",
            //.antigravity => "agy", // Custom label
            //.cline => "cline",
            //.omp => "omp",
            //.mastracode => "mastracode",
            //.open_code => "opencode",
            //.github_copilot => "copilot", // Custom label
            //.kimi => "kimi",
            //.kiro => "kiro",
            //.droid => "droid",
            //.amp => "amp",
            //.grok => "grok",
            //.hermes => "hermes",
            //.kilo => "kilo",
            //.qodercli => "qodercli",
            //.qwen => "qwen",
            //.maki => "maki",
        };
    }

    /// The executable name to launch this agent interactively.
    ///
    /// ported-from: `interactive_agent_executable` in
    /// https://github.com/herdrdev/herdr/blob/master/src/detect/mod.rs
    /// (its Windows-specific `cursor-agent.cmd` branch doesn't apply here -
    /// Cursor isn't in this build, and coastty is macOS-only besides)
    pub fn interactiveExecutable(self: Agent) []const u8 {
        return switch (self) {
            .Claude => "claude",
        };
    }

    pub fn cval(self: Agent) CAgent {
        return switch (self) {
            .Claude => .Claude,
        };
    }

    pub fn fromLabel(label: []const u8) ?Agent {
        for (ALL) |agent| {
            if (std.mem.eql(u8, agent.agentLabel(), label)) return agent;
        }
        return null;
    }
};

pub fn interactiveAgentExecutable(agent: Agent) []const u8 {
    return agent.interactiveExecutable();
}

/// Integrations whose hooks cover the agent's whole lifecycle, so their
/// reported state is authoritative and screen detection is skipped entirely
/// for that pane.
///
/// Claude is deliberately absent: its hooks emit no event for the outcome of
/// a permission prompt or for Esc, so hook authority would latch a pane in a
/// stale state with no fallback. Claude's hooks are session-identity only.
const full_lifecycle_hook_authorities = [_]struct { source: []const u8, agent_label: []const u8 }{
    // herdr's list is pi, omp, mastracode, opencode, kilo, and kimi - none of
    // which are in coastty's `Agent` yet.
};

/// Integrations that report session identity (id, transcript path) but leave
/// state to screen detection.
const session_identity_only_integrations = [_]struct { source: []const u8, agent_label: []const u8 }{
    // herdr's list is hermes, qwen, and antigravity_cli.
};

pub fn fullLifecycleHookAuthority(source: []const u8, agent_label: []const u8) bool {
    for (full_lifecycle_hook_authorities) |entry| {
        if (std.mem.eql(u8, entry.source, source) and
            std.mem.eql(u8, entry.agent_label, agent_label)) return true;
    }
    return false;
}

pub fn sessionIdentityOnlyIntegration(source: []const u8, agent_label: []const u8) bool {
    for (session_identity_only_integrations) |entry| {
        if (std.mem.eql(u8, entry.source, source) and
            std.mem.eql(u8, entry.agent_label, agent_label)) return true;
    }
    return false;
}

pub const claude_label = "claude";

pub fn foregroundJob(alloc: Allocator, child_pid: u32) ?ForegroundJob {
    return platform.foregroundJob(alloc, child_pid);
}

/// The foreground process group leader as a one-process job. Cheaper than
/// collecting every process in the foreground job.
pub fn foregroundGroupLeaderJob(alloc: Allocator, process_group_id: u32) ?ForegroundJob {
    return platform.foregroundGroupLeaderJob(alloc, process_group_id);
}

pub fn foregroundProcessGroupId(child_pid: u32) ?u32 {
    return platform.foregroundProcessGroupId(child_pid);
}

pub fn identifyClaude(alloc: Allocator, job: ForegroundJob) !bool {
    return (try identifyAgentInJob(alloc, job)) != null;
}

pub fn identifyAgentInJob(alloc: Allocator, job: ForegroundJob) !?[]const u8 {
    for (job.processes) |proc| {
        if (proc.pid != job.process_group_id) continue;
        const candidate = try normalizedProcessName(alloc, proc);
        if (identifyAgent(alloc, candidate) catch false) return candidate;
        break;
    }

    var best: ?[]const u8 = null;
    var best_score: u8 = 0;
    for (job.processes) |proc| {
        const candidate = try normalizedProcessName(alloc, proc);
        if (!(identifyAgent(alloc, candidate) catch false)) continue;
        const score = try processPriority(alloc, proc, candidate);
        if (best != null and best_score >= score) continue;
        best = candidate;
        best_score = score;
    }
    return best;
}

fn identifyAgent(alloc: Allocator, name: []const u8) !bool {
    return (try parseAgentLabel(alloc, name)) != null;
}

pub fn parseAgentLabel(alloc: Allocator, name: []const u8) !?[]const u8 {
    const normalized = try normalizedAgentLookupName(alloc, name);
    return lookupAgent(normalized);
}

/// True only when `label` is already an agent's canonical label - an alias
/// like "claude-code" does not qualify, and neither does anything needing
/// normalization first.
fn parseCanonicalAgentLabel(label: []const u8) bool {
    const agent = lookupAgent(label) orelse return false;
    return std.mem.eql(u8, agent, label);
}

/// The `Agent` an executable name or label resolves to. `parseAgentLabel`
/// answers with the canonical label; callers that need the enum go through
/// here.
pub fn agentFromLabel(alloc: Allocator, name: []const u8) !?Agent {
    const label = (try parseAgentLabel(alloc, name)) orelse return null;
    for (Agent.ALL) |agent| {
        if (std.mem.eql(u8, agent.agentLabel(), label)) return agent;
    }
    return null;
}

/// Canonical label for a normalized executable name, including each agent's
/// accepted aliases. Claude's aliases are "claude" and "claude-code".
fn lookupAgent(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "claude") or std.mem.eql(u8, name, "claude-code")) {
        return claude_label;
    }
    return null;
}

/// Detect the state of an agent from the live terminal tail snapshot.
/// `null` agent means the pane isn't running a recognized agent.
pub fn detectState(alloc: Allocator, agent: ?Agent, screen_content: []const u8) !AgentState {
    return (try detectAgent(alloc, agent, screen_content)).state;
}

pub fn detectAgent(alloc: Allocator, agent: ?Agent, screen_content: []const u8) !AgentDetection {
    return detectAgentWithOsc(alloc, agent, screen_content, "", "");
}

pub fn detectAgentWithOsc(
    alloc: Allocator,
    agent: ?Agent,
    screen_content: []const u8,
    osc_title: []const u8,
    osc_progress: []const u8,
) !AgentDetection {
    const a = agent orelse return .{ .state = .Unknown };
    return manifest.detectWithOsc(alloc, a, .{
        .screen = screen_content,
        .osc_title = osc_title,
        .osc_progress = osc_progress,
    });
}

pub fn shouldSkipStateUpdate(alloc: Allocator, agent: ?Agent, screen_content: []const u8) bool {
    const a = agent orelse return false;
    return manifest.shouldSkipStateUpdate(alloc, a, screen_content);
}

fn normalizedAgentLookupName(alloc: Allocator, name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n\x0b\x0c");
    const lower = try std.ascii.allocLowerString(alloc, trimmed);
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".ps1", ".js" }) |suffix| {
        if (std.mem.endsWith(u8, lower, suffix)) return lower[0 .. lower.len - suffix.len];
    }
    return lower;
}

fn pathBasename(path: []const u8) []const u8 {
    var it = std.mem.splitBackwardsAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (component.len > 0) return component;
    }
    return path;
}

fn isPythonRuntime(name: []const u8) bool {
    if (std.mem.eql(u8, name, "python")) return true;
    if (!std.mem.startsWith(u8, name, "python")) return false;
    const version = name["python".len..];
    if (version.len == 0) return false;
    var it = std.mem.splitScalar(u8, version, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isGenericRuntimeOrShell(alloc: Allocator, name: []const u8) !bool {
    const normalized = try normalizedAgentLookupName(alloc, pathBasename(name));
    if (isPythonRuntime(normalized)) return true;
    for ([_][]const u8{ "sh", "bash", "zsh", "fish", "tmux", "node", "bun", "cmd", "powershell", "pwsh" }) |candidate| {
        if (std.mem.eql(u8, normalized, candidate)) return true;
    }
    return false;
}

fn processPriority(alloc: Allocator, proc: ForegroundProcess, normalized_name: []const u8) !u8 {
    const lower_name = try std.ascii.allocLowerString(alloc, normalized_name);
    const lower_proc_name = try std.ascii.allocLowerString(alloc, proc.name);
    if (!std.mem.eql(u8, lower_name, lower_proc_name)) return 3;
    if (!try isGenericRuntimeOrShell(alloc, lower_name)) return 2;
    return 1;
}

fn normalizedProcessName(alloc: Allocator, proc: ForegroundProcess) ![]const u8 {
    const effective = proc.argv0 orelse proc.name;
    const lower_effective = try std.ascii.allocLowerString(alloc, effective);

    if (try isGenericRuntimeOrShell(alloc, lower_effective)) {
        if (try wrappedAgentNameFromRuntimeArgv(alloc, lower_effective, proc.argv)) |wrapped| {
            return wrapped;
        }
    }

    if (try identifyAgent(alloc, effective)) return effective;

    // herdr has a fourth branch here that re-probes argv[0] for a node/bun
    // runtime, but it only returns when the wrapped name resolves to Qwen.
    // Coastty has no Qwen variant, so the branch could never fire. Restore it
    // alongside the `Agent` entry, not before.

    if (try argv0AgentName(alloc, proc.argv)) |wrapped| return wrapped;
    if (try cmdlineArgv0AgentName(alloc, proc.cmdline orelse "")) |wrapped| return wrapped;

    return effective;
}

fn wrappedAgentNameFromRuntimeArgv(alloc: Allocator, runtime: []const u8, argv: ?[]const []const u8) !?[]const u8 {
    const av = argv orelse return null;
    const runtime_name = try normalizedAgentLookupName(alloc, pathBasename(runtime));

    if (std.mem.eql(u8, runtime_name, "node") or std.mem.eql(u8, runtime_name, "bun")) {
        return scriptArgAgentName(alloc, av, &.{ "-e", "--eval", "-p", "--print" }, &.{});
    }
    if (isPythonRuntime(runtime_name)) {
        return scriptArgAgentName(alloc, av, &.{"-c"}, &.{"-m"});
    }
    if (std.mem.eql(u8, runtime_name, "sh") or std.mem.eql(u8, runtime_name, "bash") or
        std.mem.eql(u8, runtime_name, "zsh") or std.mem.eql(u8, runtime_name, "fish"))
    {
        return scriptArgAgentName(alloc, av, &.{"-c"}, &.{});
    }
    if (std.mem.eql(u8, runtime_name, "cmd")) return windowsCmdArgAgentName(alloc, av);
    if (std.mem.eql(u8, runtime_name, "powershell") or std.mem.eql(u8, runtime_name, "pwsh")) {
        return powershellArgAgentName(alloc, av);
    }
    return null;
}

fn scriptArgAgentName(
    alloc: Allocator,
    argv: []const []const u8,
    eval_flags: []const []const u8,
    module_flags: []const []const u8,
) !?[]const u8 {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < argv.len) return agentNameFromPathToken(alloc, argv[i + 1]);
            return null;
        }
        if (flagMatches(arg, eval_flags) or flagMatches(arg, module_flags)) return null;
        if (arg.len > 0 and arg[0] == '-') {
            if (optionTakesValue(arg)) i += 1;
            continue;
        }
        return agentNameFromPathToken(alloc, arg);
    }
    return null;
}

fn flagMatches(arg: []const u8, flags: []const []const u8) bool {
    for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag) or shortFlagPayload(arg, flag) or longFlagValue(arg, flag)) {
            return true;
        }
    }
    return false;
}

fn shortFlagPayload(arg: []const u8, flag: []const u8) bool {
    return flag.len > 0 and flag[0] == '-' and !std.mem.startsWith(u8, flag, "--") and
        std.mem.startsWith(u8, arg, flag) and arg.len > flag.len;
}

fn longFlagValue(arg: []const u8, flag: []const u8) bool {
    if (!std.mem.startsWith(u8, flag, "--")) return false;
    if (!std.mem.startsWith(u8, arg, flag)) return false;
    const tail = arg[flag.len..];
    return tail.len > 0 and tail[0] == '=';
}

fn optionTakesValue(arg: []const u8) bool {
    for ([_][]const u8{
        "-r",                    "--require",      "--loader", "--import",
        "--experimental-loader", "--inspect-port", "-W",       "-X",
        "-S",                    "-L",             "-o",
    }) |candidate| {
        if (std.mem.eql(u8, arg, candidate)) return true;
    }
    return false;
}

fn argv0AgentName(alloc: Allocator, argv: ?[]const []const u8) !?[]const u8 {
    const av = argv orelse return null;
    if (av.len == 0) return null;
    return agentNameFromPathToken(alloc, av[0]);
}

fn cmdlineArgv0AgentName(alloc: Allocator, cmdline: []const u8) !?[]const u8 {
    var it = std.mem.tokenizeAny(u8, cmdline, " \t\r\n\x0b\x0c");
    const first = it.next() orelse return null;
    return agentNameFromPathToken(alloc, first);
}

fn agentNameFromPathToken(alloc: Allocator, token: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, token, "\"'");
    if (trimmed.len == 0 or trimmed[0] == '-') return null;

    if (try agentNameFromBasename(alloc, pathBasename(trimmed))) |name| return name;
    if (try agentNameFromKnownPackagePath(alloc, trimmed)) |name| return name;
    return try resolvedAgentNameFromPathToken(alloc, trimmed);
}

fn agentNameFromBasename(alloc: Allocator, basename: []const u8) !?[]const u8 {
    return parseAgentLabel(alloc, basename);
}

fn resolvedAgentNameFromPathToken(alloc: Allocator, token: []const u8) !?[]const u8 {
    if (std.fs.path.dirname(token) == null) return null;

    const resolved = std.Io.Dir.cwd().realPathFileAlloc(global.io(), token, alloc) catch return null;
    const basename = std.fs.path.basename(resolved);
    if (basename.len == 0) return null;
    return agentNameFromBasename(alloc, basename);
}

/// A package-internal entry point whose basename doesn't carry the agent's
/// name - matched as a run of consecutive path components.
const KnownPackagePath = struct {
    components: []const []const u8,
    label: []const u8,
};

/// Only the package's own entry point counts - a sibling script under the
/// same package (`scripts/build.js`) must not read as the agent.
///
/// herdr's table covers Pi, Qwen, and Mastracode; those land back here as
/// soon as those agents join `Agent`.
const known_package_paths = [_]KnownPackagePath{
    .{
        .components = &.{ "node_modules", "@anthropic-ai", "claude-code", "cli" },
        .label = claude_label,
    },
};

fn agentNameFromKnownPackagePath(alloc: Allocator, path: []const u8) !?[]const u8 {
    var components: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (component.len == 0) continue;
        try components.append(alloc, try normalizedAgentLookupName(alloc, component));
    }

    for (known_package_paths) |candidate| {
        const width = candidate.components.len;
        if (components.items.len < width) continue;
        var start: usize = 0;
        while (start + width <= components.items.len) : (start += 1) {
            const window = components.items[start .. start + width];
            const matched = for (window, candidate.components) |actual, expected| {
                if (!std.mem.eql(u8, actual, expected)) break false;
            } else true;
            if (matched) return candidate.label;
        }
    }
    return null;
}

/// The agent name from a free-form command string, skipping the shell noise
/// (`&`, `.`, `call`) that `cmd.exe` and PowerShell put in front of the
/// program being invoked.
fn commandTextAgentName(alloc: Allocator, command: []const u8) !?[]const u8 {
    var rest = command;
    while (commandTextToken(rest)) |split| {
        const token = trimAsciiWhitespace(split.token);
        if (std.ascii.eqlIgnoreCase(token, "&") or
            std.ascii.eqlIgnoreCase(token, ".") or
            std.ascii.eqlIgnoreCase(token, "call"))
        {
            rest = split.rest;
            continue;
        }
        return agentNameFromPathToken(alloc, token);
    }
    return null;
}

/// Split off the first token, honoring single and double quotes. An
/// unterminated quote takes the rest of the input.
fn commandTextToken(input: []const u8) ?struct { token: []const u8, rest: []const u8 } {
    const trimmed = std.mem.trimStart(u8, input, " \t\r\n\x0b\x0c");
    if (trimmed.len == 0) return null;

    const first = trimmed[0];
    if (first == '"' or first == '\'') {
        const body = trimmed[1..];
        const end = std.mem.indexOfScalar(u8, body, first) orelse
            return .{ .token = body, .rest = "" };
        return .{ .token = body[0..end], .rest = body[end + 1 ..] };
    }

    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n\x0b\x0c") orelse trimmed.len;
    return .{ .token = trimmed[0..end], .rest = trimmed[end..] };
}

fn trimAsciiWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

fn eqlIgnoreCaseAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

/// `cmd.exe /c <command text>`. coastty is a macOS-only build so this is
/// unreachable today, but it's pure string handling and the pane's argv
/// arrives in exactly the same shape on any platform.
fn windowsCmdArgAgentName(alloc: Allocator, argv: []const []const u8) !?[]const u8 {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const flag = std.mem.trim(u8, argv[i], "\"");
        if (eqlIgnoreCaseAny(flag, &.{ "/c", "/k" })) {
            if (i + 1 >= argv.len) return null;
            return commandTextAgentName(alloc, argv[i + 1]);
        }
        if (eqlIgnoreCaseAny(flag, &.{
            "/d",     "/s",     "/q",    "/a",     "/u",
            "/e:on",  "/e:off", "/f:on", "/f:off", "/v:on",
            "/v:off",
        })) continue;
    }
    return null;
}

/// `powershell -Command <command text>` / `-File <script>`. See
/// `windowsCmdArgAgentName`.
fn powershellArgAgentName(alloc: Allocator, argv: []const []const u8) !?[]const u8 {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const flag = std.mem.trim(u8, argv[i], "\"");
        if (eqlIgnoreCaseAny(flag, &.{ "-file", "-f", "/file" })) {
            if (i + 1 >= argv.len) return null;
            return agentNameFromPathToken(alloc, argv[i + 1]);
        }
        if (eqlIgnoreCaseAny(flag, &.{ "-command", "-c", "/command", "/c" })) {
            if (i + 1 >= argv.len) return null;
            return commandTextAgentName(alloc, argv[i + 1]);
        }
        if (eqlIgnoreCaseAny(flag, &.{ "-encodedcommand", "-enc", "/encodedcommand", "/enc" })) {
            return null;
        }
        if (eqlIgnoreCaseAny(flag, &.{
            "-configurationname", "-executionpolicy", "-outputformat",
            "-psconsolefile",     "-version",         "-windowstyle",
            "-workingdirectory",
        })) {
            i += 1;
            continue;
        }
        if (flag.len > 0 and (flag[0] == '-' or flag[0] == '/')) continue;
        return agentNameFromPathToken(alloc, argv[i]);
    }
    return null;
}

test {
    _ = manifest;
    _ = platform;
    _ = agent_detection;
    _ = pane_mod;
}

test "Agent.interactiveExecutable matches Agent.agentLabel for Claude" {
    try std.testing.expectEqualStrings(Agent.Claude.agentLabel(), Agent.Claude.interactiveExecutable());
}

const testing = std.testing;

fn foregroundProcess(alloc: Allocator, pid: u32, name: []const u8, argv: []const []const u8) !ForegroundProcess {
    return .{
        .pid = pid,
        .name = name,
        .argv0 = null,
        .argv = argv,
        .cmdline = try std.mem.join(alloc, " ", argv),
    };
}

test "identify_agent_in_job: recognizes a direct claude process as the group leader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 42,
        .processes = &.{try foregroundProcess(arena.allocator(), 42, "claude", &.{"claude"})},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_prefers_recognized_process_group_leader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 42,
        .processes = &.{
            try foregroundProcess(arena.allocator(), 42, "claude", &.{"claude"}),
            try foregroundProcess(arena.allocator(), 43, "node", &.{ "node", "/tmp/mcp/bin/other-tool" }),
        },
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_falls_back_when_process_group_leader_is_unrecognized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 42,
        .processes = &.{
            try foregroundProcess(arena.allocator(), 42, "bash", &.{"bash"}),
            try foregroundProcess(arena.allocator(), 43, "node", &.{ "node", "/tmp/mcp/bin/claude" }),
        },
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_node_wrapped_qwen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "node", &.{ "node", "/path/to/bin/claude" })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_bun_wrapped_omp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "bun", &.{ "bun", "/home/user/.bun/bin/claude" })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_python_version_wrapped_hermes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "python3.12", &.{
            "/nix/store/example/bin/python3.12",
            "/nix/store/example/bin/claude",
            "--resume",
            "session-id",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_shell_wrapped_pi" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "sh", &.{ "/bin/sh", "/tmp/test-bin/claude" })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "wrapped_agent_name_from_runtime_argv_ignores_plain_shell_flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try wrappedAgentNameFromRuntimeArgv(arena.allocator(), "bash", &.{ "bash", "-lc" });
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "identify_agent_in_job_canonicalizes_nix_wrapped_aliases_from_cmdline_argv0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{.{
            .pid = 1,
            .name = ".claude-code-wrapped",
            .argv0 = null,
            .argv = &.{"/nix/store/example/bin/claude-code"},
            .cmdline = "/nix/store/example/bin/claude-code",
        }},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_ignores_python_c_argument_named_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "python3", &.{ "python3", "-c", "import time; time.sleep(60)", "/tmp/claude" })},
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_agent_in_job_ignores_node_eval_argument_named_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "node", &.{ "node", "-e", "setTimeout(() => {}, 60000)", "/tmp/claude" })},
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_agent_in_job_ignores_shell_c_argument_named_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "bash", &.{ "bash", "-c", "sleep 60", "/tmp/claude" })},
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_agent_in_job_detects_python_script_named_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "python3", &.{ "python3", "/tmp/claude", "--resume" })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_unknown_processes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{
            try foregroundProcess(arena.allocator(), 1, "bash", &.{"bash"}),
            try foregroundProcess(arena.allocator(), 2, "vim", &.{"vim"}),
        },
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_case_insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "CLAUDE", &.{"CLAUDE"})},
    };
    try testing.expectEqualStrings("CLAUDE", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job: claude-code alias identifies as claude, preserving the raw alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 1,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "claude-code", &.{"claude-code"})},
    };
    try testing.expectEqualStrings("claude-code", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_resolves_cursor_agent_symlink_argv0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "claude", .data = "#!/bin/sh\n" });
    try tmp.dir.symLink(std.testing.io, "claude", "agent-link", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const link_path = try std.fs.path.join(arena.allocator(), &.{ dir_path, "agent-link" });

    const job = ForegroundJob{
        .process_group_id = 42,
        .processes = &.{.{
            .pid = 42,
            .name = "MainThread",
            .argv0 = null,
            .argv = &.{ link_path, "--flag", "/tmp/index.js" },
            .cmdline = link_path,
        }},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "canonical_agent_labels_are_strict" {
    try testing.expect(parseCanonicalAgentLabel("claude"));
    try testing.expect(!parseCanonicalAgentLabel("claude-code"));
    try testing.expect(!parseCanonicalAgentLabel("Claude"));
    try testing.expect(!parseCanonicalAgentLabel(" claude "));
}

/// A unique temp path for a test that needs to write a file on disk.
fn tempDetectionPath(alloc: Allocator, name: []const u8) ![]const u8 {
    const unique = try std.fmt.allocPrint(alloc, "coastty-detect-tests-{s}-{d}", .{
        name,
        std.Io.Timestamp.now(global.io(), .real).nanoseconds,
    });
    return std.fs.path.join(alloc, &.{ "/tmp", unique });
}

/// A pty pair for the process-identification tests, which need a real
/// controlling terminal to have a foreground process group at all.
fn openTestPty() !Pty {
    return Pty.open(.{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 });
}

/// Spawn `argv` on `pty`'s slave side in its own session, so it owns the
/// pty's foreground process group the way a real pane's child does.
fn spawnOnPty(pty: Pty, argv: [*:null]const ?[*:0]const u8) !platform.Pid {
    return platform.testing_support.spawnSessionLeader(pty.slave, argv);
}

fn reapChild(pid: platform.Pid) void {
    platform.testing_support.killAndReap(pid);
}

fn sleepMs(ms: u64) void {
    platform.testing_support.sleepMs(ms);
}

/// Retry `foregroundJob` until the spawned child has actually taken over the
/// pty's foreground group - spawn is asynchronous, so a single fixed sleep
/// makes the process-identification tests flaky under load.
fn awaitForegroundJob(alloc: Allocator, child_pid: u32, name: []const u8) ?ForegroundJob {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (foregroundJob(alloc, child_pid)) |job| {
            for (job.processes) |p| {
                if (std.mem.eql(u8, p.name, name)) return job;
            }
        }
        sleepMs(10);
    }
    return null;
}

test "moved_agent_detection_routes_through_production_dispatch" {
    // Claude has no plain-text working rule (its working signal is the OSC
    // title), so a blocker screen is what proves this reaches the manifest
    // engine rather than a local shortcut.
    const screen = "do you want to proceed?\n" ++
        "bash command: rm -rf /tmp/test\n" ++
        "❯ 1. Yes\n   2. No\n\n" ++
        "Esc to cancel · Tab to amend · ctrl+e to explain\n";
    const d = try detectAgent(testing.allocator, .Claude, screen);
    try testing.expectEqual(AgentState.Blocked, d.state);
    try testing.expect(d.visible_blocker);
}

test "identify_known_agents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][]const u8{ "claude", "claude-code", "Claude", "CLAUDE", "claude.exe", "Claude-Code" }) |name| {
        try testing.expect(try identifyAgent(alloc, name));
    }
    for ([_][]const u8{ "bash", "vim", "claude-helper", "my-claude", "" }) |name| {
        try testing.expect(!try identifyAgent(alloc, name));
    }
}

test "parse_known_agent_labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][]const u8{ "claude", "claude-code", "CLAUDE-CODE", "claude.cmd", "claude.js" }) |label| {
        try testing.expectEqualStrings("claude", (try parseAgentLabel(alloc, label)).?);
    }
    try testing.expectEqual(@as(?[]const u8, null), try parseAgentLabel(alloc, "claude-codex"));
}

test "every_agent_label_round_trips_through_canonical_and_alias_parsers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for (Agent.ALL) |agent| {
        const label = agent.agentLabel();
        try testing.expect(parseCanonicalAgentLabel(label));
        try testing.expectEqualStrings(label, (try parseAgentLabel(alloc, label)).?);
    }
}

test "every_agent_has_a_canonical_interactive_executable" {
    const expected = [_]struct { agent: Agent, executable: []const u8 }{
        .{ .agent = .Claude, .executable = "claude" },
    };
    try testing.expectEqual(expected.len, Agent.ALL.len);
    for (expected) |entry| {
        try testing.expectEqualStrings(entry.executable, interactiveAgentExecutable(entry.agent));
    }
}

test "mastracode_is_hook_authority_without_screen_manifest" {
    // The inverse of herdr's assertion, and the reason this port exists:
    // Claude is deliberately *not* a hook authority, so it must carry a
    // screen manifest.
    try testing.expect(!fullLifecycleHookAuthority("coastty:claude", Agent.Claude.agentLabel()));
    try testing.expect(std.mem.indexOfScalar(Agent, &Agent.SCREEN_MANIFEST_AGENTS, .Claude) != null);
}

test "session_identity_integrations_leave_state_to_screen_detection" {
    // Claude's own hook integration is session-identity only, so it must
    // leave state to screen detection.
    const label = Agent.Claude.agentLabel();
    try testing.expect(!fullLifecycleHookAuthority("coastty:claude", label));
    try testing.expect(std.mem.indexOfScalar(Agent, &Agent.SCREEN_MANIFEST_AGENTS, .Claude) != null);
}

test "identify_agent_in_job_prefers_wrapped_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{
            try foregroundProcess(arena.allocator(), 1, "node", &.{ "node", "/path/to/bin/claude" }),
            try foregroundProcess(arena.allocator(), 2, "bash", &.{"bash"}),
        },
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_nix_wrapped_codex_from_cmdline_argv0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, ".claude-wrapped", &.{
            "/etc/profiles/per-user/user/bin/claude",
            "--model",
            "opus",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_node_wrapped_pi_package_cli" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "node.exe", &.{
            "node.exe",
            "C:\\Users\\coastty\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_node_wrapped_mastracode_package_cli" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "node", &.{
            "node",
            "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_ignores_non_cli_pi_package_script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "node", &.{
            "node",
            "/usr/local/lib/node_modules/@anthropic-ai/claude-code/scripts/build.js",
        })},
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_agent_in_job_detects_windows_cmd_wrapped_codex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "cmd.exe", &.{
            "cmd.exe",
            "/D",
            "/S",
            "/C",
            "C:\\Users\\coastty\\AppData\\Roaming\\npm\\claude.cmd --model opus",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_powershell_file_wrapped_claude" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "powershell.exe", &.{
            "powershell.exe",
            "-NoProfile",
            "-File",
            "C:\\Users\\coastty\\Documents\\PowerShell\\Scripts\\claude.ps1",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_ignores_herdr_powershell_shell_integration_argv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 1, "powershell.exe", &.{
            "powershell.exe",
            "-NoExit",
            "-Command",
            pane_mod.WINDOWS_POWERSHELL_SHELL_INTEGRATION_COMMAND,
        })},
    };
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(arena.allocator(), job));
}

test "identify_agent_in_job_detects_opencode2_as_opencode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "claude-code", &.{ "claude-code", "--standalone" })},
    };
    try testing.expectEqualStrings("claude-code", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_opencode_exe_from_pnpm_package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "claude.exe", &.{
            "/home/user/.local/share/pnpm/global/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
        })},
    };
    try testing.expectEqualStrings("claude.exe", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "identify_agent_in_job_detects_opencode_exe_from_argv0_path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = ForegroundJob{
        .process_group_id = 123,
        .processes = &.{try foregroundProcess(arena.allocator(), 123, "MainThread", &.{
            "/home/user/.local/share/pnpm/global/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
        })},
    };
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(arena.allocator(), job)).?);
}

test "cmdline_argv0_agent_name_canonicalizes_known_aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "claude",
        (try cmdlineArgv0AgentName(arena.allocator(), "/nix/store/example/bin/claude-code")).?,
    );
}

test "cmdline_argv0_agent_name_requires_exact_agent_basename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(
        @as(?[]const u8, null),
        try cmdlineArgv0AgentName(arena.allocator(), "/tmp/my-claude-helper"),
    );
}

test "no_agent_returns_unknown" {
    try testing.expectEqual(AgentState.Unknown, try detectState(testing.allocator, null, "anything"));
}

test "foreground_job_detects_sleep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pty = openTestPty() catch return error.SkipZigTest;
    defer pty.deinit();

    var argv = [_:null]?[*:0]const u8{ "sleep", "999" };
    const pid = spawnOnPty(pty, &argv) catch return error.SkipZigTest;
    defer reapChild(pid);

    const job = awaitForegroundJob(alloc, @intCast(pid), "sleep") orelse return error.SkipZigTest;
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(alloc, job));
}

test "foreground_job_detects_shell_running_command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pty = openTestPty() catch return error.SkipZigTest;
    defer pty.deinit();

    // `exec` so sleep replaces sh as the pty's foreground process rather
    // than becoming a child of a still-running shell.
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", "exec sleep 999" };
    const pid = spawnOnPty(pty, &argv) catch return error.SkipZigTest;
    defer reapChild(pid);

    const job = awaitForegroundJob(alloc, @intCast(pid), "sleep") orelse return error.SkipZigTest;
    try testing.expectEqual(@as(?[]const u8, null), try identifyAgentInJob(alloc, job));
}

test "foreground_job_detects_agent_behind_shell_wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pty = openTestPty() catch return error.SkipZigTest;
    defer pty.deinit();

    // `exec -a claude` renames the process without it actually being Claude,
    // which is exactly what detection has to pick up on: the wrapper shell
    // stays in the group, and the agent is the child.
    var argv = [_:null]?[*:0]const u8{ "bash", "-c", "bash -c 'exec -a claude sleep 999' & wait" };
    const pid = spawnOnPty(pty, &argv) catch return error.SkipZigTest;
    defer reapChild(pid);

    const job = awaitForegroundJob(alloc, @intCast(pid), "sleep") orelse return error.SkipZigTest;
    platform.testing_support.killProcessGroup(job.process_group_id);

    var saw_wrapper = false;
    var saw_agent = false;
    for (job.processes) |process| {
        if (std.mem.eql(u8, process.name, "bash")) saw_wrapper = true;
        if (std.mem.eql(u8, process.name, "sleep")) {
            const argv0 = if (process.argv) |a| (if (a.len > 0) a[0] else "") else "";
            if (std.mem.eql(u8, argv0, "claude")) saw_agent = true;
        }
    }
    try testing.expect(saw_wrapper);
    try testing.expect(saw_agent);
    try testing.expectEqualStrings("claude", (try identifyAgentInJob(alloc, job)).?);
}

test "proc_stat_parsing_handles_spaces_in_comm" {
    // herdr gates this to Linux: it validates the `/proc/<pid>/stat` parser,
    // which macOS has no counterpart for - `foregroundProcessGroupId` reads
    // `e_tpgid` out of `proc_bsdinfo` instead. `commFromBsdInfo` is the
    // equivalent seam, and the equivalent hazard is a `comm` that fills or
    // overruns the fixed 16-byte field rather than one containing spaces.
    if (!platform.supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const own_pid: u32 = platform.testing_support.currentPid();
    const job = platform.foregroundJobForProcessGroup(
        alloc,
        foregroundProcessGroupId(own_pid) orelse return error.SkipZigTest,
    ) orelse return error.SkipZigTest;

    for (job.processes) |process| {
        try testing.expect(process.name.len > 0);
        try testing.expect(process.name.len <= 16);
        try testing.expect(std.mem.indexOfScalar(u8, process.name, 0) == null);
    }
}
