// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Per-surface agent detector: ties presence identification (foreground
//! process), screen/OSC state detection (the rule engine + Claude's
//! manifest), and idle-transition debouncing together behind one entry
//! point, `update`, meant to be called on every PTY-output event.
//!
//! Stateless per check beyond the debounce timing itself: nothing here is
//! derived from anything but the latest screen/OSC snapshot and the
//! previously published state.
//!
//! Not ported: herdr's `DetectionScreenReadDecision`/
//! `decide_detection_screen_read` (`src/pane.rs`), which skips re-reading
//! the screen when idle and a content-change counter shows nothing new
//! happened since the last scan. That exists because herdr's detection
//! task polls on a fixed timer (300ms, or `AGENT_PENDING_IDLE_RECHECK`
//! while a transition is pending) and needs to avoid rescanning idle
//! panes on every tick; coastty's `update` is only ever invoked by
//! `processOutputLocked` when new PTY output has actually arrived (see
//! `Termio.updateAgentDetection`), so that condition is already true by
//! construction - there's no fixed-interval tick to skip work on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const claude_manifest = @import("manifests/claude.zig");
const timing = @import("pane/agent_detection.zig");
const platform = @import("platform.zig");
const detection = @import("main.zig");

pub const Agent = detection.Agent;
pub const AgentState = detection.AgentState;
pub const AgentDetection = detection.AgentDetection;

pub const Detector = struct {
    compiled: manifest.CompiledManifest,

    /// The last published state - what a caller should currently be
    /// showing. Distinct from a single raw check, which can be held back
    /// briefly by the idle-transition debounce (see `pane/agent_detection.zig`).
    published: timing.PublishState = .{ .state = .Unknown },
    pending_idle: timing.PendingIdleConfirmation = .{},
    last_visible_signal_refresh_ms: ?i64 = null,

    /// The agent last identified as running in this pane's foreground
    /// process, if any.
    agent: ?Agent = null,

    /// Set when `agent` was just newly identified in this pane; while
    /// `now_ms` is before this, `update` performs no screen/OSC evaluation
    /// and publishes nothing, so a moment of startup-banner chrome can't be
    /// misread as an idle/blocked state before the agent settles.
    ///
    /// ported-from: `AGENT_STARTUP_GRACE_WINDOW` and the
    /// `agent_startup_grace_until` handling in
    /// https://github.com/herdrdev/herdr/blob/master/src/pane.rs
    startup_grace_until_ms: ?i64 = null,

    /// Which agent the last process probe found, with the miss counter that
    /// keeps a transient probe failure from clearing it.
    agent_presence: AgentDetectionPresence = .{},
    /// An agent whose re-acquisition is suppressed after a deliberate
    /// handoff, so its still-dying process isn't picked up as a new one.
    pending_release: ?PendingAgentRelease = null,
    /// True while a hook integration owns this pane's lifecycle, which
    /// disables screen detection entirely (see `main.zig`).
    full_lifecycle_authority_active: bool = false,

    // Process-probe scheduling state. All of it feeds
    // `timing.ProcessProbeInput`.
    has_process_probe: bool = false,
    last_foreground_pgid: ?u32 = null,
    last_process_check_ms: ?i64 = null,
    acquisition_started_at_ms: ?i64 = null,
    last_content_change_at_ms: ?i64 = null,
    /// Set when the pane's shell came back to the foreground while an agent
    /// was still identified: the agent's final idle transition is published
    /// before its identity is dropped.
    pending_foreground_shell_clear: bool = false,
    foreground_shell_exit_reported: bool = false,

    pub fn init(alloc: Allocator) !Detector {
        return .{ .compiled = try manifest.CompiledManifest.compile(alloc, &claude_manifest.rules) };
    }

    pub fn deinit(self: *Detector) void {
        self.compiled.deinit();
    }

    /// Runs one detection check and returns the new state to publish, or
    /// null if the published state hasn't changed.
    ///
    /// - `agent`: which agent is currently identified as the pane's
    ///   foreground process (via `platform.identifyClaude` resolved from
    ///   `Pty.getProcessInfo(.foreground_pid)` at the call site), or null if
    ///   none is. Presence identification is deliberately kept out of this
    ///   type so it stays testable without real OS process state.
    /// - `process_exited`: true if the pane's underlying child process is
    ///   known to have exited (forces an immediate, undebounced return to
    ///   idle regardless of `agent`, and skips the startup grace window).
    ///   Ghostty's PTY-read pipeline only calls this while output is still
    ///   arriving, so callers that don't separately track process
    ///   lifecycle can simply pass false.
    pub fn update(
        self: *Detector,
        gpa: Allocator,
        now_ms: i64,
        agent: ?Agent,
        process_exited: bool,
        input: manifest.DetectionInput,
    ) !?AgentDetection {
        const identified = agent;
        const agent_changed = identified != self.agent;
        self.agent = identified;

        if (agent_changed) {
            self.pending_idle.clear();
            self.startup_grace_until_ms = if (identified != null)
                now_ms + timing.agent_startup_grace_window_ms
            else
                null;

            // herdr reports the agent the moment the process probe finds it,
            // on its own event, so the pane shows an agent for the whole
            // grace window rather than staying blank until screen detection
            // has something to say.
            //
            // The state it starts from is `Idle`, matching herdr's detection
            // task, which keeps `Unknown` meaning exactly one thing: no agent
            // in this pane. A just-detected agent reads as idle-and-seen until
            // the grace window ends and screen detection replaces it.
            //
            // ported-from: `publish_agent_process_detected_event` and the
            // task's initial `state` in
            // https://github.com/herdrdev/herdr/blob/master/src/pane.rs
            if (identified != null and !process_exited) {
                self.published = .{ .state = .Idle };
                self.last_visible_signal_refresh_ms = null;
                return .{ .state = .Idle, .agent = identified };
            }
        }

        // A process exit forces idle unconditionally - whether or not an
        // agent was still identified - and skips both the startup grace
        // window and the screen/OSC evaluation below.
        if (process_exited) {
            return self.publish(.{ .state = .Idle, .visible_idle = true }, agent_changed, process_exited, now_ms);
        }

        if (identified == null) {
            return self.publish(.{ .state = .Unknown }, agent_changed, process_exited, now_ms);
        }

        if (self.startup_grace_until_ms) |until| {
            if (now_ms < until) return null;
            self.startup_grace_until_ms = null;
        }

        const result = try manifest.evaluate(gpa, &self.compiled, input);
        if (result.skip_state_update) return null;

        return self.publish(.{
            .state = result.state,
            .visible_idle = result.visible_idle,
            .visible_blocker = result.visible_blocker,
            .visible_working = result.visible_working,
        }, agent_changed, process_exited, now_ms);
    }

    /// How long until this pane's next detection check.
    ///
    /// herdr spawns a tokio task that re-runs detection on this interval.
    /// coastty drives the same checks from an `xev.Timer` on the IO thread,
    /// so this is what the timer re-arms from rather than a value a loop
    /// sleeps on. Output-driven checks from `Termio.processOutputLocked`
    /// still happen in between; the tick is what keeps a pane that has gone
    /// quiet - an agent sitting on a permission prompt - getting re-checked.
    ///
    /// ported-from: the `let tick = ...` selection in the detection task in
    /// https://github.com/herdrdev/herdr/blob/master/src/pane.rs. herdr also
    /// shortens the tick while its terminal has a transient default-color
    /// override, which belongs to its handoff feature and has no counterpart
    /// here.
    /// Whether this check should spend a full process probe on the pane.
    /// The probe is the expensive half of detection - a process-group
    /// enumeration plus an argv read per member - so a settled pane falls
    /// back to the 5s safety recheck instead of paying it every tick.
    ///
    /// `pending_restore_probe` is always false here: herdr seeds it from a
    /// restored session's remembered agent, and coastty's detector starts
    /// every pane from scratch.
    /// What one process observation concluded: which agent holds the pane
    /// now, and whether the agent that held it has just exited.
    pub const ProcessObservation = struct {
        agent: ?Agent,
        process_exited: bool,
    };

    pub fn shouldProbeForegroundJob(self: *Detector, now_ms: i64, foreground_pgid: ?u32) bool {
        return timing.shouldProbeForegroundJob(.{
            .current_agent = self.agent_presence.currentAgent(),
            .suppressed_agent = activePendingRelease(&self.pending_release, now_ms),
            .foreground_pgid = foreground_pgid,
            .last_foreground_pgid = self.last_foreground_pgid,
            .has_process_probe = self.has_process_probe,
            .acquisition_age_ms = if (self.acquisition_started_at_ms) |started| now_ms - started else null,
            .pending_foreground_shell_clear = self.pending_foreground_shell_clear,
            .pending_restore_probe = false,
            .elapsed_since_process_check_ms = if (self.last_process_check_ms) |last|
                now_ms - last
            else
                std.math.maxInt(i64),
        });
    }

    /// Which agent is running in the pane, re-probing the foreground process
    /// group only when the schedule calls for it and otherwise reusing the
    /// identity the last probe settled on.
    ///
    /// ported-from: the probe block in the detection task in
    /// https://github.com/herdrdev/herdr/blob/master/src/pane.rs
    pub fn observeForegroundProcess(
        self: *Detector,
        gpa: Allocator,
        now_ms: i64,
        child_pid: ?u32,
        foreground_pgid: ?u32,
    ) ProcessObservation {
        const previous = self.agent_presence.currentAgent();
        if (!self.shouldProbeForegroundJob(now_ms, foreground_pgid)) {
            return .{ .agent = previous, .process_exited = false };
        }

        const had_process_probe = self.has_process_probe;
        const group_changed = foregroundGroupChanged(foreground_pgid, self.last_foreground_pgid);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const probe: ProcessProbeResult = if (child_pid) |pid|
            (probeForegroundProcess(arena_state.allocator(), pid, foreground_pgid) catch
                ProcessProbeResult{ .process_group_id = foreground_pgid })
        else
            .{ .process_group_id = foreground_pgid };
        const found = probe.agent;

        // An agent that exits hands the pty back to the pane's own shell.
        // That is what tells a finished agent apart from one that has merely
        // gone quiet, and it publishes a final idle transition before the
        // identity is dropped so nothing waiting on the agent misses its
        // completion.
        const action = foregroundShellAgentAction(
            previous,
            found,
            probe.foreground_is_pane_shell,
            self.foreground_shell_exit_reported,
        );
        _ = applyForegroundShellAgentAction(
            &self.agent_presence,
            action,
            previous,
            found,
            &self.pending_foreground_shell_clear,
            &self.foreground_shell_exit_reported,
        );

        self.last_process_check_ms = now_ms;
        self.has_process_probe = true;
        self.last_foreground_pgid = processGroupForChangeTracking(
            foreground_pgid,
            probe.process_group_id,
        );

        // A group that changed without yielding an agent yet is a pane
        // mid-launch: the shell has forked but the agent hasn't exec'd. The
        // acquisition window is what keeps probing until it appears.
        if (found != null) {
            self.acquisition_started_at_ms = null;
            self.last_content_change_at_ms = null;
        } else if (self.agent_presence.currentAgent() == null and
            had_process_probe and
            group_changed)
        {
            self.acquisition_started_at_ms = now_ms;
        }

        // `report_process_exit` keeps the identity one more round so this
        // publish carries the agent's final transition; the next probe sees
        // `foreground_shell_exit_reported` and clears it.
        if (action == .report_process_exit) {
            self.foreground_shell_exit_reported = true;
            return .{ .agent = previous, .process_exited = true };
        }

        return .{ .agent = self.agent_presence.currentAgent(), .process_exited = false };
    }

    pub fn tickIntervalMs(self: *Detector, now_ms: i64) i64 {
        if (activePendingRelease(&self.pending_release, now_ms) != null) return tick_pending_release_ms;
        if (self.pending_idle.active()) return timing.pending_idle_recheck_ms;
        if (self.agent_presence.currentAgent() == null) return tick_unidentified_ms;
        return tick_identified_ms;
    }

    fn publish(
        self: *Detector,
        next: timing.PublishState,
        agent_changed: bool,
        process_exited: bool,
        now_ms: i64,
    ) ?AgentDetection {
        const stable_refresh_due = timing.stableVisibleSignalRefreshDue(
            self.published,
            next,
            self.last_visible_signal_refresh_ms,
            now_ms,
        );

        const decision = timing.decideDetectionTransition(
            self.published,
            next,
            agent_changed,
            process_exited,
            stable_refresh_due,
            now_ms,
            &self.pending_idle,
        );
        if (decision == .no_publish) return null;

        self.published = next;
        if (stable_refresh_due) self.last_visible_signal_refresh_ms = now_ms;

        return .{
            .state = next.state,
            .agent = self.agent,
            .skip_state_update = false,
            .visible_idle = next.visible_idle,
            .visible_blocker = next.visible_blocker,
            .visible_working = next.visible_working,
        };
    }
};

const testing = std.testing;

test "Detector: no foreground agent publishes nothing (matches the resting default)" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    // A fresh Detector already defaults to Unknown/no-agent, so a first
    // check that agrees with that has nothing new to publish.
    const first = try d.update(testing.allocator, 0, null, false, .{ .screen = "" });
    try testing.expect(first == null);
}

test "Detector: the tick tightens while the pane's identity is in flux" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    try testing.expectEqual(tick_unidentified_ms, d.tickIntervalMs(0));

    d.agent_presence = .fromAgent(.Claude);
    try testing.expectEqual(tick_identified_ms, d.tickIntervalMs(0));

    d.pending_idle.started_at_ms = 0;
    try testing.expectEqual(timing.pending_idle_recheck_ms, d.tickIntervalMs(0));

    d.pending_release = .{ .agent = .Claude, .until_ms = 1_000 };
    try testing.expectEqual(tick_pending_release_ms, d.tickIntervalMs(0));
}

test "Detector: a settled pane stops spending a process probe on every tick" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    // Nothing has been probed yet, so the first check always probes.
    try testing.expect(d.shouldProbeForegroundJob(0, 100));

    d.has_process_probe = true;
    d.last_foreground_pgid = 100;
    d.last_process_check_ms = 0;
    d.agent_presence = .fromAgent(.Claude);

    // An identified agent on an unchanged foreground group waits out the
    // safety recheck rather than probing at the tick rate.
    try testing.expect(!d.shouldProbeForegroundJob(timing.process_recheck_identified_ms - 1, 100));
    try testing.expect(d.shouldProbeForegroundJob(timing.process_recheck_identified_ms, 100));

    // A foreground group that changed is probed without waiting.
    try testing.expect(d.shouldProbeForegroundJob(1, 200));
}

/// A `now_ms` past any Detector's startup grace window, for tests that
/// aren't themselves exercising the grace window and just want normal
/// screen-detection behavior once an agent identifies.
const after_grace_ms: i64 = timing.agent_startup_grace_window_ms + 1;

test "Detector: newly identifying an agent holds screen detection for the startup grace window" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    // The very first check that identifies Claude publishes the agent at
    // once, as idle, and starts the grace window - the working evidence on
    // screen is not read yet.
    const first = try d.update(testing.allocator, 0, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expect(first != null);
    try testing.expectEqual(AgentState.Idle, first.?.state);
    try testing.expectEqual(Agent.Claude, first.?.agent.?);

    // Still within the window: still nothing.
    const still_held = try d.update(testing.allocator, timing.agent_startup_grace_window_ms - 1, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expect(still_held == null);

    // Past the window: normal detection resumes.
    const released = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expect(released != null);
    try testing.expectEqual(AgentState.Working, released.?.state);
}

test "Detector: process exit during the startup grace window still forces an immediate idle publish" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    // Identifying the agent publishes it as idle and opens the grace window.
    const first = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });
    try testing.expectEqual(AgentState.Idle, first.?.state);

    const result = try d.update(testing.allocator, 1, .Claude, true, .{ .screen = "" });
    try testing.expect(result != null);
    try testing.expectEqual(AgentState.Idle, result.?.state);
    try testing.expect(result.?.visible_idle);
}

test "Detector: agent identity changes publish, even if the state doesn't" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    _ = try d.update(testing.allocator, 0, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    const working = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expect(working != null);
    try testing.expectEqual(AgentState.Working, working.?.state);

    // Claude is no longer the foreground process: publishes Unknown even
    // though nothing else about the check changed.
    const gone = try d.update(testing.allocator, after_grace_ms + 10, null, false, .{ .screen = "" });
    try testing.expect(gone != null);
    try testing.expectEqual(AgentState.Unknown, gone.?.state);
}

test "Detector: process exit forces an immediate idle publish" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    const result = try d.update(testing.allocator, 0, null, true, .{ .screen = "" });
    try testing.expect(result != null);
    try testing.expectEqual(AgentState.Idle, result.?.state);
    try testing.expect(result.?.visible_idle);
}

test "Detector: skip_state_update rules publish nothing" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    _ = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });

    // model_picker_menu is a skip_state_update rule in Claude's manifest.
    const screen = "select model\nenter to set as default\nesc to cancel";
    const result = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{ .screen = screen });
    try testing.expect(result == null);
}

test "Detector: an identified agent's Working state publishes" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    _ = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });

    const result = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expect(result != null);
    try testing.expectEqual(AgentState.Working, result.?.state);
    try testing.expect(result.?.visible_working);
}

test "Detector: Working->Idle is held briefly, then published at the cap" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    _ = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });

    const working = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expectEqual(AgentState.Working, working.?.state);

    // Plain idle (no visible idle/blocker chrome): held briefly rather
    // than published immediately, in case the very next check reverses it.
    try testing.expect(try d.update(testing.allocator, after_grace_ms + 100, .Claude, false, .{ .screen = "" }) == null);

    // Past the debounce cap: released even without more confirmations.
    const released = try d.update(testing.allocator, after_grace_ms + timing.pending_idle_cap_ms + 100, .Claude, false, .{ .screen = "" });
    try testing.expect(released != null);
    try testing.expectEqual(AgentState.Idle, released.?.state);
}

pub const PendingAgentRelease = struct {
    agent: Agent,
    until_ms: i64,
};

pub const AgentDetectionPublishUpdate = struct {
    state: AgentState = .Unknown,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
    process_exited: bool = false,
};

/// How many consecutive probes must fail to find the current agent before
/// its identity is dropped. A single miss is routine - a probe can land
/// while the agent is between `fork`/`exec` - so clearing on one would
/// flap the pane's identity.
pub const agent_miss_confirmation_attempts: u8 = 6;

/// The pane's currently identified agent, plus the miss counter that keeps
/// a transient probe failure from clearing it.
pub const AgentDetectionPresence = struct {
    current_agent: ?Agent = null,
    consecutive_misses: u8 = 0,

    pub fn fromAgent(current_agent: ?Agent) AgentDetectionPresence {
        return .{ .current_agent = current_agent, .consecutive_misses = 0 };
    }

    pub fn currentAgent(self: AgentDetectionPresence) ?Agent {
        return self.current_agent;
    }

    /// Returns true if this actually cleared an agent.
    pub fn clearCurrentAgent(self: *AgentDetectionPresence) bool {
        if (self.current_agent == null) {
            self.consecutive_misses = 0;
            return false;
        }
        self.current_agent = null;
        self.consecutive_misses = 0;
        return true;
    }

    /// Fold one probe result in. Returns true if the pane's identity
    /// changed as a result.
    pub fn observeProcessProbe(self: *AgentDetectionPresence, identified_agent: ?Agent) bool {
        if (identified_agent) |agent| {
            self.consecutive_misses = 0;
            if (self.current_agent) |current| {
                if (current == agent) return false;
            }
            self.current_agent = agent;
            return true;
        }

        if (self.current_agent == null) {
            self.consecutive_misses = 0;
            return false;
        }
        self.consecutive_misses +|= 1;
        if (self.consecutive_misses < agent_miss_confirmation_attempts) return false;
        self.current_agent = null;
        self.consecutive_misses = 0;
        return true;
    }
};

pub const ForegroundShellAgentAction = enum {
    observe_probe,
    report_process_exit,
    report_replacement_process,
    clear_agent,
};

pub const ProcessProbeResult = struct {
    process_group_id: ?u32 = null,
    foreground_is_pane_shell: bool = false,
    agent: ?Agent = null,
    process_name: ?[]const u8 = null,
};

/// The cwd of some *other* member of the pane's foreground job - one that
/// has moved somewhere the shell hasn't. Used to follow a command that
/// `cd`'d on its own.
fn foregroundMemberCwdDifferentFromShell(
    alloc: Allocator,
    shell_pid: u32,
    shell_cwd: ?[]const u8,
) ?[]const u8 {
    const job = platform.foregroundJob(alloc, shell_pid) orelse return null;
    for (job.processes) |process| {
        if (process.pid == shell_pid) continue;
        const cwd = absoluteProcessCwd(alloc, process.pid) orelse continue;
        const same = if (shell_cwd) |shell| std.mem.eql(u8, shell, cwd) else false;
        if (!same) return cwd;
    }
    return null;
}

/// What a probe that found the pane's shell back in the foreground means
/// for the agent that was running there.
///
/// The nuance is `report_process_exit`: identity is *not* cleared right
/// away, so a final idle transition can be published for the agent that
/// just finished before the pane goes unknown. Callers waiting on that
/// agent would otherwise never see it complete.
fn foregroundShellAgentAction(
    previous_agent: ?Agent,
    new_agent: ?Agent,
    foreground_is_pane_shell: bool,
    process_exit_reported: bool,
) ForegroundShellAgentAction {
    const previous = previous_agent orelse return .observe_probe;

    if (process_exit_reported) {
        if (new_agent) |next| {
            return if (next == previous) .report_replacement_process else .observe_probe;
        }
        return .clear_agent;
    }

    if (new_agent != null) return .observe_probe;
    if (foreground_is_pane_shell) return .report_process_exit;
    return .observe_probe;
}

/// Returns true if the pane's identity changed.
fn applyForegroundShellAgentAction(
    agent_presence: *AgentDetectionPresence,
    action: ForegroundShellAgentAction,
    previous_agent: ?Agent,
    new_agent: ?Agent,
    pending_foreground_shell_clear: *bool,
    foreground_shell_exit_reported: *bool,
) bool {
    switch (action) {
        .report_replacement_process => {
            pending_foreground_shell_clear.* = false;
            foreground_shell_exit_reported.* = false;
            _ = agent_presence.observeProcessProbe(previous_agent);
            return true;
        },
        .report_process_exit => {
            pending_foreground_shell_clear.* = true;
            return false;
        },
        .clear_agent => {
            pending_foreground_shell_clear.* = false;
            foreground_shell_exit_reported.* = false;
            return agent_presence.clearCurrentAgent();
        },
        .observe_probe => {
            pending_foreground_shell_clear.* = false;
            foreground_shell_exit_reported.* = false;
            return agent_presence.observeProcessProbe(new_agent);
        },
    }
}

/// Which pgid to remember for change detection. With no observed group
/// there's nothing to track, so an inferred one from the probe must not be
/// recorded - otherwise it would read as a change on the next tick and
/// force a probe every time.
fn processGroupForChangeTracking(observed_foreground_pgid: ?u32, probed_process_group_id: ?u32) ?u32 {
    if (observed_foreground_pgid == null) return null;
    return probed_process_group_id orelse observed_foreground_pgid;
}

/// A full-lifecycle hook integration already knows the agent's state, so
/// routine probes are pure overhead - but only while everything is settled.
fn shouldSkipProcessProbeForLifecycleAuthority(
    full_lifecycle_authority_active: bool,
    input: timing.ProcessProbeInput,
) bool {
    return full_lifecycle_authority_active and
        input.foreground_pgid != null and
        !input.pending_foreground_shell_clear and
        input.suppressed_agent == null and
        input.has_process_probe and
        !foregroundGroupChanged(input.foreground_pgid, input.last_foreground_pgid);
}

fn foregroundGroupChanged(foreground_pgid: ?u32, last_foreground_pgid: ?u32) bool {
    if (foreground_pgid == null and last_foreground_pgid == null) return false;
    if (foreground_pgid == null or last_foreground_pgid == null) return true;
    return foreground_pgid.? != last_foreground_pgid.?;
}

fn shouldObserveForegroundProcessGroup(
    lifecycle_authority: bool,
    content_changed: bool,
    elapsed_ms: i64,
    input: timing.ProcessProbeInput,
) bool {
    return !input.has_process_probe or
        input.current_agent == null or
        input.suppressed_agent != null or
        input.pending_foreground_shell_clear or
        input.pending_restore_probe or
        content_changed or
        (lifecycle_authority and elapsed_ms >= timing.process_recheck_identified_ms) or
        (!lifecycle_authority and input.elapsed_since_process_check_ms >= timing.process_recheck_identified_ms);
}

/// Open (or extend) the acquisition window that makes probes more frequent
/// while a pane is producing output but nothing has been identified yet -
/// an agent that takes a while to start still gets caught. Only runs while
/// the pane is genuinely unidentified.
fn syncContentChangeAcquisition(
    current_agent: ?Agent,
    suppressed_agent: ?Agent,
    process_group_changed: bool,
    content_changed: bool,
    now_ms: i64,
    acquisition_started_at_ms: *?i64,
    last_content_change_at_ms: *?i64,
) void {
    if (current_agent != null or suppressed_agent != null or process_group_changed) return;

    if (content_changed) {
        const should_start = if (acquisition_started_at_ms.*) |started|
            (now_ms - started > timing.process_acquisition_window_ms) and
                (if (last_content_change_at_ms.*) |last|
                    now_ms - last >= timing.process_acquisition_idle_reset_ms
                else
                    true)
        else
            true;
        if (should_start) acquisition_started_at_ms.* = now_ms;
        last_content_change_at_ms.* = now_ms;
        return;
    }

    const acquisition_started = acquisition_started_at_ms.* orelse return;
    const last_content_change = last_content_change_at_ms.* orelse return;

    if (now_ms - acquisition_started > timing.process_acquisition_window_ms and
        now_ms - last_content_change >= timing.process_acquisition_idle_reset_ms)
    {
        acquisition_started_at_ms.* = null;
        last_content_change_at_ms.* = null;
    }
}

/// The hint reader used in production: the agent identity coastty stamped
/// into the pane's environment when it launched it.
fn ReadHint(comptime T: type) type {
    return *const fn (ctx: T, pid: u32) ?Agent;
}

fn agentHintForForegroundJobMembers(
    comptime T: type,
    ctx: T,
    job: platform.ForegroundJob,
    read_hint: ReadHint(T),
) ?Agent {
    if (read_hint(ctx, job.process_group_id)) |agent| return agent;
    return agentHintForNonLeaderForegroundJobMembers(T, ctx, job, read_hint);
}

/// A hint on a non-leader member covers the case where the agent `exec`s a
/// helper that becomes the group leader, leaving the marked process behind
/// it in the same group.
fn agentHintForNonLeaderForegroundJobMembers(
    comptime T: type,
    ctx: T,
    job: platform.ForegroundJob,
    read_hint: ReadHint(T),
) ?Agent {
    for (job.processes) |process| {
        if (process.pid == job.process_group_id) continue;
        if (read_hint(ctx, process.pid)) |agent| return agent;
    }
    return null;
}

/// Identify only the group leader, ignoring the rest of the job - so a
/// recognizable leader wins outright over a better-scoring member.
fn identifyProcessGroupLeaderInJob(alloc: Allocator, job: platform.ForegroundJob) !?[]const u8 {
    const leader = for (job.processes) |*process| {
        if (process.pid == job.process_group_id) break process;
    } else return null;

    const leader_job = platform.ForegroundJob{
        .process_group_id = job.process_group_id,
        .processes = leader[0..1],
    };
    return detection.identifyAgentInJob(alloc, leader_job);
}

fn processProbeResult(
    job: platform.ForegroundJob,
    pid: u32,
    agent: ?Agent,
    process_name: ?[]const u8,
) ProcessProbeResult {
    var foreground_is_pane_shell = false;
    for (job.processes) |process| {
        if (process.pid == pid) {
            foreground_is_pane_shell = true;
            break;
        }
    }
    return .{
        .process_group_id = job.process_group_id,
        .foreground_is_pane_shell = foreground_is_pane_shell,
        .agent = agent,
        .process_name = process_name,
    };
}

fn hintedProcessProbeResult(
    comptime T: type,
    ctx: T,
    job: platform.ForegroundJob,
    pid: u32,
    read_hint: ReadHint(T),
) ?ProcessProbeResult {
    const agent = agentHintForForegroundJobMembers(T, ctx, job, read_hint) orelse return null;
    return processProbeResult(job, pid, agent, agent.agentLabel());
}

/// Resolve which agent (if any) owns the pane's foreground, in descending
/// order of trust: an environment hint on the cheap leader-only job, the
/// leader's own process name, then the full job - hint first, leader
/// second, non-leader hint third, and finally whatever scores best across
/// every member.
fn probeForegroundProcessFromJobs(
    comptime T: type,
    ctx: T,
    alloc: Allocator,
    pid: u32,
    foreground_pgid: ?u32,
    leader_job: ?platform.ForegroundJob,
    foreground_job: ?platform.ForegroundJob,
    read_hint: ReadHint(T),
) !ProcessProbeResult {
    if (leader_job) |job| {
        if (hintedProcessProbeResult(T, ctx, job, pid, read_hint)) |hinted| return hinted;
        if (try detection.identifyAgentInJob(alloc, job)) |process_name| {
            return processProbeResult(job, pid, agentForLabel(alloc, process_name), process_name);
        }
    }

    if (foreground_job) |job| {
        if (read_hint(ctx, job.process_group_id)) |agent| {
            return processProbeResult(job, pid, agent, agent.agentLabel());
        }
        if (try identifyProcessGroupLeaderInJob(alloc, job)) |process_name| {
            return processProbeResult(job, pid, agentForLabel(alloc, process_name), process_name);
        }
        if (agentHintForNonLeaderForegroundJobMembers(T, ctx, job, read_hint)) |agent| {
            return processProbeResult(job, pid, agent, agent.agentLabel());
        }

        const identified = try detection.identifyAgentInJob(alloc, job);
        return processProbeResult(
            job,
            pid,
            if (identified) |name| agentForLabel(alloc, name) else null,
            identified,
        );
    }

    return .{
        .process_group_id = foreground_pgid,
        .foreground_is_pane_shell = false,
        .agent = null,
        .process_name = null,
    };
}

/// `identifyAgentInJob` reports the raw process name it matched on (e.g.
/// "claude-code", "CLAUDE"); this maps that back to the `Agent` it
/// identified as.
fn agentForLabel(alloc: Allocator, process_name: []const u8) ?Agent {
    return detection.agentFromLabel(alloc, process_name) catch null;
}

fn productionAgentHint(alloc: Allocator, pid: u32) ?Agent {
    const label = platform.processAgentHint(alloc, pid) orelse return null;
    return agentForLabel(alloc, label);
}

/// Whether a foreground job is nothing but the pane's own shell.
///
/// herdr tests this by pid - its `child_pid` *is* the shell, so asking
/// whether that pid is in the foreground job answers it. Coastty launches
/// the pane through a wrapper (`login`), so the recorded child pid is the
/// wrapper and never appears in the shell's own process group, which makes
/// the pid test permanently false. Recognising the job by process name
/// reaches the same conclusion from the outside.
fn foregroundJobIsPaneShell(job: platform.ForegroundJob) bool {
    if (job.processes.len == 0) return false;
    for (job.processes) |process| {
        if (!platform.isPaneShellProcessName(process.name)) return false;
    }
    return true;
}

fn probeForegroundProcess(alloc: Allocator, pid: u32, foreground_pgid: ?u32) !ProcessProbeResult {
    const leader_job = if (foreground_pgid) |pgid|
        platform.foregroundGroupLeaderJob(alloc, pgid)
    else
        null;
    // The job actually in front of the pty. herdr resolves this from its
    // `child_pid`, which works there because it spawns the shell itself.
    // Coastty spawns through `login`, so the recorded child pid does not
    // own the pty and resolving through it yields nothing - the pgid we
    // were handed is the reliable route to the same job.
    const foreground_job = if (foreground_pgid) |pgid|
        platform.foregroundJobForProcessGroup(alloc, pgid)
    else
        null;

    var result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        pid,
        foreground_pgid,
        leader_job,
        foreground_job,
        &productionAgentHint,
    );

    if (!result.foreground_is_pane_shell and result.agent == null) {
        if (foreground_job) |job| {
            result.foreground_is_pane_shell = foregroundJobIsPaneShell(job);
        }
    }

    return result;
}

/// How long to wait before the next detection check, by what the pane is
/// currently doing.
///
/// ported-from: `TICK_UNIDENTIFIED`, `TICK_IDENTIFIED`, and
/// `TICK_PENDING_RELEASE` in the detection task in
/// https://github.com/herdrdev/herdr/blob/master/src/pane.rs
const tick_unidentified_ms: i64 = 500;
const tick_identified_ms: i64 = 300;
const tick_pending_release_ms: i64 = 50;

/// Fold a published detection update back into the detector's own record of
/// what it last published. The visible-signal refresh clock only runs while
/// a blocker or working signal is actually on screen.
fn applyAgentDetectionPublishUpdate(
    self: *Detector,
    update: AgentDetectionPublishUpdate,
    observed_at_ms: i64,
    foreground_shell_exit_reported: *bool,
) void {
    self.published = .{
        .state = update.state,
        .visible_idle = update.visible_idle,
        .visible_blocker = update.visible_blocker,
        .visible_working = update.visible_working,
    };
    self.last_visible_signal_refresh_ms = if (update.visible_blocker or update.visible_working)
        observed_at_ms
    else
        null;
    if (update.process_exited) foreground_shell_exit_reported.* = true;
}

/// A relative cwd is meaningless to anything downstream, so it's treated as
/// no answer at all rather than resolved against coastty's own cwd.
fn absoluteProcessCwd(alloc: Allocator, pid: u32) ?[]const u8 {
    const cwd = platform.processCwd(alloc, pid) orelse return null;
    return if (std.fs.path.isAbsolute(cwd)) cwd else null;
}

// ported-from: https://github.com/herdrdev/herdr/blob/master/src/pane.rs
//
// Names are herdr's. Where a test names a non-Claude agent, the agent is
// incidental - what's being pinned down is the state machine (exit-before-
// clear ordering, hint precedence, probe scheduling), which is agent-
// independent.

/// `process_probe_input()` in herdr: a settled pane with a stable foreground
/// group and a probe already taken, which every scheduling test perturbs one
/// field at a time.
fn processProbeInput() timing.ProcessProbeInput {
    return .{
        .current_agent = null,
        .suppressed_agent = null,
        .foreground_pgid = 42,
        .last_foreground_pgid = 42,
        .has_process_probe = true,
        .acquisition_age_ms = null,
        .pending_foreground_shell_clear = false,
        .pending_restore_probe = false,
        .elapsed_since_process_check_ms = 1000,
    };
}

fn hintForPid(comptime target: u32) fn (Allocator, u32) ?Agent {
    return struct {
        fn hint(_: Allocator, pid: u32) ?Agent {
            return if (pid == target) .Claude else null;
        }
    }.hint;
}

fn noHint(_: Allocator, _: u32) ?Agent {
    return null;
}

fn namedProcess(pid: u32, name: []const u8) platform.ForegroundProcess {
    return .{ .pid = pid, .name = name, .argv0 = null, .argv = null, .cmdline = null };
}

test "foreground_shell_reports_process_exit_before_clearing_agent" {
    // The shell is back in the foreground but the exit hasn't been reported
    // yet, so identity is held one more round to publish the final idle.
    try testing.expectEqual(
        ForegroundShellAgentAction.report_process_exit,
        foregroundShellAgentAction(.Claude, null, true, false),
    );
    try testing.expectEqual(
        ForegroundShellAgentAction.clear_agent,
        foregroundShellAgentAction(.Claude, null, true, true),
    );
}

test "same_agent_after_reported_exit_is_a_replacement_process" {
    // The same agent reappearing after its exit was reported is a new run,
    // not the old one still lingering.
    try testing.expectEqual(
        ForegroundShellAgentAction.report_replacement_process,
        foregroundShellAgentAction(.Claude, .Claude, false, true),
    );
}

test "unknown_non_shell_foreground_job_is_not_immediate_clear_signal" {
    // Something unrecognized in the foreground could be a helper the agent
    // spawned, so it doesn't clear identity on its own.
    try testing.expectEqual(
        ForegroundShellAgentAction.observe_probe,
        foregroundShellAgentAction(.Claude, null, false, false),
    );
}

test "reported_process_exit_clears_before_unknown_foreground_probe" {
    try testing.expectEqual(
        ForegroundShellAgentAction.clear_agent,
        foregroundShellAgentAction(.Claude, null, false, true),
    );
}

test "foreground_agent_job_is_not_clear_signal" {
    // herdr uses a second agent here; with one agent the equivalent is the
    // same agent still being found, which is likewise not a clear signal.
    try testing.expectEqual(
        ForegroundShellAgentAction.observe_probe,
        foregroundShellAgentAction(.Claude, .Claude, true, false),
    );
}

test "foreground_agent_hint_accepts_pane_shell_environment" {
    // The pane's shell carries the hint when the agent was launched into an
    // already-running shell.
    const job = platform.ForegroundJob{
        .process_group_id = 42,
        .processes = &.{namedProcess(42, "bash")},
    };
    try testing.expectEqual(
        @as(?Agent, .Claude),
        agentHintForForegroundJobMembers(Allocator, testing.allocator, job, hintForPid(42)),
    );
}

test "foreground_agent_hint_accepts_non_leader_foreground_process_environment" {
    const job = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{ namedProcess(99, "fence"), namedProcess(100, "claude") },
    };
    try testing.expectEqual(
        @as(?Agent, .Claude),
        agentHintForForegroundJobMembers(Allocator, testing.allocator, job, hintForPid(100)),
    );
}

test "foreground_agent_hint_wins_over_process_name_detection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The environment hint is what coastty itself stamped on the pane, so it
    // beats guessing from the process name.
    const job = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{namedProcess(99, "node")},
    };
    const result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        42,
        99,
        job,
        null,
        hintForPid(99),
    );
    try testing.expectEqual(@as(?Agent, .Claude), result.agent);
    try testing.expectEqualStrings("claude", result.process_name.?);
}

test "foreground_agent_hint_on_inherited_child_environment_is_authoritative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{namedProcess(99, "vim")},
    };
    const result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        42,
        99,
        null,
        job,
        hintForPid(99),
    );
    try testing.expectEqual(@as(?Agent, .Claude), result.agent);
    try testing.expectEqualStrings("claude", result.process_name.?);
}

test "non_leader_agent_hint_does_not_override_identifiable_leader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A recognizable group leader is the strongest signal in the job, so a
    // hint on a sibling process doesn't displace it.
    const job = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{ namedProcess(99, "claude"), namedProcess(100, "vim") },
    };
    const result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        42,
        99,
        null,
        job,
        hintForPid(100),
    );
    try testing.expectEqual(@as(?Agent, .Claude), result.agent);
    try testing.expectEqualStrings("claude", result.process_name.?);
}

test "non_leader_agent_hint_wins_when_leader_is_unidentified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const job = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{ namedProcess(99, "some_vm"), namedProcess(100, "vim") },
    };
    const result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        42,
        99,
        null,
        job,
        hintForPid(100),
    );
    try testing.expectEqual(@as(?Agent, .Claude), result.agent);
    try testing.expectEqualStrings("claude", result.process_name.?);
}

test "process_probe_input" {
    // The shared fixture must actually be the settled case the other
    // scheduling tests assume, or every one of them proves nothing.
    const input = processProbeInput();
    try testing.expectEqual(@as(?Agent, null), input.current_agent);
    try testing.expectEqual(@as(?Agent, null), input.suppressed_agent);
    try testing.expectEqual(@as(?u32, 42), input.foreground_pgid);
    try testing.expectEqual(@as(?u32, 42), input.last_foreground_pgid);
    try testing.expect(input.has_process_probe);
    try testing.expectEqual(@as(?i64, null), input.acquisition_age_ms);
    try testing.expect(!input.pending_foreground_shell_clear);
    try testing.expect(!input.pending_restore_probe);
    try testing.expect(!timing.shouldProbeForegroundJob(input));
}

test "windows_foreground_observation_schedule_preserves_lifecycle_checks" {
    var quiet = processProbeInput();
    quiet.current_agent = .Claude;

    const before_safety_bound = timing.process_recheck_identified_ms - 1;

    try testing.expect(!shouldObserveForegroundProcessGroup(false, false, before_safety_bound, quiet));
    try testing.expect(shouldObserveForegroundProcessGroup(false, true, before_safety_bound, quiet));
    try testing.expect(shouldObserveForegroundProcessGroup(true, true, before_safety_bound, quiet));

    {
        var input = quiet;
        input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms;
        try testing.expect(shouldObserveForegroundProcessGroup(false, false, before_safety_bound, input));
    }
    try testing.expect(shouldObserveForegroundProcessGroup(true, false, timing.process_recheck_identified_ms, quiet));

    // Conditions that always force an observation, regardless of elapsed time.
    var immediate = [_]timing.ProcessProbeInput{ quiet, quiet, quiet, quiet, quiet };
    immediate[0].has_process_probe = false;
    immediate[1].current_agent = null;
    immediate[1].acquisition_age_ms = 0;
    immediate[2].pending_restore_probe = true;
    immediate[3].suppressed_agent = .Claude;
    immediate[4].pending_foreground_shell_clear = true;
    for (immediate) |input| {
        try testing.expect(shouldObserveForegroundProcessGroup(false, false, 0, input));
    }
}

test "unchanged_unidentified_foreground_group_skips_full_process_probe" {
    try testing.expect(!timing.shouldProbeForegroundJob(processProbeInput()));
}

test "unidentified_foreground_group_change_runs_full_process_probe" {
    var input = processProbeInput();
    input.foreground_pgid = 43;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "unidentified_pane_gets_initial_process_probe" {
    var input = processProbeInput();
    input.has_process_probe = false;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "stable_unidentified_foreground_group_has_no_safety_process_probe" {
    // With a group present and nothing changing, there's nothing a repeat
    // probe could discover.
    var input = processProbeInput();
    input.elapsed_since_process_check_ms = timing.process_recheck_missing_foreground_group_ms;
    try testing.expect(!timing.shouldProbeForegroundJob(input));
}

test "unidentified_pane_without_foreground_group_uses_safety_process_probe" {
    var input = processProbeInput();
    input.foreground_pgid = null;
    input.last_foreground_pgid = null;
    try testing.expect(!timing.shouldProbeForegroundJob(input));

    input.elapsed_since_process_check_ms = timing.process_recheck_missing_foreground_group_ms;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "unidentified_pane_probes_when_foreground_group_disappears" {
    var input = processProbeInput();
    input.foreground_pgid = null;
    input.last_foreground_pgid = 42;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "inferred_group_does_not_trigger_a_probe_on_every_tick" {
    // A pgid the probe inferred rather than observed must not be recorded,
    // or the next tick reads it as a change and probes again forever.
    const tracked = processGroupForChangeTracking(null, 300);
    try testing.expectEqual(@as(?u32, null), tracked);

    var input = processProbeInput();
    input.current_agent = .Claude;
    input.foreground_pgid = null;
    input.last_foreground_pgid = tracked;
    input.elapsed_since_process_check_ms = 300;
    try testing.expect(!timing.shouldProbeForegroundJob(input));
}

test "pending_shell_clear_and_restore_force_process_probes" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.pending_foreground_shell_clear = true;
    try testing.expect(timing.shouldProbeForegroundJob(input));

    input = processProbeInput();
    input.current_agent = .Claude;
    input.pending_restore_probe = true;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "lifecycle_authority_skips_stable_routine_process_probe" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms;

    try testing.expect(shouldSkipProcessProbeForLifecycleAuthority(true, input));
    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(false, input));
}

test "lifecycle_authority_keeps_periodic_probes_without_an_observed_group" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.foreground_pgid = null;
    input.last_foreground_pgid = null;
    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms;

    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(true, input));
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "lifecycle_authority_preserves_process_exit_and_release_probes" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.pending_foreground_shell_clear = true;
    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(true, input));

    input = processProbeInput();
    input.current_agent = .Claude;
    input.suppressed_agent = .Claude;
    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(true, input));
}

test "lifecycle_authority_preserves_initial_and_foreground_group_change_probes" {
    var input = processProbeInput();
    input.current_agent = null;
    input.has_process_probe = false;
    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(true, input));

    input = processProbeInput();
    input.current_agent = .Claude;
    input.foreground_pgid = 43;
    try testing.expect(!shouldSkipProcessProbeForLifecycleAuthority(true, input));
}

test "pending_release_forces_initial_process_probe" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.suppressed_agent = .Claude;
    input.has_process_probe = false;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "pending_release_forces_process_probe_after_runtime_identity_clears" {
    var input = processProbeInput();
    input.current_agent = null;
    input.suppressed_agent = .Claude;
    input.has_process_probe = false;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "pending_release_skips_repeated_probe_when_foreground_group_is_stable" {
    var input = processProbeInput();
    input.current_agent = null;
    input.suppressed_agent = .Claude;
    try testing.expect(!timing.shouldProbeForegroundJob(input));
}

test "pending_release_probes_when_foreground_group_changes" {
    var input = processProbeInput();
    input.current_agent = null;
    input.suppressed_agent = .Claude;
    input.foreground_pgid = 43;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "acquisition_window_catches_delayed_same_group_wrapper_startup" {
    // An agent that starts slowly inside an already-existing process group
    // produces no group change, so only the acquisition window catches it -
    // fast at first, then slower, then not at all.
    var input = processProbeInput();
    input.current_agent = null;
    input.acquisition_age_ms = 1250;
    input.elapsed_since_process_check_ms = timing.process_acquisition_fast_recheck_ms - 1;
    try testing.expect(!timing.shouldProbeForegroundJob(input));

    input.elapsed_since_process_check_ms = timing.process_acquisition_fast_recheck_ms;
    try testing.expect(timing.shouldProbeForegroundJob(input));

    input.acquisition_age_ms = 5000;
    input.elapsed_since_process_check_ms = timing.process_acquisition_slow_recheck_ms;
    try testing.expect(timing.shouldProbeForegroundJob(input));

    input.acquisition_age_ms = timing.process_acquisition_window_ms + 1;
    try testing.expect(!timing.shouldProbeForegroundJob(input));
}

test "content_change_starts_bounded_unidentified_acquisition_window" {
    const now: i64 = 1_000_000;
    var acquisition_started_at_ms: ?i64 = null;
    var last_content_change_at_ms: ?i64 = null;

    syncContentChangeAcquisition(null, null, false, true, now, &acquisition_started_at_ms, &last_content_change_at_ms);
    try testing.expectEqual(@as(?i64, now), acquisition_started_at_ms);
    try testing.expectEqual(@as(?i64, now), last_content_change_at_ms);

    // Continued output extends the last-change time but must not restart the
    // window - otherwise a busy pane would probe at the fast rate forever.
    const later = now + 1000;
    syncContentChangeAcquisition(null, null, false, true, later, &acquisition_started_at_ms, &last_content_change_at_ms);
    try testing.expectEqual(@as(?i64, now), acquisition_started_at_ms);
    try testing.expectEqual(@as(?i64, later), last_content_change_at_ms);

    const quiet_after_window = later +
        timing.process_acquisition_window_ms +
        timing.process_acquisition_idle_reset_ms;
    syncContentChangeAcquisition(null, null, false, false, quiet_after_window, &acquisition_started_at_ms, &last_content_change_at_ms);
    try testing.expectEqual(@as(?i64, null), acquisition_started_at_ms);
    try testing.expectEqual(@as(?i64, null), last_content_change_at_ms);

    const next_burst = quiet_after_window + 1000;
    syncContentChangeAcquisition(null, null, false, true, next_burst, &acquisition_started_at_ms, &last_content_change_at_ms);
    try testing.expectEqual(@as(?i64, next_burst), acquisition_started_at_ms);
    try testing.expectEqual(@as(?i64, next_burst), last_content_change_at_ms);
}

test "content_change_does_not_start_acquisition_when_process_probe_has_other_signal" {
    const now: i64 = 1_000_000;

    for ([_]struct { current: ?Agent, suppressed: ?Agent, group_changed: bool }{
        .{ .current = .Claude, .suppressed = null, .group_changed = false },
        .{ .current = null, .suppressed = .Claude, .group_changed = false },
        .{ .current = null, .suppressed = null, .group_changed = true },
    }) |case| {
        var acquisition_started_at_ms: ?i64 = null;
        var last_content_change_at_ms: ?i64 = null;
        syncContentChangeAcquisition(
            case.current,
            case.suppressed,
            case.group_changed,
            true,
            now,
            &acquisition_started_at_ms,
            &last_content_change_at_ms,
        );
        try testing.expectEqual(@as(?i64, null), acquisition_started_at_ms);
        try testing.expectEqual(@as(?i64, null), last_content_change_at_ms);
    }
}

test "content_change_restarts_stale_process_group_acquisition_window" {
    const now: i64 = 1_000_000;
    var acquisition_started_at_ms: ?i64 = now - timing.process_acquisition_window_ms - 1;
    var last_content_change_at_ms: ?i64 = null;

    syncContentChangeAcquisition(null, null, false, true, now, &acquisition_started_at_ms, &last_content_change_at_ms);
    try testing.expectEqual(@as(?i64, now), acquisition_started_at_ms);
    try testing.expectEqual(@as(?i64, now), last_content_change_at_ms);
}

test "release_expiry_can_force_reacquire_probe_by_resetting_probe_state" {
    // Clearing `has_process_probe` is how a release expiry forces a fresh
    // acquisition without any other state changing.
    var input = processProbeInput();
    input.current_agent = null;
    input.has_process_probe = false;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "identified_agent_uses_shorter_safety_process_probe" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms - 1;
    try testing.expect(!timing.shouldProbeForegroundJob(input));

    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "identified_agent_probes_when_foreground_group_disappears" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.foreground_pgid = null;
    input.last_foreground_pgid = 42;
    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms - 1;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "stable_missing_foreground_group_uses_safety_process_probe" {
    var input = processProbeInput();
    input.current_agent = .Claude;
    input.foreground_pgid = null;
    input.last_foreground_pgid = null;
    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms - 1;
    try testing.expect(!timing.shouldProbeForegroundJob(input));

    input.elapsed_since_process_check_ms = timing.process_recheck_identified_ms;
    try testing.expect(timing.shouldProbeForegroundJob(input));
}

test "transient_process_miss_keeps_current_agent_detected" {
    var presence = AgentDetectionPresence.fromAgent(.Claude);
    try testing.expect(!presence.observeProcessProbe(null));
    try testing.expectEqual(@as(?Agent, .Claude), presence.currentAgent());
}

test "agent_only_clears_after_confirmation_misses" {
    var presence = AgentDetectionPresence.fromAgent(.Claude);

    for (1..agent_miss_confirmation_attempts) |_| {
        try testing.expect(!presence.observeProcessProbe(null));
        try testing.expectEqual(@as(?Agent, .Claude), presence.currentAgent());
    }

    try testing.expect(presence.observeProcessProbe(null));
    try testing.expectEqual(@as(?Agent, null), presence.currentAgent());

    // A found agent resets the miss counter outright.
    presence = AgentDetectionPresence.fromAgent(.Claude);
    try testing.expect(!presence.observeProcessProbe(null));
    try testing.expect(!presence.observeProcessProbe(.Claude));
    try testing.expectEqual(@as(u8, 0), presence.consecutive_misses);
}

test "applyForegroundShellAgentAction drives presence and the exit-report flags" {
    var presence = AgentDetectionPresence.fromAgent(.Claude);
    var pending_clear = false;
    var exit_reported = false;

    // report_process_exit: identity held, clear pending.
    try testing.expect(!applyForegroundShellAgentAction(
        &presence,
        .report_process_exit,
        .Claude,
        null,
        &pending_clear,
        &exit_reported,
    ));
    try testing.expect(pending_clear);
    try testing.expectEqual(@as(?Agent, .Claude), presence.currentAgent());

    // clear_agent: identity dropped, both flags reset.
    exit_reported = true;
    try testing.expect(applyForegroundShellAgentAction(
        &presence,
        .clear_agent,
        .Claude,
        null,
        &pending_clear,
        &exit_reported,
    ));
    try testing.expect(!pending_clear);
    try testing.expect(!exit_reported);
    try testing.expectEqual(@as(?Agent, null), presence.currentAgent());

    // report_replacement_process: identity restored and reported as changed.
    try testing.expect(applyForegroundShellAgentAction(
        &presence,
        .report_replacement_process,
        .Claude,
        .Claude,
        &pending_clear,
        &exit_reported,
    ));
    try testing.expectEqual(@as(?Agent, .Claude), presence.currentAgent());
}

test "probeForegroundProcessFromJobs reports no agent when there is no job at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try probeForegroundProcessFromJobs(
        Allocator,
        alloc,
        alloc,
        42,
        7,
        null,
        null,
        &noHint,
    );
    try testing.expectEqual(@as(?u32, 7), result.process_group_id);
    try testing.expect(!result.foreground_is_pane_shell);
    try testing.expectEqual(@as(?Agent, null), result.agent);
    try testing.expectEqual(@as(?[]const u8, null), result.process_name);
}

test "availablePaneShellFromJob reports the shell only when nothing else is running" {
    const shell_only = platform.ForegroundJob{
        .process_group_id = 42,
        .processes = &.{namedProcess(42, "zsh")},
    };
    try testing.expectEqualStrings("zsh", platform.availablePaneShellFromJob(42, shell_only).?);

    // A non-shell in the pane's own group means something was exec'd there.
    const non_shell = platform.ForegroundJob{
        .process_group_id = 42,
        .processes = &.{namedProcess(42, "vim")},
    };
    try testing.expectEqual(@as(?[]const u8, null), platform.availablePaneShellFromJob(42, non_shell));

    // A different foreground group entirely is not the pane's shell.
    const other_group = platform.ForegroundJob{
        .process_group_id = 99,
        .processes = &.{namedProcess(99, "zsh")},
    };
    try testing.expectEqual(@as(?[]const u8, null), platform.availablePaneShellFromJob(42, other_group));
}

fn foregroundProcess(alloc: Allocator, pid: u32, name: []const u8, argv: []const []const u8) !platform.ForegroundProcess {
    return .{
        .pid = pid,
        .name = name,
        .argv0 = null,
        .argv = argv,
        .cmdline = try std.mem.join(alloc, " ", argv),
    };
}

/// An absolute cwd that still exists. A process can hold a cwd that has
/// since been deleted, and handing that to a new pane would fail.
fn usableProcessCwd(alloc: Allocator, pid: u32) ?[]const u8 {
    const cwd = absoluteProcessCwd(alloc, pid) orelse return null;
    var dir = std.fs.openDirAbsolute(cwd, .{}) catch return null;
    dir.close();
    return cwd;
}

/// The agent whose re-acquisition is currently suppressed, if the release
/// window hasn't expired. Clears the release once it has.
fn activePendingRelease(pending: *?PendingAgentRelease, now_ms: i64) ?Agent {
    const active = pending.* orelse return null;
    if (now_ms < active.until_ms) return active.agent;
    pending.* = null;
    return null;
}

/// herdr sends this to its app event loop; coastty surfaces the same
/// transition through `Detector.update`'s return value, which the caller
/// forwards over the C API. The detector's own bookkeeping for "an agent
/// was just identified here" is the startup grace window.
fn publishAgentProcessDetectedEvent(self: *Detector, agent: Agent, observed_at_ms: i64) void {
    self.agent = agent;
    self.startup_grace_until_ms = observed_at_ms + timing.agent_startup_grace_window_ms;
    self.published = .{ .state = .Unknown };
    self.last_visible_signal_refresh_ms = null;
    self.pending_idle.clear();
}

test "set_full_lifecycle_authority_active_notifies_only_on_activation_transitions" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    // Get the detector into a non-default state so the reset is observable.
    _ = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });
    _ = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    try testing.expectEqual(AgentState.Working, d.published.state);

    // false -> true resets detection: a hook integration taking over must
    // not inherit screen-derived state.
    try testing.expect(setFullLifecycleAuthorityActive(&d, true));
    try testing.expectEqual(AgentState.Unknown, d.published.state);
    try testing.expectEqual(@as(?Agent, null), d.agent);
    try testing.expect(d.full_lifecycle_authority_active);

    // true -> true is not a transition, so it must not reset again.
    _ = try d.update(testing.allocator, after_grace_ms * 2, .Claude, false, .{ .screen = "" });
    const before = d.agent;
    try testing.expect(!setFullLifecycleAuthorityActive(&d, true));
    try testing.expectEqual(before, d.agent);

    // true -> false hands control back without resetting.
    try testing.expect(!setFullLifecycleAuthorityActive(&d, false));
    try testing.expect(!d.full_lifecycle_authority_active);
    try testing.expectEqual(before, d.agent);
}

test "beginGracefulRelease suppresses the released agent until the window expires" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    beginGracefulRelease(&d, .Claude, 1000);
    try testing.expectEqual(
        @as(?Agent, .Claude),
        activePendingRelease(&d.pending_release, 1000 + release_reacquire_suppression_ms - 1),
    );

    // At the boundary the release expires and clears itself.
    try testing.expectEqual(
        @as(?Agent, null),
        activePendingRelease(&d.pending_release, 1000 + release_reacquire_suppression_ms),
    );
    try testing.expectEqual(@as(?PendingAgentRelease, null), d.pending_release);
}

test "resetAgentDetection clears every field derived from the previous process" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    _ = try d.update(testing.allocator, 0, .Claude, false, .{ .screen = "" });
    _ = try d.update(testing.allocator, after_grace_ms, .Claude, false, .{
        .screen = "",
        .osc_title = "⠂ working",
    });
    d.agent_presence = AgentDetectionPresence.fromAgent(.Claude);
    d.has_process_probe = true;
    d.last_foreground_pgid = 42;
    d.pending_foreground_shell_clear = true;
    d.foreground_shell_exit_reported = true;
    d.pending_release = .{ .agent = .Claude, .until_ms = 9999 };

    resetAgentDetection(&d);

    try testing.expectEqual(AgentState.Unknown, d.published.state);
    try testing.expectEqual(@as(?Agent, null), d.agent);
    try testing.expectEqual(@as(?Agent, null), d.agent_presence.currentAgent());
    try testing.expectEqual(@as(?i64, null), d.startup_grace_until_ms);
    try testing.expectEqual(@as(?i64, null), d.last_visible_signal_refresh_ms);
    try testing.expect(!d.has_process_probe);
    try testing.expectEqual(@as(?u32, null), d.last_foreground_pgid);
    try testing.expect(!d.pending_foreground_shell_clear);
    try testing.expect(!d.foreground_shell_exit_reported);
    try testing.expect(!d.pending_idle.active());

    // A suppression window set from outside the pane must survive the reset.
    try testing.expectEqual(@as(?Agent, .Claude), d.pending_release.?.agent);
}

test "applyAgentDetectionPublishUpdate records the publish and the exit report" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    var exit_reported = false;
    applyAgentDetectionPublishUpdate(&d, .{
        .state = .Blocked,
        .visible_blocker = true,
    }, 500, &exit_reported);

    try testing.expectEqual(AgentState.Blocked, d.published.state);
    try testing.expect(d.published.visible_blocker);
    try testing.expectEqual(@as(?i64, 500), d.last_visible_signal_refresh_ms);
    try testing.expect(!exit_reported);

    // Idle carries no live signal, so the refresh clock stops.
    applyAgentDetectionPublishUpdate(&d, .{
        .state = .Idle,
        .visible_idle = true,
        .process_exited = true,
    }, 900, &exit_reported);

    try testing.expectEqual(AgentState.Idle, d.published.state);
    try testing.expectEqual(@as(?i64, null), d.last_visible_signal_refresh_ms);
    try testing.expect(exit_reported);
}

test "detectionText and the OSC accessors read straight off the detection input" {
    const input: manifest.DetectionInput = .{
        .screen = "screen tail",
        .osc_title = "⠂ working",
        .osc_progress = "4;3;",
    };
    try testing.expectEqualStrings("screen tail", detectionText(input));
    try testing.expectEqualStrings("⠂ working", agentOscTitle(input));
    try testing.expectEqualStrings("4;3;", agentOscProgress(input));
}

test "publishAgentProcessDetectedEvent starts the startup grace window" {
    var d = try Detector.init(testing.allocator);
    defer d.deinit();

    publishAgentProcessDetectedEvent(&d, .Claude, 1000);
    try testing.expectEqual(@as(?Agent, .Claude), d.agent);
    try testing.expectEqual(
        @as(?i64, 1000 + timing.agent_startup_grace_window_ms),
        d.startup_grace_until_ms,
    );
    try testing.expectEqual(AgentState.Unknown, d.published.state);
}

// herdr owns its terminal emulator, so these three read straight off it.
// coastty's emulator is Ghostty's, and detection is a consumer of it rather
// than its owner: `Termio` captures the screen tail and the OSC side
// channels and passes them in as `manifest.DetectionInput`. These stay as
// the named seam, so a caller that holds a terminal can supply them.

fn detectionText(input: manifest.DetectionInput) []const u8 {
    return input.screen;
}

fn agentOscTitle(input: manifest.DetectionInput) []const u8 {
    return input.osc_title;
}

fn agentOscProgress(input: manifest.DetectionInput) []const u8 {
    return input.osc_progress;
}

/// Drop everything derived from the previous process so the next check
/// starts from nothing. Used when a pane is reused for new work.
///
/// `pending_release` and `full_lifecycle_authority_active` deliberately
/// survive: both describe a decision made *about* this pane from outside it,
/// and a reset is exactly when they still need to apply.
fn resetAgentDetection(self: *Detector) void {
    self.published = .{ .state = .Unknown };
    self.pending_idle.clear();
    self.last_visible_signal_refresh_ms = null;
    self.agent = null;
    self.startup_grace_until_ms = null;
    self.agent_presence = .{};
    self.has_process_probe = false;
    self.last_foreground_pgid = null;
    self.last_process_check_ms = null;
    self.acquisition_started_at_ms = null;
    self.last_content_change_at_ms = null;
    self.pending_foreground_shell_clear = false;
    self.foreground_shell_exit_reported = false;
}

/// Returns true if this call switched authority on, which is the edge that
/// has to reset detection - a hook integration taking over mid-pane must
/// not inherit screen-derived state.
fn setFullLifecycleAuthorityActive(self: *Detector, active: bool) bool {
    const previous = self.full_lifecycle_authority_active;
    self.full_lifecycle_authority_active = active;
    if (active and !previous) {
        resetAgentDetection(self);
        return true;
    }
    return false;
}

/// Stop treating `agent` as present for a short window, without clearing
/// the pane outright. Used when an agent is being deliberately handed off,
/// so its own still-dying process can't be re-acquired as a new one.
fn beginGracefulRelease(self: *Detector, agent: Agent, now_ms: i64) void {
    self.pending_release = .{
        .agent = agent,
        .until_ms = now_ms + release_reacquire_suppression_ms,
    };
    resetAgentDetection(self);
}

/// How long a released agent stays suppressed from re-acquisition.
pub const release_reacquire_suppression_ms: i64 = 3_000;

/// The cwd to inherit when splitting or duplicating a pane: whatever the
/// foreground command moved to, falling back to the shell's own cwd.
fn foregroundCwd(alloc: Allocator, child_pid: u32) ?[]const u8 {
    const shell_cwd = absoluteProcessCwd(alloc, child_pid);
    const foreground_pgid = platform.foregroundProcessGroupId(child_pid);
    const leader_cwd = if (foreground_pgid) |pgid| absoluteProcessCwd(alloc, pgid) else null;

    const leader_matches_shell = if (leader_cwd) |leader|
        (if (shell_cwd) |shell| std.mem.eql(u8, leader, shell) else false)
    else
        shell_cwd == null;

    if (leader_matches_shell) {
        return foregroundMemberCwdDifferentFromShell(alloc, child_pid, shell_cwd) orelse leader_cwd;
    }
    return leader_cwd orelse foregroundMemberCwdDifferentFromShell(alloc, child_pid, shell_cwd);
}

/// The PowerShell profile snippet coastty injects for shell integration.
/// Detection has to recognize it so a pane running shell integration isn't
/// mistaken for one running an agent named in that command text.
///
/// ported-from: `WINDOWS_POWERSHELL_SHELL_INTEGRATION_COMMAND` in
/// https://github.com/herdrdev/herdr/blob/master/src/pane.rs
pub const WINDOWS_POWERSHELL_SHELL_INTEGRATION_COMMAND =
    "if ($null -eq $global:__CoasttyOriginalPrompt) { $global:__CoasttyOriginalPrompt = " ++
    "$function:prompt; function global:prompt { $out = @(& $global:__CoasttyOriginalPrompt) -join ' '; " ++
    "$loc = $ExecutionContext.SessionState.Path.CurrentLocation; if ($loc.Provider.Name -eq 'FileSystem') " ++
    "{ $esc = [string][char]27; $out += $esc + ']9;9;' + $loc.ProviderPath + $esc + '\\' }; $out } }";
