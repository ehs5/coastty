// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Debounce/publish timing for state transitions, so a momentary blank
//! frame between agent turns doesn't flicker Working -> Idle -> Working.
//!
//! ported-from: https://github.com/herdrdev/herdr/blob/master/src/pane/agent_detection.rs
//!
//! Coastty's detector is invoked on real PTY-output events rather than a
//! fixed poll loop, so `PendingIdleConfirmation.confirmations` advances one
//! step per output event received during the hold window instead of one
//! step per timer tick; the constants below (and the timestamp-based cap)
//! are ported unchanged.

const std = @import("std");
const manifest = @import("../manifest.zig");
const detection = @import("../main.zig");
const AgentState = manifest.AgentState;

/// Recheck interval herdr uses while holding a Working -> Idle transition.
pub const pending_idle_recheck_ms: i64 = 100;
/// Number of holds required before a Working -> Idle transition is allowed
/// to publish early (before the cap below is reached).
pub const pending_idle_confirmations: u8 = 3;
/// Hard cap on how long a Working -> Idle transition can be held.
pub const pending_idle_cap_ms: i64 = 700;
/// Minimum interval between republishing an unchanged, still-visible
/// blocker signal (keeps a long-lived permission prompt's evidence fresh
/// without spamming updates).
pub const stable_visible_signal_refresh_ms: i64 = 800;
/// Grace window after an agent is first identified in a pane before its
/// detected state is trusted for transitions that depend on history.
pub const agent_startup_grace_window_ms: i64 = 3000;

/// The subset of `AgentDetection` that debounce decisions are made from.
pub const PublishState = struct {
    state: AgentState,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
};

/// Tracks a possible Working -> Idle transition that's being held open for
/// up to `pending_idle_cap_ms` in case the very next real check reverses it
/// (typical of a screen that clears between one agent turn and the next).
pub const PendingIdleConfirmation = struct {
    started_at_ms: ?i64 = null,
    confirmations: u8 = 0,

    pub fn active(self: PendingIdleConfirmation) bool {
        return self.started_at_ms != null;
    }

    pub fn clear(self: *PendingIdleConfirmation) void {
        self.started_at_ms = null;
        self.confirmations = 0;
    }

    /// Returns true if the caller should hold `next` and keep publishing
    /// `previous` instead, for now.
    pub fn shouldHoldWorkingToIdle(
        self: *PendingIdleConfirmation,
        previous: PublishState,
        next: PublishState,
        agent_changed: bool,
        process_exited: bool,
        now_ms: i64,
    ) bool {
        const is_working_to_plain_idle = previous.state == .Working and
            next.state == .Idle and
            !next.visible_idle and
            !next.visible_blocker and
            !agent_changed and
            !process_exited;

        if (!is_working_to_plain_idle) {
            self.clear();
            return false;
        }

        const started_at = self.started_at_ms orelse {
            self.started_at_ms = now_ms;
            self.confirmations = 0;
            return true;
        };

        if (now_ms - started_at >= pending_idle_cap_ms) {
            self.clear();
            return false;
        }

        self.confirmations += 1;
        if (self.confirmations >= pending_idle_confirmations) {
            self.clear();
            return false;
        }

        return true;
    }
};

fn statesDiffer(previous: PublishState, next: PublishState) bool {
    return next.state != previous.state or
        next.visible_idle != previous.visible_idle or
        next.visible_blocker != previous.visible_blocker or
        next.visible_working != previous.visible_working;
}

pub fn shouldPublishDetectionUpdate(
    previous: PublishState,
    next: PublishState,
    agent_changed: bool,
    process_exited: bool,
    stable_visible_signal_refresh_due: bool,
) bool {
    return statesDiffer(previous, next) or
        agent_changed or
        process_exited or
        (stable_visible_signal_refresh_due and next.visible_blocker and previous.visible_blocker);
}

pub fn stableVisibleSignalRefreshDue(
    previous: PublishState,
    next: PublishState,
    last_refresh_ms: ?i64,
    now_ms: i64,
) bool {
    const stable_visible_signal = next.visible_blocker and previous.visible_blocker;
    if (!stable_visible_signal) return false;
    const last = last_refresh_ms orelse return true;
    return now_ms - last >= stable_visible_signal_refresh_ms;
}

pub const TransitionDecision = enum { no_publish, publish_next };

pub fn decideDetectionTransition(
    previous: PublishState,
    next: PublishState,
    agent_changed: bool,
    process_exited: bool,
    stable_refresh_due: bool,
    now_ms: i64,
    pending_idle: *PendingIdleConfirmation,
) TransitionDecision {
    if (pending_idle.shouldHoldWorkingToIdle(previous, next, agent_changed, process_exited, now_ms)) {
        return .no_publish;
    }

    if (shouldPublishDetectionUpdate(previous, next, agent_changed, process_exited, stable_refresh_due)) {
        return .publish_next;
    }

    return .no_publish;
}

const testing = std.testing;

test "pending_idle_holds_working_to_plain_idle_until_confirmed" {
    var pending: PendingIdleConfirmation = .{};
    const working: PublishState = .{ .state = .Working };
    const idle: PublishState = .{ .state = .Idle };

    var now: i64 = 0;
    // First call starts the hold (confirmations = 0).
    try testing.expect(pending.shouldHoldWorkingToIdle(working, idle, false, false, now));
    try testing.expect(pending.active());

    // Each subsequent call within the cap increments confirmations; the
    // hold releases once `pending_idle_confirmations` is reached.
    for (0..pending_idle_confirmations - 1) |_| {
        now += pending_idle_recheck_ms;
        try testing.expect(pending.shouldHoldWorkingToIdle(working, idle, false, false, now));
    }

    now += pending_idle_recheck_ms;
    try testing.expect(!pending.shouldHoldWorkingToIdle(working, idle, false, false, now));
    try testing.expect(!pending.active());
}

test "PendingIdleConfirmation releases at the cap even without enough confirmations" {
    var pending: PendingIdleConfirmation = .{};
    const working: PublishState = .{ .state = .Working };
    const idle: PublishState = .{ .state = .Idle };

    try testing.expect(pending.shouldHoldWorkingToIdle(working, idle, false, false, 0));
    // Single recheck right at the cap boundary releases even though only
    // one confirmation has happened.
    try testing.expect(!pending.shouldHoldWorkingToIdle(working, idle, false, false, pending_idle_cap_ms));
}

test "visible_idle_bypasses_plain_idle_hold" {
    var pending: PendingIdleConfirmation = .{};
    const working: PublishState = .{ .state = .Working };
    const visible_idle: PublishState = .{ .state = .Idle, .visible_idle = true };

    try testing.expect(!pending.shouldHoldWorkingToIdle(working, visible_idle, false, false, 0));
}

test "PendingIdleConfirmation does not hold across an agent change or process exit" {
    var pending: PendingIdleConfirmation = .{};
    const working: PublishState = .{ .state = .Working };
    const idle: PublishState = .{ .state = .Idle };

    try testing.expect(!pending.shouldHoldWorkingToIdle(working, idle, true, false, 0));
    try testing.expect(!pending.shouldHoldWorkingToIdle(working, idle, false, true, 0));
}

test "transition_decision_publishes_next_for_visible_blocker" {
    const blocked: PublishState = .{ .state = .Blocked, .visible_blocker = true };
    const idle = publishState(.Idle);

    var pending: PendingIdleConfirmation = .{};
    try testing.expectEqual(
        TransitionDecision.publish_next,
        decideDetectionTransition(idle, blocked, false, false, false, 0, &pending),
    );

    try testing.expect(!stableVisibleSignalRefreshDue(idle, blocked, null, 0));
    try testing.expect(stableVisibleSignalRefreshDue(blocked, blocked, null, 0));
    try testing.expect(!stableVisibleSignalRefreshDue(blocked, blocked, 0, 500));
    try testing.expect(stableVisibleSignalRefreshDue(blocked, blocked, 0, stable_visible_signal_refresh_ms));
}

pub const process_recheck_identified_ms: i64 = 5_000;
pub const process_recheck_missing_foreground_group_ms: i64 = 30_000;
pub const process_acquisition_fast_window_ms: i64 = 1_500;
pub const process_acquisition_fast_recheck_ms: i64 = 500;
pub const process_acquisition_window_ms: i64 = 8_000;
pub const process_acquisition_slow_recheck_ms: i64 = 2_000;
pub const process_acquisition_idle_reset_ms: i64 = 2_000;

pub const ProcessProbeInput = struct {
    current_agent: ?detection.Agent,
    suppressed_agent: ?detection.Agent,
    foreground_pgid: ?u32,
    last_foreground_pgid: ?u32,
    has_process_probe: bool,
    acquisition_age_ms: ?i64,
    pending_foreground_shell_clear: bool,
    pending_restore_probe: bool,
    elapsed_since_process_check_ms: i64,
};

fn foregroundGroupChanged(foreground_pgid: ?u32, last_foreground_pgid: ?u32) bool {
    return foreground_pgid != last_foreground_pgid and (foreground_pgid != null or last_foreground_pgid != null);
}

/// Whether this tick should spend a full process probe on the pane.
///
/// Probes are the expensive part of detection (a process-group enumeration
/// plus an argv read per member), so the schedule tightens only while
/// something is actually in flux: a pending clear/restore, a suppressed
/// agent, a fresh acquisition window, or a foreground group that changed.
/// A settled pane with an identified agent falls back to the 5s safety
/// recheck.
pub fn shouldProbeForegroundJob(input: ProcessProbeInput) bool {
    if (input.pending_foreground_shell_clear or input.pending_restore_probe) return true;

    const group_changed = foregroundGroupChanged(input.foreground_pgid, input.last_foreground_pgid);

    if (input.suppressed_agent != null) {
        return !input.has_process_probe or group_changed;
    }

    if (input.acquisition_age_ms) |age| {
        const interval: i64 = if (age <= process_acquisition_fast_window_ms)
            process_acquisition_fast_recheck_ms
        else
            process_acquisition_slow_recheck_ms;
        if (age <= process_acquisition_window_ms and
            input.elapsed_since_process_check_ms >= interval) return true;
    }

    if (input.current_agent == null) {
        return !input.has_process_probe or
            group_changed or
            (input.foreground_pgid == null and
                input.elapsed_since_process_check_ms >= process_recheck_missing_foreground_group_ms);
    }

    return group_changed or input.elapsed_since_process_check_ms >= process_recheck_identified_ms;
}

test "shouldPublishDetectionUpdate fires on any observable field change" {
    const idle: PublishState = .{ .state = .Idle };
    const working: PublishState = .{ .state = .Working };
    try testing.expect(shouldPublishDetectionUpdate(idle, working, false, false, false));
    try testing.expect(!shouldPublishDetectionUpdate(idle, idle, false, false, false));
    try testing.expect(shouldPublishDetectionUpdate(idle, idle, true, false, false));
    try testing.expect(shouldPublishDetectionUpdate(idle, idle, false, true, false));
}

fn publishState(state: AgentState) DetectionPublishState {
    return .{ .state = state };
}

fn screenDetection(state: AgentState) manifest.AgentDetection {
    return .{
        .state = state,
        .skip_state_update = false,
        .visible_idle = state == .Idle,
        .visible_blocker = false,
        .visible_working = state == .Working,
    };
}

fn screenPublishInput(
    current_state: AgentState,
    screen_detection: manifest.AgentDetection,
    now_ms: i64,
) ScreenDetectionPublishInput {
    return .{
        .current_state = current_state,
        .last_visible_idle = false,
        .last_visible_blocker = false,
        .last_visible_working = false,
        .last_visible_signal_refresh_ms = null,
        .screen_detection = screen_detection,
        .process_exited = false,
        .agent_changed = false,
        .now_ms = now_ms,
    };
}

fn screenReadInput(state: AgentState, current_seq: u64) DetectionScreenReadInput {
    return .{
        .state = state,
        .agent = .Claude,
        .pending_idle_active = false,
        .agent_changed = false,
        .process_exited = false,
        .current_detection_content_seq = current_seq,
        .last_screen_scan_detection_content_seq = 10,
    };
}

test "screen_read_skips_unchanged_idle_bottom_buffer" {
    try testing.expectEqual(
        DetectionScreenReadDecision.skip,
        decideDetectionScreenRead(screenReadInput(.Idle, 10)),
    );
}

test "screen_read_reads_when_idle_bottom_buffer_changes" {
    try testing.expectEqual(
        DetectionScreenReadDecision.read,
        decideDetectionScreenRead(screenReadInput(.Idle, 11)),
    );
}

test "screen_read_reads_for_transitions_and_missing_agent" {
    {
        var input = screenReadInput(.Idle, 10);
        input.pending_idle_active = true;
        try testing.expectEqual(DetectionScreenReadDecision.read, decideDetectionScreenRead(input));
    }
    {
        var input = screenReadInput(.Idle, 10);
        input.agent_changed = true;
        try testing.expectEqual(DetectionScreenReadDecision.read, decideDetectionScreenRead(input));
    }
    {
        var input = screenReadInput(.Idle, 10);
        input.process_exited = true;
        try testing.expectEqual(DetectionScreenReadDecision.read, decideDetectionScreenRead(input));
    }
    {
        var input = screenReadInput(.Idle, 10);
        input.agent = null;
        try testing.expectEqual(DetectionScreenReadDecision.read, decideDetectionScreenRead(input));
    }
    {
        const input = screenReadInput(.Working, 10);
        try testing.expectEqual(DetectionScreenReadDecision.read, decideDetectionScreenRead(input));
    }
}

test "screen_publish_keeps_visible_working_without_pty_activity" {
    var pending_idle: PendingIdleConfirmation = .{};
    const decision = decideScreenDetectionPublish(
        screenPublishInput(.Idle, screenDetection(.Working), 0),
        &pending_idle,
    );
    try testing.expectEqual(AgentState.Working, decision.publish.state);
    try testing.expect(!decision.publish.visible_idle);
    try testing.expect(!decision.publish.visible_blocker);
    try testing.expect(decision.publish.visible_working);
    try testing.expect(!decision.publish.process_exited);
}

test "screen_publish_can_publish_idle_without_input_taint_delay" {
    var pending_idle: PendingIdleConfirmation = .{};
    const decision = decideScreenDetectionPublish(
        screenPublishInput(.Blocked, screenDetection(.Idle), 0),
        &pending_idle,
    );
    try testing.expectEqual(AgentState.Idle, decision.publish.state);
    try testing.expect(decision.publish.visible_idle);
    try testing.expect(!decision.publish.visible_blocker);
    try testing.expect(!decision.publish.visible_working);
    try testing.expect(!decision.publish.process_exited);
}

test "detection_content_change_tracks_raw_nonempty_reads_for_scan_scheduling" {
    var seq = std.atomic.Value(u64).init(0);

    observeDetectionContentChange("", &seq);
    try testing.expectEqual(@as(u64, 0), seq.load(.monotonic));

    observeDetectionContentChange("\x1b[?2026h", &seq);
    try testing.expectEqual(@as(u64, 1), seq.load(.monotonic));

    observeDetectionContentChange("body bytes", &seq);
    try testing.expectEqual(@as(u64, 2), seq.load(.monotonic));
}

test "local_terminal_mutations_can_invalidate_idle_scan_skip" {
    var seq = std.atomic.Value(u64).init(0);
    markDetectionContentChanged(&seq);
    try testing.expectEqual(@as(u64, 1), seq.load(.monotonic));
}

test "shouldProbeForegroundJob schedules probes only while identity is in flux" {
    const settled = ProcessProbeInput{
        .current_agent = .Claude,
        .suppressed_agent = null,
        .foreground_pgid = 42,
        .last_foreground_pgid = 42,
        .has_process_probe = true,
        .acquisition_age_ms = null,
        .pending_foreground_shell_clear = false,
        .pending_restore_probe = false,
        .elapsed_since_process_check_ms = 0,
    };
    try testing.expect(!shouldProbeForegroundJob(settled));

    {
        var input = settled;
        input.elapsed_since_process_check_ms = process_recheck_identified_ms;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        var input = settled;
        input.last_foreground_pgid = 43;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        var input = settled;
        input.pending_foreground_shell_clear = true;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        var input = settled;
        input.pending_restore_probe = true;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        // Unidentified pane with no probe yet always gets an initial probe.
        var input = settled;
        input.current_agent = null;
        input.has_process_probe = false;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        // A stable unidentified group is not re-probed on every tick.
        var input = settled;
        input.current_agent = null;
        try testing.expect(!shouldProbeForegroundJob(input));
    }
    {
        // No foreground group at all falls back to the safety recheck.
        var input = settled;
        input.current_agent = null;
        input.foreground_pgid = null;
        input.last_foreground_pgid = null;
        input.elapsed_since_process_check_ms = process_recheck_missing_foreground_group_ms;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        // A fresh acquisition window probes on the fast interval.
        var input = settled;
        input.current_agent = null;
        input.acquisition_age_ms = 0;
        input.elapsed_since_process_check_ms = process_acquisition_fast_recheck_ms;
        try testing.expect(shouldProbeForegroundJob(input));
    }
    {
        // Past the acquisition window entirely, the window stops forcing probes.
        var input = settled;
        input.current_agent = null;
        input.acquisition_age_ms = process_acquisition_window_ms + 1;
        input.elapsed_since_process_check_ms = process_acquisition_slow_recheck_ms;
        try testing.expect(!shouldProbeForegroundJob(input));
    }
}

/// herdr names this type separately from its own `PublishState`; the two
/// carry identical fields and are used interchangeably, so they're one type
/// here under both names.
pub const DetectionPublishState = PublishState;

pub const IdleScreenScanSkipInput = struct {
    state: AgentState,
    agent: ?detection.Agent,
    pending_idle_active: bool,
    agent_changed: bool,
    process_exited: bool,
    current_detection_content_seq: ?u64,
    last_screen_scan_detection_content_seq: ?u64,
};

pub const DetectionScreenReadDecision = enum { read, skip };

pub const DetectionScreenReadInput = struct {
    state: AgentState,
    agent: ?detection.Agent,
    pending_idle_active: bool,
    agent_changed: bool,
    process_exited: bool,
    current_detection_content_seq: ?u64,
    last_screen_scan_detection_content_seq: ?u64,
};

pub const DetectionTransitionDecision = TransitionDecision;

/// The arguments `decideDetectionTransition` takes, grouped the way herdr
/// groups them. It passes them positionally here.
pub const DetectionTransitionInput = struct {
    previous_publish: DetectionPublishState,
    next_publish: DetectionPublishState,
    agent_changed: bool,
    process_exited: bool,
    stable_refresh_due: bool,
    now_ms: i64,
};

pub const DetectionPublishDecision = union(enum) {
    no_publish,
    publish: struct {
        state: AgentState,
        visible_idle: bool,
        visible_blocker: bool,
        visible_working: bool,
        process_exited: bool,
    },
};

pub const ScreenDetectionPublishInput = struct {
    current_state: AgentState,
    last_visible_idle: bool,
    last_visible_blocker: bool,
    last_visible_working: bool,
    last_visible_signal_refresh_ms: ?i64,
    screen_detection: manifest.AgentDetection,
    process_exited: bool,
    agent_changed: bool,
    now_ms: i64,
};

/// An idle pane whose detection content hasn't changed since the last scan
/// has nothing new to read - the only thing a rescan could produce is the
/// same answer. Any transition in flight (pending idle, agent change,
/// process exit) disables the skip.
pub fn shouldSkipIdleScreenScan(input: IdleScreenScanSkipInput) bool {
    if (input.state != .Idle or
        input.agent == null or
        input.pending_idle_active or
        input.agent_changed or
        input.process_exited) return false;

    const current = input.current_detection_content_seq orelse return false;
    const last = input.last_screen_scan_detection_content_seq orelse return false;
    return last == current;
}

pub fn decideDetectionScreenRead(input: DetectionScreenReadInput) DetectionScreenReadDecision {
    return if (shouldSkipIdleScreenScan(.{
        .state = input.state,
        .agent = input.agent,
        .pending_idle_active = input.pending_idle_active,
        .agent_changed = input.agent_changed,
        .process_exited = input.process_exited,
        .current_detection_content_seq = input.current_detection_content_seq,
        .last_screen_scan_detection_content_seq = input.last_screen_scan_detection_content_seq,
    })) .skip else .read;
}

/// The `visible_*` flags only survive when they agree with the state that
/// actually won, so a rule's idle chrome can't be reported alongside a
/// blocked publish.
pub fn decideScreenDetectionPublish(
    input: ScreenDetectionPublishInput,
    pending_idle: *PendingIdleConfirmation,
) DetectionPublishDecision {
    const d = input.screen_detection;
    const new_state = stabilizeAgentDetection(d);
    const visible_idle = d.visible_idle and new_state == .Idle;
    const visible_blocker = d.visible_blocker and new_state == .Blocked;
    const visible_working = d.visible_working and new_state == .Working;

    const previous_publish = PublishState{
        .state = input.current_state,
        .visible_idle = input.last_visible_idle,
        .visible_blocker = input.last_visible_blocker,
        .visible_working = input.last_visible_working,
    };
    const next_publish = PublishState{
        .state = new_state,
        .visible_idle = visible_idle,
        .visible_blocker = visible_blocker,
        .visible_working = visible_working,
    };
    const stable_refresh_due = stableVisibleSignalRefreshDue(
        previous_publish,
        next_publish,
        input.last_visible_signal_refresh_ms,
        input.now_ms,
    );

    return switch (decideDetectionTransition(
        previous_publish,
        next_publish,
        input.agent_changed,
        input.process_exited,
        stable_refresh_due,
        input.now_ms,
        pending_idle,
    )) {
        .no_publish => .no_publish,
        .publish_next => .{ .publish = .{
            .state = new_state,
            .visible_idle = visible_idle,
            .visible_blocker = visible_blocker,
            .visible_working = visible_working,
            .process_exited = input.process_exited,
        } },
    };
}

/// The seam where a terminal-side stabilization pass would go. herdr's is
/// also an identity function today; it exists so screen state can be damped
/// in one place if it ever needs to be.
fn stabilizeAgentDetection(d: manifest.AgentDetection) AgentState {
    return d.state;
}

pub fn detectionUpdateForPublish(
    alloc: std.mem.Allocator,
    agent: ?detection.Agent,
    screen_content: []const u8,
    process_exited: bool,
) !?manifest.AgentDetection {
    return detectionUpdateForPublishWithOsc(alloc, agent, screen_content, "", "", process_exited);
}

/// A process exit is idle unconditionally, without consulting the screen -
/// whatever chrome is still on it belongs to a process that's gone.
/// Otherwise a `skip_state_update` rule wins by publishing nothing.
pub fn detectionUpdateForPublishWithOsc(
    alloc: std.mem.Allocator,
    agent: ?detection.Agent,
    screen_content: []const u8,
    osc_title: []const u8,
    osc_progress: []const u8,
    process_exited: bool,
) !?manifest.AgentDetection {
    if (process_exited) return manifest.AgentDetection{
        .state = .Idle,
        .skip_state_update = false,
        .visible_idle = true,
        .visible_blocker = false,
        .visible_working = false,
    };

    const d = try detection.detectAgentWithOsc(alloc, agent, screen_content, osc_title, osc_progress);
    return if (d.skip_state_update) null else d;
}

/// Bump the detection content sequence for a PTY read. Empty reads don't
/// count - they can't have changed what's on screen.
pub fn observeDetectionContentChange(bytes: []const u8, seq: *std.atomic.Value(u64)) void {
    if (bytes.len != 0) _ = seq.fetchAdd(1, .monotonic);
}

/// Force the next idle scan to happen, for changes that didn't arrive as
/// PTY output (a local resize, a clear, a scrollback edit).
pub fn markDetectionContentChanged(seq: *std.atomic.Value(u64)) void {
    _ = seq.fetchAdd(1, .monotonic);
}
