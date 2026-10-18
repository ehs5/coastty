//! The daemon's model: the ordered Spaces, the ordered tabs in each, and
//! which panes sit in each tab, with the names, hidden state and
//! directories that go with them. coastty-host owns this and every
//! client - the Mac app included - reads it from here.
//!
//! Nothing a window means lives here. Frames, which window shows which
//! Space, active indices, split ratios, focus, tab colour and sidebar
//! width are presentation, owned by whichever GUI window is drawing;
//! Spaces and tabs are coastty's own concepts and move between windows
//! freely. If a fact only means something relative to a window on a
//! screen, it does not belong in this file.
//!
//! Plain data with no locking of its own: `Host` holds the one mutex
//! that guards it, which also keeps this file testable without a socket
//! or a thread.
const Model = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.coastty_host_model);

/// The shape of the model file this build writes. An older file still
/// loads - every field it can be missing has a default - and the next
/// write brings it forward to this version. A file from a newer version
/// is moved aside unread rather than guessed at.
pub const current_version: u32 = 1;

/// How much of a model file this daemon is willing to read. Far beyond
/// any real user's Space count, and bounded so a corrupt length can't
/// make startup allocate unboundedly.
const max_file_bytes = 8 * 1024 * 1024;

pub const Pane = struct {
    id: []u8,

    /// Last known working directory. Persisted, because it is what a
    /// fresh shell comes back in after the daemon restarts.
    directory: []u8,

    /// The live process's current terminal title. Never persisted:
    /// there is no title to restore for a process that is gone.
    title: []u8,

    /// What the pane's agent is doing. Live-only, like the title.
    agent: AgentFacts = .{},
};

/// A pane's agent as clients see it. Every string is a static name, so a
/// copy owns nothing.
pub const AgentFacts = struct {
    /// Which agent, or null for none.
    agent: ?[]const u8 = null,
    state: []const u8 = "unknown",

    /// The attention state: `state` folded with `seen`, so an idle agent
    /// nobody has looked at is "done".
    attention: []const u8 = "unknown",
    seen: bool = true,

    /// When `state` last changed. A client acknowledging what it rendered
    /// names this, so it cannot acknowledge a newer state by accident.
    state_seq: u64 = 0,

    /// Orders agents across every pane, the same for every client.
    recency: u64 = 0,

    fn eql(a: AgentFacts, b: AgentFacts) bool {
        const same_agent = if (a.agent) |x| (if (b.agent) |y| std.mem.eql(u8, x, y) else false) else b.agent == null;
        return same_agent and
            std.mem.eql(u8, a.state, b.state) and
            std.mem.eql(u8, a.attention, b.attention) and
            a.seen == b.seen and
            a.state_seq == b.state_seq and
            a.recency == b.recency;
    }
};

pub const Tab = struct {
    id: []u8,

    /// User-set title; empty when the user has not named this tab.
    name: []u8,

    panes: std.ArrayList(Pane) = .empty,
};

pub const Space = struct {
    id: []u8,

    /// User-set name; empty when the user has not named this Space.
    name: []u8,

    /// Derived from the starter pane's directory the first time this
    /// Space has one, then frozen: a Space's name must not drift
    /// because a later tab arrives or a shell changes directory.
    default_name: []u8,

    hidden: bool = false,

    /// The position among the visible Spaces that an unhide puts this
    /// Space back at.
    restore_index: usize = 0,

    tabs: std.ArrayList(Tab) = .empty,
};

alloc: Allocator,

/// Identifies this run of the daemon. A client seeing a different one
/// than it cached knows the daemon restarted underneath it, and that
/// `revision` started over with it.
run_id: [32]u8,

/// Increases on every change. Run-scoped rather than persisted: paired
/// with `run_id` it is what tells a client its cached copy is stale.
revision: u64 = 0,

/// Increases only on the changes the persisted document holds, so a
/// live-only fact like a pane's title never owes the disk a write.
/// Bookkeeping for whoever writes the file; no client ever sees it.
file_revision: u64 = 0,

spaces: std.ArrayList(Space) = .empty,

pub fn init(alloc: Allocator, run_id: [32]u8) Model {
    return .{ .alloc = alloc, .run_id = run_id };
}

pub fn deinit(model: *Model) void {
    model.clear();
    model.spaces.deinit(model.alloc);
}

/// Drops everything the model holds, back to the shape `init` gave it.
fn clear(model: *Model) void {
    for (model.spaces.items) |*space| model.deinitSpace(space);
    model.spaces.clearRetainingCapacity();
    model.revision = 0;
    model.file_revision = 0;
}

fn deinitSpace(model: *Model, space: *Space) void {
    for (space.tabs.items) |*tab| model.deinitTab(tab);
    space.tabs.deinit(model.alloc);
    model.alloc.free(space.id);
    model.alloc.free(space.name);
    model.alloc.free(space.default_name);
}

fn deinitTab(model: *Model, tab: *Tab) void {
    for (tab.panes.items) |*pane| model.deinitPane(pane);
    tab.panes.deinit(model.alloc);
    model.alloc.free(tab.id);
    model.alloc.free(tab.name);
}

fn deinitPane(model: *Model, pane: *Pane) void {
    model.alloc.free(pane.id);
    model.alloc.free(pane.directory);
    model.alloc.free(pane.title);
}

/// Replaces an owned string field with a copy of `value`. The new copy
/// is taken before the old one is freed, so a failed allocation leaves
/// the field as it was.
fn setString(model: *Model, field: *[]u8, value: []const u8) !void {
    const copy = try model.alloc.dupe(u8, value);
    model.alloc.free(field.*);
    field.* = copy;
}

/// Records a change every client sees and the file has to hold.
fn recordChange(model: *Model) void {
    model.revision += 1;
    model.file_revision += 1;
}

/// Records a change to a live-only fact. Clients see it, the file never
/// holds it, so it owes the disk nothing.
fn recordLiveChange(model: *Model) void {
    model.revision += 1;
}

fn findSpaceIndex(model: *const Model, id: []const u8) ?usize {
    for (model.spaces.items, 0..) |space, i| {
        if (std.mem.eql(u8, space.id, id)) return i;
    }
    return null;
}

pub fn findSpace(model: *Model, id: []const u8) ?*Space {
    const index = model.findSpaceIndex(id) orelse return null;
    return &model.spaces.items[index];
}

/// The tab with this id, wherever in the model it sits, together with
/// the Space holding it and its position in that Space.
pub const TabLocation = struct { space: *Space, index: usize };

pub fn findTab(model: *Model, id: []const u8) ?TabLocation {
    for (model.spaces.items) |*space| {
        for (space.tabs.items, 0..) |tab, i| {
            if (std.mem.eql(u8, tab.id, id)) return .{ .space = space, .index = i };
        }
    }
    return null;
}

/// The pane with this id, wherever in the model it sits, together with
/// the tab holding it and its position in that tab.
const PaneLocation = struct { tab: *Tab, index: usize };

fn findPaneLocation(model: *Model, id: []const u8) ?PaneLocation {
    for (model.spaces.items) |*space| {
        for (space.tabs.items) |*tab| {
            for (tab.panes.items, 0..) |pane, i| {
                if (std.mem.eql(u8, pane.id, id)) return .{ .tab = tab, .index = i };
            }
        }
    }
    return null;
}

/// The Space holding the pane with this id.
pub fn findSpaceOfPane(model: *Model, pane_id: []const u8) ?*Space {
    for (model.spaces.items) |*space| {
        for (space.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                if (std.mem.eql(u8, pane.id, pane_id)) return space;
            }
        }
    }
    return null;
}

/// The tab holding the pane with this id.
pub fn findTabOfPane(model: *Model, pane_id: []const u8) ?*Tab {
    const found = model.findPaneLocation(pane_id) orelse return null;
    return found.tab;
}

pub fn findPane(model: *Model, id: []const u8) ?*Pane {
    const found = model.findPaneLocation(id) orelse return null;
    return &found.tab.panes.items[found.index];
}

/// The array slot a Space must sit at to occupy visible position
/// `index`, hidden Spaces not counting towards it. Computed against the
/// list as it currently stands, so a caller moving a Space removes it
/// first and asks afterwards.
fn slotForVisibleIndex(model: *const Model, index: usize) usize {
    var seen: usize = 0;
    for (model.spaces.items, 0..) |space, slot| {
        if (space.hidden) continue;
        if (seen == index) return slot;
        seen += 1;
    }
    return model.spaces.items.len;
}

/// The visible position of the Space at array slot `slot`.
fn visibleIndexOf(model: *const Model, slot: usize) usize {
    var seen: usize = 0;
    for (model.spaces.items[0..slot]) |space| {
        if (space.hidden) continue;
        seen += 1;
    }
    return seen;
}

/// Adds a Space at the end of the order. `name` is the user-set name and
/// is normally empty - the default comes from the starter pane's
/// directory, once there is one (see `deriveDefaultNames`).
pub fn createSpace(model: *Model, id: []const u8, name: []const u8) !void {
    if (id.len == 0) return error.MissingId;
    if (model.findSpaceIndex(id) != null) return error.DuplicateId;

    const space_id = try model.alloc.dupe(u8, id);
    errdefer model.alloc.free(space_id);
    const space_name = try model.alloc.dupe(u8, name);
    errdefer model.alloc.free(space_name);
    const default_name = try model.alloc.dupe(u8, "");
    errdefer model.alloc.free(default_name);

    try model.spaces.append(model.alloc, .{
        .id = space_id,
        .name = space_name,
        .default_name = default_name,
    });
    model.recordChange();
}

/// Drops a Space and everything under it from the model. Structural
/// only: the panes it held keep running until a `KILL` ends them.
pub fn closeSpace(model: *Model, id: []const u8) !void {
    const slot = model.findSpaceIndex(id) orelse return error.NoSuchSpace;
    var space = model.spaces.orderedRemove(slot);
    model.deinitSpace(&space);
    model.recordChange();
}

/// Sets a Space's user-set name. An empty name clears it, putting the
/// Space back on its derived default.
pub fn renameSpace(model: *Model, id: []const u8, name: []const u8) !void {
    const space = model.findSpace(id) orelse return error.NoSuchSpace;
    try model.setString(&space.name, name);
    model.recordChange();
}

/// Moves a Space to visible position `index`. A position past the end
/// lands it last.
pub fn moveSpace(model: *Model, id: []const u8, index: usize) !void {
    const from = model.findSpaceIndex(id) orelse return error.NoSuchSpace;
    const space = model.spaces.orderedRemove(from);
    const to = model.slotForVisibleIndex(index);

    // The remove above freed a slot without shrinking capacity, so this
    // insert cannot allocate and cannot fail.
    model.spaces.insertAssumeCapacity(to, space);
    if (to != from) model.recordChange();
}

/// Tucks a Space out of the normal order, remembering where to put it
/// back. Nothing is killed - a hidden Space is fully alive.
pub fn hideSpace(model: *Model, id: []const u8) !void {
    const slot = model.findSpaceIndex(id) orelse return error.NoSuchSpace;
    const space = &model.spaces.items[slot];
    if (space.hidden) return;

    space.restore_index = model.visibleIndexOf(slot);
    space.hidden = true;
    model.recordChange();
}

/// Brings a hidden Space back at the position it was hidden from.
pub fn showSpace(model: *Model, id: []const u8) !void {
    const slot = model.findSpaceIndex(id) orelse return error.NoSuchSpace;
    if (!model.spaces.items[slot].hidden) return;

    var space = model.spaces.orderedRemove(slot);
    space.hidden = false;
    const to = model.slotForVisibleIndex(space.restore_index);
    model.spaces.insertAssumeCapacity(to, space);
    model.recordChange();
}

/// Adds a tab at the end of a Space's tab order.
pub fn createTab(model: *Model, space_id: []const u8, tab_id: []const u8, name: []const u8) !void {
    if (tab_id.len == 0) return error.MissingId;
    if (model.findTab(tab_id) != null) return error.DuplicateId;
    const space = model.findSpace(space_id) orelse return error.NoSuchSpace;

    const id = try model.alloc.dupe(u8, tab_id);
    errdefer model.alloc.free(id);
    const tab_name = try model.alloc.dupe(u8, name);
    errdefer model.alloc.free(tab_name);

    try space.tabs.append(model.alloc, .{ .id = id, .name = tab_name });
    model.recordChange();
}

/// Drops a tab and its pane membership. Structural only, like
/// `closeSpace`.
pub fn closeTab(model: *Model, id: []const u8) !void {
    const found = model.findTab(id) orelse return error.NoSuchTab;
    var tab = found.space.tabs.orderedRemove(found.index);
    model.deinitTab(&tab);
    model.recordChange();
}

/// Sets a tab's user-set title. An empty name clears it.
pub fn renameTab(model: *Model, id: []const u8, name: []const u8) !void {
    const found = model.findTab(id) orelse return error.NoSuchTab;
    const tab = &found.space.tabs.items[found.index];
    try model.setString(&tab.name, name);
    model.recordChange();
}

/// Moves a tab within its own Space. A position past the end lands it
/// last.
pub fn moveTab(model: *Model, id: []const u8, index: usize) !void {
    const found = model.findTab(id) orelse return error.NoSuchTab;
    const tabs = &found.space.tabs;
    const tab = tabs.orderedRemove(found.index);
    const to = @min(index, tabs.items.len);

    tabs.insertAssumeCapacity(to, tab);
    if (to != found.index) model.recordChange();
}

/// Puts a pane in a tab at a position, taking it out of whatever tab it
/// was in before. This is also how a pane first joins the model.
pub fn movePane(model: *Model, pane_id: []const u8, tab_id: []const u8, index: usize) !void {
    if (pane_id.len == 0) return error.MissingId;
    const found = model.findTab(tab_id) orelse return error.NoSuchTab;
    const tab = &found.space.tabs.items[found.index];

    // Reserved before the pane is lifted out of its old tab, so a failed
    // allocation leaves it where it was rather than dropping it.
    try tab.panes.ensureUnusedCapacity(model.alloc, 1);

    const pane = model.takePane(pane_id) orelse try model.newPane(pane_id);
    const to = @min(index, tab.panes.items.len);
    tab.panes.insertAssumeCapacity(to, pane);
    model.recordChange();
}

/// Forgets a pane entirely - what a `KILL` or a `SWEEP` leaves behind.
/// Returns whether the model held it.
pub fn removePane(model: *Model, pane_id: []const u8) bool {
    var pane = model.takePane(pane_id) orelse return false;
    model.deinitPane(&pane);
    model.recordChange();
    return true;
}

/// Lifts a pane out of whatever tab holds it, handing ownership of its
/// strings to the caller.
fn takePane(model: *Model, pane_id: []const u8) ?Pane {
    const found = model.findPaneLocation(pane_id) orelse return null;
    return found.tab.panes.orderedRemove(found.index);
}

fn newPane(model: *Model, pane_id: []const u8) !Pane {
    const id = try model.alloc.dupe(u8, pane_id);
    errdefer model.alloc.free(id);
    const directory = try model.alloc.dupe(u8, "");
    errdefer model.alloc.free(directory);
    const title = try model.alloc.dupe(u8, "");
    return .{ .id = id, .directory = directory, .title = title };
}

/// Records where a pane's shell currently is. A change here is a change
/// to the model - the directory is what a restored pane reopens in - so
/// it moves the revision on.
pub fn setDirectory(model: *Model, pane: *Pane, directory: []const u8) !void {
    if (std.mem.eql(u8, pane.directory, directory)) return;

    try model.setString(&pane.directory, directory);
    model.recordChange();
}

/// Records a pane's current terminal title. It rides in the snapshot a
/// client renders from, so it moves the revision; it is never persisted,
/// so it never asks for a write.
pub fn setTitle(model: *Model, pane: *Pane, title: []const u8) !void {
    if (std.mem.eql(u8, pane.title, title)) return;

    try model.setString(&pane.title, title);
    model.recordLiveChange();
}

/// Records what a pane's agent is doing. Clients render it, the file never
/// holds it.
pub fn setAgentFacts(model: *Model, pane: *Pane, facts: AgentFacts) void {
    if (pane.agent.eql(facts)) return;
    pane.agent = facts;
    model.recordLiveChange();
}

/// Gives every still-unnamed Space the default name its starter pane's
/// directory implies, once that pane has one. Frozen from then on, so a
/// later `cd` or a second tab never renames a Space underneath the user.
pub fn deriveDefaultNames(model: *Model, home: []const u8) !void {
    for (model.spaces.items) |*space| {
        if (space.default_name.len > 0) continue;
        const starter = starterDirectory(space) orelse continue;
        const derived = defaultSpaceName(starter, home);
        if (derived.len == 0) continue;

        try model.setString(&space.default_name, derived);
        model.recordChange();
    }
}

/// The directory of a Space's starter pane: the first pane of its first
/// tab, the one the Space was opened on.
fn starterDirectory(space: *const Space) ?[]const u8 {
    if (space.tabs.items.len == 0) return null;
    const first_tab = &space.tabs.items[0];
    if (first_tab.panes.items.len == 0) return null;

    const directory = first_tab.panes.items[0].directory;
    return if (directory.len > 0) directory else null;
}

/// The name a directory gives a Space: its own folder, or `~` for the
/// home directory itself.
pub fn defaultSpaceName(directory: []const u8, home: []const u8) []const u8 {
    const trimmed = trimTrailingSlash(directory);
    if (trimmed.len == 0) return "/";
    if (home.len > 0 and std.mem.eql(u8, trimmed, trimTrailingSlash(home))) return "~";
    return std.fs.path.basename(trimmed);
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return if (end == 1 and path[0] == '/') path[0..0] else path[0..end];
}

/// Which of the two documents `writeDocument` is producing.
const Document = enum {
    /// Everything a client needs to render coastty in one response,
    /// live facts included.
    snapshot,

    /// What goes on disk: what exists, never what is running.
    file,
};

/// Writes the model as one JSON document.
///
/// The snapshot carries `run_id` and `revision`, so a client can tell a
/// stale cached copy from a current one, and each pane's live title
/// alongside the directory it is sitting in. The file leaves all three
/// out: a restart brings the structure and the directories back, not
/// the processes that were in them.
fn writeDocument(model: *const Model, writer: *Io.Writer, document: Document) Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(current_version);

    if (document == .snapshot) {
        try json.objectField("run_id");
        try json.write(@as([]const u8, &model.run_id));
        try json.objectField("revision");
        try json.write(model.revision);
    }

    try json.objectField("spaces");
    try json.beginArray();
    for (model.spaces.items) |space| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(space.id);
        try json.objectField("name");
        try json.write(space.name);
        try json.objectField("default_name");
        try json.write(space.default_name);
        try json.objectField("hidden");
        try json.write(space.hidden);
        try json.objectField("restore_index");
        try json.write(space.restore_index);
        try json.objectField("tabs");
        try json.beginArray();
        for (space.tabs.items) |tab| {
            try json.beginObject();
            try json.objectField("id");
            try json.write(tab.id);
            try json.objectField("name");
            try json.write(tab.name);
            try json.objectField("panes");
            try json.beginArray();
            for (tab.panes.items) |pane| {
                try json.beginObject();
                try json.objectField("id");
                try json.write(pane.id);
                try json.objectField("directory");
                try json.write(pane.directory);
                if (document == .snapshot) {
                    try json.objectField("title");
                    try json.write(pane.title);
                    try json.objectField("agent");
                    try json.write(pane.agent.agent);
                    try json.objectField("state");
                    try json.write(pane.agent.state);
                    try json.objectField("attention");
                    try json.write(pane.agent.attention);
                    try json.objectField("seen");
                    try json.write(pane.agent.seen);
                    try json.objectField("state_seq");
                    try json.write(pane.agent.state_seq);
                    try json.objectField("recency");
                    try json.write(pane.agent.recency);
                }
                try json.endObject();
            }
            try json.endArray();
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

/// The whole model in one document, as bytes the caller owns: what a
/// client renders everything it shows from.
pub fn renderSnapshot(model: *const Model, alloc: Allocator) ![]u8 {
    return model.renderDocument(alloc, .snapshot);
}

/// The persisted shape as bytes the caller owns. Separate from
/// `writeBytes` so the daemon holds its model lock only while
/// serialising and never while it is talking to the disk.
pub fn renderFile(model: *const Model, alloc: Allocator) ![]u8 {
    return model.renderDocument(alloc, .file);
}

fn renderDocument(model: *const Model, alloc: Allocator, document: Document) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try model.writeDocument(&out.writer, document);
    return out.toOwnedSlice();
}

/// The file's decoded shape. Every field defaults, which is what lets a
/// file written by an older version load here and be brought forward on
/// the next write instead of being thrown away.
const FilePane = struct {
    id: []const u8 = "",
    directory: []const u8 = "",
};

const FileTab = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    panes: []const FilePane = &.{},
};

const FileSpace = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    default_name: []const u8 = "",
    hidden: bool = false,
    restore_index: usize = 0,
    tabs: []const FileTab = &.{},
};

const FileDocument = struct {
    version: u32 = 0,
    spaces: []const FileSpace = &.{},
};

/// Puts `bytes` at `path`, replacing whatever is there, and does not
/// return until they are on disk: a half-written model is worse than an
/// old one. The temp file and the rename are what make it
/// all-or-nothing; the syncs are what make it survive a power cut.
pub fn writeBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.PathHasNoParent;
    const basename = std.fs.path.basename(path);

    std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic.deinit(io);

    var buf: [8192]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buf);
    try file_writer.interface.writeAll(bytes);
    try file_writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);

    syncDir(io, parent) catch |err| {
        if (!directorySyncUnsupported(err)) log.warn(
            "model written but its directory's sync failed: {t}",
            .{err},
        );
    };
}

/// Renders and writes in one step, for callers with no lock to worry
/// about.
pub fn save(model: *const Model, io: Io, path: []const u8) !void {
    const bytes = try model.renderFile(model.alloc);
    defer model.alloc.free(bytes);
    try writeBytes(io, path, bytes);
}

/// Some filesystems refuse a directory fsync. The rename already
/// happened, so that is not a failure to commit.
fn directorySyncUnsupported(err: anyerror) bool {
    return switch (err) {
        error.Unsupported, error.InvalidArgument, error.AccessDenied, error.PermissionDenied => true,
        else => false,
    };
}

fn syncDir(io: Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const as_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

/// Reads `path` into this model, which must be empty. A missing file is
/// an empty model, not a failure - that is a first run.
///
/// A file this build cannot read is moved aside rather than left in
/// place to be overwritten by the first save: whatever it holds is the
/// user's structure, and the daemon has to keep serving either way.
pub fn load(model: *Model, io: Io, path: []const u8) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, model.alloc, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer model.alloc.free(content);

    const parsed = std.json.parseFromSlice(FileDocument, model.alloc, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        moveAside(io, path, model.alloc);
        return err;
    };
    defer parsed.deinit();

    if (parsed.value.version > current_version) {
        moveAside(io, path, model.alloc);
        return error.ModelFileTooNew;
    }

    try model.adopt(parsed.value);
}

/// Copies a decoded file into the model. Entries without an id are
/// dropped rather than rejected: one unusable Space is not a reason to
/// lose the rest of a user's structure.
fn adopt(model: *Model, doc: FileDocument) !void {
    for (doc.spaces) |file_space| {
        if (file_space.id.len == 0) continue;
        model.createSpace(file_space.id, file_space.name) catch |err| switch (err) {
            error.DuplicateId, error.MissingId => continue,
            else => return err,
        };

        const space = model.findSpace(file_space.id).?;
        try model.setString(&space.default_name, file_space.default_name);
        space.hidden = file_space.hidden;
        space.restore_index = file_space.restore_index;

        for (file_space.tabs) |file_tab| {
            if (file_tab.id.len == 0) continue;
            model.createTab(file_space.id, file_tab.id, file_tab.name) catch |err| switch (err) {
                error.DuplicateId, error.MissingId, error.NoSuchSpace => continue,
                else => return err,
            };

            for (file_tab.panes, 0..) |file_pane, index| {
                if (file_pane.id.len == 0) continue;
                model.movePane(file_pane.id, file_tab.id, index) catch |err| switch (err) {
                    error.MissingId, error.NoSuchTab => continue,
                    else => return err,
                };
                try model.setDirectory(model.findPane(file_pane.id).?, file_pane.directory);
            }
        }
    }

    // Loading is not a change anybody made: a fresh run starts its
    // revision count at zero over whatever it read back.
    model.revision = 0;
}

/// Renames an unreadable model file out of the way, stamped so a second
/// bad file never overwrites the first.
fn moveAside(io: Io, path: []const u8, alloc: Allocator) void {
    const stamp = std.Io.Timestamp.now(io, .real);
    const aside = std.fmt.allocPrint(alloc, "{s}.unreadable-{d}", .{
        path,
        stamp.toSeconds(),
    }) catch return;
    defer alloc.free(aside);

    const cwd = std.Io.Dir.cwd();
    cwd.rename(path, cwd, aside, io) catch |err| {
        log.warn("could not move unreadable model file {s} aside: {t}", .{ path, err });
        return;
    };
    log.warn("model file {s} was unreadable, kept at {s}, starting empty", .{ path, aside });
}

const testing = std.testing;

/// A model with a fixed run id, so a test's expectations can name it.
fn testModel() Model {
    return .init(testing.allocator, "0123456789abcdef0123456789abcdef".*);
}

test "a Space, a tab and a pane show up in the snapshot in order" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.createTab("space-a", "tab-2", "build");
    try model.movePane("surface:p1", "tab-1", 0);

    const snapshot = try model.renderSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snapshot, .{});
    defer parsed.deinit();
    const spaces = parsed.value.object.get("spaces").?.array;
    try testing.expectEqual(@as(usize, 1), spaces.items.len);

    const tabs = spaces.items[0].object.get("tabs").?.array;
    try testing.expectEqual(@as(usize, 2), tabs.items.len);
    try testing.expectEqualStrings("tab-1", tabs.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("build", tabs.items[1].object.get("name").?.string);

    const panes = tabs.items[0].object.get("panes").?.array;
    try testing.expectEqual(@as(usize, 1), panes.items.len);
    try testing.expectEqualStrings("surface:p1", panes.items[0].object.get("id").?.string);
}

test "an agent's status rides the snapshot and never asks for a write" {
    var model = testModel();
    defer model.deinit();
    try model.createSpace("s", "");
    try model.createTab("s", "t", "");
    try model.movePane("p", "t", 0);

    const file_before = model.file_revision;
    const revision_before = model.revision;
    model.setAgentFacts(model.findPane("p").?, .{
        .agent = "claude",
        .state = "idle",
        .attention = "done",
        .seen = false,
        .state_seq = 4,
        .recency = 5,
    });
    try testing.expect(model.revision > revision_before);
    try testing.expectEqual(file_before, model.file_revision);

    const snapshot = try model.renderSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"attention\":\"done\"") != null);

    const file = try model.renderFile(testing.allocator);
    defer testing.allocator.free(file);
    try testing.expect(std.mem.indexOf(u8, file, "attention") == null);
}

test "the snapshot carries the run id and a revision that only ever goes up" {
    var model = testModel();
    defer model.deinit();

    try testing.expectEqual(@as(u64, 0), model.revision);
    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.renameSpace("space-a", "work");
    try testing.expectEqual(@as(u64, 3), model.revision);

    const snapshot = try model.renderSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snapshot, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings(&model.run_id, parsed.value.object.get("run_id").?.string);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("revision").?.integer);
}

test "a pane moved into another tab leaves the first one" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.createTab("space-a", "tab-2", "");
    try model.movePane("surface:p1", "tab-1", 0);
    try model.movePane("surface:p2", "tab-1", 1);
    try model.movePane("surface:p1", "tab-2", 0);

    const space = model.findSpace("space-a").?;
    try testing.expectEqual(@as(usize, 1), space.tabs.items[0].panes.items.len);
    try testing.expectEqualStrings("surface:p2", space.tabs.items[0].panes.items[0].id);
    try testing.expectEqualStrings("surface:p1", space.tabs.items[1].panes.items[0].id);
}

test "hiding a Space remembers the slot an unhide puts it back in" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("a", "");
    try model.createSpace("b", "");
    try model.createSpace("c", "");
    try model.hideSpace("b");

    // Hidden Spaces don't count towards the visible order, so what was
    // third is now second while `b` is away.
    try testing.expect(model.spaces.items[1].hidden);
    try testing.expectEqual(@as(usize, 1), model.spaces.items[1].restore_index);

    try model.moveSpace("c", 0);
    try model.showSpace("b");

    const order = [_][]const u8{ "c", "b", "a" };
    for (order, 0..) |id, i| try testing.expectEqualStrings(id, model.spaces.items[i].id);
    try testing.expect(!model.findSpace("b").?.hidden);
}

test "moving a Space past the end lands it last" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("a", "");
    try model.createSpace("b", "");
    try model.moveSpace("a", 99);

    try testing.expectEqualStrings("b", model.spaces.items[0].id);
    try testing.expectEqualStrings("a", model.spaces.items[1].id);
}

test "closing a Space takes its tabs and pane membership with it" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.movePane("surface:p1", "tab-1", 0);
    try model.closeSpace("space-a");

    try testing.expectEqual(@as(usize, 0), model.spaces.items.len);
    try testing.expect(model.findPane("surface:p1") == null);
}

test "operations on ids nobody knows are refused, not invented" {
    var model = testModel();
    defer model.deinit();

    try testing.expectError(error.NoSuchSpace, model.closeSpace("nope"));
    try testing.expectError(error.NoSuchTab, model.renameTab("nope", "x"));
    try testing.expectError(error.NoSuchTab, model.movePane("surface:p1", "nope", 0));
    try testing.expect(!model.removePane("surface:p1"));

    try model.createSpace("space-a", "");
    try testing.expectError(error.DuplicateId, model.createSpace("space-a", ""));
}

test "a Space's default name comes from its starter pane's directory, then stops moving" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.movePane("surface:p1", "tab-1", 0);
    try model.deriveDefaultNames("/Users/someone");

    // No directory yet, so nothing to derive from.
    try testing.expectEqualStrings("", model.findSpace("space-a").?.default_name);

    try model.setDirectory(model.findPane("surface:p1").?, "/Users/someone/dev/work");
    try model.deriveDefaultNames("/Users/someone");
    try testing.expectEqualStrings("work", model.findSpace("space-a").?.default_name);

    // A later cd must not rename the Space underneath the user.
    try model.setDirectory(model.findPane("surface:p1").?, "/Users/someone/dev/other");
    try model.deriveDefaultNames("/Users/someone");
    try testing.expectEqualStrings("work", model.findSpace("space-a").?.default_name);
}

test "defaultSpaceName names the home directory itself ~" {
    try testing.expectEqualStrings("~", defaultSpaceName("/Users/someone", "/Users/someone"));
    try testing.expectEqualStrings("~", defaultSpaceName("/Users/someone/", "/Users/someone"));
    try testing.expectEqualStrings("work", defaultSpaceName("/Users/someone/work/", ""));
    try testing.expectEqualStrings("/", defaultSpaceName("/", "/Users/someone"));
}

test "a pane's title owes clients a revision but owes the file nothing" {
    var model = testModel();
    defer model.deinit();

    try model.createSpace("space-a", "");
    try model.createTab("space-a", "tab-1", "");
    try model.movePane("surface:p1", "tab-1", 0);

    const revision = model.revision;
    const file_revision = model.file_revision;

    // A title is in the snapshot clients cache, so it moves `revision`;
    // it is not in the file, so it must not move `file_revision` - an
    // agent redrawing its spinner would otherwise rewrite the model file
    // continuously.
    try model.setTitle(model.findPane("surface:p1").?, "zsh");
    try testing.expectEqual(revision + 1, model.revision);
    try testing.expectEqual(file_revision, model.file_revision);

    // A directory is in both, so it moves both.
    try model.setDirectory(model.findPane("surface:p1").?, "/tmp");
    try testing.expectEqual(revision + 2, model.revision);
    try testing.expectEqual(file_revision + 1, model.file_revision);

    // Setting either to the value it already has is not a change.
    try model.setTitle(model.findPane("surface:p1").?, "zsh");
    try model.setDirectory(model.findPane("surface:p1").?, "/tmp");
    try testing.expectEqual(revision + 2, model.revision);
    try testing.expectEqual(file_revision + 1, model.file_revision);
}

/// A unique path under /tmp for a test that writes a real model file.
fn uniqueModelPath(tag: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    testing.io.random(&rand_bytes);
    return std.fmt.allocPrint(testing.allocator, "/tmp/coastty-model-test-{s}-{s}/model.json", .{
        tag,
        std.fmt.bytesToHex(rand_bytes, .lower),
    });
}

fn removeModelDir(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().deleteTree(testing.io, parent) catch {};
}

test "a saved model reads back with its structure intact" {
    const path = try uniqueModelPath("roundtrip");
    defer testing.allocator.free(path);
    defer removeModelDir(path);

    {
        var model = testModel();
        defer model.deinit();
        try model.createSpace("space-a", "work");
        try model.createTab("space-a", "tab-1", "build");
        try model.movePane("surface:p1", "tab-1", 0);
        try model.setDirectory(model.findPane("surface:p1").?, "/Users/someone/dev");
        try model.setTitle(model.findPane("surface:p1").?, "vim");
        try model.createSpace("space-b", "");
        try model.hideSpace("space-b");
        try model.save(testing.io, path);
    }

    var restored = testModel();
    defer restored.deinit();
    try restored.load(testing.io, path);

    try testing.expectEqual(@as(usize, 2), restored.spaces.items.len);
    const space = restored.findSpace("space-a").?;
    try testing.expectEqualStrings("work", space.name);
    try testing.expectEqualStrings("build", space.tabs.items[0].name);
    try testing.expectEqualStrings("/Users/someone/dev", space.tabs.items[0].panes.items[0].directory);
    try testing.expect(restored.findSpace("space-b").?.hidden);

    // A title belongs to a process that is gone; the structure comes
    // back, the running state does not.
    try testing.expectEqualStrings("", space.tabs.items[0].panes.items[0].title);
    try testing.expectEqual(@as(u64, 0), restored.revision);
}

test "a missing model file is a first run, not a failure" {
    const path = try uniqueModelPath("missing");
    defer testing.allocator.free(path);

    var model = testModel();
    defer model.deinit();
    try model.load(testing.io, path);
    try testing.expectEqual(@as(usize, 0), model.spaces.items.len);
}

test "a file from an older version loads, defaulting what it never had" {
    const path = try uniqueModelPath("older");
    defer testing.allocator.free(path);
    defer removeModelDir(path);

    const older =
        \\{"version":0,"spaces":[{"id":"space-a","tabs":[{"id":"tab-1","panes":[{"id":"surface:p1"}]}]}]}
    ;
    try writeTestFile(path, older);

    var model = testModel();
    defer model.deinit();
    try model.load(testing.io, path);

    const space = model.findSpace("space-a").?;
    try testing.expectEqualStrings("", space.name);
    try testing.expectEqualStrings("", space.default_name);
    try testing.expect(!space.hidden);
    try testing.expectEqualStrings("surface:p1", space.tabs.items[0].panes.items[0].id);

    // The next write brings it forward to this build's version.
    try model.save(testing.io, path);
    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"version\":1") != null);
}

test "an unreadable model file is kept, not overwritten, and startup goes on" {
    const path = try uniqueModelPath("corrupt");
    defer testing.allocator.free(path);
    defer removeModelDir(path);

    try writeTestFile(path, "{not json at all");

    var model = testModel();
    defer model.deinit();
    try testing.expect(isError(model.load(testing.io, path)));
    try testing.expectEqual(@as(usize, 0), model.spaces.items.len);

    // The original bytes still exist somewhere in the model's own
    // directory, and the path itself is free for a fresh write.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, path, .{}));
    try testing.expect(try keptAsideCount(path) > 0);
}

test "a file from a newer version is kept unread rather than guessed at" {
    const path = try uniqueModelPath("newer");
    defer testing.allocator.free(path);
    defer removeModelDir(path);

    try writeTestFile(path, "{\"version\":99,\"spaces\":[]}");

    var model = testModel();
    defer model.deinit();
    try testing.expectError(error.ModelFileTooNew, model.load(testing.io, path));
    try testing.expect(try keptAsideCount(path) > 0);
}

/// Whether a fallible call failed at all, when which failure it was is
/// std.json's business rather than this model's.
fn isError(result: anytype) bool {
    if (result) |_| return false else |_| return true;
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    const parent = std.fs.path.dirname(path).?;
    try std.Io.Dir.cwd().createDirPath(testing.io, parent);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, parent, .{});
    defer dir.close(testing.io);
    var file = try dir.createFile(testing.io, std.fs.path.basename(path), .{});
    defer file.close(testing.io);
    var buf: [512]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(content);
    try writer.flush();
}

/// How many `.unreadable-*` siblings the model file's directory holds.
fn keptAsideCount(path: []const u8) !usize {
    const parent = std.fs.path.dirname(path).?;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, parent, .{ .iterate = true });
    defer dir.close(testing.io);

    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, basename)) continue;
        if (std.mem.startsWith(u8, entry.name, basename)) count += 1;
    }
    return count;
}
