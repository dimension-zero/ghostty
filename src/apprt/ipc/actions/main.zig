//! IPC action handlers.
//!
//! This module provides action handlers for the IPC server.
//! Each action corresponds to a CLI command or API call.

pub const get_cwd = @import("get_cwd.zig");
pub const new_tab = @import("new_tab.zig");
pub const list_windows = @import("list_windows.zig");
pub const close_tab = @import("close_tab.zig");
pub const close_window = @import("close_window.zig");
pub const goto_tab = @import("goto_tab.zig");
pub const toggle_fullscreen = @import("toggle_fullscreen.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
