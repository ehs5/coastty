//! Entry point for the `coastty-host` executable.
//!
//! This lives directly in `src/`, alongside `main.zig`, rather than as
//! `src/host/main.zig`'s own module root: a module's relative imports
//! can't escape above its root file's directory, and `src/host/*.zig`
//! reaches into `src/pty.zig`, `src/Command.zig`, and `src/terminal/`
//! the same way the rest of the core does.
pub const main = @import("host/main.zig").main;

// A plain `pub const main` reference isn't enough to pull the daemon's
// own files into a test build's analysis, so `coastty-host-test` built
// with zero tests in it and silently passed. Importing them here is what
// actually makes `Host.zig`/`Pane.zig`/`wire.zig`'s suites run.
test {
    // Zig 0.16 fails a test command over anything printed to stderr, even
    // when every test passed - and the daemon warns for real reasons the
    // tests deliberately provoke. Same bump `main.zig` makes for the core.
    @import("std").testing.log_level = .err;

    _ = @import("host/access.zig");
    _ = @import("host/Events.zig");
    _ = @import("host/Focus.zig");
    _ = @import("host/Host.zig");
    _ = @import("host/layout_commands.zig");
    _ = @import("host/Model.zig");
    _ = @import("host/Pane.zig");
    _ = @import("host/paths.zig");
    _ = @import("host/process.zig");
    _ = @import("host/upgrade.zig");
    _ = @import("host/Windows.zig");
    _ = @import("host/wire.zig");
}
