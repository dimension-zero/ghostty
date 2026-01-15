//! CLI command for creating a new split in a running Ghostty instance.
//!
//! Usage: ghostty +new-split [--direction=right|down|left|up] [--json]
//!
//! This command connects to a running Ghostty instance via IPC and creates
//! a new split in the focused terminal.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const cli_ipc = @import("ipc.zig");

pub const Options = struct {
    /// Output in JSON format for scripting.
    json: bool = false,

    /// Split direction: right (default), down, left, up
    direction: Direction = .right,

    pub const Direction = enum {
        right,
        down,
        left,
        up,
    };

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `new-split` command creates a new split in the focused terminal.
///
/// This command uses Ghostty's socket IPC mechanism to communicate with a
/// running instance and create a split.
///
/// Flags:
///
///   * `--direction=<dir>`: Split direction (right, down, left, up). Default: right
///   * `--json`: Output in JSON format for scripting.
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

    // Build request params
    var params_obj = std.json.ObjectMap.init(alloc);
    const dir_str: []const u8 = switch (opts.direction) {
        .right => "right",
        .down => "down",
        .left => "left",
        .up => "up",
    };
    params_obj.put("direction", .{ .string = dir_str }) catch {
        stderr.writeAll("Out of memory\n") catch {};
        return 1;
    };
    const params: std.json.Value = .{ .object = params_obj };

    // Send the new_split request
    const response = cli_ipc.call(alloc, "new_split", params) catch |err| {
        if (opts.json) {
            stdout.print("{{\"success\":false,\"error\":\"{}\"}}\n", .{err}) catch {};
        } else {
            stderr.print("Error: {}\n", .{err}) catch {};
        }
        return 1;
    };

    if (opts.json) {
        cli_ipc.printResponse(stdout, response, .json) catch |err| {
            stderr.print("Error writing output: {}\n", .{err}) catch {};
            return 1;
        };
    } else {
        if (!response.success) {
            const msg = response.@"error" orelse "Unknown error";
            stderr.print("Error: {s}\n", .{msg}) catch {};
            return 1;
        }
        stdout.writeAll("Split created\n") catch {};
    }

    return if (response.success) 0 else 1;
}
