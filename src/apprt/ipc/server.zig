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
const posix = std.posix;

/// Handler function type for IPC actions.
/// The context is an opaque pointer to the app runtime.
pub const Handler = *const fn (ctx: *anyopaque, alloc: Allocator, params: ?std.json.Value) protocol.Response;

/// A subscriber to real-time events.
pub const Subscriber = struct {
    /// File descriptor of the connected socket.
    fd: posix.fd_t,

    /// Events this subscriber is interested in (bitmask).
    events: EventSet,

    /// Create a subscriber for the given events.
    pub fn init(fd: posix.fd_t, events: EventSet) Subscriber {
        return .{ .fd = fd, .events = events };
    }
};

/// Set of event types for subscription filtering.
pub const EventSet = struct {
    pwd_change: bool = false,

    /// Check if any event is subscribed.
    pub fn any(self: EventSet) bool {
        return self.pwd_change;
    }

    /// Create an EventSet with all events enabled.
    pub fn all() EventSet {
        return .{ .pwd_change = true };
    }

    /// Check if a specific event type is enabled.
    pub fn contains(self: EventSet, event_type: protocol.EventType) bool {
        return switch (event_type) {
            .pwd_change => self.pwd_change,
        };
    }
};

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

    /// Active subscribers for real-time events.
    subscribers: std.ArrayList(Subscriber),

    /// Initialize the server but don't start listening yet.
    pub fn init(alloc: Allocator, context: *anyopaque) !Server {
        return .{
            .socket = undefined,
            .socket_path = undefined,
            .alloc = alloc,
            .handlers = std.StringHashMap(Handler).init(alloc),
            .context = context,
            .running = false,
            .subscribers = std.ArrayList(Subscriber).init(alloc),
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

        // Close all subscriber sockets
        for (self.subscribers.items) |subscriber| {
            posix.close(subscriber.fd);
        }
        self.subscribers.deinit();

        // Remove socket file
        std.fs.cwd().deleteFile(self.socket_path) catch |err| {
            log.warn("Failed to remove socket file: {}", .{err});
        };

        self.alloc.free(self.socket_path);
        self.handlers.deinit();

        log.info("IPC server stopped", .{});
    }

    /// Add a subscriber for real-time events.
    /// The socket fd is NOT closed by the server when added as a subscriber.
    pub fn addSubscriber(self: *Server, fd: posix.fd_t, events: EventSet) !void {
        try self.subscribers.append(Subscriber.init(fd, events));
        log.debug("Added subscriber fd={}, total={}", .{ fd, self.subscribers.items.len });
    }

    /// Remove a subscriber by file descriptor.
    pub fn removeSubscriber(self: *Server, fd: posix.fd_t) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            if (self.subscribers.items[i].fd == fd) {
                posix.close(fd);
                _ = self.subscribers.swapRemove(i);
                log.debug("Removed subscriber fd={}", .{fd});
                return;
            }
            i += 1;
        }
    }

    /// Broadcast an event to all interested subscribers.
    /// Removes subscribers that fail to receive (disconnected).
    pub fn broadcastEvent(self: *Server, event_type: protocol.EventType, data: ?std.json.Value) void {
        const event = protocol.Event.init(event_type, data);
        const event_data = event.serialize(self.alloc) catch {
            log.warn("Failed to serialize event", .{});
            return;
        };
        defer self.alloc.free(event_data);

        // Iterate backwards so we can safely remove disconnected subscribers
        var i: usize = self.subscribers.items.len;
        while (i > 0) {
            i -= 1;
            const subscriber = self.subscribers.items[i];

            // Check if subscriber wants this event type
            if (!subscriber.events.contains(event_type)) continue;

            // Try to write event to subscriber
            const writer = Socket.writerFromFd(subscriber.fd);
            protocol.writeMessage(writer, event_data) catch {
                // Subscriber disconnected, remove it
                log.debug("Subscriber fd={} disconnected, removing", .{subscriber.fd});
                posix.close(subscriber.fd);
                _ = self.subscribers.swapRemove(i);
                continue;
            };
        }
    }

    /// Accept and handle a single connection.
    /// This should be called in a loop or from an event handler.
    pub fn acceptAndHandle(self: *Server) !void {
        var client = try self.socket.accept();

        const keep_open = self.handleClient(&client) catch |err| {
            log.warn("Error handling client: {}", .{err});
            client.close();
            return;
        };

        // Only close if not a subscription
        if (!keep_open) {
            client.close();
        }
    }

    /// Handle a connected client.
    /// Returns true if the socket should be kept open (subscription).
    fn handleClient(self: *Server, client: *Socket) !bool {
        const reader = client.reader();
        const writer = client.writer();

        // Read request
        const req_data = try protocol.readMessage(self.alloc, reader) orelse {
            log.debug("Client disconnected without sending data", .{});
            return false;
        };
        defer self.alloc.free(req_data);

        // Parse request
        const request = protocol.Request.parse(self.alloc, req_data) catch |err| {
            log.warn("Failed to parse request: {}", .{err});
            const resp = protocol.Response.err("Invalid request format");
            const resp_data = try resp.serialize(self.alloc);
            defer self.alloc.free(resp_data);
            try protocol.writeMessage(writer, resp_data);
            return false;
        };

        // Check for subscribe action (built-in, needs socket access)
        if (std.mem.eql(u8, request.action, "subscribe")) {
            return self.handleSubscribe(client, request.params, writer);
        }

        // Dispatch to handler
        const response = self.dispatch(request);

        // Send response
        const resp_data = try response.serialize(self.alloc);
        defer self.alloc.free(resp_data);
        try protocol.writeMessage(writer, resp_data);

        return false;
    }

    /// Handle a subscribe request.
    /// Returns true to keep the socket open.
    fn handleSubscribe(
        self: *Server,
        client: *Socket,
        params: ?std.json.Value,
        writer: anytype,
    ) !bool {
        // Parse events from params
        var events = EventSet{};

        if (params) |p| {
            if (p == .object) {
                if (p.object.get("events")) |events_val| {
                    if (events_val == .array) {
                        for (events_val.array) |ev| {
                            if (ev == .string) {
                                if (std.mem.eql(u8, ev.string, "pwd_change")) {
                                    events.pwd_change = true;
                                } else if (std.mem.eql(u8, ev.string, "all")) {
                                    events = EventSet.all();
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!events.any()) {
            const resp = protocol.Response.err("No valid events specified");
            const resp_data = try resp.serialize(self.alloc);
            defer self.alloc.free(resp_data);
            try protocol.writeMessage(writer, resp_data);
            return false;
        }

        // Add as subscriber (transfer socket ownership to subscribers list)
        try self.addSubscriber(client.fd, events);

        // Send success response
        const resp = protocol.Response.okEmpty();
        const resp_data = try resp.serialize(self.alloc);
        defer self.alloc.free(resp_data);
        try protocol.writeMessage(writer, resp_data);

        // Return true to keep socket open
        return true;
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
        actions.append("subscribe") catch return protocol.Response.err("Out of memory");

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
