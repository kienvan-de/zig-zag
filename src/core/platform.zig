// SPDX-License-Identifier: Apache-2.0
//! Platform utilities: resolve absolute paths for external tools (curl, tar).
//!
//! The dylib may run with an empty or stripped environment where $PATH does not
//! include /usr/bin, so bare tool names like "curl" fail to spawn. These helpers
//! probe a fixed candidate list and return the first path that exists, giving a
//! clear error log on failure instead of a silent downstream spawn failure.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

pub const PlatformError = error{ToolNotFound};

/// Probe `candidates` in order and return an allocator-owned copy of the first
/// path that exists and is accessible. Logs all tried paths on failure.
pub fn resolveToolPath(
    allocator: std.mem.Allocator,
    name: []const u8,
    candidates: []const []const u8,
) PlatformError![]const u8 {
    for (candidates) |path| {
        const path_c = std.posix.toPosixPath(path) catch continue;
        if (std.c.access(&path_c, std.posix.F_OK) == 0) {
            return allocator.dupe(u8, path) catch return error.ToolNotFound;
        }
    }
    log.warn("{s} not found; tried: {s}", .{ name, candidates[0] });
    for (candidates[1..]) |path| log.warn("  {s}", .{path});
    return error.ToolNotFound;
}

const CURL_CANDIDATES = [_][]const u8{
    "/usr/bin/curl",
    "/usr/local/bin/curl",
    "/opt/homebrew/bin/curl",
};

const TAR_CANDIDATES = [_][]const u8{
    "/usr/bin/tar",
    "/usr/local/bin/tar",
    "/opt/homebrew/bin/tar",
};

pub fn resolveCurl(allocator: std.mem.Allocator) PlatformError![]const u8 {
    return resolveToolPath(allocator, "curl", &CURL_CANDIDATES);
}

pub fn resolveTar(allocator: std.mem.Allocator) PlatformError![]const u8 {
    return resolveToolPath(allocator, "tar", &TAR_CANDIDATES);
}
