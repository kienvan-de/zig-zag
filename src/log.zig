//! Logging Module
//!
//! Provides file-based logging with configurable log levels.
//! Supports buffered writes and size-based log rotation.

const std = @import("std");
const builtin = @import("builtin");
const worker_pool = @import("worker_pool.zig");

/// Log configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    path: ?[]const u8 = null, // null = use OS default
    max_file_size_mb: i64 = 10, // rotate when file exceeds this size
    max_files: i64 = 5, // keep this many rotated files
    buffer_size: i64 = 100, // number of messages to buffer before flush
    flush_interval_ms: i64 = 1000, // auto-flush interval
};

/// Global log state
var log_file: ?std.fs.File = null;
var log_level: std.log.Level = .info;
var initialized: bool = false;
var log_mutex: std.Thread.Mutex = .{};
var log_allocator: ?std.mem.Allocator = null;

/// Buffering state
var log_buffer: std.ArrayList(u8) = .{};
var buffer_count: usize = 0;
var last_flush_time: i64 = 0;
var current_file_size: usize = 0;

/// Rotation config (set during init)
var max_file_size: usize = 10 * 1024 * 1024; // 10 MB default
var max_files: usize = 5;
var buffer_threshold: usize = 100;
var flush_interval_ms: i64 = 1000;
var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var log_path: []const u8 = "";

/// Initialize logging with configuration
pub fn init(config: LogConfig, allocator: std.mem.Allocator) !void {
    log_level = config.level;
    log_allocator = allocator;

    // Set rotation config
    max_file_size = @intCast(@as(u64, @intCast(config.max_file_size_mb)) * 1024 * 1024);
    max_files = @intCast(config.max_files);
    buffer_threshold = @intCast(config.buffer_size);
    flush_interval_ms = config.flush_interval_ms;

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

    // Seek to end for append mode and get current size
    if (log_file) |f| {
        const stat = try f.stat();
        current_file_size = stat.size;
        f.seekFromEnd(0) catch {};
    }

    // Initialize buffer
    log_buffer = .{};
    buffer_count = 0;
    last_flush_time = std.time.milliTimestamp();

    initialized = true;

    // Use sync write for init message since pool may not be ready
    writeSync("Logging initialized: level={s}, path={s}", .{ @tagName(log_level), path });
}

/// Deinitialize logging
pub fn deinit() void {
    log_mutex.lock();
    defer log_mutex.unlock();

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
    buffer_count = 0;
    current_file_size = 0;
}

/// Get default log path based on OS
fn getDefaultLogPath() []const u8 {
    // Use a static buffer for the path
    const Static = struct {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    };

    if (builtin.os.tag == .macos) {
        // macOS: ~/Library/Logs/zig-zag/zig-zag.log
        const home = std.posix.getenv("HOME") orelse return "zig-zag.log";
        return std.fmt.bufPrint(
            &Static.path_buf,
            "{s}/Library/Logs/zig-zag/zig-zag.log",
            .{home},
        ) catch "zig-zag.log";
    } else if (builtin.os.tag == .linux) {
        // Linux: /var/log/zig-zag/zig-zag.log or ~/.local/state/zig-zag/zig-zag.log
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
        // Windows: %LOCALAPPDATA%\zig-zag\zig-zag.log
        if (std.posix.getenv("LOCALAPPDATA")) |app_data| {
            return std.fmt.bufPrint(
                &Static.path_buf,
                "{s}\\zig-zag\\zig-zag.log",
                .{app_data},
            ) catch "zig-zag.log";
        }
        return "zig-zag.log";
    } else {
        // Fallback: current directory
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
    return .info; // default
}

/// Get current timestamp as formatted string
fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: u64 = @intCast(ts);

    // Convert to broken down time (UTC)
    const epoch_day = epoch_secs / 86400;
    const day_secs = epoch_secs % 86400;

    const hours = day_secs / 3600;
    const minutes = (day_secs % 3600) / 60;
    const seconds = day_secs % 60;

    // Calculate year/month/day from epoch days
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

/// Synchronous write to log file (used during init/deinit or when pool unavailable)
fn writeSync(comptime format: []const u8, args: anytype) void {
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[{s}] [info] " ++ format ++ "\n", .{timestamp} ++ args) catch return;

    if (log_file) |f| {
        log_mutex.lock();
        defer log_mutex.unlock();
        f.writeAll(msg) catch {};
        current_file_size += msg.len;
    } else {
        std.debug.print("{s}", .{msg});
    }
}

/// Flush buffer to file (must be called with log_mutex held)
fn flushBufferLocked() void {
    if (buffer_count == 0 or log_buffer.items.len == 0) return;

    if (log_file) |f| {
        // Check if rotation needed before writing
        if (current_file_size + log_buffer.items.len > max_file_size) {
            rotateLogsLocked();
        }

        f.writeAll(log_buffer.items) catch {};
        current_file_size += log_buffer.items.len;
    }

    log_buffer.clearRetainingCapacity();
    buffer_count = 0;
    last_flush_time = std.time.milliTimestamp();
}

/// Rotate log files (must be called with log_mutex held)
fn rotateLogsLocked() void {
    // Close current file
    if (log_file) |f| {
        f.close();
        log_file = null;
    }

    // Rotate existing files: .log.N -> .log.N+1, delete oldest
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
            // Delete oldest file
            std.fs.cwd().deleteFile(new_path) catch {};
        }

        // Rename old to new
        std.fs.cwd().rename(old_path, new_path) catch {};
    }

    // Create new log file
    log_file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch null;
    current_file_size = 0;
}

/// Check if flush is needed and flush if so (must be called with log_mutex held)
fn maybeFlushLocked() void {
    const now = std.time.milliTimestamp();
    const time_elapsed = now - last_flush_time;

    if (buffer_count >= buffer_threshold or time_elapsed >= flush_interval_ms) {
        flushBufferLocked();
    }
}

/// Append message to buffer (must be called with log_mutex held)
fn appendToBufferLocked(msg: []const u8) void {
    const allocator = log_allocator orelse return;
    log_buffer.appendSlice(allocator, msg) catch {
        // If buffer append fails, try direct write
        if (log_file) |f| {
            f.writeAll(msg) catch {};
            current_file_size += msg.len;
        }
        return;
    };
    buffer_count += 1;
    maybeFlushLocked();
}

/// Core logging function
fn logImpl(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Check log level
    if (@intFromEnum(level) > @intFromEnum(log_level)) {
        return;
    }

    const level_txt = comptime level.asText();
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Format the message
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[{s}] [{s}] {s}" ++ format ++ "\n", .{ timestamp, level_txt, scope_prefix } ++ args) catch return;

    // Use buffered write
    log_mutex.lock();
    defer log_mutex.unlock();

    if (initialized and log_allocator != null) {
        appendToBufferLocked(msg);
    } else {
        // Fallback: direct write if not initialized
        if (log_file) |f| {
            f.writeAll(msg) catch {};
            current_file_size += msg.len;
        } else {
            std.debug.print("{s}", .{msg});
        }
    }
}

/// Force flush the log buffer (public API for explicit flush)
pub fn flush() void {
    log_mutex.lock();
    defer log_mutex.unlock();
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
// Public logging functions (can be used directly without std.log)
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