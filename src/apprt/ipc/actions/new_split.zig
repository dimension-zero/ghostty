//! IPC action handler for creating new splits.
//!
//! Supports creating splits in any direction.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// Parameters for new_split action.
pub const Params = struct {
    /// Split direction: "right" (default), "down", "left", "up"
    direction: []const u8 = "right",
};

/// Parse split direction from string.
pub fn parseDirection(direction: []const u8) enum { right, down, left, up } {
    if (std.mem.eql(u8, direction, "down")) return .down;
    if (std.mem.eql(u8, direction, "left")) return .left;
    if (std.mem.eql(u8, direction, "up")) return .up;
    return .right;
}
