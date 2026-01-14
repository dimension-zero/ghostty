//! IPC action handler for listing windows and tabs.
//!
//! Returns information about all open Ghostty windows and their tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const CoreApp = @import("../../../App.zig");

const log = std.log.scoped(.ipc_list_windows);

/// Window information returned by list_windows.
pub const WindowInfo = struct {
    id: u32,
    tab_count: u32,
    active_tab: u32,
    focused: bool,
};

/// Build a JSON response with window information.
/// This is called by platform-specific handlers that provide the window data.
pub fn buildResponse(alloc: Allocator, windows: []const WindowInfo) protocol.Response {
    // Build JSON array of window objects
    var json_array = std.ArrayList(std.json.Value).init(alloc);
    defer json_array.deinit();

    for (windows) |win| {
        // Create object for this window
        var obj = std.json.ObjectMap.init(alloc);

        obj.put("id", .{ .integer = @intCast(win.id) }) catch {
            return protocol.Response.err("Out of memory");
        };
        obj.put("tab_count", .{ .integer = @intCast(win.tab_count) }) catch {
            return protocol.Response.err("Out of memory");
        };
        obj.put("active_tab", .{ .integer = @intCast(win.active_tab) }) catch {
            return protocol.Response.err("Out of memory");
        };
        obj.put("focused", .{ .bool = win.focused }) catch {
            return protocol.Response.err("Out of memory");
        };

        json_array.append(.{ .object = obj }) catch {
            return protocol.Response.err("Out of memory");
        };
    }

    // Wrap in a "windows" object
    var result = std.json.ObjectMap.init(alloc);
    result.put("windows", .{ .array = json_array.toOwnedSlice() catch {
        return protocol.Response.err("Out of memory");
    } }) catch {
        return protocol.Response.err("Out of memory");
    };

    return protocol.Response.ok(.{ .object = result });
}
