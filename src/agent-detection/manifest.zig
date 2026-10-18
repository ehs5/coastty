// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Generic, priority-based rule-evaluation engine for agent detection.
//!
//! ported-from: https://github.com/herdrdev/herdr/blob/master/src/detect/manifest.rs
//!
//! A manifest is a fixed list of `Rule`s. Each rule names a text `Region`
//! to run against (a slice of the pane's screen content, or one of the
//! OSC-derived side channels) and a boolean `Gate` that decides whether the
//! rule matches. On every check, every rule is evaluated; among the rules
//! that match, the one with the highest `priority` wins (ties favor the
//! earlier-declared rule). No match falls back to `.Idle`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");
const detection = @import("main.zig");
const manifest_update = @import("manifest_update.zig");
const claude_manifest_rules = @import("manifests/claude.zig");

pub const Agent = detection.Agent;
pub const AgentState = detection.AgentState;
pub const AgentDetection = detection.AgentDetection;

/// Input to the detection engine: the current screen snapshot plus the
/// OSC-derived title/progress strings captured from the pane. Pass empty
/// strings for `osc_title`/`osc_progress` when that data isn't available.
pub const DetectionInput = struct {
    screen: []const u8,
    osc_title: []const u8 = "",
    osc_progress: []const u8 = "",
};

/// Which named text region a matcher runs against. This is the full region
/// set from herdr's generic engine; Claude's rule set only exercises a
/// subset of these (osc_title, osc_progress, whole_recent,
/// bottom_non_empty_lines(N), prompt_box_body, after_last_horizontal_rule),
/// but the others are ported too since they're engine features, not
/// per-agent behavior.
pub const Region = union(enum) {
    osc_title,
    osc_progress,
    whole_recent,
    /// The screen content after the last Codex-style `›`-prompt-marker
    /// line, or the whole screen if there isn't one.
    after_last_prompt_marker,
    /// The screen content before the *current* (unanswered) Codex-style
    /// prompt marker, or the whole screen if there isn't one.
    before_current_prompt_marker,
    /// The whole screen, unless a current prompt marker is present (in
    /// which case "").
    whole_recent_without_current_prompt_marker,
    /// The block-marker line (`•`/`■`/`✗`/`✓`) immediately preceding the
    /// current prompt marker, if any.
    current_prompt_block_marker,
    /// The screen content from that block-marker line onward, if any.
    after_current_prompt_block_marker,
    prompt_box_body,
    /// The screen content above the live prompt box's top border.
    above_prompt_box,
    /// The last non-empty line above the live prompt box.
    last_non_empty_above_prompt_box,
    after_last_horizontal_rule,
    bottom_lines: usize,
    bottom_non_empty_lines: usize,
    top_non_empty_lines: usize,
};

/// A boolean matcher gate. `contains`/`regex`/`line_regex` are AND-ed with
/// each other and with `all`; `any` requires at least one nested gate to
/// match; `not` disqualifies the match if any nested gate matches. An empty
/// gate (no matchers at all) matches vacuously.
pub const Gate = struct {
    contains: []const []const u8 = &.{},
    regex: []const []const u8 = &.{},
    line_regex: []const []const u8 = &.{},
    all: []const Gate = &.{},
    any: []const Gate = &.{},
    not: []const Gate = &.{},
};

pub const Rule = struct {
    id: []const u8,
    state: AgentState,
    priority: i32 = 0,
    region: Region = .whole_recent,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
    /// When this rule wins, the caller should keep the previously published
    /// state instead of publishing `state`. Used for agent-owned viewers
    /// (e.g. a transcript scrollback overlay) that show something other
    /// than the live prompt.
    skip_state_update: bool = false,
    gate: Gate = .{},
};

const CompiledGate = struct {
    contains: []const []const u8,
    regex: []oni.Regex,
    line_regex: []oni.Regex,
    all: []CompiledGate,
    any: []CompiledGate,
    not: []CompiledGate,

    fn deinit(self: *CompiledGate, alloc: Allocator) void {
        for (self.regex) |*r| r.deinit();
        for (self.line_regex) |*r| r.deinit();
        for (self.all) |*g| g.deinit(alloc);
        for (self.any) |*g| g.deinit(alloc);
        for (self.not) |*g| g.deinit(alloc);
        alloc.free(self.regex);
        alloc.free(self.line_regex);
        alloc.free(self.all);
        alloc.free(self.any);
        alloc.free(self.not);
    }
};

const CompiledRule = struct {
    rule: *const Rule,
    gate: CompiledGate,
};

/// A manifest with all of its regex patterns pre-compiled. Build once per
/// long-lived detector (e.g. once per surface), not per check.
pub const CompiledManifest = struct {
    alloc: Allocator,
    rules: []CompiledRule,

    pub fn compile(alloc: Allocator, rules: []const Rule) !CompiledManifest {
        const compiled = try alloc.alloc(CompiledRule, rules.len);
        errdefer alloc.free(compiled);

        var built: usize = 0;
        errdefer for (compiled[0..built]) |*cr| cr.gate.deinit(alloc);

        for (rules, 0..) |*rule, i| {
            compiled[i] = .{ .rule = rule, .gate = try compileGate(alloc, rule.gate) };
            built = i + 1;
        }

        return .{ .alloc = alloc, .rules = compiled };
    }

    pub fn deinit(self: *CompiledManifest) void {
        for (self.rules) |*cr| cr.gate.deinit(self.alloc);
        self.alloc.free(self.rules);
    }
};

/// `compileGate` and `compileGateList` recurse into each other (a gate can
/// nest gates), so their error sets can't be mutually inferred - at least
/// one side needs an explicit type to break the cycle.
const CompileError = Allocator.Error || oni.errors.Error;

fn compileGate(alloc: Allocator, gate: Gate) CompileError!CompiledGate {
    const regex = try compilePatterns(alloc, gate.regex);
    errdefer freeRegexList(alloc, regex);

    const line_regex = try compilePatterns(alloc, gate.line_regex);
    errdefer freeRegexList(alloc, line_regex);

    const all = try compileGateList(alloc, gate.all);
    errdefer freeGateList(alloc, all);

    const any = try compileGateList(alloc, gate.any);
    errdefer freeGateList(alloc, any);

    const not = try compileGateList(alloc, gate.not);
    errdefer freeGateList(alloc, not);

    return .{
        .contains = gate.contains,
        .regex = regex,
        .line_regex = line_regex,
        .all = all,
        .any = any,
        .not = not,
    };
}

fn compilePatterns(alloc: Allocator, patterns: []const []const u8) CompileError![]oni.Regex {
    var list: std.ArrayList(oni.Regex) = .empty;
    errdefer freeRegexList(alloc, list.items);
    for (patterns) |pattern| {
        var regex = try oni.Regex.init(pattern, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
        errdefer regex.deinit();
        try list.append(alloc, regex);
    }
    return try list.toOwnedSlice(alloc);
}

fn compileGateList(alloc: Allocator, gates: []const Gate) CompileError![]CompiledGate {
    var list: std.ArrayList(CompiledGate) = .empty;
    errdefer freeGateList(alloc, list.items);
    for (gates) |gate| {
        var compiled = try compileGate(alloc, gate);
        errdefer compiled.deinit(alloc);
        try list.append(alloc, compiled);
    }
    return try list.toOwnedSlice(alloc);
}

fn freeRegexList(alloc: Allocator, list: []oni.Regex) void {
    for (list) |*r| r.deinit();
    alloc.free(list);
}

fn freeGateList(alloc: Allocator, list: []CompiledGate) void {
    for (list) |*g| g.deinit(alloc);
    alloc.free(list);
}

/// Evaluate every rule in `compiled` against `input` and return the
/// winning rule's detection, or `.Idle` if nothing matched. Allocates a
/// short-lived arena for region-text extraction; safe to call on every
/// PTY-output event.
pub fn evaluate(gpa: Allocator, compiled: *const CompiledManifest, input: DetectionInput) !AgentDetection {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var matched: ?*const CompiledRule = null;
    for (compiled.rules) |*candidate| {
        const region_text = try region(arena, input, candidate.rule.region);
        if (!try gateMatches(&candidate.gate, region_text)) continue;

        if (matched) |previous| {
            if (previous.rule.priority >= candidate.rule.priority) continue;
        }
        matched = candidate;
    }

    const winner = (matched orelse return .{ .state = .Idle }).rule;
    return .{
        .state = winner.state,
        .skip_state_update = winner.skip_state_update,
        .visible_idle = winner.visible_idle and winner.state == .Idle,
        .visible_blocker = winner.visible_blocker and winner.state == .Blocked,
        .visible_working = winner.visible_working and winner.state == .Working,
    };
}

fn gateMatches(gate: *const CompiledGate, text: []const u8) !bool {
    for (gate.contains) |needle| {
        if (!containsIgnoreCase(text, needle)) return false;
    }
    for (gate.regex) |*r| {
        if (!try regexMatches(r, text)) return false;
    }
    for (gate.line_regex) |*r| {
        if (!try lineRegexMatches(r, text)) return false;
    }
    for (gate.all) |*nested| {
        if (!try gateMatches(nested, text)) return false;
    }
    if (gate.any.len > 0) {
        for (gate.any) |*nested| {
            if (try gateMatches(nested, text)) break;
        } else return false;
    }
    for (gate.not) |*nested| {
        if (try gateMatches(nested, text)) return false;
    }
    return true;
}

fn regexMatches(r: *oni.Regex, text: []const u8) !bool {
    var match = r.search(text, .{}) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    match.deinit();
    return true;
}

fn lineRegexMatches(r: *oni.Regex, text: []const u8) !bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (try regexMatches(r, line)) return true;
    }
    return false;
}

/// ASCII case-insensitive substring search. All of Claude's manifest
/// `contains` needles are plain ASCII, so full Unicode case-folding (as
/// herdr's Rust implementation does) isn't needed here.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn region(alloc: Allocator, input: DetectionInput, spec: Region) ![]const u8 {
    return switch (spec) {
        .osc_title => input.osc_title,
        .osc_progress => input.osc_progress,
        .whole_recent => input.screen,
        .after_last_prompt_marker => try afterLastPromptMarker(alloc, input.screen),
        .before_current_prompt_marker => try beforeCurrentPromptMarker(alloc, input.screen),
        .whole_recent_without_current_prompt_marker => try wholeRecentWithoutCurrentPromptMarker(alloc, input.screen),
        .current_prompt_block_marker => (try currentPromptBlockMarker(alloc, input.screen)) orelse "",
        .after_current_prompt_block_marker => (try afterCurrentPromptBlockMarker(alloc, input.screen)) orelse "",
        .after_last_horizontal_rule => afterLastHorizontalRule(input.screen),
        .prompt_box_body => (try promptBoxBody(alloc, input.screen)) orelse "",
        .above_prompt_box => try abovePromptBox(alloc, input.screen),
        .last_non_empty_above_prompt_box => lastNonEmptyLine(try abovePromptBox(alloc, input.screen)),
        .bottom_lines => |n| try bottomLines(alloc, input.screen, n),
        .bottom_non_empty_lines => |n| try bottomNonEmptyLines(alloc, input.screen, n),
        .top_non_empty_lines => |n| try topNonEmptyLines(alloc, input.screen, n),
    };
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', 0x0b, 0x0c => true,
        else => false,
    };
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and isWhitespace(s[start])) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and isWhitespace(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

/// A line of text made up entirely of box-drawing horizontal-rule
/// characters ('─', U+2500), possibly padded with whitespace, with at
/// least 3 of them (a run of 1-2 is treated as decoration, not a rule).
fn isHorizontalRule(line: []const u8) bool {
    const trimmed = trimWhitespace(line);
    if (trimmed.len == 0) return false;

    var rule_chars: usize = 0;
    var rule_bytes: usize = 0;
    var it: std.unicode.Utf8Iterator = (std.unicode.Utf8View.init(trimmed) catch return false).iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch break;
        if (cp != 0x2500) break;
        rule_chars += 1;
        rule_bytes += slice.len;
    }
    if (rule_chars == 0) return false;

    const suffix = trimWhitespace(trimmed[rule_bytes..]);
    return suffix.len == 0 or rule_chars >= 3;
}

/// The screen text after the last horizontal-rule line, or the whole
/// screen if there isn't one.
fn afterLastHorizontalRule(content: []const u8) []const u8 {
    var last_rule_end: usize = 0;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const next_offset = @min(offset + line.len + 1, content.len);
        if (isHorizontalRule(line)) last_rule_end = next_offset;
        offset = next_offset;
    }
    return content[last_rule_end..];
}

/// Splits `content` into lines the way Rust's `str::lines()` does: on '\n',
/// with no trailing empty element for a final line terminator (so "a\nb\n"
/// is 2 lines, not 3). Each returned slice is a sub-slice of `content`, so
/// its byte offset within `content` can be recovered with `lineStartOffset`
/// via pointer arithmetic instead of re-summing lengths.
fn splitLines(alloc: Allocator, content: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try list.append(alloc, line);
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
        _ = list.pop();
    }
    return try list.toOwnedSlice(alloc);
}

fn lineStartOffset(content: []const u8, lines: []const []const u8, index: usize) usize {
    if (index >= lines.len) return content.len;
    return @intFromPtr(lines[index].ptr) - @intFromPtr(content.ptr);
}

/// The last `count` non-empty (post-trim) lines of `content`, and
/// everything after them. Returns "" if there are no non-empty lines.
fn bottomNonEmptyLines(alloc: Allocator, content: []const u8, count: usize) ![]const u8 {
    if (count == 0) return "";

    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);

    var collected: usize = 0;
    var start_index: usize = lines.len;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (trimWhitespace(lines[i]).len == 0) continue;
        start_index = i;
        collected += 1;
        if (collected == count) break;
    }
    if (collected == 0) return "";

    return content[lineStartOffset(content, lines, start_index)..];
}

/// The body of the live prompt box: the text strictly between the last two
/// horizontal-rule lines in the buffer (its bottom and top borders,
/// scanning backward). Returns null if fewer than two rule lines exist.
fn promptBoxBody(alloc: Allocator, content: []const u8) !?[]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);

    const top = promptBoxTopBorderIndex(lines) orelse return null;

    const start = lineStartOffset(content, lines, top + 1);
    var end_index: usize = lines.len;
    var j: usize = top + 1;
    while (j < lines.len) : (j += 1) {
        if (isHorizontalRule(lines[j])) {
            end_index = j;
            break;
        }
    }
    const end = lineStartOffset(content, lines, end_index);

    return content[@min(start, content.len)..@min(end, content.len)];
}

fn promptBoxTopBorderIndex(lines: []const []const u8) ?usize {
    var border_count: usize = 0;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (isHorizontalRule(lines[i])) {
            border_count += 1;
            if (border_count == 2) return i;
        }
    }
    return null;
}

/// The screen content above the live prompt box's top border, or the whole
/// screen if there isn't one.
fn abovePromptBox(alloc: Allocator, content: []const u8) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    const top = promptBoxTopBorderIndex(lines) orelse return content;
    return content[0..@min(lineStartOffset(content, lines, top), content.len)];
}

/// The last non-blank (post-trim) line of `content`, or "" if there are
/// none.
fn lastNonEmptyLine(content: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (trimWhitespace(line).len != 0) return line;
    }
    return "";
}

/// `count`th-from-bottom line onward (unlike `bottomNonEmptyLines`, blank
/// lines count toward `count`).
fn bottomLines(alloc: Allocator, content: []const u8, count: usize) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    const start = if (count >= lines.len) 0 else lines.len - count;
    return content[@min(lineStartOffset(content, lines, start), content.len)..];
}

/// Everything from the start of `content` through the `count`th non-blank
/// (post-trim) line, inclusive of any blank lines in between. Returns "" if
/// there are no non-blank lines at all.
fn topNonEmptyLines(alloc: Allocator, content: []const u8, count: usize) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);

    var collected: usize = 0;
    var end_index: ?usize = null;
    var i: usize = 0;
    while (i < lines.len and collected < count) : (i += 1) {
        if (trimWhitespace(lines[i]).len == 0) continue;
        end_index = i;
        collected += 1;
    }
    const idx = end_index orelse return "";
    return content[0..@min(lineStartOffset(content, lines, idx + 1), content.len)];
}

/// A Codex-style `›`-prefixed prompt-marker line: exactly "›", or starting
/// with "› ".
fn codexPromptLine(line: []const u8) bool {
    return std.mem.eql(u8, line, "›") or std.mem.startsWith(u8, line, "› ");
}

/// A Codex-style transcript block marker line: starts with '•', '■', '✗',
/// or '✓'.
fn codexBlockMarkerLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "•") or
        std.mem.startsWith(u8, line, "■") or
        std.mem.startsWith(u8, line, "✗") or
        std.mem.startsWith(u8, line, "✓");
}

/// The index of the last prompt-marker line, if it's still "current" (no
/// block-marker line appears after it, i.e. it hasn't been answered yet).
fn currentCodexPromptIndex(lines: []const []const u8) ?usize {
    var prompt_index: ?usize = null;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (codexPromptLine(lines[i])) {
            prompt_index = i;
            break;
        }
    }
    const idx = prompt_index orelse return null;
    for (lines[idx + 1 ..]) |line| {
        if (codexBlockMarkerLine(line)) return null;
    }
    return idx;
}

/// The screen content after the last prompt-marker line, or the whole
/// screen if there isn't one.
fn afterLastPromptMarker(alloc: Allocator, content: []const u8) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    var index: ?usize = null;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (codexPromptLine(lines[i])) {
            index = i;
            break;
        }
    }
    const idx = index orelse return content;
    return content[@min(lineStartOffset(content, lines, idx + 1), content.len)..];
}

/// The screen content before the current (unanswered) prompt marker, or
/// the whole screen if there isn't one.
fn beforeCurrentPromptMarker(alloc: Allocator, content: []const u8) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    const idx = currentCodexPromptIndex(lines) orelse return content;
    return content[0..@min(lineStartOffset(content, lines, idx), content.len)];
}

/// The whole screen, unless a current (unanswered) prompt marker is
/// present, in which case "".
fn wholeRecentWithoutCurrentPromptMarker(alloc: Allocator, content: []const u8) ![]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    return if (currentCodexPromptIndex(lines) != null) "" else content;
}

/// The block-marker line immediately preceding the current prompt marker,
/// if any.
fn currentPromptBlockMarker(alloc: Allocator, content: []const u8) !?[]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    const prompt_index = currentCodexPromptIndex(lines) orelse return null;
    var i: usize = prompt_index;
    while (i > 0) {
        i -= 1;
        if (codexBlockMarkerLine(lines[i])) return lines[i];
    }
    return null;
}

/// The screen content from the block-marker line preceding the current
/// prompt marker onward, if any.
fn afterCurrentPromptBlockMarker(alloc: Allocator, content: []const u8) !?[]const u8 {
    const lines = try splitLines(alloc, content);
    defer alloc.free(lines);
    const prompt_index = currentCodexPromptIndex(lines) orelse return null;
    var block_index: ?usize = null;
    var i: usize = prompt_index;
    while (i > 0) {
        i -= 1;
        if (codexBlockMarkerLine(lines[i])) {
            block_index = i;
            break;
        }
    }
    const bidx = block_index orelse return null;
    return content[@min(lineStartOffset(content, lines, bidx), content.len)..];
}

pub const ManifestSource = union(enum) {
    bundled,
    remote: struct { path: []const u8, version: []const u8 },
    override_: []const u8,

    /// A human-readable identifier for where the active manifest came
    /// from, for `explain` output and diagnostics.
    pub fn label(self: ManifestSource, alloc: Allocator) ![]const u8 {
        return switch (self) {
            .bundled => "bundled",
            .remote => |r| std.fmt.allocPrint(alloc, "remote:{s}", .{r.path}),
            .override_ => |path| path,
        };
    }

    pub fn kind(self: ManifestSource) []const u8 {
        return switch (self) {
            .bundled => "bundled",
            .remote => "remote",
            .override_ => "local override",
        };
    }
};

pub const AgentManifestSummary = struct {
    agent: Agent,
    active_source: ManifestSource,
    active_version: ?[]const u8 = null,
    cached_remote_version: ?[]const u8 = null,
    local_override_shadowing_remote: bool = false,
    warning: ?[]const u8 = null,
};

pub const ManifestState = enum {
    idle,
    working,
    blocked,
    unknown,

    pub fn from(value: ManifestState) AgentState {
        return switch (value) {
            .idle => .Idle,
            .working => .Working,
            .blocked => .Blocked,
            .unknown => .Unknown,
        };
    }
};

pub const ManifestGate = struct {
    all: []const ManifestGate = &.{},
    any: []const ManifestGate = &.{},
    not_gate: []const ManifestGate = &.{},
    contains: []const []const u8 = &.{},
    regex: []const []const u8 = &.{},
    line_regex: []const []const u8 = &.{},
};

pub const ManifestRule = struct {
    id: []const u8,
    state: ?ManifestState = null,
    priority: i32 = 0,
    region: []const u8 = "whole_recent",
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
    skip_state_update: bool = false,
    all: []const ManifestGate = &.{},
    any: []const ManifestGate = &.{},
    not_gate: []const ManifestGate = &.{},
    contains: []const []const u8 = &.{},
    regex: []const []const u8 = &.{},
    line_regex: []const []const u8 = &.{},
};

pub const AgentManifest = struct {
    id: []const u8,
    version: ?[]const u8 = null,
    min_engine_version: ?u32 = null,
    updated_at: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    rules: []const ManifestRule = &.{},
};

pub const ParsedRemoteManifest = struct {
    manifest: AgentManifest,
    version: []const u8,
};

pub const LoadedManifest = struct {
    manifest: AgentManifest,
    compiled: CompiledManifest,
    source: ManifestSource,
    warning: ?[]const u8 = null,
    cached_remote_version: ?[]const u8 = null,
    local_override_shadowing_remote: bool = false,
};

pub const ManifestCache = struct {
    manifests: []const struct { agent: Agent, loaded: ?LoadedManifest },
};

const ManifestComplexity = struct {
    total_gates: usize = 0,
    total_matchers: usize = 0,
};

var MANIFEST_CACHE: ?ManifestCache = null;

pub const DEFAULT_KNOWN_AGENT_IDLE_FALLBACK: []const u8 = "default_known_agent_idle_fallback";

const BUNDLED_MANIFESTS = [_]struct { label: []const u8, rules: []const Rule }{
    .{ .label = "claude", .rules = &claude_manifest_rules.rules },
};

const TOP_NON_EMPTY_LINES_ENGINE_VERSION: u32 = 3;
const MAX_TOP_REGION_LINE_COUNT: usize = std.math.maxInt(u16);
const MAX_PREVIEW_CHARS: usize = 240;

const MAX_RULES_PER_MANIFEST: usize = 128;
const MAX_GATE_DEPTH: usize = 8;
const MAX_TOTAL_GATES: usize = 512;
const MAX_MATCHERS_PER_GATE: usize = 32;
const MAX_TOTAL_MATCHERS: usize = 1024;
const MAX_MATCHER_CHARS: usize = 512;

/// Rebuild the manifest cache from disk and return a summary per agent.
/// Called after a remote manifest update commits, and by anything that
/// wants to pick up a newly written local override without a restart.
pub fn reloadManifests(alloc: Allocator) ![]const AgentManifestSummary {
    manifest_cache_mutex.lockUncancelable(global.io());
    defer manifest_cache_mutex.unlock(global.io());

    const cache = try rebuildManifestCacheLocked();
    return manifestSummariesFromCache(alloc, cache);
}

pub fn manifestSummaries(alloc: Allocator) ![]const AgentManifestSummary {
    manifest_cache_mutex.lockUncancelable(global.io());
    defer manifest_cache_mutex.unlock(global.io());
    return manifestSummariesFromCache(alloc, try manifestCacheLocked());
}

/// The cached manifest for `agent`, building the cache on first use.
///
/// Manifests are loaded once and held for the process's lifetime: a load
/// touches the filesystem three times (override, remote cache, bundled) and
/// compiles every regex in the rule set, which is far too much to repeat on
/// each detection check.
fn loadManifest(agent: Agent) ?LoadedManifest {
    manifest_cache_mutex.lockUncancelable(global.io());
    defer manifest_cache_mutex.unlock(global.io());

    const cache = manifestCacheLocked() catch return null;
    for (cache.manifests) |entry| {
        if (entry.agent == agent) return entry.loaded;
    }
    return null;
}

/// Resolve `agent`'s manifest from disk, in precedence order: a local
/// override wins over a cached remote manifest, which wins over the bundled
/// one. Anything unusable at a higher tier degrades to the next with a
/// warning attached rather than failing the load - detection must keep
/// working with a broken override sitting on disk.
fn loadManifestUncached(alloc: Allocator, agent: Agent) !?LoadedManifest {
    const bundled = bundledManifest(agent) orelse return null;

    var remote = try readRemoteManifest(alloc, agent, bundled);
    const cached_remote_version: ?[]const u8 = if (remote) |loaded|
        (loaded.cached_remote_version orelse switch (loaded.source) {
            .remote => |r| r.version,
            else => null,
        })
    else
        null;

    const path = try overridePath(alloc, agent);
    const override_exists = fileExists(path);
    const local_override_shadowing_remote = override_exists and cached_remote_version != null;

    if (remote) |*loaded| {
        loaded.cached_remote_version = cached_remote_version;
        loaded.local_override_shadowing_remote = local_override_shadowing_remote;
    }

    const fallback = remote orelse try bundledLoadedManifest(
        alloc,
        agent,
        bundled,
        null,
        cached_remote_version,
        local_override_shadowing_remote,
    );
    if (!override_exists) return fallback;

    const parsed = readOverrideManifest(alloc, path) catch |err| {
        var loaded = fallback;
        loaded.warning = try std.fmt.allocPrint(
            alloc,
            "ignored override {s} because it could not be loaded: {t}",
            .{ path, err },
        );
        return loaded;
    };
    const override_manifest = parsed orelse return fallback;

    if (!manifestMatchesAgent(override_manifest, agent)) {
        var loaded = fallback;
        loaded.warning = try std.fmt.allocPrint(
            alloc,
            "ignored override {s} because manifest id {s} does not match {s}",
            .{ path, override_manifest.id, agent.agentLabel() },
        );
        return loaded;
    }

    return loadedManifest(
        alloc,
        override_manifest,
        .{ .override_ = path },
        null,
        cached_remote_version,
        local_override_shadowing_remote,
    ) catch |err| {
        var loaded = fallback;
        loaded.warning = try std.fmt.allocPrint(
            alloc,
            "ignored override {s} because it could not be compiled: {t}",
            .{ path, err },
        );
        return loaded;
    };
}

/// The manifest compiled into the binary. Unlike herdr's, coastty's bundled
/// manifests are Zig `Rule` values rather than embedded TOML text, so this
/// converts rather than parses - which also means a bundled manifest cannot
/// fail to parse.
fn bundledManifest(agent: Agent) ?AgentManifest {
    const id = agent.agentLabel();
    inline for (BUNDLED_MANIFESTS) |entry| {
        if (std.mem.eql(u8, entry.label, id)) {
            return comptime agentManifestFromRules(entry.label, entry.rules);
        }
    }
    return null;
}

fn readOverrideManifest(alloc: Allocator, path: []const u8) !?AgentManifest {
    const content = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(max_manifest_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parseManifest(alloc, content);
}

/// The remote manifest cached on disk by `manifest_update`, if it's usable.
/// A cached copy older than the bundled one is refused: shipping a newer
/// manifest in the binary must not be undone by a stale cache.
fn readRemoteManifest(alloc: Allocator, agent: Agent, bundled: AgentManifest) !?LoadedManifest {
    const path = try manifest_update.remoteManifestPath(alloc, agent.agentLabel());
    if (!fileExists(path)) return null;

    const content = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(max_manifest_bytes),
    ) catch |err| {
        return try bundledLoadedManifest(alloc, agent, bundled, try std.fmt.allocPrint(
            alloc,
            "ignored remote manifest {s} because it could not be loaded: {t}",
            .{ path, err },
        ), null, false);
    };

    const parsed = parseRemoteManifestForAgent(alloc, agent.agentLabel(), content) catch |err| {
        return try bundledLoadedManifest(alloc, agent, bundled, try std.fmt.allocPrint(
            alloc,
            "ignored remote manifest {s} because it could not be loaded: {t}",
            .{ path, err },
        ), null, false);
    };

    const remote_version = parsed.manifest.version orelse "unknown";
    if (parsed.manifest.version) |remote| {
        if (bundled.version) |bundled_version| {
            const remote_parsed = try manifest_update.ManifestVersion.parse(remote);
            const bundled_parsed = try manifest_update.ManifestVersion.parse(bundled_version);
            if (remote_parsed.cmp(bundled_parsed) == .lt) {
                return try bundledLoadedManifest(alloc, agent, bundled, try std.fmt.allocPrint(
                    alloc,
                    "ignored remote manifest {s} because cached version {s} is older than bundled {s}",
                    .{ path, remote, bundled_version },
                ), remote, false);
            }
        }
    }

    return loadedManifest(
        alloc,
        parsed.manifest,
        .{ .remote = .{ .path = path, .version = remote_version } },
        null,
        null,
        false,
    ) catch |err| try bundledLoadedManifest(alloc, agent, bundled, try std.fmt.allocPrint(
        alloc,
        "ignored remote manifest {s} because it could not be compiled: {t}",
        .{ path, err },
    ), null, false);
}

/// Parse a manifest document and validate it.
///
/// The wire format is JSON rather than herdr's TOML (Zig has no TOML parser
/// in std, and coastty's catalog is meant to be a file in this repo served
/// over `raw.githubusercontent.com`). The schema is field-for-field the
/// same, with herdr's `not` gate key spelled `not_gate`.
pub fn parseManifest(alloc: Allocator, content: []const u8) !AgentManifest {
    const parsed = try std.json.parseFromSlice(AgentManifest, alloc, content, .{
        .allocate = .alloc_always,
    });
    try validateManifest(parsed.value);
    return parsed.value;
}

/// A remote manifest carries stricter requirements than a local override:
/// it must name the agent it's for, carry a version so downgrades can be
/// refused, and declare the engine version it needs.
pub fn parseRemoteManifestForAgent(
    alloc: Allocator,
    agent_label: []const u8,
    content: []const u8,
) !ParsedRemoteManifest {
    const agent = (try detection.agentFromLabel(alloc, agent_label)) orelse return error.UnknownAgent;
    const m = try parseManifest(alloc, content);
    if (!manifestMatchesAgent(m, agent)) return error.ManifestIdDoesNotMatchAgent;

    const version = m.version orelse return error.RemoteManifestMissingVersion;
    const min_engine_version = m.min_engine_version orelse return error.RemoteManifestMissingMinEngineVersion;
    if (min_engine_version > manifest_update.MANIFEST_ENGINE_VERSION) {
        return error.RemoteManifestRequiresNewerEngine;
    }
    return .{ .manifest = m, .version = version };
}

/// Manifests can come from a remote server, so they're treated as untrusted
/// input: bounded rule count, gate depth, matcher count, and matcher
/// length, so a hostile or broken manifest can't turn every detection check
/// into unbounded work.
pub fn validateManifest(m: AgentManifest) !void {
    if (m.rules.len == 0) return error.ManifestHasNoRules;
    if (m.rules.len > MAX_RULES_PER_MANIFEST) return error.ManifestHasTooManyRules;

    var complexity: ManifestComplexity = .{};
    for (m.rules) |rule| {
        if (std.mem.trim(u8, rule.id, " \t\r\n").len == 0) return error.ManifestRuleIdIsEmpty;

        if (rule.skip_state_update) {
            // A skip rule publishes nothing, so declaring a state or
            // visible-chrome evidence alongside it is always a mistake.
            if (rule.state != ManifestState.unknown) return error.SkipStateUpdateRuleMustBeUnknown;
            if (rule.visible_idle or rule.visible_blocker or rule.visible_working) {
                return error.SkipStateUpdateRuleHasVisibleEvidence;
            }
        }

        try validateRegionName(rule.region);
        if (std.mem.startsWith(u8, std.mem.trim(u8, rule.region, " \t\r\n"), "top_non_empty_lines(")) {
            if (m.min_engine_version) |version| {
                if (version < TOP_NON_EMPTY_LINES_ENGINE_VERSION) {
                    return error.RegionRequiresNewerMinEngineVersion;
                }
            }
        }

        try validateRuleGate(rule, &complexity);
    }
}

/// `validateGate` and `validateNotGate` recurse into each other, so their
/// error sets can't be mutually inferred.
const ValidateError = error{
    GateDepthExceeded,
    TooManyGates,
    TooManyMatchersInGate,
    TooManyMatchers,
    MatcherTooLong,
    GateHasNoPositiveMatcher,
    EmptyNotGate,
    InvalidRegexPattern,
};

fn validateRuleGate(rule: ManifestRule, complexity: *ManifestComplexity) ValidateError!void {
    try validateGate(manifestGateFromRule(rule), "rule", 0, complexity);
}

fn validateGate(gate: ManifestGate, context: []const u8, depth: usize, complexity: *ManifestComplexity) ValidateError!void {
    if (depth > MAX_GATE_DEPTH) return error.GateDepthExceeded;
    complexity.total_gates += 1;
    if (complexity.total_gates > MAX_TOTAL_GATES) return error.TooManyGates;

    try validateMatcherLimits(gate, context, complexity);
    // A gate that only says what must *not* be present matches almost
    // everything, so it can never stand alone as a rule's condition.
    if (!gateHasPositiveMatcher(gate)) return error.GateHasNoPositiveMatcher;

    try validateRegexPatterns(gate.regex, context, "regex");
    try validateRegexPatterns(gate.line_regex, context, "line_regex");

    for (gate.all) |nested| try validateGate(nested, "all gate", depth + 1, complexity);
    for (gate.any) |nested| try validateGate(nested, "any gate", depth + 1, complexity);
    for (gate.not_gate) |nested| {
        if (!gateHasAnyMatcher(nested)) return error.EmptyNotGate;
        try validateNotGate(nested, depth + 1, complexity);
    }
}

/// Same limits as `validateGate`, minus the positive-matcher requirement: a
/// negation is allowed to be purely negative.
fn validateNotGate(gate: ManifestGate, depth: usize, complexity: *ManifestComplexity) ValidateError!void {
    if (depth > MAX_GATE_DEPTH) return error.GateDepthExceeded;
    complexity.total_gates += 1;
    if (complexity.total_gates > MAX_TOTAL_GATES) return error.TooManyGates;

    try validateMatcherLimits(gate, "not gate", complexity);
    if (!gateHasAnyMatcher(gate)) return error.EmptyNotGate;

    try validateRegexPatterns(gate.regex, "not gate", "regex");
    try validateRegexPatterns(gate.line_regex, "not gate", "line_regex");

    for (gate.all) |nested| try validateGate(nested, "not all gate", depth + 1, complexity);
    for (gate.any) |nested| try validateGate(nested, "not any gate", depth + 1, complexity);
    for (gate.not_gate) |nested| try validateNotGate(nested, depth + 1, complexity);
}

fn validateMatcherLimits(gate: ManifestGate, context: []const u8, complexity: *ManifestComplexity) !void {
    _ = context;
    const matcher_count = gate.contains.len + gate.regex.len + gate.line_regex.len;
    if (matcher_count > MAX_MATCHERS_PER_GATE) return error.TooManyMatchersInGate;

    complexity.total_matchers += matcher_count;
    if (complexity.total_matchers > MAX_TOTAL_MATCHERS) return error.TooManyMatchers;

    for ([_][]const []const u8{ gate.contains, gate.regex, gate.line_regex }) |list| {
        for (list) |value| {
            if (std.unicode.utf8CountCodepoints(value) catch value.len > MAX_MATCHER_CHARS) {
                return error.MatcherTooLong;
            }
        }
    }
}

/// Compile every pattern up front so an invalid regex is rejected at load
/// time rather than silently failing to match forever.
fn validateRegexPatterns(patterns: []const []const u8, context: []const u8, field: []const u8) !void {
    _ = context;
    _ = field;
    for (patterns) |pattern| {
        var regex = oni.Regex.init(pattern, .{}, oni.Encoding.utf8, oni.Syntax.default, null) catch {
            return error.InvalidRegexPattern;
        };
        regex.deinit();
    }
}

fn gateHasPositiveMatcher(gate: ManifestGate) bool {
    return gate.contains.len != 0 or gate.regex.len != 0 or gate.line_regex.len != 0 or
        gate.all.len != 0 or gate.any.len != 0;
}

fn gateHasAnyMatcher(gate: ManifestGate) bool {
    return gateHasPositiveMatcher(gate) or gate.not_gate.len != 0;
}

fn validateRegionName(spec: []const u8) !void {
    _ = parseRegion(spec) catch return error.InvalidRegionName;
}

/// Where a user-authored manifest override lives. Dropping a file here
/// replaces the bundled rule set for that agent, which is how a UI change
/// can be worked around without waiting for a coastty release.
fn overridePath(alloc: Allocator, agent: Agent) ![]const u8 {
    const basename = try std.fmt.allocPrint(alloc, "{s}.json", .{agent.agentLabel()});

    // Test-only redirection; see `manifest_update.test_state_dir_override`.
    if (builtin.is_test) {
        if (test_config_dir_override) |config_dir| {
            return std.fs.path.join(alloc, &.{ config_dir, "agent-detection", basename });
        }
    }

    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const config_dir = try internal_os.xdg.config(global.io(), alloc, &environ_map, .{
        .subdir = "ghostty",
    });
    return std.fs.path.join(alloc, &.{ config_dir, "agent-detection", basename });
}

var test_config_dir_override: ?[]const u8 = null;

fn remoteUpdateStatus(alloc: Allocator, agent: Agent) ?manifest_update.AgentRemoteStatus {
    const status = manifest_update.loadStatus(alloc) catch return null;
    return status.agentStatus(agent.agentLabel());
}

/// A manifest claims an agent by id or by alias, matched either literally
/// against the canonical label or through the same alias table process
/// names go through.
fn manifestMatchesAgent(m: AgentManifest, agent: Agent) bool {
    const id = agent.agentLabel();
    if (std.mem.eql(u8, m.id, id)) return true;
    for (m.aliases) |alias| {
        if (std.mem.eql(u8, alias, id)) return true;
    }

    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    if (detection.agentFromLabel(fba.allocator(), m.id) catch null) |parsed| {
        if (parsed == agent) return true;
    }
    for (m.aliases) |alias| {
        fba.reset();
        if (detection.agentFromLabel(fba.allocator(), alias) catch null) |parsed| {
            if (parsed == agent) return true;
        }
    }
    return false;
}

fn manifestGateFromRule(rule: ManifestRule) ManifestGate {
    return .{
        .all = rule.all,
        .any = rule.any,
        .not_gate = rule.not_gate,
        .contains = rule.contains,
        .regex = rule.regex,
        .line_regex = rule.line_regex,
    };
}

pub fn shouldSkipStateUpdate(alloc: Allocator, agent: Agent, screen_content: []const u8) bool {
    const loaded = loadManifest(agent) orelse return false;
    const e = evaluateLoadedManifest(
        alloc,
        agent,
        .{ .screen = screen_content },
        loaded,
        false,
    ) catch return false;
    return e.skip_state_update;
}

pub const MatchedRule = struct {
    id: []const u8,
    priority: i32,
    region: []const u8,
    state: AgentState,
};

pub const RuleEvidence = struct {
    contains: []const []const u8,
    regex: []const []const u8,
    line_regex: []const []const u8,
    all_count: usize,
    any_count: usize,
    not_count: usize,
    region_bytes: usize,
    region_preview: []const u8,
};

pub const EvaluatedRule = struct {
    id: []const u8,
    priority: i32,
    region: []const u8,
    evidence: RuleEvidence,
    state: AgentState,
    matched: bool,
};

pub const DetectionExplain = struct {
    agent_label: ?[]const u8 = null,
    state: AgentState,
    source: ?ManifestSource = null,
    matched_rule: ?MatchedRule = null,
    screen_detection_skipped: bool = false,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
    skip_state_update: bool = false,
    skipped_update_reason: ?[]const u8 = null,
    fallback_reason: ?[]const u8 = null,
    evaluated_rules: []const EvaluatedRule = &.{},
    warning: ?[]const u8 = null,
    manifest_version: ?[]const u8 = null,
    cached_remote_version: ?[]const u8 = null,
    local_override_shadowing_remote: bool = false,
    remote_update_status: ?[]const u8 = null,
    remote_update_error: ?[]const u8 = null,

    pub fn intoDetection(self: DetectionExplain) AgentDetection {
        return .{
            .state = self.state,
            .skip_state_update = self.skip_state_update,
            .visible_idle = self.visible_idle,
            .visible_blocker = self.visible_blocker,
            .visible_working = self.visible_working,
        };
    }
};

pub fn explain(alloc: Allocator, agent: Agent, screen_content: []const u8) !DetectionExplain {
    return explainWithInput(alloc, agent, .{ .screen = screen_content });
}

pub fn explainWithInput(alloc: Allocator, agent: Agent, input: DetectionInput) !DetectionExplain {
    const loaded = loadManifest(agent) orelse
        return fallbackExplain(alloc, agent, null, true);
    return evaluateLoadedManifest(alloc, agent, input, loaded, true);
}

pub fn explainForLabel(alloc: Allocator, agent_label: []const u8, screen_content: []const u8) !DetectionExplain {
    const agent = (try detection.agentFromLabel(alloc, agent_label)) orelse return .{
        .agent_label = agent_label,
        .state = .Unknown,
        .fallback_reason = "unknown_agent",
    };
    return explain(alloc, agent, screen_content);
}

/// Run every rule, record what each one saw, and let the highest-priority
/// match win (ties favor the earlier rule). Every rule is evaluated even
/// after a winner is found, so `explain` can show why the others didn't
/// match.
fn evaluateLoadedManifest(
    alloc: Allocator,
    agent: Agent,
    input: DetectionInput,
    loaded: LoadedManifest,
    include_update_status: bool,
) !DetectionExplain {
    var matched: ?ManifestRule = null;
    var evaluated_rules: std.ArrayList(EvaluatedRule) = .empty;

    for (loaded.manifest.rules, loaded.compiled.rules) |rule, compiled_rule| {
        const region_text = try region(alloc, input, try parseRegion(rule.region));
        const rule_matched = compiledRuleMatches(alloc, &compiled_rule, region_text);

        try evaluated_rules.append(alloc, .{
            .id = rule.id,
            .priority = rule.priority,
            .region = rule.region,
            .evidence = ruleEvidence(rule, region_text),
            .state = ManifestState.from(rule.state orelse .unknown),
            .matched = rule_matched,
        });

        if (!rule_matched) continue;
        if (matched) |previous| {
            if (previous.priority >= rule.priority) continue;
        }
        matched = rule;
    }

    const rule = matched orelse return fallbackExplain(
        alloc,
        agent,
        .{ .loaded = loaded, .evaluated_rules = evaluated_rules.items },
        include_update_status,
    );

    const state = ManifestState.from(rule.state orelse .unknown);
    const skipped_update_reason: ?[]const u8 = if (rule.skip_state_update)
        try std.fmt.allocPrint(alloc, "matched_rule:{s}", .{rule.id})
    else
        null;

    const update_status = if (include_update_status) remoteUpdateStatus(alloc, agent) else null;

    return .{
        .agent_label = agent.agentLabel(),
        .state = state,
        .source = loaded.source,
        .matched_rule = .{
            .id = rule.id,
            .priority = rule.priority,
            .region = rule.region,
            .state = state,
        },
        .screen_detection_skipped = false,
        // A rule's visible-chrome flags only apply when they agree with the
        // state it declared.
        .visible_idle = rule.visible_idle and state == .Idle,
        .visible_blocker = rule.visible_blocker and state == .Blocked,
        .visible_working = rule.visible_working and state == .Working,
        .skip_state_update = rule.skip_state_update,
        .skipped_update_reason = skipped_update_reason,
        .fallback_reason = null,
        .evaluated_rules = evaluated_rules.items,
        .warning = loaded.warning,
        .manifest_version = loaded.manifest.version,
        .cached_remote_version = loaded.cached_remote_version,
        .local_override_shadowing_remote = loaded.local_override_shadowing_remote,
        .remote_update_status = if (update_status) |s| s.last_result else null,
        .remote_update_error = if (update_status) |s| s.last_error else null,
    };
}

const FallbackContext = struct {
    loaded: LoadedManifest,
    evaluated_rules: []const EvaluatedRule,
};

/// What to report when no rule matched. A known agent with a working
/// manifest resolves to Idle - the agent is there and showing nothing that
/// indicates otherwise - while no agent at all is Unknown.
fn fallbackExplain(
    alloc: Allocator,
    agent: ?Agent,
    context: ?FallbackContext,
    include_update_status: bool,
) DetectionExplain {
    const known_agent = agent != null;
    const update_status = if (include_update_status and agent != null)
        remoteUpdateStatus(alloc, agent.?)
    else
        null;

    return .{
        .agent_label = if (agent) |a| a.agentLabel() else null,
        .state = if (known_agent) .Idle else .Unknown,
        .source = if (context) |c| c.loaded.source else null,
        .matched_rule = null,
        .screen_detection_skipped = false,
        .visible_idle = false,
        .visible_blocker = false,
        .visible_working = false,
        .skip_state_update = false,
        .skipped_update_reason = null,
        .fallback_reason = if (known_agent) DEFAULT_KNOWN_AGENT_IDLE_FALLBACK else null,
        .evaluated_rules = if (context) |c| c.evaluated_rules else &.{},
        .warning = if (context) |c| c.loaded.warning else null,
        .manifest_version = if (context) |c| c.loaded.manifest.version else null,
        .cached_remote_version = if (context) |c| c.loaded.cached_remote_version else null,
        .local_override_shadowing_remote = if (context) |c| c.loaded.local_override_shadowing_remote else false,
        .remote_update_status = if (update_status) |s| s.last_result else null,
        .remote_update_error = if (update_status) |s| s.last_error else null,
    };
}

pub fn agentStateLabel(state: AgentState) []const u8 {
    return switch (state) {
        .Idle => "idle",
        .Working => "working",
        .Blocked => "blocked",
        .Unknown => "unknown",
    };
}

/// The `explain` output as JSON, for diagnostics: why a pane is in the
/// state it's in, which rule won, and what every other rule saw.
pub fn explainToJsonValue(alloc: Allocator, e: DetectionExplain) !std.json.Value {
    var root: std.json.ObjectMap = .empty;

    try root.put(alloc, "agent", optionalString(e.agent_label));
    try root.put(alloc, "state", .{ .string = agentStateLabel(e.state) });
    try root.put(alloc, "manifest_source", if (e.source) |s|
        .{ .string = try s.label(alloc) }
    else
        .null);
    try root.put(alloc, "manifest_version", optionalString(e.manifest_version));
    try root.put(alloc, "cached_remote_version", optionalString(e.cached_remote_version));
    try root.put(alloc, "local_override_shadowing_remote", .{ .bool = e.local_override_shadowing_remote });
    try root.put(alloc, "remote_update_status", optionalString(e.remote_update_status));
    try root.put(alloc, "remote_update_error", optionalString(e.remote_update_error));

    if (e.matched_rule) |rule| {
        var matched: std.json.ObjectMap = .empty;
        try matched.put(alloc, "id", .{ .string = rule.id });
        try matched.put(alloc, "priority", .{ .integer = rule.priority });
        try matched.put(alloc, "region", .{ .string = rule.region });
        try matched.put(alloc, "state", .{ .string = agentStateLabel(rule.state) });
        try root.put(alloc, "matched_rule", .{ .object = matched });
    } else {
        try root.put(alloc, "matched_rule", .null);
    }

    try root.put(alloc, "visible_idle", .{ .bool = e.visible_idle });
    try root.put(alloc, "visible_blocker", .{ .bool = e.visible_blocker });
    try root.put(alloc, "visible_working", .{ .bool = e.visible_working });
    try root.put(alloc, "screen_detection_skipped", .{ .bool = e.screen_detection_skipped });
    try root.put(alloc, "skip_state_update", .{ .bool = e.skip_state_update });
    try root.put(alloc, "skipped_update_reason", optionalString(e.skipped_update_reason));
    try root.put(alloc, "fallback_reason", optionalString(e.fallback_reason));
    try root.put(alloc, "warning", optionalString(e.warning));

    var evaluated: std.json.Array = .init(alloc);
    for (e.evaluated_rules) |rule| {
        var evidence: std.json.ObjectMap = .empty;
        try evidence.put(alloc, "contains", try stringArray(alloc, rule.evidence.contains));
        try evidence.put(alloc, "regex", try stringArray(alloc, rule.evidence.regex));
        try evidence.put(alloc, "line_regex", try stringArray(alloc, rule.evidence.line_regex));
        try evidence.put(alloc, "all_count", .{ .integer = @intCast(rule.evidence.all_count) });
        try evidence.put(alloc, "any_count", .{ .integer = @intCast(rule.evidence.any_count) });
        try evidence.put(alloc, "not_count", .{ .integer = @intCast(rule.evidence.not_count) });
        try evidence.put(alloc, "region_bytes", .{ .integer = @intCast(rule.evidence.region_bytes) });
        try evidence.put(alloc, "region_preview", .{ .string = rule.evidence.region_preview });

        var entry: std.json.ObjectMap = .empty;
        try entry.put(alloc, "id", .{ .string = rule.id });
        try entry.put(alloc, "priority", .{ .integer = rule.priority });
        try entry.put(alloc, "region", .{ .string = rule.region });
        try entry.put(alloc, "state", .{ .string = agentStateLabel(rule.state) });
        try entry.put(alloc, "matched", .{ .bool = rule.matched });
        try entry.put(alloc, "evidence", .{ .object = evidence });
        try evaluated.append(.{ .object = entry });
    }
    try root.put(alloc, "evaluated_rules", .{ .array = evaluated });

    return .{ .object = root };
}

fn optionalString(value: ?[]const u8) std.json.Value {
    return if (value) |v| .{ .string = v } else .null;
}

fn stringArray(alloc: Allocator, values: []const []const u8) !std.json.Value {
    var array: std.json.Array = .init(alloc);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn ruleEvidence(rule: ManifestRule, region_text: []const u8) RuleEvidence {
    return .{
        .contains = rule.contains,
        .regex = rule.regex,
        .line_regex = rule.line_regex,
        .all_count = rule.all.len,
        .any_count = rule.any.len,
        .not_count = rule.not_gate.len,
        .region_bytes = region_text.len,
        .region_preview = boundedPreview(region_text),
    };
}

/// A short, codepoint-bounded excerpt of the region a rule ran against,
/// for `explain` output. Truncated on a codepoint boundary so the preview
/// is always valid UTF-8.
fn boundedPreview(text: []const u8) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (count == MAX_PREVIEW_CHARS) return text[0..i];
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
        count += 1;
    }
    return text;
}

test {
    std.testing.refAllDecls(@This());
}

test "evaluate: highest priority wins, ties favor earlier rule" {
    const rules = [_]Rule{
        .{ .id = "low", .state = .Working, .priority = 1, .gate = .{ .contains = &.{"x"} } },
        .{ .id = "high", .state = .Blocked, .priority = 10, .gate = .{ .contains = &.{"x"} } },
        .{ .id = "tie_a", .state = .Idle, .priority = 5, .gate = .{ .contains = &.{"y"} } },
        .{ .id = "tie_b", .state = .Working, .priority = 5, .gate = .{ .contains = &.{"y"} } },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    {
        const d = try evaluate(std.testing.allocator, &compiled, .{ .screen = "some x here" });
        try std.testing.expectEqual(AgentState.Blocked, d.state);
    }
    {
        // Both tie_a and tie_b match; tie_a was declared first and wins.
        const d = try evaluate(std.testing.allocator, &compiled, .{ .screen = "some y here" });
        try std.testing.expectEqual(AgentState.Idle, d.state);
    }
}

test "evaluate: no match falls back to Idle" {
    const rules = [_]Rule{
        .{ .id = "only", .state = .Working, .priority = 1, .gate = .{ .contains = &.{"nope"} } },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    const d = try evaluate(std.testing.allocator, &compiled, .{ .screen = "totally unrelated" });
    try std.testing.expectEqual(AgentState.Idle, d.state);
    try std.testing.expect(!d.skip_state_update);
}

test "evaluate: skip_state_update is carried from the winning rule" {
    const rules = [_]Rule{
        .{
            .id = "viewer",
            .state = .Unknown,
            .priority = 100,
            .skip_state_update = true,
            .gate = .{ .contains = &.{"transcript"} },
        },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    const d = try evaluate(std.testing.allocator, &compiled, .{ .screen = "showing transcript" });
    try std.testing.expect(d.skip_state_update);
}

test "region: bottom_non_empty_lines skips blank lines from the bottom" {
    const rules = [_]Rule{
        .{
            .id = "tail",
            .state = .Working,
            .priority = 1,
            .region = .{ .bottom_non_empty_lines = 2 },
            .gate = .{ .contains = &.{"needle"} },
        },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    const screen = "needle here\nsome other line\nlast line\n\n\n";
    const d = try evaluate(std.testing.allocator, &compiled, .{ .screen = screen });
    // "needle" is 3 non-empty lines up from the bottom, outside the
    // bottom_non_empty_lines(2) window, so it should not match.
    try std.testing.expectEqual(AgentState.Idle, d.state);
}

test "region: after_last_horizontal_rule scopes to the last rule" {
    const rules = [_]Rule{
        .{
            .id = "after_rule",
            .state = .Blocked,
            .priority = 1,
            .region = .after_last_horizontal_rule,
            .gate = .{ .contains = &.{"proceed?"} },
        },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    const before_rule = "do you want to proceed?\n───\nsomething else";
    const d1 = try evaluate(std.testing.allocator, &compiled, .{ .screen = before_rule });
    try std.testing.expectEqual(AgentState.Idle, d1.state);

    const after_rule = "something else\n───\ndo you want to proceed?";
    const d2 = try evaluate(std.testing.allocator, &compiled, .{ .screen = after_rule });
    try std.testing.expectEqual(AgentState.Blocked, d2.state);
}

test "region: osc_title and osc_progress source from their own fields" {
    const rules = [_]Rule{
        .{
            .id = "title",
            .state = .Working,
            .priority = 10,
            .region = .osc_title,
            .gate = .{ .regex = &.{"^working"} },
        },
        .{
            .id = "progress",
            .state = .Idle,
            .priority = 5,
            .region = .osc_progress,
            .gate = .{ .regex = &.{"^4;0"} },
        },
    };
    var compiled = try CompiledManifest.compile(std.testing.allocator, &rules);
    defer compiled.deinit();

    const d = try evaluate(std.testing.allocator, &compiled, .{
        .screen = "4;0 is right here in the screen text, but should not match osc rules",
        .osc_title = "working...",
        .osc_progress = "",
    });
    try std.testing.expectEqual(AgentState.Working, d.state);
}

// Region resolver tests, ported from herdr's `src/detect/manifest/tests.rs`.
// These regions are unused by Claude's own manifest but are engine features,
// exercised directly against `region` here.

fn resolvedRegion(alloc: Allocator, screen: []const u8, spec: Region) ![]const u8 {
    return region(alloc, .{ .screen = screen }, spec);
}

test "region: bottom_lines(N) counts blank lines toward N, unlike bottom_non_empty_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "one\ntwo\nthree\n\n";
    try std.testing.expectEqualStrings("\n", try resolvedRegion(arena.allocator(), content, .{ .bottom_lines = 1 }));
    try std.testing.expectEqualStrings("three\n\n", try resolvedRegion(arena.allocator(), content, .{ .bottom_lines = 2 }));
}

test "bottom_non_empty_lines_uses_bottom_occurrence_for_repeated_text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "marker\nold\n\nmiddle\nmarker\nnew\n";
    try std.testing.expectEqualStrings("marker\nnew\n", try resolvedRegion(arena.allocator(), content, .{ .bottom_non_empty_lines = 2 }));
}

test "top_non_empty_lines_uses_top_occurrence_for_repeated_text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "\nmarker\nold\n\nmiddle\nmarker\nnew\n";
    try std.testing.expectEqualStrings("\nmarker\nold\n", try resolvedRegion(arena.allocator(), content, .{ .top_non_empty_lines = 2 }));
}

test "region: top_non_empty_lines returns everything available when count exceeds non-blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "only\n";
    try std.testing.expectEqualStrings("only\n", try resolvedRegion(arena.allocator(), content, .{ .top_non_empty_lines = 50 }));
    try std.testing.expectEqualStrings("", try resolvedRegion(arena.allocator(), "\n\n", .{ .top_non_empty_lines = 5 }));
}

test "region: after_last_prompt_marker and before_current_prompt_marker split at the current prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "older output\n› answer this\nnew output here\n";
    try std.testing.expectEqualStrings("new output here\n", try resolvedRegion(arena.allocator(), content, .after_last_prompt_marker));
    try std.testing.expectEqualStrings("older output\n", try resolvedRegion(arena.allocator(), content, .before_current_prompt_marker));
}

test "region: a prompt marker answered by a later block marker is no longer current" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // "✓" after the "›" marker means it's been answered - before/after
    // "current" prompt marker regions should see no current marker at all.
    const content = "› answer this\n✓ done\nmore output\n";
    try std.testing.expectEqualStrings(content, try resolvedRegion(arena.allocator(), content, .before_current_prompt_marker));
    try std.testing.expectEqualStrings(content, try resolvedRegion(arena.allocator(), content, .whole_recent_without_current_prompt_marker));
}

test "region: whole_recent_without_current_prompt_marker empties out only when a prompt is pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const with_prompt = "output\n› pending\n";
    const without_prompt = "output\nno prompt here\n";
    try std.testing.expectEqualStrings("", try resolvedRegion(arena.allocator(), with_prompt, .whole_recent_without_current_prompt_marker));
    try std.testing.expectEqualStrings(without_prompt, try resolvedRegion(arena.allocator(), without_prompt, .whole_recent_without_current_prompt_marker));
}

test "region: current_prompt_block_marker and after_current_prompt_block_marker find the preceding marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "intro\n■ working on it\nmore detail\n› answer this\n";
    try std.testing.expectEqualStrings("■ working on it", try resolvedRegion(arena.allocator(), content, .current_prompt_block_marker));
    try std.testing.expectEqualStrings("■ working on it\nmore detail\n› answer this\n", try resolvedRegion(arena.allocator(), content, .after_current_prompt_block_marker));
}

test "region: above_prompt_box and last_non_empty_above_prompt_box scope to before the live box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "history line\n\n───\ninside the box\n───\n";
    try std.testing.expectEqualStrings("history line\n\n", try resolvedRegion(arena.allocator(), content, .above_prompt_box));
    try std.testing.expectEqualStrings("history line", try resolvedRegion(arena.allocator(), content, .last_non_empty_above_prompt_box));
}

// Claude OSC + screen fixture tests, ported close to verbatim from herdr's
// `claude_*`-prefixed tests in `src/detect/manifest/tests.rs`, evaluated
// against Claude's actual rule set.

const claude_manifest = @import("manifests/claude.zig");

fn claudeDetect(gpa: Allocator, screen: []const u8, osc_title: []const u8, osc_progress: []const u8) !AgentDetection {
    var compiled = try CompiledManifest.compile(gpa, &claude_manifest.rules);
    defer compiled.deinit();
    return evaluate(gpa, &compiled, .{ .screen = screen, .osc_title = osc_title, .osc_progress = osc_progress });
}

test "claude_osc_title_braille_prefix_is_working" {
    // "⠂" is U+2802, in the braille block U+2800-U+28FF.
    const d = try claudeDetect(std.testing.allocator, "", "⠂ project", "");
    try std.testing.expectEqual(AgentState.Working, d.state);
    try std.testing.expect(d.visible_working);
}

test "claude_osc_title_half_circle_frames_are_working" {
    for ([_][]const u8{ "◐ frame", "◓ frame", "◑ frame", "◒ frame" }) |title| {
        const d = try claudeDetect(std.testing.allocator, "", title, "");
        try std.testing.expectEqual(AgentState.Working, d.state);
        try std.testing.expect(d.visible_working);
    }
}

test "claude_osc_title_static_prefix_is_idle" {
    // "✳" is U+2733, the static prefix when Claude is not working.
    const d = try claudeDetect(std.testing.allocator, "", "✳ Claude Code", "");
    try std.testing.expectEqual(AgentState.Idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude_osc_progress_4_3_alone_does_not_force_working" {
    // Claude leaves progress stuck at 4;3 while waiting for permission, so
    // 4;3 must not be a working signal on its own.
    const d = try claudeDetect(std.testing.allocator, "", "", "4;3;");
    try std.testing.expectEqual(AgentState.Idle, d.state);
    try std.testing.expect(!d.visible_working);
}

test "claude_blocker_screen_outranks_stale_osc_progress" {
    const blocker_screen = "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n";
    const d = try claudeDetect(std.testing.allocator, blocker_screen, "✳ Task title", "4;3;");
    try std.testing.expectEqual(AgentState.Blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

test "claude_osc_progress_4_0_is_idle" {
    const d = try claudeDetect(std.testing.allocator, "", "", "4;0;");
    try std.testing.expectEqual(AgentState.Idle, d.state);
}

test "claude_blocker_screen_outranks_osc_idle_title" {
    const blocker_screen = "do you want to proceed?\n" ++
        "bash command: rm -rf /tmp/test\n" ++
        "❯ 1. Yes\n   2. No\n\n" ++
        "Esc to cancel · Tab to amend · ctrl+e to explain\n";
    const d = try claudeDetect(std.testing.allocator, blocker_screen, "✳ Claude Code", "");
    try std.testing.expectEqual(AgentState.Blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

test "claude_empty_osc_empty_screen_is_idle_fallback" {
    const d = try claudeDetect(std.testing.allocator, "", "", "");
    try std.testing.expectEqual(AgentState.Idle, d.state);
    try std.testing.expect(!d.visible_idle);
}

fn defaultRegion() []const u8 {
    return "whole_recent";
}

/// The cache is built once and held for the process's lifetime, so it owns
/// its own arena rather than borrowing a caller's allocator.
var manifest_cache_mutex: std.Io.Mutex = .init;
var manifest_cache_arena: ?std.heap.ArenaAllocator = null;

const max_manifest_bytes: usize = 256 * 1024;

fn manifestCache() ?ManifestCache {
    manifest_cache_mutex.lockUncancelable(global.io());
    defer manifest_cache_mutex.unlock(global.io());
    return manifestCacheLocked() catch null;
}

fn manifestCacheLocked() !ManifestCache {
    if (MANIFEST_CACHE) |cache| return cache;
    return rebuildManifestCacheLocked();
}

fn rebuildManifestCacheLocked() !ManifestCache {
    if (manifest_cache_arena) |*arena| arena.deinit();
    manifest_cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer {
        manifest_cache_arena.?.deinit();
        manifest_cache_arena = null;
        MANIFEST_CACHE = null;
    }

    const cache = try buildManifestCache(manifest_cache_arena.?.allocator());
    MANIFEST_CACHE = cache;
    return cache;
}

fn buildManifestCache(alloc: Allocator) !ManifestCache {
    const entries = try alloc.alloc(
        @typeInfo(@FieldType(ManifestCache, "manifests")).pointer.child,
        Agent.SCREEN_MANIFEST_AGENTS.len,
    );
    for (Agent.SCREEN_MANIFEST_AGENTS, 0..) |agent, i| {
        entries[i] = .{
            .agent = agent,
            // A single agent's manifest failing to load must not take the
            // whole cache down with it.
            .loaded = loadManifestUncached(alloc, agent) catch null,
        };
    }
    return .{ .manifests = entries };
}

fn manifestSummariesFromCache(alloc: Allocator, cache: ManifestCache) ![]const AgentManifestSummary {
    var summaries: std.ArrayList(AgentManifestSummary) = .empty;
    for (cache.manifests) |entry| {
        const loaded = entry.loaded orelse continue;
        try summaries.append(alloc, manifestSummaryFromLoaded(entry.agent, loaded));
    }
    return summaries.items;
}

fn manifestSummaryFromLoaded(agent: Agent, loaded: LoadedManifest) AgentManifestSummary {
    return .{
        .agent = agent,
        .active_source = loaded.source,
        .active_version = loaded.manifest.version,
        .cached_remote_version = loaded.cached_remote_version,
        .local_override_shadowing_remote = loaded.local_override_shadowing_remote,
        .warning = loaded.warning,
    };
}

pub fn detect(gpa: Allocator, agent: Agent, screen_content: []const u8) !AgentDetection {
    return detectWithOsc(gpa, agent, .{ .screen = screen_content });
}

pub fn detectWithOsc(gpa: Allocator, agent: Agent, input: DetectionInput) !AgentDetection {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = loadManifest(agent) orelse
        return fallbackExplain(arena, agent, null, false).intoDetection();
    return (try evaluateLoadedManifest(arena, agent, input, loaded, false)).intoDetection();
}

fn loadedManifest(
    alloc: Allocator,
    m: AgentManifest,
    source: ManifestSource,
    warning: ?[]const u8,
    cached_remote_version: ?[]const u8,
    local_override_shadowing_remote: bool,
) !LoadedManifest {
    return .{
        .manifest = m,
        .compiled = .{ .alloc = alloc, .rules = try compileManifest(alloc, m) },
        .source = source,
        .warning = warning,
        .cached_remote_version = cached_remote_version,
        .local_override_shadowing_remote = local_override_shadowing_remote,
    };
}

/// The bundled manifest is compiled into the binary and validated by the
/// `all_bundled_manifests_parse_and_validate` test, so a compile failure
/// here is a build-time bug rather than a runtime condition.
fn bundledLoadedManifest(
    alloc: Allocator,
    agent: Agent,
    bundled: AgentManifest,
    warning: ?[]const u8,
    cached_remote_version: ?[]const u8,
    local_override_shadowing_remote: bool,
) !LoadedManifest {
    _ = agent;
    return loadedManifest(
        alloc,
        bundled,
        .bundled,
        warning,
        cached_remote_version,
        local_override_shadowing_remote,
    );
}

/// Bridge the parsed representation to the executable one: materialize a
/// `Rule` per `ManifestRule` and pre-compile its gate's regexes.
fn compileManifest(alloc: Allocator, m: AgentManifest) ![]CompiledRule {
    const rules = try alloc.alloc(Rule, m.rules.len);
    const compiled = try alloc.alloc(CompiledRule, m.rules.len);

    for (m.rules, 0..) |manifest_rule, i| {
        rules[i] = try ruleFromManifestRule(alloc, manifest_rule);
        compiled[i] = .{
            .rule = &rules[i],
            .gate = try compileGate(alloc, rules[i].gate),
        };
    }
    return compiled;
}

fn ruleFromManifestRule(alloc: Allocator, rule: ManifestRule) !Rule {
    return .{
        .id = rule.id,
        .state = ManifestState.from(rule.state orelse .unknown),
        .priority = rule.priority,
        .region = try parseRegion(rule.region),
        .visible_idle = rule.visible_idle,
        .visible_blocker = rule.visible_blocker,
        .visible_working = rule.visible_working,
        .skip_state_update = rule.skip_state_update,
        .gate = try gateFromManifestGate(alloc, manifestGateFromRule(rule)),
    };
}

fn gateFromManifestGate(alloc: Allocator, gate: ManifestGate) GateConvertError!Gate {
    return .{
        .contains = gate.contains,
        .regex = gate.regex,
        .line_regex = gate.line_regex,
        .all = try gateListFromManifestGates(alloc, gate.all),
        .any = try gateListFromManifestGates(alloc, gate.any),
        .not = try gateListFromManifestGates(alloc, gate.not_gate),
    };
}

/// `gateFromManifestGate` and `gateListFromManifestGates` recurse into each
/// other, so one side needs an explicit error set to break the cycle.
const GateConvertError = Allocator.Error || error{InvalidRegionName};

fn gateListFromManifestGates(alloc: Allocator, gates: []const ManifestGate) GateConvertError![]const Gate {
    const converted = try alloc.alloc(Gate, gates.len);
    for (gates, 0..) |gate, i| converted[i] = try gateFromManifestGate(alloc, gate);
    return converted;
}

/// Build an `AgentManifest` from a bundled Zig rule set, so the bundled and
/// parsed paths meet at the same type. Comptime, so the region formatting
/// costs nothing at runtime.
fn agentManifestFromRules(comptime label: []const u8, comptime rules: []const Rule) AgentManifest {
    comptime {
        var manifest_rules: [rules.len]ManifestRule = undefined;
        for (rules, 0..) |rule, i| {
            manifest_rules[i] = .{
                .id = rule.id,
                .state = manifestStateFromAgentState(rule.state),
                .priority = rule.priority,
                .region = regionName(rule.region),
                .visible_idle = rule.visible_idle,
                .visible_blocker = rule.visible_blocker,
                .visible_working = rule.visible_working,
                .skip_state_update = rule.skip_state_update,
                .all = manifestGatesFromGates(rule.gate.all),
                .any = manifestGatesFromGates(rule.gate.any),
                .not_gate = manifestGatesFromGates(rule.gate.not),
                .contains = rule.gate.contains,
                .regex = rule.gate.regex,
                .line_regex = rule.gate.line_regex,
            };
        }
        const frozen = manifest_rules;
        return .{
            .id = label,
            .version = bundled_manifest_version,
            .min_engine_version = manifest_update.MANIFEST_ENGINE_VERSION,
            .rules = &frozen,
        };
    }
}

/// The version stamped on the bundled rule sets. Bumping this is what lets
/// a newer bundled manifest take precedence over an older cached remote
/// one; it tracks the `manifest version` in `manifests/claude.zig`.
const bundled_manifest_version: []const u8 = "2026.8.13.1";

fn manifestStateFromAgentState(state: AgentState) ManifestState {
    return switch (state) {
        .Idle => .idle,
        .Working => .working,
        .Blocked => .blocked,
        .Unknown => .unknown,
    };
}

fn manifestGatesFromGates(comptime gates: []const Gate) []const ManifestGate {
    comptime {
        var converted: [gates.len]ManifestGate = undefined;
        for (gates, 0..) |gate, i| {
            converted[i] = .{
                .all = manifestGatesFromGates(gate.all),
                .any = manifestGatesFromGates(gate.any),
                .not_gate = manifestGatesFromGates(gate.not),
                .contains = gate.contains,
                .regex = gate.regex,
                .line_regex = gate.line_regex,
            };
        }
        const frozen = converted;
        return &frozen;
    }
}

/// The region spec string for a `Region`, the inverse of `parseRegion`.
fn regionName(comptime spec: Region) []const u8 {
    return switch (spec) {
        .bottom_lines => |n| std.fmt.comptimePrint("bottom_lines({d})", .{n}),
        .bottom_non_empty_lines => |n| std.fmt.comptimePrint("bottom_non_empty_lines({d})", .{n}),
        .top_non_empty_lines => |n| std.fmt.comptimePrint("top_non_empty_lines({d})", .{n}),
        inline else => |_, tag| @tagName(tag),
    };
}

/// Parse a manifest's region spec string into the engine's `Region`.
fn parseRegion(spec: []const u8) !Region {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");

    if (regionCount(trimmed, "bottom_lines")) |n| return .{ .bottom_lines = n };
    if (regionCount(trimmed, "bottom_non_empty_lines")) |n| return .{ .bottom_non_empty_lines = n };
    if (topRegionCount(trimmed)) |n| return .{ .top_non_empty_lines = n };

    inline for (@typeInfo(Region).@"union".fields) |field| {
        if (field.type == void and std.mem.eql(u8, trimmed, field.name)) {
            return @unionInit(Region, field.name, {});
        }
    }
    return error.InvalidRegionName;
}

fn compiledRuleMatches(alloc: Allocator, rule: *const CompiledRule, text: []const u8) bool {
    const lower_text = std.ascii.allocLowerString(alloc, text) catch return false;
    return compiledGateMatches(&rule.gate, text, lower_text);
}

/// The compiled twin of `gateMatches`, taking a pre-lowercased copy of the
/// text so a `contains` needle isn't re-lowercasing the whole region on
/// every rule.
fn compiledGateMatches(gate: *const CompiledGate, text: []const u8, lower_text: []const u8) bool {
    for (gate.contains) |needle| {
        if (!containsIgnoreCase(lower_text, needle)) return false;
    }
    for (gate.regex) |*r| {
        var mutable = r.*;
        if (!(regexMatches(&mutable, text) catch false)) return false;
    }
    for (gate.line_regex) |*r| {
        var mutable = r.*;
        if (!(lineRegexMatches(&mutable, text) catch false)) return false;
    }
    for (gate.all) |*nested| {
        if (!compiledGateMatches(nested, text, lower_text)) return false;
    }
    if (gate.any.len > 0) {
        for (gate.any) |*nested| {
            if (compiledGateMatches(nested, text, lower_text)) break;
        } else return false;
    }
    for (gate.not) |*nested| {
        if (compiledGateMatches(nested, text, lower_text)) return false;
    }
    return true;
}

/// The count in a `name(N)` region spec, or null if `spec` isn't that form.
fn regionCount(spec: []const u8, name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, spec, name)) return null;
    const rest = spec[name.len..];
    if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;
    return std.fmt.parseInt(usize, rest[1 .. rest.len - 1], 10) catch null;
}

/// `top_non_empty_lines(N)` is stricter than the other counted regions: no
/// leading zero, no sign, and bounded - it scans from the top of the
/// scrollback, so an unbounded count would walk the whole buffer.
fn topRegionCount(spec: []const u8) ?usize {
    if (!std.mem.startsWith(u8, spec, "top_non_empty_lines")) return null;
    const rest = spec["top_non_empty_lines".len..];
    if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;

    const count = rest[1 .. rest.len - 1];
    if (count.len == 0 or count[0] == '0') return null;
    for (count) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    const parsed = std.fmt.parseInt(usize, count, 10) catch return null;
    return if (parsed <= MAX_TOP_REGION_LINE_COUNT) parsed else null;
}

fn sliceFromLineIndex(content: []const u8, lines: []const []const u8, index: usize) []const u8 {
    if (index >= lines.len) return "";
    return content[@min(lineStartOffset(content, lines, index), content.len)..];
}

fn fileExists(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(global.io(), path, .{}) catch return false;
    return stat.kind == .file;
}

// ported-from: https://github.com/herdrdev/herdr/blob/master/src/detect/manifest/tests.rs
//
// herdr's loader fixtures are Codex TOML manifests; these are the same
// fixtures as Claude JSON. The `codex_*` names are kept because what each one
// pins down is a property of the engine (priority ordering, region scoping,
// OSC vs screen precedence), not of Codex.

fn remoteManifest(alloc: Allocator, version: []const u8, state: []const u8, contains: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "id": "claude",
        \\  "version": "{s}",
        \\  "min_engine_version": 1,
        \\  "updated_at": "2026-06-10T12:00:00Z",
        \\  "rules": [
        \\    {{ "id": "test", "state": "{s}", "contains": ["{s}"] }}
        \\  ]
        \\}}
    , .{ version, state, contains });
}

fn localManifest(alloc: Allocator, state: []const u8, contains: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "id": "claude",
        \\  "rules": [
        \\    {{ "id": "test", "state": "{s}", "contains": ["{s}"] }}
        \\  ]
        \\}}
    , .{ state, contains });
}

fn rulesManifest(alloc: Allocator, rules_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{ "id": "claude", "rules": [{s}] }}
    , .{rules_json});
}

/// Point the config and state roots at a scratch directory and reload, so a
/// test can write override and remote manifests without touching the real
/// ones. Restores and reloads on `deinit`.
const ManifestDirs = struct {
    alloc: Allocator,
    base: []const u8,
    previous_config: ?[]const u8,
    previous_state: ?[]const u8,

    fn deinit(self: *ManifestDirs) void {
        test_config_dir_override = self.previous_config;
        manifest_update.test_state_dir_override = self.previous_state;
        _ = reloadManifests(self.alloc) catch {};
        std.Io.Dir.cwd().deleteTree(global.io(), self.base) catch {};
    }
};

/// A per-run suffix for scratch paths. Derived from the wall clock rather
/// than the pid so this file makes no direct OS call.
fn uniqueSuffix() i96 {
    return std.Io.Timestamp.now(global.io(), .real).nanoseconds;
}

fn withManifestDirs(alloc: Allocator, name: []const u8) !ManifestDirs {
    const base = try std.fs.path.join(alloc, &.{
        "/tmp",
        try std.fmt.allocPrint(alloc, "coastty-manifest-loader-{s}-{d}", .{ name, uniqueSuffix() }),
    });
    std.Io.Dir.cwd().deleteTree(global.io(), base) catch {};

    const dirs: ManifestDirs = .{
        .alloc = alloc,
        .base = base,
        .previous_config = test_config_dir_override,
        .previous_state = manifest_update.test_state_dir_override,
    };
    test_config_dir_override = try std.fs.path.join(alloc, &.{ base, "config" });
    manifest_update.test_state_dir_override = try std.fs.path.join(alloc, &.{ base, "state" });
    _ = try reloadManifests(alloc);
    return dirs;
}

fn writeManifestFile(path: []const u8, content: []const u8) !void {
    const io = global.io();
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    try file_writer.interface.writeAll(content);
    try file_writer.flush();
}

fn writeRemoteCodex(alloc: Allocator, version: []const u8, state: []const u8, contains: []const u8) !void {
    try writeRemoteCodexWithoutReload(alloc, version, state, contains);
    _ = try reloadManifests(alloc);
}

fn writeRemoteCodexWithoutReload(alloc: Allocator, version: []const u8, state: []const u8, contains: []const u8) !void {
    const path = try manifest_update.remoteManifestPath(alloc, Agent.Claude.agentLabel());
    try writeManifestFile(path, try remoteManifest(alloc, version, state, contains));
}

fn writeLocalCodex(alloc: Allocator, content: []const u8) !void {
    const path = try overridePath(alloc, .Claude);
    try writeManifestFile(path, content);
    _ = try reloadManifests(alloc);
}

fn oscExplain(alloc: Allocator, agent: Agent, screen: []const u8, osc_title: []const u8, osc_progress: []const u8) !DetectionExplain {
    return explainWithInput(alloc, agent, .{
        .screen = screen,
        .osc_title = osc_title,
        .osc_progress = osc_progress,
    });
}

fn matchedRuleId(e: DetectionExplain) ?[]const u8 {
    return if (e.matched_rule) |rule| rule.id else null;
}

test "known_agent_no_match_defaults_to_idle_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e = try explain(alloc, .Claude, "ordinary prompt text");
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expect(!e.visible_idle);
    try std.testing.expectEqualStrings(DEFAULT_KNOWN_AGENT_IDLE_FALLBACK, e.fallback_reason.?);
}

test "rule_semantics_apply_gates_priority_and_line_regex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "rule-semantics");
    defer dirs.deinit();

    try writeLocalCodex(alloc, try rulesManifest(alloc,
        \\{ "id": "low_contains", "state": "idle", "priority": 1, "contains": ["match"] },
        \\{ "id": "high_nested_gates", "state": "working", "priority": 10, "contains": ["match"],
        \\  "all": [ { "any": [ { "regex": ["w[io]n"] }, { "contains": ["fallback"] } ] } ],
        \\  "not_gate": [ { "contains": ["blocked"] } ] },
        \\{ "id": "line_regex", "state": "blocked", "priority": 20, "line_regex": ["^exact line$"] }
    ));

    const high = try explain(alloc, .Claude, "match win");
    try std.testing.expectEqual(AgentState.Working, high.state);
    try std.testing.expectEqualStrings("high_nested_gates", matchedRuleId(high).?);

    // The `not` gate disqualifies the higher-priority rule, so the lower one wins.
    const not_gate = try explain(alloc, .Claude, "match win blocked");
    try std.testing.expectEqual(AgentState.Idle, not_gate.state);
    try std.testing.expectEqualStrings("low_contains", matchedRuleId(not_gate).?);

    // `line_regex` anchors per line, not against the whole region.
    const line = try explain(alloc, .Claude, "before\nexact line\nafter");
    try std.testing.expectEqual(AgentState.Blocked, line.state);
    try std.testing.expectEqualStrings("line_regex", matchedRuleId(line).?);
}

test "remote_manifest_loads_between_local_override_and_bundled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "remote-source");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "9999.01.01.1", "blocked", "remote-ready");

    const e = try explain(alloc, .Claude, "remote-ready");
    try std.testing.expectEqual(AgentState.Blocked, e.state);
    try std.testing.expect(e.source.? == .remote);
    try std.testing.expectEqualStrings("9999.01.01.1", e.manifest_version.?);
    try std.testing.expectEqualStrings("9999.01.01.1", e.cached_remote_version.?);
}

test "fallback_explain_preserves_active_manifest_version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "fallback-version");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "9999.01.01.1", "blocked", "remote-ready");

    // No rule matches, but the fallback still reports which manifest was active.
    const e = try explain(alloc, .Claude, "ordinary prompt text");
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expectEqualStrings(DEFAULT_KNOWN_AGENT_IDLE_FALLBACK, e.fallback_reason.?);
    try std.testing.expectEqualStrings("9999.01.01.1", e.manifest_version.?);
    try std.testing.expect(e.source.? == .remote);
}

test "older_cached_remote_manifest_does_not_shadow_newer_bundled_manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "older-remote-bundled-fallback");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "2026.6.10.0", "blocked", "remote-ready");

    const e = try explain(alloc, .Claude, "remote-ready");
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expect(e.source.? == .bundled);
    try std.testing.expectEqualStrings("2026.6.10.0", e.cached_remote_version.?);
    try std.testing.expect(std.mem.indexOf(u8, e.warning.?, "older than bundled") != null);
}

test "local_override_shadows_cached_remote_manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "local-shadows-remote");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "9999.01.01.1", "blocked", "remote-ready");
    try writeLocalCodex(alloc, try localManifest(alloc, "idle", "local-ready"));

    const e = try explain(alloc, .Claude, "local-ready");
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expect(e.source.? == .override_);
    try std.testing.expect(e.local_override_shadowing_remote);
    try std.testing.expectEqualStrings("9999.01.01.1", e.cached_remote_version.?);
}

test "invalid_local_override_falls_back_to_cached_remote_manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "invalid-local-remote-fallback");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "9999.01.01.1", "blocked", "remote-ready");
    try writeLocalCodex(alloc, "{ \"id\": ");

    const e = try explain(alloc, .Claude, "remote-ready");
    try std.testing.expectEqual(AgentState.Blocked, e.state);
    try std.testing.expect(e.source.? == .remote);
    try std.testing.expect(e.warning != null);
}

test "detection_uses_cached_manifest_until_explicit_reload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = try withManifestDirs(alloc, "cache-boundary");
    defer dirs.deinit();

    try writeRemoteCodex(alloc, "9999.01.01.1", "blocked", "cached-ready");

    const cached = try explain(alloc, .Claude, "cached-ready");
    try std.testing.expectEqual(AgentState.Blocked, cached.state);
    try std.testing.expect(cached.source.? == .remote);
    try std.testing.expectEqualStrings("test", matchedRuleId(cached).?);

    // Writing a new manifest without reloading must not change detection:
    // manifests are read once, not stat'd on every check.
    try writeRemoteCodexWithoutReload(alloc, "9999.01.01.2", "working", "new-ready");

    const unchanged = try explain(alloc, .Claude, "new-ready");
    try std.testing.expectEqual(AgentState.Idle, unchanged.state);
    try std.testing.expectEqualStrings(DEFAULT_KNOWN_AGENT_IDLE_FALLBACK, unchanged.fallback_reason.?);
    try std.testing.expectEqualStrings("9999.01.01.1", unchanged.cached_remote_version.?);

    _ = try reloadManifests(alloc);

    const reloaded = try explain(alloc, .Claude, "new-ready");
    try std.testing.expectEqual(AgentState.Working, reloaded.state);
    try std.testing.expectEqualStrings("9999.01.01.2", reloaded.cached_remote_version.?);
    try std.testing.expectEqualStrings("test", matchedRuleId(reloaded).?);
}

test "all_bundled_manifests_parse_and_validate" {
    for (Agent.SCREEN_MANIFEST_AGENTS) |agent| {
        const m = bundledManifest(agent) orelse return error.MissingBundledManifest;
        try validateManifest(m);
        try std.testing.expect(manifestMatchesAgent(m, agent));
    }
}

test "devin_manifest_detects_idle_working_and_blocked_states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // herdr checks Devin's bundled manifest covers all three states; the
    // equivalent here is that Claude's does.
    const idle = try oscExplain(alloc, .Claude, "", "\u{2733} Claude Code", "");
    try std.testing.expectEqual(AgentState.Idle, idle.state);
    try std.testing.expect(idle.visible_idle);

    const working = try oscExplain(alloc, .Claude, "", "\u{2802} project", "");
    try std.testing.expectEqual(AgentState.Working, working.state);
    try std.testing.expect(working.visible_working);

    const blocked = try oscExplain(
        alloc,
        .Claude,
        "do you want to proceed?\nbash command: rm -rf /tmp/x\n\u{276F} 1. Yes\n   2. No\n\nEsc to cancel \u{B7} Tab to amend\n",
        "",
        "",
    );
    try std.testing.expectEqual(AgentState.Blocked, blocked.state);
    try std.testing.expect(blocked.visible_blocker);
}

test "manifest_validation_rejects_unknown_fields_empty_rules_invalid_regions_and_regexes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A misspelled key must fail rather than being silently ignored - a
    // typo'd matcher would otherwise make the rule match everything.
    try std.testing.expectError(error.UnknownField, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "typo", "state": "working", "contain": ["Working"] } ] }
    ));

    try std.testing.expectError(error.GateHasNoPositiveMatcher, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "empty", "state": "working" } ] }
    ));

    try std.testing.expectError(error.ManifestHasNoRules, parseManifest(alloc,
        \\{ "id": "claude", "rules": [] }
    ));

    try std.testing.expectError(error.InvalidRegionName, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "bad_region", "state": "working",
        \\  "region": "after_last_promt_marker", "contains": ["Working"] } ] }
    ));

    try std.testing.expectError(error.InvalidRegexPattern, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "bad_regex", "state": "working", "regex": ["["] } ] }
    ));

    try std.testing.expectError(error.InvalidRegexPattern, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "bad_nested_regex", "state": "working",
        \\  "any": [ { "line_regex": ["["] } ] } ] }
    ));
}

test "manifest_validation_keeps_skip_rules_neutral" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(error.SkipStateUpdateRuleMustBeUnknown, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "bad_skip_state", "state": "idle",
        \\  "skip_state_update": true, "contains": ["menu"] } ] }
    ));

    try std.testing.expectError(error.SkipStateUpdateRuleHasVisibleEvidence, parseManifest(alloc,
        \\{ "id": "claude", "rules": [ { "id": "bad_skip_visible", "state": "unknown",
        \\  "skip_state_update": true, "visible_blocker": true, "contains": ["menu"] } ] }
    ));
}

test "manifest_validation_rejects_excessive_rule_count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var rules: std.ArrayList(u8) = .empty;
    for (0..MAX_RULES_PER_MANIFEST + 1) |index| {
        if (index > 0) try rules.appendSlice(alloc, ",");
        try rules.appendSlice(alloc, try std.fmt.allocPrint(alloc,
            \\{{ "id": "rule_{d}", "state": "idle", "contains": ["ready"] }}
        , .{index}));
    }

    try std.testing.expectError(
        error.ManifestHasTooManyRules,
        parseManifest(alloc, try rulesManifest(alloc, rules.items)),
    );
}

test "manifest_validation_rejects_excessive_gate_depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var gate: std.ArrayList(u8) = .empty;
    try gate.appendSlice(alloc,
        \\{ "contains": ["deepest"] }
    );
    for (0..MAX_GATE_DEPTH + 2) |depth| {
        const nested = try std.fmt.allocPrint(alloc,
            \\{{ "contains": ["d{d}"], "all": [{s}] }}
        , .{ depth, gate.items });
        gate.clearRetainingCapacity();
        try gate.appendSlice(alloc, nested);
    }

    const content = try rulesManifest(alloc, try std.fmt.allocPrint(alloc,
        \\{{ "id": "deep", "state": "idle", "contains": ["ready"], "all": [{s}] }}
    , .{gate.items}));

    try std.testing.expectError(error.GateDepthExceeded, parseManifest(alloc, content));
}

test "manifest_validation_rejects_excessive_matchers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var matchers: std.ArrayList(u8) = .empty;
    for (0..MAX_MATCHERS_PER_GATE + 1) |index| {
        if (index > 0) try matchers.appendSlice(alloc, ", ");
        try matchers.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\"m{d}\"", .{index}));
    }

    const content = try rulesManifest(alloc, try std.fmt.allocPrint(alloc,
        \\{{ "id": "many", "state": "idle", "contains": [{s}] }}
    , .{matchers.items}));

    try std.testing.expectError(error.TooManyMatchersInGate, parseManifest(alloc, content));
}

test "top_non_empty_lines_requires_a_canonical_positive_bounded_count" {
    try validateRegionName("top_non_empty_lines(1)");
    try validateRegionName("top_non_empty_lines(65535)");

    // No zero, no leading zero, no sign, and bounded: the region scans from
    // the top of the scrollback, so the count has to stay small.
    for ([_][]const u8{ "0", "01", "+1", "65536", "999999999999999999999999" }) |count| {
        var buf: [64]u8 = undefined;
        const spec = try std.fmt.bufPrint(&buf, "top_non_empty_lines({s})", .{count});
        try std.testing.expectError(error.InvalidRegionName, validateRegionName(spec));
    }
}

test "top_non_empty_lines_requires_engine_three_when_declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Declaring an older engine while using a region that engine didn't have
    // would make the manifest silently misbehave on an older build.
    try std.testing.expectError(error.RegionRequiresNewerMinEngineVersion, parseManifest(alloc,
        \\{ "id": "claude", "version": "1", "min_engine_version": 2,
        \\  "rules": [ { "id": "background", "state": "working",
        \\    "region": " top_non_empty_lines(1) ", "contains": ["active"] } ] }
    ));
}

test "codex_osc_title_braille_spinner_is_working" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e = try oscExplain(alloc, .Claude, "", "\u{2802} project", "");
    try std.testing.expectEqual(AgentState.Working, e.state);
    try std.testing.expect(e.visible_working);
    try std.testing.expectEqualStrings("osc_title_working", matchedRuleId(e).?);
}

test "codex_osc_title_action_required_is_blocked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Claude has no "action required" OSC title; its blocked signal is live
    // screen chrome, which outranks an idle title.
    const e = try oscExplain(
        alloc,
        .Claude,
        "\u{2500}\u{2500}\u{2500}\u{2500}\n  1. Yes\n  2. No\n\nEnter to select \u{B7} \u{2191}/\u{2193} to navigate \u{B7} Esc to cancel\n",
        "\u{2733} Claude Code",
        "",
    );
    try std.testing.expectEqual(AgentState.Blocked, e.state);
    try std.testing.expect(e.visible_blocker);
}

test "codex_osc_title_plain_is_idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e = try oscExplain(alloc, .Claude, "", "\u{2733} Claude Code", "");
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expect(e.visible_idle);
    try std.testing.expectEqualStrings("osc_title_idle", matchedRuleId(e).?);
}

test "codex_trust_directory_requires_live_top_region" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `live_blocked_form` is scoped to after the last horizontal rule, so a
    // prompt that has already scrolled above one is not a live blocker.
    const stale =
        "Enter to select \u{B7} \u{2191}/\u{2193} to navigate \u{B7} Esc to cancel\n" ++
        "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n" ++
        "all done\n";
    const e = try oscExplain(alloc, .Claude, stale, "", "");
    try std.testing.expect(e.state != AgentState.Blocked or matchedRuleId(e) == null or
        !std.mem.eql(u8, matchedRuleId(e).?, "live_blocked_form"));

    const live =
        "all done\n" ++
        "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n" ++
        "Enter to select \u{B7} \u{2191}/\u{2193} to navigate \u{B7} Esc to cancel\n";
    const live_explain = try oscExplain(alloc, .Claude, live, "", "");
    try std.testing.expectEqual(AgentState.Blocked, live_explain.state);
    try std.testing.expectEqualStrings("live_blocked_form", matchedRuleId(live_explain).?);
}

test "codex_background_terminal_screen_does_not_override_osc_idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Ordinary transcript text is not live chrome, so the idle title stands.
    const e = try oscExplain(
        alloc,
        .Claude,
        "running some build output\nnothing interactive here\n",
        "\u{2733} Claude Code",
        "",
    );
    try std.testing.expectEqual(AgentState.Idle, e.state);
    try std.testing.expectEqualStrings("osc_title_idle", matchedRuleId(e).?);
}

test "codex_screen_working_fallback_handles_static_osc_title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The `/btw` overlay is Claude's screen-side working signal, and it
    // outranks a static (idle) OSC title.
    const e = try oscExplain(
        alloc,
        .Claude,
        "  /btw something\n\nesc to close\n",
        "\u{2733} Claude Code",
        "",
    );
    try std.testing.expectEqual(AgentState.Working, e.state);
    try std.testing.expectEqualStrings("btw_overlay_working", matchedRuleId(e).?);
}

test "codex_osc_working_remains_preferred_over_screen_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e = try oscExplain(
        alloc,
        .Claude,
        "  /btw something\n\nesc to close\n",
        "\u{2802} working",
        "",
    );
    try std.testing.expectEqual(AgentState.Working, e.state);
    try std.testing.expectEqualStrings("osc_title_working", matchedRuleId(e).?);
}

test "codex_screen_blocker_outranks_working_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // live_blocked_form (980) over btw_overlay_working (975): being blocked
    // on a human is more urgent than looking busy.
    const e = try oscExplain(
        alloc,
        .Claude,
        "  /btw something\n\nesc to close\n" ++
            "\u{2500}\u{2500}\u{2500}\u{2500}\n" ++
            "Enter to confirm \u{B7} Esc to cancel\n",
        "",
        "",
    );
    try std.testing.expectEqual(AgentState.Blocked, e.state);
    try std.testing.expectEqualStrings("live_blocked_form", matchedRuleId(e).?);
}

test "codex_weak_blocker_outranks_working_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Claude orders these the other way round from Codex:
    // `legacy_no_prompt_blocker` is priority 300, below the 975 working
    // overlay, precisely because prompt-like prose in the scrollback is a
    // weak signal. It still wins when nothing stronger is on screen.
    const weak = try oscExplain(alloc, .Claude, "would you like to continue? yes\n", "", "");
    try std.testing.expectEqual(AgentState.Blocked, weak.state);
    try std.testing.expectEqualStrings("legacy_no_prompt_blocker", matchedRuleId(weak).?);

    const with_working = try oscExplain(
        alloc,
        .Claude,
        "would you like to continue? yes\n  /btw something\n\nesc to close\n",
        "",
        "",
    );
    try std.testing.expectEqual(AgentState.Working, with_working.state);
    try std.testing.expectEqualStrings("btw_overlay_working", matchedRuleId(with_working).?);
}

test "codex_transcript_viewer_outranks_working_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The transcript viewer (1000) shows history rather than live state, so
    // it suppresses the publish entirely instead of reporting one.
    const e = try oscExplain(
        alloc,
        .Claude,
        "showing detailed transcript\nctrl+o to toggle\n",
        "",
        "",
    );
    try std.testing.expectEqualStrings("transcript_viewer", matchedRuleId(e).?);
    try std.testing.expect(e.skip_state_update);
    try std.testing.expect(std.mem.indexOf(u8, e.skipped_update_reason.?, "transcript_viewer") != null);
}

test "codex_screen_working_fallback_ignores_stale_and_prompt_text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `/btw` has to be at the start of a line within the bottom 5 non-empty
    // lines, alongside its own "esc to close" footer - a mention of it in
    // prose is not the overlay.
    const e = try oscExplain(
        alloc,
        .Claude,
        "I ran /btw earlier and it printed something\nthen kept going\n",
        "",
        "",
    );
    try std.testing.expect(e.state != AgentState.Working);
}

test "codex_screen_working_fallback_ignores_interrupted_short_terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A truncated overlay - the `/btw` line without its footer - must not
    // read as working.
    const e = try oscExplain(alloc, .Claude, "  /btw something\n", "", "");
    try std.testing.expect(e.state != AgentState.Working);
}

test "codex_osc_working_beats_weak_blocker_screen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const e = try oscExplain(
        alloc,
        .Claude,
        "would you like to continue? yes\n",
        "\u{2802} working",
        "",
    );
    try std.testing.expectEqual(AgentState.Working, e.state);
    try std.testing.expectEqualStrings("osc_title_working", matchedRuleId(e).?);
}
