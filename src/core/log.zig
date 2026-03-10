// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Logging Module
//!
//! Provides file-based logging with configurable log levels.
//! HTTP threads submit log tasks to worker pool, workers buffer and write to file.
//! This ensures HTTP threads are never blocked by file I/O.

const std = @import("std");
const builtin = @import("builtin");
const worker_pool = @import("worker_pool.zig");

/// Log output destination
pub const LogOutput = enum {
    file,
    stderr,
};

/// Log configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    path: ?[]const u8 = null, // null = use OS default
    max_file_size_mb: i64 = 10, // rotate when file exceeds this size
    max_files: i64 = 5, // keep this many rotated files
    buffer_size: i64 = 8192, // buffer size in bytes before flush
    output: LogOutput = .stderr, // output destination
    flush_interval_ms: i64 = 1000, // auto-flush interval in milliseconds
};

/// Global log state
var log_file: ?std.fs.File = null;
var log_level: std.log.Level = .info;
var initialized: bool = false;
var log_allocator: ?std.mem.Allocator = null;
var log_output: LogOutput = .file;

/// Flush timer state
var flush_thread: ?std.Thread = null;
var flush_interval_ns: u64 = 1000 * std.time.ns_per_ms;
var shutdown_flush: bool = false;

/// Buffer state (only accessed by worker threads)
var buffer_mutex: std.Thread.Mutex = .{};
var log_buffer: std.ArrayList(u8) = .{};

/// Rotation config
var max_file_size: usize = 10 * 1024 * 1024;
var max_files: usize = 5;
var buffer_threshold: usize = 8192;
var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var log_path: []const u8 = "";

/// Context for log task submitted to worker pool
const LogTaskContext = struct {
    message: []u8,
    allocator: std.mem.Allocator,
};

/// Initialize logging with configuration
pub fn init(config: LogConfig, allocator: std.mem.Allocator) !void {
    log_level = config.level;
    log_allocator = allocator;
    log_output = config.output;

    // Set rotation config
    max_file_size = @intCast(@as(u64, @intCast(config.max_file_size_mb)) * 1024 * 1024);
    max_files = @intCast(config.max_files);
    buffer_threshold = @intCast(config.buffer_size);

    if (log_output == .file) {
        const path = config.path orelse getDefaultLogPath();

        // Store path for rotation
        @memcpy(log_path_buf[0..path.len], path);
        log_path = log_path_buf[0..path.len];

        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        // Open file in append mode
        log_file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |e| blk: {
            if (e == error.FileNotFound) {
                break :blk try std.fs.cwd().createFile(path, .{ .truncate = false });
            }
            return e;
        };

        // Seek to end for append mode
        if (log_file) |f| {
            f.seekFromEnd(0) catch {};
        }

        // Initialize buffer
        log_buffer = .{};

        initialized = true;

        // Write init message directly (worker pool may not be ready)
        writeDirectSync("Logging initialized: level={s}, path={s}", .{ @tagName(log_level), path });
    } else {
        // stderr mode - no file setup needed
        initialized = true;
        writeDirectSync("Logging initialized: level={s}, output=stderr", .{@tagName(log_level)});
    }

    // Start flush timer thread
    flush_interval_ns = @intCast(@as(u64, @intCast(config.flush_interval_ms)) * std.time.ns_per_ms);
    shutdown_flush = false;
    flush_thread = std.Thread.spawn(.{}, flushTimerLoop, .{}) catch null;
}

/// Flush timer thread loop
fn flushTimerLoop() void {
    while (!shutdown_flush) {
        std.Thread.sleep(flush_interval_ns);
        if (shutdown_flush) break;

        buffer_mutex.lock();
        defer buffer_mutex.unlock();
        flushBufferLocked();
    }
}

/// Deinitialize logging
pub fn deinit() void {
    // Stop flush timer thread
    shutdown_flush = true;
    if (flush_thread) |thread| {
        thread.join();
        flush_thread = null;
    }

    buffer_mutex.lock();
    defer buffer_mutex.unlock();

    // Flush remaining buffer
    flushBufferLocked();

    if (log_file) |f| {
        f.close();
        log_file = null;
    }

    if (log_allocator) |allocator| {
        log_buffer.deinit(allocator);
    }

    initialized = false;
    log_allocator = null;
}

/// Get default log path based on OS
fn getDefaultLogPath() []const u8 {
    const Static = struct {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    };

    if (builtin.os.tag == .macos) {
        const home = std.posix.getenv("HOME") orelse return "zig-zag.log";
        return std.fmt.bufPrint(
            &Static.path_buf,
            "{s}/Library/Logs/zig-zag/zig-zag.log",
            .{home},
        ) catch "zig-zag.log";
    } else if (builtin.os.tag == .linux) {
        if (std.posix.getenv("XDG_STATE_HOME")) |state_home| {
            return std.fmt.bufPrint(
                &Static.path_buf,
                "{s}/zig-zag/zig-zag.log",
                .{state_home},
            ) catch "zig-zag.log";
        }
        const home = std.posix.getenv("HOME") orelse return "zig-zag.log";
        return std.fmt.bufPrint(
            &Static.path_buf,
            "{s}/.local/state/zig-zag/zig-zag.log",
            .{home},
        ) catch "zig-zag.log";
    } else if (builtin.os.tag == .windows) {
        if (std.posix.getenv("LOCALAPPDATA")) |app_data| {
            return std.fmt.bufPrint(
                &Static.path_buf,
                "{s}\\zig-zag\\zig-zag.log",
                .{app_data},
            ) catch "zig-zag.log";
        }
        return "zig-zag.log";
    } else {
        return "zig-zag.log";
    }
}

/// Parse log level from string
pub fn parseLevel(level_str: []const u8) std.log.Level {
    if (std.mem.eql(u8, level_str, "err") or std.mem.eql(u8, level_str, "error")) {
        return .err;
    } else if (std.mem.eql(u8, level_str, "warn") or std.mem.eql(u8, level_str, "warning")) {
        return .warn;
    } else if (std.mem.eql(u8, level_str, "info")) {
        return .info;
    } else if (std.mem.eql(u8, level_str, "debug")) {
        return .debug;
    }
    return .info;
}

/// Get current timestamp as formatted string
fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: u64 = @intCast(ts);

    const epoch_day = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;

    const hours = day_secs / 3600;
    const minutes = (day_secs % 3600) / 60;
    const seconds = day_secs % 60;

    var days = epoch_day;
    var year: u32 = 1970;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const is_leap = isLeapYear(year);
    const days_in_months = if (is_leap)
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
        month += 1;
    }
    const day: u8 = @intCast(days + 1);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
    }) catch "????-??-?? ??:??:??";
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Write directly to file/stderr synchronously (used during init/deinit)
fn writeDirectSync(comptime format: []const u8, args: anytype) void {
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[{s}] [info] " ++ format ++ "\n", .{timestamp} ++ args) catch return;

    if (log_output == .stderr) {
        _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
    } else if (log_file) |f| {
        f.writeAll(msg) catch {};
    }
}

/// Flush buffer to file (must be called with buffer_mutex held)
fn flushBufferLocked() void {
    if (log_buffer.items.len == 0) return;

    if (log_output == .stderr) {
        _ = std.posix.write(std.posix.STDERR_FILENO, log_buffer.items) catch {};
    } else if (log_file) |f| {
        const stat = f.stat() catch return;
        if (stat.size + log_buffer.items.len > max_file_size) {
            rotateLogsLocked();
        }

        f.writeAll(log_buffer.items) catch {};
    }

    log_buffer.clearRetainingCapacity();
}

/// Rotate log files (must be called with buffer_mutex held)
fn rotateLogsLocked() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }

    var i: usize = max_files;
    while (i > 0) : (i -= 1) {
        var old_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var new_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        const old_path = if (i == 1)
            log_path
        else
            std.fmt.bufPrint(&old_path_buf, "{s}.{d}", .{ log_path, i - 1 }) catch continue;

        const new_path = std.fmt.bufPrint(&new_path_buf, "{s}.{d}", .{ log_path, i }) catch continue;

        if (i == max_files) {
            std.fs.cwd().deleteFile(new_path) catch {};
        }

        std.fs.cwd().rename(old_path, new_path) catch {};
    }

    log_file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch null;
}

/// Worker task: append message to buffer and flush if needed
fn logWorkerTask(ctx: *anyopaque) void {
    const task_ctx: *LogTaskContext = @ptrCast(@alignCast(ctx));
    defer {
        task_ctx.allocator.free(task_ctx.message);
        task_ctx.allocator.destroy(task_ctx);
    }

    buffer_mutex.lock();
    defer buffer_mutex.unlock();

    const allocator = log_allocator orelse return;

    log_buffer.appendSlice(allocator, task_ctx.message) catch return;

    if (log_buffer.items.len >= buffer_threshold) {
        flushBufferLocked();
    }
}

/// Core logging function - submits to worker pool, never blocks HTTP threads
fn logImpl(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) {
        return;
    }

    const allocator = log_allocator orelse return;

    const level_txt = comptime level.asText();
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Format the message
    const msg = std.fmt.allocPrint(allocator, "[{s}] [{s}] {s}" ++ format ++ "\n", .{ timestamp, level_txt, scope_prefix } ++ args) catch return;

    // Try to submit to worker pool
    if (worker_pool.getPool()) |_| {
        const task_ctx = allocator.create(LogTaskContext) catch {
            allocator.free(msg);
            return;
        };
        task_ctx.* = .{
            .message = msg,
            .allocator = allocator,
        };

        worker_pool.submit(logWorkerTask, task_ctx) catch {
            allocator.free(msg);
            allocator.destroy(task_ctx);
            return;
        };
    } else {
        // Fallback: write directly if worker pool not available
        if (log_output == .stderr) {
            _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
        } else if (log_file) |f| {
            f.writeAll(msg) catch {};
        }
        allocator.free(msg);
    }
}

/// Force flush the log buffer
pub fn flush() void {
    buffer_mutex.lock();
    defer buffer_mutex.unlock();
    flushBufferLocked();
}

/// Custom log function for std.log override
pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    logImpl(level, scope, format, args);
}

// ============================================================================
// Public logging functions
// ============================================================================

pub fn err(comptime format: []const u8, args: anytype) void {
    logImpl(.err, .default, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    logImpl(.warn, .default, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    logImpl(.info, .default, format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    logImpl(.debug, .default, format, args);
}

// ============================================================================
// Scoped logging
// ============================================================================

pub fn scoped(comptime scope: @TypeOf(.enum_literal)) type {
    return struct {
        pub fn err(comptime format: []const u8, args: anytype) void {
            logImpl(.err, scope, format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            logImpl(.warn, scope, format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            logImpl(.info, scope, format, args);
        }

        pub fn debug(comptime format: []const u8, args: anytype) void {
            logImpl(.debug, scope, format, args);
        }
    };
}
