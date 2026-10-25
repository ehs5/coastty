const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const global = @import("../global.zig");

const gtk_version = @import("../apprt/gtk/gtk_version.zig");
const adw_version = @import("../apprt/gtk/adw_version.zig");

pub const Options = struct {};

/// Writes coastty's version line, linked to its commit when one is given, then the Ghostty version it is built on.
fn printHeader(
    stdout: *std.Io.Writer,
    coastty_version: []const u8,
    ghostty_version: std.SemanticVersion,
    commit_hash: ?[]const u8,
) !void {
    if (commit_hash) |hash| try stdout.print(
        "\x1b]8;;https://github.com/ehs5/coastty/commit/{s}\x1b\\",
        .{hash},
    );
    try stdout.print("Coastty {s}", .{coastty_version});
    if (commit_hash != null) try stdout.print("\x1b]8;;\x1b\\", .{});
    try stdout.print("\n", .{});

    try stdout.print("Built on Ghostty {d}.{d}.{d}\n", .{
        ghostty_version.major,
        ghostty_version.minor,
        ghostty_version.patch,
    });
}

/// The `version` command is used to display information about Coastty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    var buffer: [1024]u8 = undefined;
    const stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &buffer);

    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const stdout = &stdout_writer.interface;
    const tty = try stdout_file.isTty(global.io());

    const commit_hash: ?[]const u8 = if (tty) build_config.version.build else null;
    try printHeader(stdout, build_config.coastty_version_string, build_config.version, commit_hash);
    try stdout.print("\n", .{});

    try stdout.print("Version\n", .{});
    try stdout.print("  - version: {s}\n", .{build_config.coastty_version_string});
    try stdout.print("  - ghostty: {s}\n", .{build_config.version_string});
    try stdout.print("  - channel: {t}\n", .{build_config.release_channel});

    try stdout.print("Build Config\n", .{});
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime   : {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine   : {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev        : {t}\n", .{xev.backend});
    if (comptime build_config.app_runtime == .gtk) {
        if (comptime builtin.os.tag == .linux) {
            const kernel_info = internal_os.getKernelInfo(alloc);
            defer if (kernel_info) |k| alloc.free(k);
            try stdout.print("  - kernel version: {s}\n", .{kernel_info orelse "Kernel information unavailable"});
        }
        try stdout.print("  - desktop env   : {t}\n", .{internal_os.desktopEnvironment(&environ_map)});
        try stdout.print("  - GTK version   :\n", .{});
        try stdout.print("    build         : {f}\n", .{gtk_version.comptime_version});
        try stdout.print("    runtime       : {f}\n", .{gtk_version.getRuntimeVersion()});
        try stdout.print("  - libadwaita    : enabled\n", .{});
        try stdout.print("    build         : {f}\n", .{adw_version.comptime_version});
        try stdout.print("    runtime       : {f}\n", .{adw_version.getRuntimeVersion()});
        if (comptime build_options.x11) {
            try stdout.print("  - libX11        : enabled\n", .{});
        } else {
            try stdout.print("  - libX11        : disabled\n", .{});
        }

        // We say `libwayland` since it is possible to build Ghostty without
        // Wayland integration but with Wayland-enabled GTK
        if (comptime build_options.wayland) {
            try stdout.print("  - libwayland    : enabled\n", .{});
        } else {
            try stdout.print("  - libwayland    : disabled\n", .{});
        }
    }

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}

test "printHeader: coastty's version first, then Ghostty's without its pre-release" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try printHeader(&writer, "0.1.0", try std.SemanticVersion.parse("1.3.2-main+abc1234"), null);
    try testing.expectEqualStrings("Coastty 0.1.0\nBuilt on Ghostty 1.3.2\n", writer.buffered());
}

test "printHeader: the commit link covers only coastty's version line" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try printHeader(&writer, "0.1.0-dev", try std.SemanticVersion.parse("1.3.2"), "abc1234");
    try testing.expectEqualStrings(
        "\x1b]8;;https://github.com/ehs5/coastty/commit/abc1234\x1b\\Coastty 0.1.0-dev\x1b]8;;\x1b\\\nBuilt on Ghostty 1.3.2\n",
        writer.buffered(),
    );
}
