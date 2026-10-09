// SPDX-License-Identifier: Apache-2.0
//! Platform utilities: resolve absolute paths for external tools (curl).
//!
//! The dylib may run with an empty or stripped environment where $PATH does not
//! include /usr/bin, so bare tool names like "curl" fail to spawn. These helpers
//! probe a fixed candidate list and return the first path that exists, giving a
//! clear error log on failure instead of a silent downstream spawn failure.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");
const log = @import("log.zig");

pub const PlatformError = error{ToolNotFound};

/// Probe `candidates` in order and return an allocator-owned copy of the first
/// path that exists. Uses fs.cwd().openFile for cross-platform existence check
/// (no std.c.access / std.posix.toPosixPath which are POSIX-only).
/// Logs all tried paths on failure.
pub fn resolveToolPath(
    allocator: std.mem.Allocator,
    name: []const u8,
    candidates: []const []const u8,
) PlatformError![]const u8 {
    for (candidates) |path| {
        const f = fs.cwd().openFile(path, .{}) catch continue;
        f.close();
        return allocator.dupe(u8, path) catch return error.ToolNotFound;
    }
    log.warn("{s} not found; tried: {s}", .{ name, candidates[0] });
    for (candidates[1..]) |path| log.warn("  {s}", .{path});
    return error.ToolNotFound;
}

const CURL_CANDIDATES: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{
        "C:\\Windows\\System32\\curl.exe",       // inbox since Windows 10 1803
        "C:\\Program Files\\Git\\mingw64\\bin\\curl.exe", // Git for Windows
        "C:\\ProgramData\\chocolatey\\bin\\curl.exe",
    },
    else => &.{
        "/usr/bin/curl",
        "/usr/local/bin/curl",
        "/opt/homebrew/bin/curl",
    },
};

pub fn resolveCurl(allocator: std.mem.Allocator) PlatformError![]const u8 {
    return resolveToolPath(allocator, "curl", CURL_CANDIDATES);
}
