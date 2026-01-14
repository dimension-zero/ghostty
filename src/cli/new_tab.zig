//! CLI command for creating a new tab in a running Ghostty instance.
//!
//! Usage: ghostty +new-tab [--json]
//!
//! This command connects to a running Ghostty instance via IPC and creates
//! a new tab in the window containing the focused terminal surface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const cli_ipc = @import("ipc.zig");

pub const Options = struct {
    /// Output in JSON format for scripting.
    json: bool = false,

    /// Working directory for the new tab.
    cwd: ?[]const u8 = null,

    /// Command to run in the new tab (use -e for compatibility with other terminals).
    e: ?[]const u8 = null,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `new-tab` command creates a new tab in the window containing the focused
/// terminal surface.
///
/// This command uses Ghostty's socket IPC mechanism to communicate with a
/// running instance. The new tab is created in the same window as the currently
/// focused surface.
///
/// Flags:
///
///   * `--json`: Output in JSON format for scripting.
///
/// Output (default):
///   OK
///
/// Output (--json):
///   {"success":true}
///
/// Exit codes:
///   0 - Success
///   1 - Error (no running Ghostty, no focused surface, etc.)
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

    // Build request params if cwd or command specified
    var params: ?std.json.Value = null;
    if (opts.cwd != null or opts.e != null) {
        var params_obj = std.json.ObjectMap.init(alloc);
        if (opts.cwd) |cwd| {
            params_obj.put("cwd", .{ .string = cwd }) catch {
                stderr.writeAll("Out of memory\n") catch {};
                return 1;
            };
        }
        if (opts.e) |cmd| {
            params_obj.put("command", .{ .string = cmd }) catch {
                stderr.writeAll("Out of memory\n") catch {};
                return 1;
            };
        }
        params = .{ .object = params_obj };
    }

    // Send the new_tab request
    const response = cli_ipc.call(alloc, "new_tab", params) catch |err| {
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
