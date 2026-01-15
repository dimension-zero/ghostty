//! Unix domain socket abstraction for IPC.
//!
//! Provides a simple wrapper around Unix domain sockets for both
//! server (listening) and client (connecting) use cases.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const path_module = @import("path.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.ipc_socket);

pub const SocketError = error{
    /// Socket creation failed.
    SocketCreateFailed,

    /// Binding to the socket path failed.
    BindFailed,

    /// Listening on the socket failed.
    ListenFailed,

    /// Connecting to the socket failed.
    ConnectFailed,

    /// Accept failed.
    AcceptFailed,

    /// The socket path is too long.
    PathTooLong,

    /// Send/receive operation failed.
    IoError,
};

/// Unix domain socket wrapper.
pub const Socket = struct {
    /// The underlying file descriptor.
    fd: posix.fd_t,

    /// Create a new Unix domain socket.
    pub fn create() SocketError!Socket {
        const fd = posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM,
            0,
        ) catch {
            log.err("Failed to create Unix socket", .{});
            return SocketError.SocketCreateFailed;
        };

        return .{ .fd = fd };
    }

    /// Close the socket.
    pub fn close(self: *Socket) void {
        posix.close(self.fd);
        self.fd = -1;
    }

    /// Bind the socket to a path and start listening.
    pub fn listen(self: *Socket, socket_path: [:0]const u8, backlog: u31) SocketError!void {
        // Remove existing socket file if it exists
        std.fs.cwd().deleteFile(socket_path) catch |err| switch (err) {
            error.FileNotFound => {}, // OK, doesn't exist
            else => {
                log.warn("Failed to remove existing socket file: {}", .{err});
            },
        };

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return SocketError.PathTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        posix.bind(self.fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            log.err("Failed to bind socket to path: {s}", .{socket_path});
            return SocketError.BindFailed;
        };

        posix.listen(self.fd, backlog) catch {
            log.err("Failed to listen on socket", .{});
            return SocketError.ListenFailed;
        };

        log.info("IPC socket listening on: {s}", .{socket_path});
    }

    /// Accept a new connection.
    pub fn accept(self: *Socket) SocketError!Socket {
        const client_fd = posix.accept(self.fd, null, null) catch {
            return SocketError.AcceptFailed;
        };

        return .{ .fd = client_fd };
    }

    /// Connect to a socket at the given path.
    pub fn connect(socket_path: [:0]const u8) SocketError!Socket {
        var sock = try Socket.create();
        errdefer sock.close();

        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return SocketError.PathTooLong;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        posix.connect(sock.fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            log.err("Failed to connect to socket: {s}", .{socket_path});
            return SocketError.ConnectFailed;
        };

        return sock;
    }

    /// Get a reader for this socket.
    pub fn reader(self: Socket) std.io.AnyReader {
        return .{
            .context = @ptrFromInt(@as(usize, @intCast(self.fd))),
            .readFn = struct {
                fn read(ctx: *const anyopaque, buf: []u8) anyerror!usize {
                    const fd: posix.fd_t = @intCast(@intFromPtr(ctx));
                    return posix.read(fd, buf) catch |err| {
                        log.debug("Socket read error: {}", .{err});
                        return err;
                    };
                }
            }.read,
        };
    }

    /// Get a writer for this socket.
    pub fn writer(self: Socket) std.io.AnyWriter {
        return .{
            .context = @ptrFromInt(@as(usize, @intCast(self.fd))),
            .writeFn = struct {
                fn write(ctx: *const anyopaque, buf: []const u8) anyerror!usize {
                    const fd: posix.fd_t = @intCast(@intFromPtr(ctx));
                    return posix.write(fd, buf) catch |err| {
                        log.debug("Socket write error: {}", .{err});
                        return err;
                    };
                }
            }.write,
        };
    }

    /// Get a writer for a raw file descriptor (for use with subscriber fds).
    pub fn writerFromFd(fd: posix.fd_t) std.io.AnyWriter {
        return .{
            .context = @ptrFromInt(@as(usize, @intCast(fd))),
            .writeFn = struct {
                fn write(ctx: *const anyopaque, buf: []const u8) anyerror!usize {
                    const sock_fd: posix.fd_t = @intCast(@intFromPtr(ctx));
                    return posix.write(sock_fd, buf) catch |err| {
                        log.debug("Socket write error: {}", .{err});
                        return err;
                    };
                }
            }.write,
        };
    }

    /// Send data on the socket.
    pub fn send(self: Socket, data: []const u8) SocketError!void {
        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const sent = posix.write(self.fd, data[total_sent..]) catch {
                return SocketError.IoError;
            };
            total_sent += sent;
        }
    }

    /// Receive data from the socket into the provided buffer.
    /// Returns the number of bytes received.
    pub fn recv(self: Socket, buf: []u8) SocketError!usize {
        return posix.read(self.fd, buf) catch {
            return SocketError.IoError;
        };
    }
};

/// Client helper for connecting to and communicating with the IPC server.
pub const Client = struct {
    socket: Socket,
    alloc: Allocator,

    /// Connect to the IPC server.
    pub fn connect(alloc: Allocator) !Client {
        const socket_path = try path_module.getSocketPath(alloc);
        defer alloc.free(socket_path);

        const socket = try Socket.connect(socket_path);

        return .{
            .socket = socket,
            .alloc = alloc,
        };
    }

    /// Close the client connection.
    pub fn close(self: *Client) void {
        self.socket.close();
    }

    /// Send a request and receive a response.
    pub fn call(self: *Client, request: protocol.Request) !protocol.Response {
        // Serialize and send request
        const req_data = try request.serialize(self.alloc);
        defer self.alloc.free(req_data);

        try protocol.writeMessage(self.socket.writer(), req_data);

        // Read response
        const resp_data = try protocol.readMessage(self.alloc, self.socket.reader()) orelse {
            return protocol.Response.err("No response from server");
        };
        defer self.alloc.free(resp_data);

        return try protocol.Response.parse(self.alloc, resp_data);
    }
};
