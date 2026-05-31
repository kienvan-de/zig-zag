// SPDX-License-Identifier: Apache-2.0
//! Time utilities and I/O instance for zig-zag.
//!
//! Replaces the removed `std.time.timestamp`, `std.time.milliTimestamp`,
//! and `std.time.nanoTimestamp` from Zig 0.16 using libc clock_gettime.
//! Also provides a global `std.Io` instance for operations that require one
//! (process spawning, HTTP client, etc.).

const std = @import("std");

// ============================================================================
// Global I/O instance
// ============================================================================

/// A properly initialized Threaded I/O instance with a real allocator.
/// Unlike `std.Io.Threaded.global_single_threaded` (which uses `.failing`
/// allocator), this instance supports process spawning and other operations
/// that need memory allocation.
var global_io_instance: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
var global_io_initialized: bool = false;

/// Get a usable `std.Io` instance for operations that require one.
/// This uses `page_allocator` internally (suitable for short-lived I/O ops
/// like process spawning, HTTP client connections, etc.).
pub fn io() std.Io {
    if (!global_io_initialized) {
        global_io_instance.allocator = std.heap.page_allocator;
        global_io_initialized = true;
    }
    return global_io_instance.io();
}

/// Returns the current time as seconds since the Unix epoch.
/// Equivalent to the old std.time.timestamp().
pub fn timestamp() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Returns the current time as milliseconds since the Unix epoch.
/// Equivalent to the old std.time.milliTimestamp().
pub fn milliTimestamp() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Returns the current time as nanoseconds since the Unix epoch.
/// Equivalent to the old std.time.nanoTimestamp().
pub fn nanoTimestamp() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

/// Sleep for the given number of nanoseconds.
/// Equivalent to the old std.Thread.sleep().
pub fn sleep(nanoseconds: u64) void {
    const sec: isize = @intCast(nanoseconds / 1_000_000_000);
    const nsec: isize = @intCast(nanoseconds % 1_000_000_000);
    const req = std.posix.timespec{ .sec = sec, .nsec = nsec };
    _ = std.c.nanosleep(&req, null);
}
