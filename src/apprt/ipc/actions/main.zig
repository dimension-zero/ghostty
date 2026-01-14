//! IPC action handlers.
//!
//! This module provides action handlers for the IPC server.
//! Each action corresponds to a CLI command or API call.

pub const get_cwd = @import("get_cwd.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
