//! IPC Server for handling requests from CLI tools.
//!
//! The server listens on a Unix domain socket and dispatches incoming
//! requests to the appropriate action handlers.
const std = @import("std");
const Allocator = std.mem.Allocator;

const socket_module = @import("socket.zig");
const path_module = @import("path.zig");
const protocol = @import("protocol.zig");
const Socket = socket_module.Socket;

const log = std.log.scoped(.ipc_server);

/// Handler function type for IPC actions.
/// The context is an opaque pointer to the app runtime.
pub const Handler = *const fn (ctx: *anyopaque, alloc: Allocator, params: ?std.json.Value) protocol.Response;

/// IPC Server that listens for and handles requests.
pub const Server = struct {
    /// The listening socket.
    socket: Socket,

    /// Socket path (for cleanup).
    socket_path: [:0]const u8,

    /// Allocator for server operations.
    alloc: Allocator,

    /// Action handlers map.
    handlers: std.StringHashMap(Handler),

    /// Context pointer passed to handlers (typically the App).
    context: *anyopaque,

    /// Whether the server is running.
    running: bool,

    /// Initialize the server but don't start listening yet.
    pub fn init(alloc: Allocator, context: *anyopaque) !Server {
        return .{
            .socket = undefined,
            .socket_path = undefined,
            .alloc = alloc,
            .handlers = std.StringHashMap(Handler).init(alloc),
            .context = context,
            .running = false,
        };
    }

    /// Register an action handler.
    pub fn registerHandler(self: *Server, action: []const u8, handler: Handler) !void {
        try self.handlers.put(action, handler);
    }

    /// Start listening on the IPC socket.
    pub fn start(self: *Server) !void {
        const socket_path = try path_module.getSocketPath(self.alloc);
        errdefer self.alloc.free(socket_path);

        var sock = try Socket.create();
        errdefer sock.close();

        try sock.listen(socket_path, 5);

        self.socket = sock;
        self.socket_path = socket_path;
        self.running = true;

        log.info("IPC server started", .{});
    }

    /// Stop the server and clean up.
    pub fn stop(self: *Server) void {
        if (!self.running) return;

        self.running = false;
        self.socket.close();

        // Remove socket file
        std.fs.cwd().deleteFile(self.socket_path) catch |err| {
            log.warn("Failed to remove socket file: {}", .{err});
        };

        self.alloc.free(self.socket_path);
        self.handlers.deinit();

        log.info("IPC server stopped", .{});
    }

    /// Accept and handle a single connection.
    /// This should be called in a loop or from an event handler.
    pub fn acceptAndHandle(self: *Server) !void {
        var client = try self.socket.accept();
        defer client.close();

        self.handleClient(&client) catch |err| {
            log.warn("Error handling client: {}", .{err});
        };
    }

    /// Handle a connected client.
    fn handleClient(self: *Server, client: *Socket) !void {
        const reader = client.reader();
        const writer = client.writer();

        // Read request
        const req_data = try protocol.readMessage(self.alloc, reader) orelse {
            log.debug("Client disconnected without sending data", .{});
            return;
        };
        defer self.alloc.free(req_data);

        // Parse request
        const request = protocol.Request.parse(self.alloc, req_data) catch |err| {
            log.warn("Failed to parse request: {}", .{err});
            const resp = protocol.Response.err("Invalid request format");
            const resp_data = try resp.serialize(self.alloc);
            defer self.alloc.free(resp_data);
            try protocol.writeMessage(writer, resp_data);
            return;
        };

        // Dispatch to handler
        const response = self.dispatch(request);

        // Send response
        const resp_data = try response.serialize(self.alloc);
        defer self.alloc.free(resp_data);
        try protocol.writeMessage(writer, resp_data);
    }

    /// Dispatch a request to the appropriate handler.
    fn dispatch(self: *Server, request: protocol.Request) protocol.Response {
        // Special case: list_actions returns available actions
        if (std.mem.eql(u8, request.action, "list_actions")) {
            return self.listActions();
        }

        const handler = self.handlers.get(request.action) orelse {
            log.debug("Unknown action: {s}", .{request.action});
            return protocol.Response.err("Unknown action");
        };

        return handler(self.context, self.alloc, request.params);
    }

    /// Built-in handler for listing available actions.
    fn listActions(self: *Server) protocol.Response {
        var actions = std.ArrayList([]const u8).init(self.alloc);
        defer actions.deinit();

        // Add built-in actions
        actions.append("list_actions") catch return protocol.Response.err("Out of memory");

        // Add registered actions
        var iter = self.handlers.keyIterator();
        while (iter.next()) |key| {
            actions.append(key.*) catch return protocol.Response.err("Out of memory");
        }

        // Build JSON array
        var json_array = std.ArrayList(std.json.Value).init(self.alloc);
        defer json_array.deinit();

        for (actions.items) |action| {
            json_array.append(.{ .string = action }) catch return protocol.Response.err("Out of memory");
        }

        return protocol.Response.ok(.{ .array = json_array.toOwnedSlice() catch return protocol.Response.err("Out of memory") });
    }

    /// Get the file descriptor for use with poll/select/epoll.
    pub fn getFd(self: *Server) std.posix.fd_t {
        return self.socket.fd;
    }
};

/// Simple action that echoes the params back (for testing).
pub fn echoHandler(_: *anyopaque, _: Allocator, params: ?std.json.Value) protocol.Response {
    return protocol.Response.ok(params);
}

test "Server init and deinit" {
    const alloc = std.testing.allocator;
    var dummy_context: u8 = 0;

    var server = try Server.init(alloc, &dummy_context);
    defer server.stop();

    try server.registerHandler("echo", echoHandler);
}
