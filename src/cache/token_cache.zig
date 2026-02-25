//! Global Token Cache
//!
//! Thread-safe cache for OAuth tokens, keyed by domain.
//! Tokens are cached until they expire (with a buffer).
//! Includes fetch mutex to prevent thundering herd problem.

const std = @import("std");
const log = @import("../log.zig");

/// Opaque handle returned by acquireFetchLock, must be passed to releaseFetchLock
pub const FetchLockHandle = *std.Thread.Mutex;

/// Cached token entry
pub const CachedToken = struct {
    access_token: []const u8,
    expires_at: i64, // Unix timestamp in seconds

    pub fn isValid(self: CachedToken, buffer_seconds: i64) bool {
        const now = @divTrunc(std.time.milliTimestamp(), 1000);
        return now < self.expires_at - buffer_seconds;
    }
};

/// Global token cache
var cache: ?std.StringHashMap(CachedToken) = null;
var cache_allocator: ?std.mem.Allocator = null;
var mutex: std.Thread.Mutex = .{};

/// Fetch mutexes per domain to prevent thundering herd
var fetch_mutexes: ?std.StringHashMap(*std.Thread.Mutex) = null;
var fetch_mutex_lock: std.Thread.Mutex = .{};

/// Initialize the global token cache
pub fn init(allocator: std.mem.Allocator) void {
    mutex.lock();
    defer mutex.unlock();

    if (cache == null) {
        cache = std.StringHashMap(CachedToken).init(allocator);
        fetch_mutexes = std.StringHashMap(*std.Thread.Mutex).init(allocator);
        cache_allocator = allocator;
        log.debug("Token cache initialized", .{});
    }
}

/// Deinitialize the global token cache
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |*c| {
        // Free all cached tokens and keys
        var iter = c.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |alloc| {
                alloc.free(entry.key_ptr.*);
                alloc.free(entry.value_ptr.access_token);
            }
        }
        c.deinit();
        cache = null;
    }

    // Free fetch mutexes
    if (fetch_mutexes) |*fm| {
        var iter = fm.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |alloc| {
                alloc.free(entry.key_ptr.*);
                alloc.destroy(entry.value_ptr.*);
            }
        }
        fm.deinit();
        fetch_mutexes = null;
    }

    cache_allocator = null;
    log.debug("Token cache deinitialized", .{});
}

/// Get a cached token if valid
/// Returns null if not found or expired
pub fn get(key: []const u8, expiry_buffer_seconds: i64) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |c| {
        if (c.get(key)) |token| {
            if (token.isValid(expiry_buffer_seconds)) {
                log.debug("Token cache hit for '{s}'", .{key});
                return token.access_token;
            } else {
                log.debug("Token cache expired for '{s}'", .{key});
            }
        }
    }
    return null;
}

/// Acquire fetch lock for a domain to prevent thundering herd
/// Only one thread can fetch a token for a given domain at a time
/// Returns a handle that MUST be passed to releaseFetchLock
pub fn acquireFetchLock(key: []const u8) !FetchLockHandle {
    const domain_mutex = blk: {
        fetch_mutex_lock.lock();
        defer fetch_mutex_lock.unlock();

        const alloc = cache_allocator orelse return error.CacheNotInitialized;
        var fm = &(fetch_mutexes orelse return error.CacheNotInitialized);

        if (fm.get(key)) |m| {
            break :blk m;
        }

        // Create new mutex for this domain
        const new_mutex = try alloc.create(std.Thread.Mutex);
        new_mutex.* = .{};

        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);

        try fm.put(key_copy, new_mutex);
        log.debug("Created fetch mutex for '{s}'", .{key});
        break :blk new_mutex;
    };

    // Now lock the domain-specific mutex (outside fetch_mutex_lock to avoid deadlock)
    domain_mutex.lock();
    return domain_mutex;
}

/// Release fetch lock using the handle returned by acquireFetchLock
/// This ensures the exact same mutex is unlocked, avoiding races with deinit
pub fn releaseFetchLock(handle: FetchLockHandle) void {
    handle.unlock();
}

/// Store a token in the cache
/// The token and key are duplicated, caller retains ownership of originals
pub fn put(key: []const u8, access_token: []const u8, expires_in_seconds: i64) !void {
    mutex.lock();
    defer mutex.unlock();

    const alloc = cache_allocator orelse return error.CacheNotInitialized;
    var c = &(cache orelse return error.CacheNotInitialized);

    const now = @divTrunc(std.time.milliTimestamp(), 1000);
    const expires_at = now + expires_in_seconds;

    // Check if key already exists
    if (c.getPtr(key)) |existing| {
        // Free old token and update
        alloc.free(existing.access_token);
        existing.access_token = try alloc.dupe(u8, access_token);
        existing.expires_at = expires_at;
        log.debug("Token cache updated for '{s}', expires in {d}s", .{ key, expires_in_seconds });
    } else {
        // New entry - duplicate both key and token
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);

        const token_copy = try alloc.dupe(u8, access_token);
        errdefer alloc.free(token_copy);

        try c.put(key_copy, .{
            .access_token = token_copy,
            .expires_at = expires_at,
        });
        log.debug("Token cache stored for '{s}', expires in {d}s", .{ key, expires_in_seconds });
    }
}

/// Remove a token from the cache
pub fn remove(key: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |*c| {
        if (c.fetchRemove(key)) |entry| {
            if (cache_allocator) |alloc| {
                alloc.free(entry.key);
                alloc.free(entry.value.access_token);
            }
            log.debug("Token cache removed for '{s}'", .{key});
        }
    }
}