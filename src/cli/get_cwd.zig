//! CLI command for getting the current working directory of the focused terminal.
//!
//! Usage: ghostty +get-cwd [--json]
//!
//! This command connects to a running Ghostty instance via IPC and retrieves
//! the current working directory of the focused terminal surface.
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

/// The `get-cwd` command retrieves the current working directory of the focused
/// terminal surface in a running Ghostty instance.
///
/// This uses Ghostty's IPC mechanism to query the running instance. The CWD
/// is obtained from OSC 7 reports sent by the shell.
///
/// Flags:
///
///   * `--json`: Output in JSON format for scripting.
///
/// Output (default):
///   /path/to/current/directory
///
/// Output (--json):
///   {"success":true,"data":"/path/to/current/directory"}
///
/// Exit codes:
///   0 - Success
///   1 - Error (no running Ghostty, no focused surface, CWD not available)
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [1024]u8 = undefined;
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

    // Send the get_cwd request
    const response = cli_ipc.call(alloc, "get_cwd", null) catch |err| {
        if (opts.json) {
            stdout.print("{{\"success\":false,\"error\":\"{}\"}}\n", .{err}) catch {};
        } else {
            stderr.print("Error: {}\n", .{err}) catch {};
        }
        return 1;
    };

    // Output the response
    const format: cli_ipc.OutputFormat = if (opts.json) .json else .human;
    cli_ipc.printResponse(stdout, response, format) catch |err| {
        stderr.print("Error writing output: {}\n", .{err}) catch {};
        return 1;
    };

    return if (response.success) 0 else 1;
}
