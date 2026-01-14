//! IPC action handler for creating a new tab.
//!
//! Creates a new tab in the window containing the focused surface.
//!
//! Note: The actual handler implementation is platform-specific because
//! it needs to call performAction on the runtime App. See the GTK and
//! embedded app implementations for the actual handlers.
const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const CoreApp = @import("../../../App.zig");
const apprt = @import("../../../apprt.zig");

const log = std.log.scoped(.ipc_new_tab);

/// Parameters for new_tab action.
pub const Params = struct {
    /// Command to run in the new tab. If null, uses default shell.
    command: ?[]const u8 = null,

    /// Working directory for the new tab. If null, inherits from parent.
    cwd: ?[]const u8 = null,
};

/// Parse JSON params into Params struct.
pub fn parseParams(alloc: Allocator, json_params: ?std.json.Value) ?Params {
    _ = alloc;
    // For now, we ignore params since new_tab doesn't support them yet
    if (json_params) |_| {
        // TODO: Parse command and cwd when supported
    }
    return .{};
}
