// SPDX-License-Identifier: Apache-2.0
//! Filesystem utilities for zig-zag.
//!
//! Replaces the removed `std.fs.cwd().openFile/createFile/deleteFile/makePath/rename`
//! from Zig 0.16 using libc POSIX APIs. These do NOT require an `io: std.Io` parameter.
//!
//! Usage:
//!   const fs = @import("fs.zig");  // or core.fs from wrapper layer
//!   const file = fs.cwd().openFile(path, .{}) catch |err| { ... };
//!   defer file.close();
//!   const data = try file.readToEndAlloc(allocator, max_size);

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const max_path_bytes = std.fs.max_path_bytes;

/// Read all content from a file descriptor into allocated memory (up to max_bytes).
/// Useful for reading stdout/stderr from child processes.
pub fn readFdAlloc(allocator: std.mem.Allocator, fd: posix.fd_t, max_bytes: usize) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (result.items.len < max_bytes) {
        const n = posix.read(fd, &buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return error.ReadFailed;
        };
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return result.toOwnedSlice(allocator);
}

/// A file handle wrapping a POSIX fd.
pub const File = struct {
    fd: posix.fd_t,

    pub fn close(self: File) void {
        _ = c.close(self.fd);
    }

    /// Read all file content into an allocated buffer (up to max_bytes).
    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var buf: [8192]u8 = undefined;
        while (result.items.len < max_bytes) {
            const n = posix.read(self.fd, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                return error.ReadFailed;
            };
            if (n == 0) break;
            try result.appendSlice(allocator, buf[0..n]);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Write all data to the file.
    pub fn writeAll(self: File, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = c.write(self.fd, remaining.ptr, remaining.len);
            if (n <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(n)..];
        }
    }

    /// Stat the file to get its size.
    pub fn stat(self: File) !Stat {
        var s: std.c.Stat = undefined;
        if (std.c.fstat(self.fd, &s) < 0) return error.StatFailed;
        return .{ .size = @intCast(s.size) };
    }

    /// Seek to a position relative to the end of the file.
    pub fn seekFromEnd(self: File, offset: i64) !void {
        _ = std.c.lseek(self.fd, @intCast(offset), std.c.SEEK.END);
    }

    /// Read into a fixed buffer (non-allocating). Returns bytes read.
    pub fn readAll(self: File, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = posix.read(self.fd, buf[total..]) catch |err| {
                if (err == error.WouldBlock) continue;
                return error.ReadFailed;
            };
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub const Stat = struct {
        size: u64,
    };
};

/// Options for openFile (matches the old std.fs API shape).
pub const OpenFileOptions = struct {
    mode: Mode = .read_only,

    pub const Mode = enum {
        read_only,
        write_only,
    };
};

/// Options for createFile.
pub const CreateFileOptions = struct {
    truncate: bool = true,
};

/// A directory handle (for cwd pattern).
pub const Dir = struct {
    dir_ptr: ?*c.DIR = null,
    path: ?[]const u8 = null,

    /// Open a file relative to this directory.
    pub fn openFile(self: Dir, file_path: []const u8, options: OpenFileOptions) !File {
        _ = self;
        return openFileImpl(file_path, options.mode == .write_only, false);
    }

    /// Create a file for writing relative to this directory.
    pub fn createFile(self: Dir, file_path: []const u8, options: CreateFileOptions) !File {
        _ = self;
        return openFileImpl(file_path, true, options.truncate);
    }

    /// Delete a file (prepends dir path if available).
    pub fn deleteFile(self: Dir, file_path: []const u8) !void {
        var path_buf: [max_path_bytes]u8 = undefined;
        var full_path: []const u8 = file_path;
        if (self.path) |dir_path| {
            full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, file_path }) catch return error.PathTooLong;
        }
        var unlink_buf: [max_path_bytes]u8 = undefined;
        const path_z = toNullTerminated(full_path, &unlink_buf) orelse return error.PathTooLong;
        if (c.unlink(path_z) < 0) return error.DeleteFailed;
    }

    /// Create all directories in path (like mkdir -p).
    pub fn makePath(self: Dir, dir_path: []const u8) !void {
        _ = self;
        var path_buf: [max_path_bytes]u8 = undefined;
        if (dir_path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..dir_path.len], dir_path);
        path_buf[dir_path.len] = 0;

        var i: usize = 1;
        while (i <= dir_path.len) : (i += 1) {
            if (i == dir_path.len or path_buf[i] == '/') {
                const saved = path_buf[i];
                path_buf[i] = 0;
                const dir_z: [*:0]const u8 = path_buf[0..i :0];
                _ = c.mkdir(dir_z, 0o755);
                path_buf[i] = saved;
            }
        }
    }

    /// Rename a file.
    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        _ = self;
        var old_buf: [max_path_bytes]u8 = undefined;
        var new_buf: [max_path_bytes]u8 = undefined;
        const old_z = toNullTerminated(old_path, &old_buf) orelse return error.PathTooLong;
        const new_z = toNullTerminated(new_path, &new_buf) orelse return error.PathTooLong;
        if (c.rename(old_z, new_z) < 0) return error.RenameFailed;
    }

    /// Open a subdirectory with opendir for iteration.
    pub fn openDir(self: Dir, sub_path: []const u8, options: anytype) !Dir {
        _ = self;
        _ = options;
        var path_buf: [max_path_bytes]u8 = undefined;
        const path_z = toNullTerminated(sub_path, &path_buf) orelse return error.PathTooLong;
        const dp = c.opendir(path_z) orelse return error.FileNotFound;
        return .{ .dir_ptr = dp, .path = sub_path };
    }

    /// Close the directory (only needed for directories opened with openDir).
    pub fn close(self: *Dir) void {
        if (self.dir_ptr) |dp| {
            _ = c.closedir(dp);
            self.dir_ptr = null;
        }
    }

    /// Iterate directory entries.
    pub fn iterate(self: *Dir) Iterator {
        return .{ .dir_ptr = self.dir_ptr };
    }

    /// Read a file's entire content (convenience).
    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, file_path: []const u8, max_bytes: usize) ![]u8 {
        const file = try self.openFile(file_path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, max_bytes);
    }

    /// Get the realpath of a relative path (allocates).
    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
        _ = self;
        var path_buf: [max_path_bytes]u8 = undefined;
        const path_z = toNullTerminated(rel_path, &path_buf) orelse return error.PathTooLong;
        var resolved_buf: [max_path_bytes]u8 = undefined;
        const result_ptr = c.realpath(path_z, &resolved_buf) orelse return error.FileNotFound;
        const result = std.mem.sliceTo(result_ptr, 0);
        return try allocator.dupe(u8, result);
    }

    /// Directory entry from iteration.
    pub const Entry = struct {
        name: []const u8,
        kind: Kind,

        pub const Kind = enum {
            file,
            directory,
            other,
        };
    };

    /// Directory iterator.
    pub const Iterator = struct {
        dir_ptr: ?*c.DIR,
        name_buf: [1024]u8 = undefined,

        pub fn next(self: *Iterator) !?Entry {
            const dp = self.dir_ptr orelse return null;
            while (true) {
                const entry = c.readdir(dp) orelse return null;
                const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
                const name = std.mem.sliceTo(name_ptr, 0);
                // Skip . and ..
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                // Copy name to stable buffer
                if (name.len >= self.name_buf.len) continue;
                @memcpy(self.name_buf[0..name.len], name);
                const kind: Entry.Kind = switch (entry.type) {
                    8 => .file, // DT_REG
                    4 => .directory, // DT_DIR
                    else => .other,
                };
                return .{ .name = self.name_buf[0..name.len], .kind = kind };
            }
        }
    };
};

/// Returns the current working directory handle (matches old std.fs.cwd() API).
pub fn cwd() Dir {
    return Dir{};
}

/// Open a file by absolute path (matches old std.fs.openFileAbsolute).
pub fn openFileAbsolute(path: []const u8, options: OpenFileOptions) !File {
    return openFileImpl(path, options.mode == .write_only, false);
}

// ============================================================================
// Private helpers
// ============================================================================

fn openFileImpl(path: []const u8, write_mode: bool, truncate: bool) !File {
    var path_buf: [max_path_bytes]u8 = undefined;
    const path_z = toNullTerminated(path, &path_buf) orelse return error.PathTooLong;
    const flags: c.O = if (write_mode)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = truncate }
    else
        .{ .ACCMODE = .RDONLY };
    const mode: c.mode_t = if (write_mode) 0o644 else 0;
    const fd = c.open(path_z, flags, mode);
    if (fd < 0) return error.FileNotFound;
    return .{ .fd = fd };
}

fn toNullTerminated(path: []const u8, buf: *[max_path_bytes]u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}
