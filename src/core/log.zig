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

//! Logging Facade
//!
//! Thin interface for structured logging. Core modules call `err`, `warn`,
//! `info`, `debug` without knowing the backend. The wrapper injects a
//! concrete sink via `setSink()` at startup.
//!
//! Default sink writes to stderr — works with zero configuration.

const std = @import("std");

/// Sink function signature — receives a fully-formatted log line (with trailing newline).
pub const SinkFn = *const fn ([]const u8) void;

/// Pluggable sink — set by the wrapper during init.
var sink: SinkFn = &stderrSink;

/// Current log level filter.
var log_level: std.log.Level = .info;

// ============================================================================
// Configuration
// ============================================================================

/// Register a log sink (called by the wrapper at startup).
pub fn setSink(s: SinkFn) void {
    sink = s;
}

/// Reset to the default stderr sink.
pub fn resetSink() void {
    sink = &stderrSink;
}

/// Set the minimum log level.
pub fn setLevel(level: std.log.Level) void {
    log_level = level;
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

// ============================================================================
// Internal
// ============================================================================

/// Core logging function — level check, format to stack buffer, call sink.
fn logImpl(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) {
        return;
    }

    const level_txt = comptime level.asText();
    const scope_prefix = comptime if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{s}] [{s}] {s}" ++ format ++ "\n", .{ timestamp, level_txt, scope_prefix } ++ args) catch |e| switch (e) {
        error.NoSpaceLeft => blk: {
            // Message too long — write what fits with truncation marker
            const truncated = "[truncated]\n";
            @memcpy(buf[buf.len - truncated.len ..], truncated);
            break :blk &buf;
        },
    };

    sink(msg);
}

/// Default sink — write to stderr.
fn stderrSink(msg: []const u8) void {
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
}

/// Get current timestamp as formatted string.
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
