//! IPC action handler for toggling fullscreen mode.
//!
//! Supports different fullscreen modes on different platforms.

const std = @import("std");
const protocol = @import("../protocol.zig");

/// Parameters for toggle_fullscreen action.
pub const Params = struct {
    /// Mode: "native" (default), "macos_non_native", etc.
    mode: []const u8 = "native",
};

/// Parse fullscreen mode from string.
pub fn parseMode(mode: []const u8) enum { native, macos_non_native, macos_non_native_visible_menu, macos_non_native_padded_notch } {
    if (std.mem.eql(u8, mode, "macos_non_native")) return .macos_non_native;
    if (std.mem.eql(u8, mode, "macos_non_native_visible_menu")) return .macos_non_native_visible_menu;
    if (std.mem.eql(u8, mode, "macos_non_native_padded_notch")) return .macos_non_native_padded_notch;
    return .native;
}
