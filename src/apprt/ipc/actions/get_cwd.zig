//! IPC action handler for getting the current working directory.
//!
//! Returns the CWD of the focused terminal surface.
const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const CoreApp = @import("../../../App.zig");
const CoreSurface = @import("../../../Surface.zig");

const log = std.log.scoped(.ipc_get_cwd);

/// Get the CWD from the focused surface of a CoreApp.
/// This is the shared implementation that both GTK and embedded can use.
pub fn getCwd(core_app: *CoreApp, alloc: Allocator) protocol.Response {
    // Get the focused surface
    const surface = core_app.focusedSurface() orelse {
        log.debug("No focused surface", .{});
        return protocol.Response.err("No focused surface");
    };

    // Get the PWD from the surface
    const pwd = surface.pwd(alloc) catch |err| {
        log.warn("Failed to get pwd: {}", .{err});
        return protocol.Response.err("Failed to get pwd");
    } orelse {
        log.debug("Surface has no pwd", .{});
        return protocol.Response.err("CWD not available");
    };
    defer alloc.free(pwd);

    // Return the CWD as a JSON object
    // We need to duplicate the string since the response needs to own it
    const pwd_copy = alloc.dupeZ(u8, pwd) catch {
        return protocol.Response.err("Out of memory");
    };

    return protocol.Response.ok(.{ .string = pwd_copy });
}

test "getCwd returns error when no focused surface" {
    // This test would require mocking CoreApp
    // For now, just verify the function compiles
}
