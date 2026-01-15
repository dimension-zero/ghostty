//! IPC Protocol definitions for JSON-based communication.
//!
//! The protocol uses a simple JSON request/response format over Unix sockets.
//! Each message is a newline-delimited JSON object.
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.ipc_protocol);

/// Maximum size of a single IPC message (64KB).
pub const max_message_size = 64 * 1024;

/// IPC Request sent from client to server.
pub const Request = struct {
    /// The action to perform.
    action: []const u8,

    /// Optional parameters for the action (JSON object).
    params: ?std.json.Value = null,

    /// Parse a request from JSON bytes.
    pub fn parse(alloc: Allocator, bytes: []const u8) std.json.ParseError(std.json.Scanner)!Request {
        const parsed = try std.json.parseFromSlice(Request, alloc, bytes, .{
            .allocate = .alloc_always,
        });
        return parsed.value;
    }

    /// Serialize request to JSON.
    pub fn serialize(self: Request, alloc: Allocator) Allocator.Error![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();

        std.json.stringify(self, .{}, buf.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return buf.toOwnedSlice();
    }
};

/// IPC Response sent from server to client.
pub const Response = struct {
    /// Whether the action succeeded.
    success: bool,

    /// Optional data returned by the action.
    data: ?std.json.Value = null,

    /// Error message if success is false.
    @"error": ?[]const u8 = null,

    /// Create a successful response with data.
    pub fn ok(data: ?std.json.Value) Response {
        return .{ .success = true, .data = data };
    }

    /// Create a successful response with no data.
    pub fn okEmpty() Response {
        return .{ .success = true };
    }

    /// Create an error response.
    pub fn err(message: []const u8) Response {
        return .{ .success = false, .@"error" = message };
    }

    /// Serialize response to JSON.
    pub fn serialize(self: Response, alloc: Allocator) Allocator.Error![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();

        std.json.stringify(self, .{}, buf.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return buf.toOwnedSlice();
    }

    /// Parse a response from JSON bytes.
    pub fn parse(alloc: Allocator, bytes: []const u8) std.json.ParseError(std.json.Scanner)!Response {
        const parsed = try std.json.parseFromSlice(Response, alloc, bytes, .{
            .allocate = .alloc_always,
        });
        return parsed.value;
    }
};

/// Error codes for structured error responses.
pub const ErrorCode = enum {
    /// Unknown or unrecognized action.
    unknown_action,

    /// Invalid parameters for the action.
    invalid_params,

    /// No valid target for the action (e.g., no active window).
    no_target,

    /// Internal error during action execution.
    internal,

    /// Protocol error (malformed message, etc.).
    protocol,
};

/// Event types for subscription-based notifications.
pub const EventType = enum {
    /// Working directory changed (OSC 7).
    pwd_change,

    // Future event types:
    // tab_created,
    // tab_closed,
    // window_focus,

    /// Convert to string for JSON serialization.
    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .pwd_change => "pwd_change",
        };
    }

    /// Parse from string.
    pub fn fromString(s: []const u8) ?EventType {
        if (std.mem.eql(u8, s, "pwd_change")) return .pwd_change;
        return null;
    }
};

/// Event notification sent from server to subscribed clients.
pub const Event = struct {
    /// Type of event.
    event_type: []const u8,

    /// Event data (type-specific).
    data: ?std.json.Value = null,

    /// Create an event with the given type and data.
    pub fn init(event_type: EventType, data: ?std.json.Value) Event {
        return .{
            .event_type = event_type.toString(),
            .data = data,
        };
    }

    /// Serialize event to JSON.
    pub fn serialize(self: Event, alloc: Allocator) Allocator.Error![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();

        std.json.stringify(self, .{}, buf.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return buf.toOwnedSlice();
    }
};

/// Read a newline-delimited message from a reader.
pub fn readMessage(alloc: Allocator, reader: anytype) !?[]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();

    reader.streamUntilDelimiter(buf.writer(), '\n', max_message_size) catch |err| switch (err) {
        error.EndOfStream => {
            if (buf.items.len == 0) return null;
            // Return what we have if there's data without newline
        },
        else => return err,
    };

    return buf.toOwnedSlice();
}

/// Write a newline-delimited message to a writer.
pub fn writeMessage(writer: anytype, data: []const u8) !void {
    try writer.writeAll(data);
    try writer.writeByte('\n');
}

test "Request serialize and parse roundtrip" {
    const alloc = std.testing.allocator;

    const req = Request{
        .action = "get_cwd",
        .params = null,
    };

    const serialized = try req.serialize(alloc);
    defer alloc.free(serialized);

    const parsed = try Request.parse(alloc, serialized);
    _ = parsed;
    // Note: parsed contains allocated memory that would need to be freed
    // in real code via json.parseFree or similar
}

test "Response ok and err" {
    const ok_resp = Response.okEmpty();
    try std.testing.expect(ok_resp.success);
    try std.testing.expect(ok_resp.@"error" == null);

    const err_resp = Response.err("something went wrong");
    try std.testing.expect(!err_resp.success);
    try std.testing.expectEqualStrings("something went wrong", err_resp.@"error".?);
}
