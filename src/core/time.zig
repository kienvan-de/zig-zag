// SPDX-License-Identifier: Apache-2.0
//! Time utilities and I/O instance for zig-zag.
//!
//! All time and sleep operations go through the global `std.Io` instance so
//! they work cross-platform (macOS, Linux, Windows). The previous libc
//! clock_gettime / nanosleep implementation was POSIX-only.

const std = @import("std");

// ============================================================================
// Global I/O instance
// ============================================================================

/// A fully concurrent Threaded I/O instance.
/// Constructed via `std.Io.Threaded.init(allocator, .{})` which sets
/// `async_limit` to `cpu_count - 1` and spawns worker threads on demand.
/// This enables real concurrency through `io.async` / `io.concurrent` /
/// `Io.Group`, replacing the hand-rolled worker pool.
var global_io_instance: std.Io.Threaded = std.Io.Threaded.init_single_threaded;
var global_io_initialized: bool = false;

/// Initialize the global I/O backend with the given allocator.
/// `async_limit` caps the thread pool size (0 = default: cpu_count-1).
/// Safe to call multiple times; subsequent calls are no-ops.
pub fn init(allocator: std.mem.Allocator, environ: ?std.process.Environ, async_limit: usize) void {
    if (global_io_initialized) return;
    global_io_instance = std.Io.Threaded.init(allocator, .{
        .environ = environ orelse .empty,
        .async_limit = if (async_limit == 0) null else std.Io.Limit.limited(async_limit),
    });
    global_io_initialized = true;
}

/// Update the async thread limit after init. Takes effect immediately —
/// call after loading config so the configured pool size is applied.
/// Passing 0 leaves the limit unchanged.
pub fn setAsyncLimit(limit: usize) void {
    if (!global_io_initialized or limit == 0) return;
    global_io_instance.setAsyncLimit(std.Io.Limit.limited(limit));
}

/// Tear down the global I/O backend and reset it to a clean state.
/// Must be called before the allocator passed to init() is destroyed
/// (e.g. in lib.zig's serverThreadFn before the GPA is torn down).
/// Joins any worker threads spawned by Io.Threaded so the next startServer()
/// starts with no dangling threads or stale allocator references.
pub fn deinit() void {
    if (!global_io_initialized) return;
    global_io_instance.deinit();
    global_io_instance = std.Io.Threaded.init_single_threaded;
    global_io_initialized = false;
}

/// Get a usable `std.Io` instance for operations that require one.
/// If init() was not called, falls back to page_allocator (concurrent backend).
pub fn io() std.Io {
    if (!global_io_initialized) {
        global_io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
        global_io_initialized = true;
    }
    return global_io_instance.io();
}

// ============================================================================
// Cross-platform time — all via std.Io (works on macOS, Linux, Windows)
// ============================================================================

/// Returns the current wall-clock time as seconds since the Unix epoch.
pub fn timestamp() i64 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.toSeconds();
}

/// Returns the current wall-clock time as milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.toMilliseconds();
}

/// Returns the current wall-clock time as nanoseconds since the Unix epoch.
pub fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return @intCast(ts.nanoseconds);
}

/// Sleep for the given number of nanoseconds.
pub fn sleep(nanoseconds: u64) void {
    const duration = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = @intCast(nanoseconds) },
        .clock = .awake,
    };
    duration.sleep(io()) catch {};
}
