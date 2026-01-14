//! Cross-platform IPC for Ghostty.
//!
//! This module provides Unix socket-based IPC for communication between
//! CLI tools and running Ghostty instances. It works on both Linux and macOS.
//!
//! ## Architecture
//!
//! - Server: Runs within the Ghostty application, listening for requests
//! - Client: Used by CLI tools to send requests to the server
//! - Protocol: JSON-based request/response over newline-delimited messages
//!
//! ## Usage (Server)
//!
//! ```zig
//! var server = try ipc.Server.init(alloc, app_context);
//! defer server.stop();
//!
//! try server.registerHandler("get_cwd", getCwdHandler);
//! try server.start();
//!
//! // In event loop:
//! try server.acceptAndHandle();
//! ```
//!
//! ## Usage (Client)
//!
//! ```zig
//! var client = try ipc.socket.Client.connect(alloc);
//! defer client.close();
//!
//! const response = try client.call(.{ .action = "get_cwd" });
//! ```

pub const socket = @import("socket.zig");
pub const protocol = @import("protocol.zig");
pub const path = @import("path.zig");
pub const server = @import("server.zig");

pub const Socket = socket.Socket;
pub const Client = socket.Client;
pub const Server = server.Server;
pub const Request = protocol.Request;
pub const Response = protocol.Response;
pub const Handler = server.Handler;

test {
    @import("std").testing.refAllDecls(@This());
}
