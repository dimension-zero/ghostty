//! IPC action handler for switching tabs.
//!
//! Supports switching to a specific tab by index or relative movement.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// Parameters for goto_tab action.
pub const Params = struct {
    /// Tab index (0-based), or special values: -1=previous, -2=next, -3=last
    index: i32 = -2, // Default to next tab
};
