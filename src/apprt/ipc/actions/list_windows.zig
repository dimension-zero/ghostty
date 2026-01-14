//! IPC action handler for listing windows and tabs.
//!
//! Returns information about all open Ghostty windows and their tabs.
//! Supports both basic (3-star) and rich (4-star) output formats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const CoreApp = @import("../../../App.zig");

const log = std.log.scoped(.ipc_list_windows);

/// Surface information for rich output (4-star).
pub const SurfaceInfo = struct {
    id: u32,
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    is_focused: bool = false,
    /// Position in split: null=root, "left", "right", "up", "down"
    split_side: ?[]const u8 = null,
};

/// Tab information for rich output (4-star).
pub const TabInfo = struct {
    id: u32,
    active: bool = false,
    surfaces: []const SurfaceInfo = &.{},
};

/// Window information - basic (3-star) format.
pub const WindowInfo = struct {
    id: u32,
    tab_count: u32,
    active_tab: u32,
    focused: bool,
};

/// Window information - rich (4-star) format with tabs and surfaces.
pub const RichWindowInfo = struct {
    id: u32,
    focused: bool,
    tabs: []const TabInfo = &.{},
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

/// Build a rich JSON response with full window/tab/surface hierarchy.
/// This is the 4-star format with per-surface metadata.
pub fn buildRichResponse(alloc: Allocator, windows: []const RichWindowInfo) protocol.Response {
    var json_windows = std.ArrayList(std.json.Value).init(alloc);
    defer json_windows.deinit();

    for (windows) |win| {
        var win_obj = std.json.ObjectMap.init(alloc);

        win_obj.put("id", .{ .integer = @intCast(win.id) }) catch {
            return protocol.Response.err("Out of memory");
        };
        win_obj.put("focused", .{ .bool = win.focused }) catch {
            return protocol.Response.err("Out of memory");
        };

        // Build tabs array
        var json_tabs = std.ArrayList(std.json.Value).init(alloc);
        for (win.tabs) |tab| {
            var tab_obj = std.json.ObjectMap.init(alloc);

            tab_obj.put("id", .{ .integer = @intCast(tab.id) }) catch {
                return protocol.Response.err("Out of memory");
            };
            tab_obj.put("active", .{ .bool = tab.active }) catch {
                return protocol.Response.err("Out of memory");
            };

            // Build surfaces array
            var json_surfaces = std.ArrayList(std.json.Value).init(alloc);
            for (tab.surfaces) |surface| {
                var surf_obj = std.json.ObjectMap.init(alloc);

                surf_obj.put("id", .{ .integer = @intCast(surface.id) }) catch {
                    return protocol.Response.err("Out of memory");
                };
                surf_obj.put("is_focused", .{ .bool = surface.is_focused }) catch {
                    return protocol.Response.err("Out of memory");
                };

                if (surface.title) |title| {
                    const title_copy = alloc.dupe(u8, title) catch {
                        return protocol.Response.err("Out of memory");
                    };
                    surf_obj.put("title", .{ .string = title_copy }) catch {
                        return protocol.Response.err("Out of memory");
                    };
                } else {
                    surf_obj.put("title", .null) catch {
                        return protocol.Response.err("Out of memory");
                    };
                }

                if (surface.cwd) |cwd| {
                    const cwd_copy = alloc.dupe(u8, cwd) catch {
                        return protocol.Response.err("Out of memory");
                    };
                    surf_obj.put("cwd", .{ .string = cwd_copy }) catch {
                        return protocol.Response.err("Out of memory");
                    };
                } else {
                    surf_obj.put("cwd", .null) catch {
                        return protocol.Response.err("Out of memory");
                    };
                }

                if (surface.split_side) |side| {
                    const side_copy = alloc.dupe(u8, side) catch {
                        return protocol.Response.err("Out of memory");
                    };
                    surf_obj.put("split_side", .{ .string = side_copy }) catch {
                        return protocol.Response.err("Out of memory");
                    };
                } else {
                    surf_obj.put("split_side", .null) catch {
                        return protocol.Response.err("Out of memory");
                    };
                }

                json_surfaces.append(.{ .object = surf_obj }) catch {
                    return protocol.Response.err("Out of memory");
                };
            }

            tab_obj.put("surfaces", .{ .array = json_surfaces.toOwnedSlice() catch {
                return protocol.Response.err("Out of memory");
            } }) catch {
                return protocol.Response.err("Out of memory");
            };

            json_tabs.append(.{ .object = tab_obj }) catch {
                return protocol.Response.err("Out of memory");
            };
        }

        win_obj.put("tabs", .{ .array = json_tabs.toOwnedSlice() catch {
            return protocol.Response.err("Out of memory");
        } }) catch {
            return protocol.Response.err("Out of memory");
        };

        json_windows.append(.{ .object = win_obj }) catch {
            return protocol.Response.err("Out of memory");
        };
    }

    var result = std.json.ObjectMap.init(alloc);
    result.put("windows", .{ .array = json_windows.toOwnedSlice() catch {
        return protocol.Response.err("Out of memory");
    } }) catch {
        return protocol.Response.err("Out of memory");
    };

    return protocol.Response.ok(.{ .object = result });
}
