//! CLI helpers for IPC communication.
//!
//! This module provides utilities for CLI commands to communicate with
//! running Ghostty instances via Unix socket IPC.
const std = @import("std");
const Allocator = std.mem.Allocator;

const ipc = @import("../apprt/ipc/main.zig");

const log = std.log.scoped(.cli_ipc);

/// Error types for CLI IPC operations.
pub const Error = error{
    /// Failed to connect to the IPC server.
    ConnectionFailed,

    /// The IPC call returned an error.
    ActionFailed,

    /// Failed to serialize/deserialize data.
    SerializationError,

    /// Allocation failure.
    OutOfMemory,
};

/// Options for CLI output format.
pub const OutputFormat = enum {
    /// Human-readable plain text.
    human,
    /// JSON format for scripting.
    json,
};

/// Send an IPC request and get the response.
pub fn call(
    alloc: Allocator,
    action: []const u8,
    params: ?std.json.Value,
) Error!ipc.Response {
    var client = ipc.Client.connect(alloc) catch {
        return Error.ConnectionFailed;
    };
    defer client.close();

    const request = ipc.Request{
        .action = action,
        .params = params,
    };

    return client.call(request) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.ActionFailed,
    };
}

/// Print a response in the specified format.
pub fn printResponse(
    writer: anytype,
    response: ipc.Response,
    format: OutputFormat,
) !void {
    switch (format) {
        .json => {
            // Output full JSON response
            try std.json.stringify(response, .{}, writer);
            try writer.writeByte('\n');
        },
        .human => {
            if (!response.success) {
                const msg = response.@"error" orelse "Unknown error";
                try writer.print("Error: {s}\n", .{msg});
                return;
            }

            if (response.data) |data| {
                try printJsonValue(writer, data);
                try writer.writeByte('\n');
            } else {
                try writer.writeAll("OK\n");
            }
        },
    }
}

/// Print a JSON value in human-readable format.
fn printJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string, .string => |s| try writer.writeAll(s),
        .array => |arr| {
            for (arr, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try printJsonValue(writer, item);
            }
        },
        .object => |obj| {
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.print("{s}: ", .{entry.key_ptr.*});
                try printJsonValue(writer, entry.value_ptr.*);
            }
        },
    }
}

/// Parse JSON string into a value.
pub fn parseJson(alloc: Allocator, json_str: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{
        .allocate = .alloc_always,
    });
    return parsed.value;
}

/// Check if a running Ghostty instance is available.
pub fn isServerAvailable(alloc: Allocator) bool {
    const socket_path = ipc.path.getSocketPath(alloc) catch return false;
    defer alloc.free(socket_path);

    // Check if socket file exists
    std.fs.cwd().access(socket_path, .{}) catch return false;
    return true;
}

/// Print a connection error message.
pub fn printConnectionError(writer: anytype) !void {
    try writer.writeAll("Error: Unable to connect to Ghostty.\n");
    try writer.writeAll("Make sure Ghostty is running and IPC is enabled.\n");
}

test "OutputFormat enum" {
    try std.testing.expect(@intFromEnum(OutputFormat.human) == 0);
    try std.testing.expect(@intFromEnum(OutputFormat.json) == 1);
}
