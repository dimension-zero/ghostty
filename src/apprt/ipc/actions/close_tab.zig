//! IPC action handler for closing a tab.
//!
//! Supports closing the current tab or other tabs based on mode.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// Parameters for close_tab action.
pub const Params = struct {
    /// Mode: "this" (default), "other", or "right"
    mode: []const u8 = "this",
};

/// Parse close tab mode from string.
pub fn parseMode(mode: []const u8) enum { this, other, right } {
    if (std.mem.eql(u8, mode, "other")) return .other;
    if (std.mem.eql(u8, mode, "right")) return .right;
    return .this;
}
