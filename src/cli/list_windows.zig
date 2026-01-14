//! CLI command for listing windows and tabs in a running Ghostty instance.
//!
//! Usage: ghostty +list-windows [--json]
//!
//! This command connects to a running Ghostty instance via IPC and retrieves
//! information about all open windows and their tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const cli_ipc = @import("ipc.zig");

pub const Options = struct {
    /// Output in JSON format for scripting.
    json: bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-windows` command lists all open windows and their tabs in a
/// running Ghostty instance.
///
/// This command uses Ghostty's socket IPC mechanism to communicate with a
/// running instance and enumerate window/tab information.
///
/// Flags:
///
///   * `--json`: Output in JSON format for scripting.
///
/// Output (default):
///   Window 0 (focused)
///     Tabs: 3, Active: 1
///   Window 1
///     Tabs: 1, Active: 0
///
/// Output (--json):
///   {"windows":[{"id":0,"tab_count":3,"active_tab":1,"focused":true},...]}
///
/// Exit codes:
///   0 - Success
///   1 - Error (no running Ghostty, etc.)
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const result = runArgs(alloc, &iter, stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) u8 {
    var opts: Options = .{};

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            stderr.print("Error parsing args: {}\n", .{err}) catch {};
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Check if server is available
    if (!cli_ipc.isServerAvailable(alloc)) {
        if (opts.json) {
            stdout.writeAll("{\"success\":false,\"error\":\"Unable to connect to Ghostty\"}\n") catch {};
        } else {
            cli_ipc.printConnectionError(stderr) catch {};
        }
        return 1;
    }

    // Send the list_windows request
    const response = cli_ipc.call(alloc, "list_windows", null) catch |err| {
        if (opts.json) {
            stdout.print("{{\"success\":false,\"error\":\"{}\"}}\n", .{err}) catch {};
        } else {
            stderr.print("Error: {}\n", .{err}) catch {};
        }
        return 1;
    };

    if (opts.json) {
        // JSON output - just print the full response
        cli_ipc.printResponse(stdout, response, .json) catch |err| {
            stderr.print("Error writing output: {}\n", .{err}) catch {};
            return 1;
        };
    } else {
        // Human-readable output
        if (!response.success) {
            const msg = response.@"error" orelse "Unknown error";
            stderr.print("Error: {s}\n", .{msg}) catch {};
            return 1;
        }

        if (response.data) |data| {
            printHumanOutput(stdout, data) catch |err| {
                stderr.print("Error writing output: {}\n", .{err}) catch {};
                return 1;
            };
        } else {
            stdout.writeAll("No windows\n") catch {};
        }
    }

    return if (response.success) 0 else 1;
}

/// Print human-readable window list.
fn printHumanOutput(stdout: *std.Io.Writer, data: std.json.Value) !void {
    // Expect data to be an object with "windows" array
    if (data != .object) {
        try stdout.writeAll("Invalid response format\n");
        return;
    }

    const windows = data.object.get("windows") orelse {
        try stdout.writeAll("No windows\n");
        return;
    };

    if (windows != .array) {
        try stdout.writeAll("Invalid response format\n");
        return;
    }

    if (windows.array.len == 0) {
        try stdout.writeAll("No windows\n");
        return;
    }

    for (windows.array) |win| {
        if (win != .object) continue;

        const id = win.object.get("id");
        const tab_count = win.object.get("tab_count");
        const active_tab = win.object.get("active_tab");
        const focused = win.object.get("focused");

        const id_val: i64 = if (id) |v| if (v == .integer) v.integer else 0 else 0;
        const tab_val: i64 = if (tab_count) |v| if (v == .integer) v.integer else 0 else 0;
        const active_val: i64 = if (active_tab) |v| if (v == .integer) v.integer else 0 else 0;
        const focused_val: bool = if (focused) |v| if (v == .bool) v.bool else false else false;

        if (focused_val) {
            try stdout.print("Window {d} (focused)\n", .{id_val});
        } else {
            try stdout.print("Window {d}\n", .{id_val});
        }
        try stdout.print("  Tabs: {d}, Active: {d}\n", .{ tab_val, active_val });
    }
}
