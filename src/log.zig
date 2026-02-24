//! Logging Module
//!
//! Provides file-based logging with configurable log levels.
//! Supports writing to file or stderr (default).

const std = @import("std");
const builtin = @import("builtin");

/// Log configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    path: ?[]const u8 = null, // null = use OS default
};

/// Global log state
var log_file: ?std.fs.File = null;
var log_level: std.log.Level = .info;
var initialized: bool = false;
var log_mutex: std.Thread.Mutex = .{};

/// Initialize logging with configuration
pub fn init(config: LogConfig) !void {
    log_level = config.level;

    const path = config.path orelse getDefaultLogPath();

    // Ensure parent directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    log_file = try std.fs.cwd().createFile(path, .{
        .truncate = false,
    });

    // Seek to end for append mode
    if (log_file) |f| {
        f.seekFromEnd(0) catch {};
    }

    initialized = true;

    info("Logging initialized: level={s}, path={s}", .{ @tagName(log_level), path });
}

/// Deinitialize logging
pub fn deinit() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
    initialized = false;
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

    // Format the message first
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "[{s}] [{s}] {s}" ++ format ++ "\n", .{ timestamp, level_txt, scope_prefix } ++ args) catch return;

    if (log_file) |f| {
        log_mutex.lock();
        defer log_mutex.unlock();
        f.writeAll(msg) catch {};
    } else {
        // Use std.debug for stderr output (Zig 0.15 compatible)
        std.debug.print("{s}", .{msg});
    }
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