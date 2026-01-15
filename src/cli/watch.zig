//! CLI command for watching real-time events from Ghostty.
//!
//! Usage: ghostty +watch [event-types...]
//!
//! This command connects to a running Ghostty instance via IPC and subscribes
//! to real-time events. Events are streamed as JSON lines to stdout.
//!
//! Event types:
//!   - pwd_change: Working directory changes (OSC 7)
//!   - all: Subscribe to all event types
//!
//! Example:
//!   ghostty +watch pwd_change
//!   ghostty +watch all
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const ipc = @import("../apprt/ipc/main.zig");

const log = std.log.scoped(.cli_watch);

pub const Options = struct {
    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `watch` command subscribes to real-time events from a running Ghostty instance.
///
/// Events are output as JSON lines (one JSON object per line) for easy parsing.
/// The connection stays open until Ghostty closes or the command is interrupted.
///
/// Event types:
///   - `pwd_change`: Working directory changes (from OSC 7)
///   - `all`: All available event types
///
/// Output format (per event):
///   {"event_type":"pwd_change","data":"/new/working/directory"}
///
/// Exit codes:
///   0 - Normal exit (connection closed by server)
///   1 - Error (no running Ghostty, subscription failed)
///
/// Available since: 1.3.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const result = try runArgs(alloc, &iter, stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            stderr.print("Error parsing args: {}\n", .{err}) catch {};
            return 1;
        },
    };

    // Collect remaining args as event types
    var events = std.ArrayList([]const u8).init(alloc_gpa);
    defer events.deinit();

    while (argsIter.next()) |arg| {
        events.append(arg) catch {
            stderr.writeAll("Error: Out of memory\n") catch {};
            return 1;
        };
    }

    // Default to "all" if no events specified
    if (events.items.len == 0) {
        events.append("all") catch {
            stderr.writeAll("Error: Out of memory\n") catch {};
            return 1;
        };
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Connect to IPC server
    var client = ipc.Client.connect(alloc) catch {
        stderr.writeAll("Error: Unable to connect to Ghostty.\n") catch {};
        stderr.writeAll("Make sure Ghostty is running and IPC is enabled.\n") catch {};
        return 1;
    };
    // Don't defer close - we want to keep it open for streaming

    // Build subscribe request with events array
    var json_events = std.ArrayList(std.json.Value).init(alloc);
    for (events.items) |event| {
        json_events.append(.{ .string = event }) catch {
            stderr.writeAll("Error: Out of memory\n") catch {};
            client.close();
            return 1;
        };
    }

    var params_obj = std.json.ObjectMap.init(alloc);
    params_obj.put("events", .{ .array = json_events.toOwnedSlice() catch {
        stderr.writeAll("Error: Out of memory\n") catch {};
        client.close();
        return 1;
    } }) catch {
        stderr.writeAll("Error: Out of memory\n") catch {};
        client.close();
        return 1;
    };

    const request = ipc.Request{
        .action = "subscribe",
        .params = .{ .object = params_obj },
    };

    // Send subscribe request
    const response = client.call(request) catch |err| {
        stderr.print("Error sending subscribe request: {}\n", .{err}) catch {};
        client.close();
        return 1;
    };

    if (!response.success) {
        const msg = response.@"error" orelse "Unknown error";
        stderr.print("Subscription failed: {s}\n", .{msg}) catch {};
        client.close();
        return 1;
    }

    // Now read events in a loop
    const reader = client.socket.reader();
    while (true) {
        const event_data = ipc.protocol.readMessage(alloc, reader) catch |err| {
            log.debug("Read error: {}", .{err});
            break;
        } orelse {
            // Connection closed
            break;
        };
        defer alloc.free(event_data);

        // Output the event line
        stdout.writeAll(event_data) catch {};
        stdout.writeByte('\n') catch {};
        stdout.flush() catch {};
    }

    client.close();
    return 0;
}
