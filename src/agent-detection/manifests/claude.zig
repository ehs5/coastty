// Derived from herdr (https://github.com/herdrdev/herdr), Apache License 2.0 - see src/agent-detection/LICENSE-herdr.
// Translated from Rust to Zig and modified for coastty.

//! Claude Code's detection rule set.
//!
//! ported-from: https://github.com/herdrdev/herdr/blob/master/src/detect/manifests/claude.toml
//! manifest version: 2026.08.13.1
//!
//! Twelve rules, evaluated in priority order (ties favor the earlier rule
//! in this list) by the generic engine in `../manifest.zig`.

const manifest = @import("../manifest.zig");
const Rule = manifest.Rule;
const Gate = manifest.Gate;

pub const rules = [_]Rule{
    .{
        .id = "osc_title_working",
        .state = .Working,
        .priority = 1100,
        .region = .osc_title,
        .visible_working = true,
        // Braille covers <= 2.1.227; half-circles are the 2.1.228 busy spinner.
        .gate = .{ .regex = &.{"^[\\x{2800}-\\x{28FF}\\x{25D0}-\\x{25D3}] "} },
    },
    .{
        .id = "btw_overlay_working",
        .state = .Working,
        .priority = 975,
        .region = .{ .bottom_non_empty_lines = 5 },
        .visible_working = true,
        .gate = .{ .line_regex = &.{
            "^\\s*/btw(?:\\s|$)",
            "(?i)esc to close\\s*$",
        } },
    },
    .{
        .id = "transcript_viewer",
        .state = .Unknown,
        .priority = 1000,
        .region = .{ .bottom_non_empty_lines = 3 },
        .skip_state_update = true,
        .gate = .{
            .contains = &.{"showing detailed transcript"},
            .any = &.{
                .{ .contains = &.{ "ctrl+o", "to toggle" } },
                .{ .contains = &.{ "ctrl+e", "show all" } },
                .{ .contains = &.{ "ctrl+e", "collapse" } },
                .{ .contains = &.{"↑↓ scroll"} },
                .{ .contains = &.{"? for shortcuts"} },
            },
        },
    },
    .{
        .id = "live_blocked_form",
        .state = .Blocked,
        .priority = 980,
        .region = .after_last_horizontal_rule,
        .visible_blocker = true,
        .gate = .{
            .contains = &.{"esc to cancel"},
            .any = &.{
                .{ .contains = &.{"enter to confirm"} },
                .{
                    .contains = &.{"enter to select"},
                    .any = &.{
                        .{ .contains = &.{"tab/arrow keys to navigate"} },
                        .{ .contains = &.{"arrow keys to navigate"} },
                        .{ .contains = &.{"arrows to navigate"} },
                        .{ .contains = &.{"↑/↓ to navigate"} },
                        .{ .contains = &.{"↑↓ to navigate"} },
                    },
                },
            },
        },
    },
    .{
        .id = "dynamic_workflow_prompt",
        .state = .Blocked,
        .priority = 980,
        .region = .whole_recent,
        .visible_blocker = true,
        .gate = .{ .contains = &.{ "run a dynamic workflow?", "esc to cancel" } },
    },
    .{
        .id = "live_prompt_box",
        .state = .Idle,
        .priority = 950,
        .region = .prompt_box_body,
        .visible_idle = true,
        .gate = .{
            .line_regex = &.{"^\\s*❯"},
            .not = &.{
                .{ .contains = &.{"enter to select"} },
                .{ .contains = &.{"esc to cancel"} },
                .{ .contains = &.{"tab/arrow keys"} },
                .{ .contains = &.{"arrow keys to navigate"} },
                .{ .contains = &.{"↑/↓ to navigate"} },
            },
        },
    },
    .{
        .id = "model_picker_menu",
        .state = .Unknown,
        .priority = 900,
        .region = .whole_recent,
        .skip_state_update = true,
        .gate = .{
            .contains = &.{ "select model", "enter to set as default", "esc to cancel" },
            .not = &.{
                .{ .contains = &.{"do you want to proceed?"} },
                .{ .contains = &.{"enter to select"} },
            },
        },
    },
    .{
        .id = "bash_permission_prompt",
        .state = .Blocked,
        .priority = 850,
        .region = .whole_recent,
        .visible_blocker = true,
        .gate = .{
            .contains = &.{"do you want to proceed?"},
            .any = &.{
                .{ .contains = &.{"bash command"} },
                .{ .contains = &.{"bash("} },
                .{ .contains = &.{"contains expansion"} },
                .{ .contains = &.{"tab to amend"} },
                .{ .contains = &.{"ctrl+e to explain"} },
            },
            .all = &.{
                .{ .any = &.{
                    .{ .line_regex = &.{"(?i)^\\s*❯?\\s*yes\\b"} },
                    .{ .line_regex = &.{"(?i)^\\s*1\\.\\s*yes\\b"} },
                    .{ .line_regex = &.{"(?i)^\\s*2\\.\\s*no\\b"} },
                } },
            },
        },
    },
    .{
        .id = "generic_permission_prompt",
        .state = .Blocked,
        .priority = 840,
        .region = .after_last_horizontal_rule,
        .visible_blocker = true,
        .gate = .{
            .contains = &.{ "do you want to proceed?", "esc to cancel" },
            .all = &.{
                .{ .any = &.{
                    .{ .line_regex = &.{"(?i)^\\s*❯?\\s*1\\.\\s*yes\\b"} },
                    .{ .line_regex = &.{"(?i)^\\s*2\\.\\s*yes\\b"} },
                    .{ .line_regex = &.{"(?i)^\\s*2\\.\\s*no\\b"} },
                    .{ .line_regex = &.{"(?i)^\\s*3\\.\\s*no\\b"} },
                } },
            },
        },
    },
    .{
        .id = "legacy_no_prompt_blocker",
        .state = .Blocked,
        .priority = 300,
        .region = .whole_recent,
        .gate = .{
            .any = &.{
                .{ .contains = &.{"do you want to"}, .any = &.{
                    .{ .contains = &.{"yes"} },
                    .{ .contains = &.{"❯"} },
                } },
                .{ .contains = &.{"would you like to"}, .any = &.{
                    .{ .contains = &.{"yes"} },
                    .{ .contains = &.{"❯"} },
                } },
                .{ .contains = &.{"waiting for permission"} },
                .{ .contains = &.{"do you want to allow this connection?"} },
                .{ .contains = &.{"tab to amend"} },
                .{ .contains = &.{"ctrl+e to explain"} },
                .{ .contains = &.{ "do you want to proceed?", "esc to cancel" } },
                .{ .contains = &.{"review your answers"} },
                .{ .contains = &.{"skip interview and plan immediately"} },
            },
            .not = &.{
                .{ .regex = &.{"(?m)^\\s*❯\\s*$"} },
            },
        },
    },
    .{
        .id = "osc_title_idle",
        .state = .Idle,
        .priority = 250,
        .region = .osc_title,
        .visible_idle = true,
        .gate = .{ .regex = &.{"^\\x{2733} "} },
    },
    .{
        .id = "osc_progress_idle",
        .state = .Idle,
        .priority = 250,
        .region = .osc_progress,
        .gate = .{ .regex = &.{"^4;0"} },
    },
};
