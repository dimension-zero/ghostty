//! Socket path resolution for IPC.
//!
//! Resolves the path to the Unix domain socket used for IPC between
//! CLI commands and running Ghostty instances.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.ipc_path);

/// Platform-specific C imports for getuid().
const c = @cImport({
    @cInclude("unistd.h");
});

/// Maximum path length for Unix domain sockets.
/// Linux: 108 bytes, macOS: 104 bytes. We use the smaller value.
pub const max_path_len = 104;

/// Error type for path operations.
pub const PathError = error{
    /// The socket path would exceed the maximum length.
    PathTooLong,

    /// Unable to determine socket path (missing environment variables).
    NoSocketPath,
};

/// Get the socket path for IPC.
///
/// On Linux: Uses $XDG_RUNTIME_DIR if available, falls back to /tmp.
/// On macOS: Uses $TMPDIR if available, falls back to /tmp.
///
/// The returned path is owned by the caller and must be freed.
pub fn getSocketPath(alloc: Allocator) (Allocator.Error || PathError)![:0]const u8 {
    const uid = getUid();
    return getSocketPathForUid(alloc, uid);
}

/// Get the socket path for a specific UID.
pub fn getSocketPathForUid(alloc: Allocator, uid: u32) (Allocator.Error || PathError)![:0]const u8 {
    const dir = getSocketDir() orelse return PathError.NoSocketPath;

    // Format: {dir}/ghostty-{uid}.sock
    const path = try std.fmt.allocPrintZ(alloc, "{s}/ghostty-{d}.sock", .{ dir, uid });

    if (path.len >= max_path_len) {
        alloc.free(path);
        return PathError.PathTooLong;
    }

    return path;
}

/// Get the directory for socket files.
fn getSocketDir() ?[]const u8 {
    // On macOS, prefer TMPDIR
    if (comptime builtin.target.os.tag == .macos) {
        if (std.posix.getenv("TMPDIR")) |tmpdir| {
            // Remove trailing slash if present
            const dir = std.mem.trimRight(u8, tmpdir, "/");
            if (dir.len > 0) return dir;
        }
    }

    // On Linux, prefer XDG_RUNTIME_DIR
    if (comptime builtin.target.os.tag == .linux) {
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
            if (runtime_dir.len > 0) return runtime_dir;
        }
    }

    // Fall back to /tmp
    return "/tmp";
}

/// Get the current user's UID.
pub fn getUid() u32 {
    return c.getuid();
}

test "getSocketDir returns non-null" {
    const dir = getSocketDir();
    try std.testing.expect(dir != null);
}

test "getSocketPathForUid generates valid path" {
    const alloc = std.testing.allocator;
    const path = try getSocketPathForUid(alloc, 1000);
    defer alloc.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
    try std.testing.expect(std.mem.indexOf(u8, path, "ghostty-1000") != null);
}
