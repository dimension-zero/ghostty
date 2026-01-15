//! Platform-specific process CWD query.
//!
//! This module provides functions to query the current working directory
//! of a process by PID. Used as a fallback when OSC 7 is unavailable.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.process_cwd);

/// Query the current working directory of a process by PID.
/// Returns null if the CWD cannot be determined.
/// The returned string is allocated with the provided allocator.
pub fn getProcessCwd(alloc: Allocator, pid: posix.pid_t) ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => getProcessCwdLinux(alloc, pid),
        .macos => getProcessCwdMacos(alloc, pid),
        else => null,
    };
}

/// Linux implementation using /proc/{pid}/cwd symlink.
fn getProcessCwdLinux(alloc: Allocator, pid: posix.pid_t) ?[]const u8 {
    // Build path to /proc/{pid}/cwd
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;

    // Read the symlink
    var result_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.readlink(path, &result_buf) catch |err| {
        log.debug("readlink {s} failed: {}", .{ path, err });
        return null;
    };

    // Duplicate to return owned memory
    return alloc.dupe(u8, cwd) catch null;
}

/// macOS implementation using proc_pidinfo.
fn getProcessCwdMacos(alloc: Allocator, pid: posix.pid_t) ?[]const u8 {
    const c = @cImport({
        @cInclude("libproc.h");
    });

    var vpi: c.struct_proc_vnodepathinfo = undefined;
    const size = c.proc_pidinfo(
        pid,
        c.PROC_PIDVNODEPATHINFO,
        0,
        &vpi,
        @sizeOf(c.struct_proc_vnodepathinfo),
    );

    if (size <= 0) {
        log.debug("proc_pidinfo failed for pid {}", .{pid});
        return null;
    }

    // vpi.pvi_cdir.vip_path contains the current directory
    const path_ptr: [*:0]const u8 = @ptrCast(&vpi.pvi_cdir.vip_path);
    const cwd = std.mem.span(path_ptr);

    if (cwd.len == 0) {
        return null;
    }

    return alloc.dupe(u8, cwd) catch null;
}

test "getProcessCwd returns own cwd" {
    const alloc = std.testing.allocator;
    const pid = std.os.linux.getpid();

    if (getProcessCwd(alloc, pid)) |cwd| {
        defer alloc.free(cwd);
        // Should return something non-empty
        try std.testing.expect(cwd.len > 0);
    }
}
