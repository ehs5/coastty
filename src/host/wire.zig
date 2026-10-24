//! The host's control protocol: plain text, one connection per request
//! except `attach`, which turns the connection into a long-lived,
//! bidirectional pane stream.
//!
//! Every message is a single header line (space-separated tokens,
//! newline-terminated) optionally followed by a raw byte body whose exact
//! length the header names. Bodies are raw bytes rather than an escaped
//! text encoding (JSON, base64, ...) on purpose: pty output is arbitrary
//! binary data and a pane's cwd/argv can contain any byte a filesystem
//! allows, so length-prefixing sidesteps escaping entirely.
//!
//! The app's token: a request that reads or types into a pane, starts one
//! or ends one - `CREATE`, `ATTACH`, `KILL` and `SWEEP` - and a `SUBSCRIBE`
//! as `app` end their header line with one more argument, the token the
//! daemon wrote to `<socket path>.token` on start (64 hex characters,
//! owner-only, new every run; see `access.zig`). Without it, or with a
//! wrong one, the answer is `ERR unauthorized` and the connection closes.
//! The forms below leave it out. Everything else, the layout requests
//! included, needs no token, so anything running as the user can see and
//! arrange the layout but cannot reach inside a pane.
//!
//! Control requests (one per connection, connection closes after the
//! response):
//!   CREATE <cols> <rows> <body-len> [<env-len>]\n
//!     <id>\0<cwd>\0<argv0>\0<argv1>\0...<env-len bytes: KEY=VAL\0KEY=VAL\0...>
//!     -> OK <id> <reused|new|ended>\n
//!      | ERR <reason>\n
//!     The id is generated unless the body's id was non-empty and already
//!     live, in which case that pane is `reused` and resized to
//!     <cols>/<rows> before responding. `ended` means the id did name a
//!     pane but its process had already exited, so the daemon discarded
//!     the corpse and spawned a fresh pane under that id - the caller
//!     asked to come back to a session that is gone, which it can then
//!     say so about rather than silently present the new shell as it.
//!     <env-len> is optional and defaults to 0 (no env section) - the CLI
//!     debug client omits it, relying on the daemon's own inherited
//!     environment instead; a real GUI-created pane always sends its
//!     resolved shell env so a host-attached pane's shell is
//!     indistinguishable from a local one.
//!   LIST\n
//!     -> OK <count>\n
//!        <id> <cols> <rows> <alive:0|1>\n   (repeated count times)
//!   KILL <id> [<id> ...]\n
//!     -> OK <killed-count>\n
//!     Ends each named pane's process (SIGTERM to its process group, then
//!     SIGKILL if it doesn't exit) and forgets it. Ids nobody knows about
//!     are skipped rather than erroring, so a client closing several panes
//!     at once needs one request, not one per pane.
//!   SWEEP <id> <id> ...\n
//!     -> OK <killed-count>\n
//!     The inverse: the client names every pane it still wants, and the
//!     daemon kills everything else in its registry. The set difference is
//!     computed here rather than by the client fetching `LIST` and diffing
//!     it locally. An empty id list means "keep nothing".
//!   VERSION\n
//!     -> OK <protocol-version> <daemon-version>\n
//!     The two numbers that decide what the app does with a daemon it
//!     finds running (see `upgrade.zig`). Needs no token. A daemon from
//!     before this request answers `ERR unknown command`.
//!
//! The model (see `Model.zig`): the Spaces, tabs and pane membership the
//! daemon owns, which every client reads from and writes to the same way.
//!   MODEL\n
//!     -> OK <len>\n<len bytes: the whole model as one JSON document>
//!     One request, one document: a client renders everything it shows
//!     from this without stitching calls together. It carries `run_id`
//!     (this run of the daemon) and `revision` (bumped on every change),
//!     which together tell a client whether its cached copy is stale.
//!   SPACE <op> <body-len>\n<field>\0<field>...
//!   TAB <op> <body-len>\n<field>\0<field>...
//!   PANE <op> <body-len>\n<field>\0<field>...
//!     -> OK <revision>\n
//!      | ERR <reason>\n
//!     One structural change each. The ops and their fields:
//!       SPACE new    <space-id>\0<name>      (appended last; name may be empty)
//!       SPACE close  <space-id>
//!       SPACE rename <space-id>\0<name>      (empty name clears it)
//!       SPACE move   <space-id>\0<index>     (position among visible Spaces)
//!       SPACE hide   <space-id>
//!       SPACE show   <space-id>
//!       TAB   new    <space-id>\0<tab-id>\0<name>
//!       TAB   close  <tab-id>
//!       TAB   rename <tab-id>\0<name>
//!       TAB   move   <tab-id>\0<index>       (within its own Space)
//!       PANE  move   <pane-id>\0<tab-id>\0<index>
//!     Ids and names can hold any byte a user or a filesystem allows, so
//!     they travel as body fields rather than header tokens; an index
//!     rides along with them to keep each op's arguments in one list.
//!     These are structural only - they never start or end a process.
//!     A pane the model has stopped holding keeps running until `KILL`.
//!
//! Requests: a change asked of the app rather than reported by it - what a
//! layout command sends. The daemon resolves and validates it against the
//! model, generates the ids of anything new, and hands it to the app as a
//! `request` event. The app carries it out the way it would for the user
//! and reports the result like any change of its own.
//!   REQUEST <SPACE|TAB|PANE> <op> <body-len>\n<target>\0<near>\0<arg>...
//!     -> OK [<id> ...]\n
//!      | ERR <reason>\n
//!     <near> is the pane the request comes from, empty if none. An empty
//!     <target> means the one holding <near>. With both empty, TAB new
//!     joins the focused Space and PANE split splits the focused pane
//!     (refused with `ERR nothing focused` when nothing is); every other
//!     op needs one of the two. The ops and their args:
//!       SPACE new    name\0directory\0focus[\0window] -> OK <space-id> <tab-id>
//!                    (target: unused. The Space opens with one starter
//!                    tab in the window named, else the window holding
//!                    <near>'s Space, else the frontmost window; focus is
//!                    0 or 1. A window the app hasn't reported is refused
//!                    with `ERR no such window`)
//!       SPACE close  force\0job               -> OK <space-id> [<ended>]
//!                    (as TAB close, over every pane in the Space)
//!       SPACE rename name                     -> OK <space-id>
//!                    (an empty name clears it)
//!       SPACE move   index                    -> OK <space-id>
//!                    (0-based among visible Spaces; refused with
//!                    `ERR no such position` past the last one, and with
//!                    `ERR space is hidden` for a hidden Space)
//!       SPACE move   index\0window            -> OK <space-id> <index>
//!                    (to the window named, 0-based among its visible
//!                    Spaces, or after the last of them with index empty;
//!                    answered with where it lands. Refused as above, and
//!                    with `ERR no such window` for a window the app
//!                    hasn't reported)
//!       SPACE focus                           -> OK <space-id>
//!                    (shows the Space in its window and brings that
//!                    window to the front)
//!       TAB new    name\0directory\0focus   -> OK <tab-id>
//!                  (target: the Space the tab joins, at its end; focus
//!                  is 0 or 1)
//!       TAB close  force\0job               -> OK <tab-id> [<ended>]
//!                  (force is 0 or 1. Without it a close is refused with
//!                  `ERR running <what>` while any pane in the tab runs
//!                  something other than a shell at its prompt; with it,
//!                  <ended> names what ran, comma-separated, to the end
//!                  of the line. job is the process group the requesting
//!                  command leads, or empty; a pane whose foreground job
//!                  it is counts as running nothing)
//!       TAB rename name                     -> OK <tab-id>
//!                  (an empty name clears it)
//!       TAB move   index                    -> OK <tab-id>
//!                  (0-based within the tab's own Space; refused with
//!                  `ERR no such position` past its last tab)
//!       TAB focus                           -> OK <tab-id>
//!                  (shows the tab's Space, selects the tab and brings
//!                  its window to the front)
//!       PANE split direction\0directory\0focus -> OK <pane-id>
//!                  (direction is right or down; the new pane opens beside
//!                  the target in its tab, focus is 0 or 1)
//!       PANE close force\0job               -> OK <pane-id> [<ended>]
//!                  (as TAB close, over the one pane; closing a tab's last
//!                  pane asks the app to close the tab instead)
//!       PANE focus                          -> OK <pane-id>
//!                  (as TAB focus for the pane's tab, then moves keyboard
//!                  focus to the pane)
//!     Refused with `ERR app not running` when no app is subscribed to
//!     carry it out. The OK only means the app was asked: a client that
//!     needs the result waits for the model to show it, or after a focus
//!     op for the focus the app reports (see Focus) to show it.
//!
//! Focus: which Space, tab and pane the user was last in - the active Space,
//! tab and focused pane of the coastty window they used last, kept while
//! coastty is in the background. Presentation, not model: held in memory
//! only, never in model.json.
//!   FOCUSED\n
//!     -> OK <len>\n<space-id>\0<tab-id>\0<pane-id>
//!        (len 0 when nothing is focused: every coastty window is closed,
//!        or no app is connected)
//!   The app reports focus on its own SUBSCRIBE connection (see Events),
//!   so it is gone the moment the app disconnects.
//!
//! Windows: the app's windows and the Spaces each shows. The daemon owns
//! nothing about windows; it holds what the app reports, in memory only,
//! never in model.json.
//!   WINDOWS\n
//!     -> OK <len>\n<window>\n<window>...
//!        each <window> being <window-id>\0<active-space-id>\0<space-id>...
//!        with its Spaces in the window's order, hidden ones included
//!        (len 0 when no window is open, or no app is connected)
//!   The app reports windows on its own SUBSCRIBE connection (see Events),
//!   so they are gone the moment the app disconnects.
//!
//! Attach (the connection stays open as a duplex pane stream):
//!   ATTACH <id>\n
//!     -> OK\n
//!        META <pgid> <child_pid>\n    (0 stands in for "unknown")
//!        SNAPSHOT <len>\n<len bytes: current screen, real VT - cursor
//!                                     position/styles/modes included,
//!                                     see Pane.zig's own snapshot()>
//!        STATUS <len>\n<len bytes: JSON - agent, state, attention,
//!                                   seen, state_seq, recency>
//!        DATA <len>\n<len bytes>        (repeated, as pty output arrives)
//!        STATUS <len>\n<len bytes>      (repeated, whenever the pane's
//!                                        attention state changes)
//!        SNAPSHOT <len>\n<len bytes>    (repeated, after each RESIZE,
//!                                        rebuilt for the new size)
//!        META <pgid> <child_pid>\n      (repeated, whenever the pane's
//!                                        foreground process group changes -
//!                                        this is what lets a GUI client
//!                                        run its own agent-detection
//!                                        against a pane it doesn't own a
//!                                        local pty for)
//!      | ERR <reason>\n
//!   Meanwhile the client may send, in any order:
//!     INPUT <len>\n<len bytes>          (written to the pane's pty)
//!     RESIZE <cols> <rows>\n
//!     VIEW <0|1>\n                      (whether the user is looking at
//!                                        the pane; 1 marks it seen, and a
//!                                        finish while any client is
//!                                        looking counts as seen)
//!     SEEN <state_seq>\n                (acknowledges the state a client
//!                                        rendered, named by its state_seq,
//!                                        and no newer one)
//!
//! Events (the connection stays open; the daemon pushes what changed):
//!   SUBSCRIBE <version> <kind> [capability ...]\n
//!     <kind> is `app` (the Mac app, which must speak exactly the daemon's
//!     protocol_version) or `client` (anything else, which may speak any
//!     version from protocol_floor up and is answered in the newest both
//!     know). Capabilities name optional features the client wants; the
//!     answer lists the ones this daemon has. One that is missing disables
//!     that feature alone, never the connection.
//!     -> OK <version> <run_id> <revision> <capability,...>\n
//!        EVENT <len>\n<len bytes: one JSON object>   (repeated)
//!      | ERR <reason>\n                              (and the daemon closes)
//!   Events, by their "event" field:
//!     pane_created, pane_exited, pane_killed     {"pane"}
//!     model_changed                              {"revision"}
//!     attention_changed                          {"pane", and every STATUS
//!                                                 field: agent, state,
//!                                                 attention, seen,
//!                                                 state_seq, recency}
//!     attached, detached                         {"pane", "clients"}
//!     request                                    {"scope", "op", and the
//!                                                 op's own fields}
//!                                                 - sent to the app only,
//!                                                 see REQUEST
//!     resync                                     {} - the client fell too
//!                                                far behind and lost events;
//!                                                it fetches the model again
//!   The app, and only the app, may send on this connection:
//!     FOCUS <len>\n<space-id>\0<tab-id>\0<pane-id>
//!       whenever what it shows the user changes, and once on subscribing.
//!       An empty body, or any of the three empty, means nothing is
//!       focused. A client other than the app is ignored.
//!     WINDOWS <len>\n<window>\n<window>...
//!       every open window, as `WINDOWS` answers them, whenever a window
//!       opens or closes or the Spaces it shows change, and once on
//!       subscribing. Each report replaces the last.
//!   Catching up without losing anything, in this order:
//!     1. SUBSCRIBE. From the answer on, every change is an event.
//!     2. MODEL. Note its revision R.
//!     3. Apply events: skip model_changed with revision <= R, which the
//!        fetched copy already holds; apply attention_changed only when its
//!        recency is newer than the pane's in the copy. Pane and attachment
//!        events are facts and can be applied as they come.
//!   A run_id other than the one a client last saw means the daemon
//!   restarted, and everything it cached is stale.
const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;

pub const max_header_len = 4096;

/// The event protocol this build speaks. The Mac app ships with the daemon and must speak exactly this.
/// Bump it only when the app and the daemon can no longer talk: an app that finds a daemon speaking another one has to restart it, ending every pane's process.
pub const protocol_version: u32 = 2;

/// The daemon's own version, which `VERSION` answers with. Bumped when the daemon's code changes in a way users should get; an app that finds another one running restarts it, ending every pane's process.
/// The app's own version never enters into it, so an app-only release leaves running panes alone.
pub const daemon_version: u32 = 1;

/// The oldest protocol an outside client may speak. It does not move, so a
/// client written against it keeps working against every later daemon.
pub const protocol_floor: u32 = 1;

/// Optional features, by name. A client checks the list a `SUBSCRIBE` is
/// answered with before using one; a feature missing from it disables that
/// one action, never the connection.
pub const capabilities = [_][]const u8{ "attention", "seen", "hide", "attachments" };

pub fn hasCapability(name: []const u8) bool {
    for (capabilities) |cap| {
        if (std.mem.eql(u8, cap, name)) return true;
    }
    return false;
}

/// The capabilities a `SUBSCRIBE` asked for that this daemon has, comma
/// separated - or every one there is, when it asked for none in particular.
pub fn writeCapabilities(writer: *Io.Writer, wanted: *std.mem.TokenIterator(u8, .scalar)) !void {
    var asked = false;
    var written: usize = 0;
    while (wanted.next()) |name| {
        asked = true;
        if (!hasCapability(name)) continue;
        if (written > 0) try writer.writeAll(",");
        try writer.writeAll(name);
        written += 1;
    }
    if (asked) return;
    for (capabilities, 0..) |cap, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll(cap);
    }
}

/// Who is subscribing, which decides how strictly versions have to agree.
pub const ClientKind = enum {
    /// The Mac app, built together with the daemon.
    app,
    /// Anything else: a script, a CLI, a phone app later.
    client,

    pub fn parse(name: []const u8) ?ClientKind {
        return std.meta.stringToEnum(ClientKind, name);
    }
};

pub const Negotiation = union(enum) {
    /// The version both ends will speak.
    speaks: u32,
    /// Why the connection is refused, written into the caller's buffer.
    refused: []const u8,
};

/// Settles which protocol version a subscriber gets. The app must match
/// exactly - a mismatch means a stale daemon or a stale app, and the
/// connection says which. An outside client may speak anything from the
/// floor up, and is answered in the newest version both ends know.
pub fn negotiate(kind: ClientKind, version: u32, reason_buf: []u8) Negotiation {
    switch (kind) {
        .app => if (version != protocol_version) return .{ .refused = std.fmt.bufPrint(
            reason_buf,
            "version mismatch: the app speaks protocol {d}, this daemon speaks {d} - restart one so both are the same build",
            .{ version, protocol_version },
        ) catch "version mismatch" },
        .client => if (version < protocol_floor) return .{ .refused = std.fmt.bufPrint(
            reason_buf,
            "protocol {d} is older than this daemon supports; it speaks {d} through {d}",
            .{ version, protocol_floor, protocol_version },
        ) catch "protocol too old" },
    }
    return .{ .speaks = @min(version, protocol_version) };
}

/// Read one newline-terminated header line and return it with the
/// allocator's own copy of the bytes (the reader's internal buffer is
/// reused on the next read, so the raw slice it hands back doesn't
/// outlive that next call).
///
/// `takeDelimiterExclusive` only tosses the bytes it returns, never the
/// delimiter itself - using it here left every subsequent read starting
/// one byte early, on the header's own trailing newline, which then
/// silently dropped the true last byte of whatever followed (the body,
/// for a request with one). `takeDelimiter` advances past the delimiter
/// too, which is what a line reader actually needs.
pub fn readHeader(alloc: Allocator, reader: *Io.Reader) !?[]u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    return try alloc.dupe(u8, line);
}

/// Read exactly `len` raw body bytes following a header.
pub fn readBody(alloc: Allocator, reader: *Io.Reader, len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try reader.readSliceAll(buf);
    return buf;
}

/// What a `CREATE` did with the id it was given - the third token of its
/// `OK` response, described in full at the top of this file. Defined here
/// rather than on either side so the daemon and its clients can't drift
/// apart on the vocabulary.
pub const CreateOutcome = enum {
    reused,
    new,
    ended,

    pub fn token(self: CreateOutcome) []const u8 {
        return @tagName(self);
    }
};

/// Pulls the outcome out of a `CREATE` response's `<id> <outcome>` tail.
/// The id itself is already known to the caller (it sent it, or the
/// daemon generated it from the same request), so only the token matters.
/// Null means no outcome was reported, or one this build doesn't know.
pub fn parseCreateOutcome(tail: []const u8) ?CreateOutcome {
    var it = std.mem.tokenizeScalar(u8, tail, ' ');
    _ = it.next();
    const tok = it.next() orelse return null;
    return std.meta.stringToEnum(CreateOutcome, tok);
}

/// The structural changes the model accepts, grouped by what each acts
/// on. Defined here rather than on either side, like `CreateOutcome`, so
/// the daemon and its clients can't drift apart on the vocabulary.
pub const SpaceOp = enum { new, close, rename, move, hide, show };

pub const TabOp = enum { new, close, rename, move };

pub const PaneOp = enum { move };

/// What a `REQUEST` may ask of the app for a Space.
pub const SpaceRequestOp = enum { new, close, rename, move, focus };

/// What a `REQUEST` may ask of the app for a tab.
pub const TabRequestOp = enum { new, close, rename, move, focus };

/// What a `REQUEST` may ask of the app for a pane.
pub const PaneRequestOp = enum { split, close, focus };

/// Where a `REQUEST PANE split` opens the new pane, beside the one it splits.
pub const SplitDirection = enum { right, down };

/// Names the pane a process runs in, so a layout command run inside it can act on its own pane, tab or Space without being told which.
pub const pane_id_env = "COASTTY_PANE_ID";

/// What a model operation acts on, named by the verb that carried it.
pub const Scope = enum {
    space,
    tab,
    pane,

    /// The scope a header token names: `SPACE`, `TAB` or `PANE`.
    pub fn parseVerb(verb: []const u8) ?Scope {
        if (std.mem.eql(u8, verb, "SPACE")) return .space;
        if (std.mem.eql(u8, verb, "TAB")) return .tab;
        if (std.mem.eql(u8, verb, "PANE")) return .pane;
        return null;
    }
};

/// Write a header line, e.g. `writeHeaderLine(w, "OK {s}", .{id})`.
pub fn writeHeaderLine(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt ++ "\n", args);
    try writer.flush();
}

/// Write a `<verb> <id> <id> ... <token>` header line for the id-list
/// commands (`KILL`, `SWEEP`). An empty `ids` sends only the verb and the
/// token, which for `SWEEP` means "keep nothing". `token_arg` is the token
/// with its leading space, or empty for a daemon that asks for none.
pub fn writeIdCommandLine(writer: *Io.Writer, verb: []const u8, ids: []const []const u8, token_arg: []const u8) !void {
    try writer.writeAll(verb);
    for (ids) |id| {
        try writer.writeByte(' ');
        try writer.writeAll(id);
    }
    try writer.writeAll(token_arg);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Write a `<tag> <len>\n` header immediately followed by `data` and flush.
pub fn writeFrame(writer: *Io.Writer, tag: []const u8, data: []const u8) !void {
    try writer.print("{s} {d}\n", .{ tag, data.len });
    try writer.writeAll(data);
    try writer.flush();
}

/// Write one model operation: a `<verb> <op> <body-len>` header followed
/// by the op's fields, NUL-separated. The write side of `FieldIterator`,
/// kept beside it so both halves of the encoding live in one file.
pub fn writeModelOp(
    writer: *Io.Writer,
    verb: []const u8,
    op: []const u8,
    fields: []const []const u8,
) !void {
    try writer.print("{s} {s} {d}\n", .{ verb, op, fieldsLen(fields) });
    try writeFieldBody(writer, fields);
}

/// Write a `<tag> <body-len>` header followed by `fields`, NUL-separated: a `FOCUS` report or a `FOCUSED` answer.
pub fn writeFields(writer: *Io.Writer, tag: []const u8, fields: []const []const u8) !void {
    try writer.print("{s} {d}\n", .{ tag, fieldsLen(fields) });
    try writeFieldBody(writer, fields);
}

/// How long `fields` are as one NUL-separated body.
fn fieldsLen(fields: []const []const u8) usize {
    // One NUL between fields, so n fields carry n - 1 separators.
    var body_len: usize = fields.len -| 1;
    for (fields) |field| body_len += field.len;
    return body_len;
}

/// Writes `fields` NUL-separated and flushes.
fn writeFieldBody(writer: *Io.Writer, fields: []const []const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try writer.writeByte(0);
        try writer.writeAll(field);
    }
    try writer.flush();
}

/// Write one `REQUEST <scope> <op> <body-len>` header and its fields, as a layout command asks the app for a change.
pub fn writeRequest(writer: *Io.Writer, scope: Scope, op: []const u8, fields: []const []const u8) !void {
    const verb = switch (scope) {
        .space => "REQUEST SPACE",
        .tab => "REQUEST TAB",
        .pane => "REQUEST PANE",
    };
    try writeModelOp(writer, verb, op, fields);
}

/// Splits a NUL-separated body into its fields. Does not allocate; fields
/// borrow from `body`.
pub const FieldIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(body: []const u8) FieldIterator {
        return .{ .it = std.mem.splitScalar(u8, body, 0) };
    }

    pub fn next(self: *FieldIterator) ?[]const u8 {
        return self.it.next();
    }
};

/// One window in a `WINDOWS` body, borrowing from it: its id, its active Space and the Spaces it shows.
pub const ShownWindow = struct {
    id: []const u8,
    /// Empty when the window has no Space showing.
    active: []const u8,
    /// The Space ids it shows, in order, NUL-separated; empty for none.
    spaces: []const u8,

    /// Walks the ids of the Spaces this window shows, in order.
    pub fn spaceIds(self: ShownWindow) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.spaces, 0);
    }

    /// Whether this window shows the Space with this id.
    pub fn shows(self: ShownWindow, space_id: []const u8) bool {
        var ids = self.spaceIds();
        while (ids.next()) |id| {
            if (std.mem.eql(u8, id, space_id)) return true;
        }
        return false;
    }
};

/// Splits a `WINDOWS` body - one `<window-id>\0<active-space-id>\0<space-id>...` line per window - into its windows. Does not allocate.
pub const WindowIterator = struct {
    lines: std.mem.TokenIterator(u8, .scalar),

    pub fn init(body: []const u8) WindowIterator {
        return .{ .lines = std.mem.tokenizeScalar(u8, body, '\n') };
    }

    pub fn next(self: *WindowIterator) ?ShownWindow {
        while (self.lines.next()) |line| {
            var fields: FieldIterator = .init(line);
            const id = fields.next() orelse continue;
            // A line without an id names no window anything could target.
            if (id.len == 0) continue;
            const active = fields.next() orelse "";
            return .{ .id = id, .active = active, .spaces = fields.it.rest() };
        }
        return null;
    }

    /// The window showing the Space with this id, or null when none does.
    pub fn holding(body: []const u8, space_id: []const u8) ?ShownWindow {
        var windows: WindowIterator = .init(body);
        while (windows.next()) |window| {
            if (window.shows(space_id)) return window;
        }
        return null;
    }

    /// The window with this id, or null when there is none.
    pub fn find(body: []const u8, window_id: []const u8) ?ShownWindow {
        var windows: WindowIterator = .init(body);
        while (windows.next()) |window| {
            if (std.mem.eql(u8, window.id, window_id)) return window;
        }
        return null;
    }
};

/// Splits a NUL-separated `KEY=VALUE\0KEY=VALUE\0...` env body (see
/// CREATE's own format above) into an `Environ.Map`. A field with no `=`
/// is skipped rather than erroring - this is best-effort process
/// environment, not something worth failing pane creation over.
pub fn parseEnvBody(alloc: Allocator, body: []const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(alloc);
    errdefer map.deinit();
    var fields: FieldIterator = .init(body);
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        try map.put(field[0..eq], field[eq + 1 ..]);
    }
    return map;
}

test "parseEnvBody splits KEY=VALUE pairs and skips malformed ones" {
    var map = try parseEnvBody(std.testing.allocator, "A=1\x00B=two\x00malformed\x00C=");
    defer map.deinit();
    try std.testing.expectEqualStrings("1", map.get("A").?);
    try std.testing.expectEqualStrings("two", map.get("B").?);
    try std.testing.expectEqualStrings("", map.get("C").?);
    try std.testing.expectEqual(@as(usize, 3), map.count());
}

test "parseCreateOutcome reads the token after the id" {
    try std.testing.expectEqual(CreateOutcome.reused, parseCreateOutcome("abc reused").?);
    try std.testing.expectEqual(CreateOutcome.ended, parseCreateOutcome("abc ended").?);
    try std.testing.expect(parseCreateOutcome("abc") == null);
    try std.testing.expect(parseCreateOutcome("abc sideways") == null);
}

test "writeModelOp joins its fields with NUL and counts them in the header" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeModelOp(&out.writer, "TAB", "new", &.{ "space-a", "tab-1", "" });
    try std.testing.expectEqualStrings("TAB new 14\nspace-a\x00tab-1\x00", out.written());
}

test "writeRequest names its scope after the REQUEST verb" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .tab, "new", &.{ "space-a", "", "build" });
    try std.testing.expectEqualStrings("REQUEST TAB new 14\nspace-a\x00\x00build", out.written());
}

test "FieldIterator splits on NUL" {
    var it: FieldIterator = .init("one\x00two\x00three");
    try std.testing.expectEqualStrings("one", it.next().?);
    try std.testing.expectEqualStrings("two", it.next().?);
    try std.testing.expectEqualStrings("three", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "WindowIterator reads each window's id, active Space and Spaces in order" {
    const body = "win-1\x00space-b\x00space-a\x00space-b\nwin-2\x00\n\x00stray\n";
    var windows: WindowIterator = .init(body);

    const first = windows.next().?;
    try std.testing.expectEqualStrings("win-1", first.id);
    try std.testing.expectEqualStrings("space-b", first.active);
    var ids = first.spaceIds();
    try std.testing.expectEqualStrings("space-a", ids.next().?);
    try std.testing.expectEqualStrings("space-b", ids.next().?);
    try std.testing.expect(ids.next() == null);

    const second = windows.next().?;
    try std.testing.expectEqualStrings("win-2", second.id);
    try std.testing.expectEqualStrings("", second.active);
    var no_ids = second.spaceIds();
    try std.testing.expect(no_ids.next() == null);

    try std.testing.expect(windows.next() == null);

    try std.testing.expectEqualStrings("win-1", WindowIterator.holding(body, "space-a").?.id);
    try std.testing.expect(WindowIterator.holding(body, "space-z") == null);
    try std.testing.expectEqualStrings("win-2", WindowIterator.find(body, "win-2").?.id);
    try std.testing.expect(WindowIterator.find(body, "win-3") == null);
}
