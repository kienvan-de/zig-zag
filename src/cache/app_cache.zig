//! Generic App Cache
//!
//! Thread-safe key-value cache for app-level data.
//! Used for caching OIDC discovery configs and other non-sensitive data.
//!
//! Unlike token_cache, this cache:
//! - Has no expiry mechanism (data persists until explicitly removed or deinit)
//! - Has no fetch lock (no thundering herd protection needed)
//! - Stores arbitrary byte slices as values

const std = @import("std");
const log = @import("../log.zig");

/// Global app cache
var cache: ?std.StringHashMap([]const u8) = null;
var cache_allocator: ?std.mem.Allocator = null;
var mutex: std.Thread.Mutex = .{};

/// Initialize the global app cache
pub fn init(allocator: std.mem.Allocator) void {
    mutex.lock();
    defer mutex.unlock();

    if (cache == null) {
        cache = std.StringHashMap([]const u8).init(allocator);
        cache_allocator = allocator;
        log.debug("App cache initialized", .{});
    }
}

/// Deinitialize the global app cache
pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |*c| {
        // Free all cached values and keys
        var iter = c.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |alloc| {
                alloc.free(entry.key_ptr.*);
                alloc.free(entry.value_ptr.*);
            }
        }
        c.deinit();
        cache = null;
    }

    cache_allocator = null;
    log.debug("App cache deinitialized", .{});
}

/// Get a cached value
/// Returns a duplicated value that the caller must free, or null if not found
/// This prevents use-after-free if another thread modifies the cache concurrently
pub fn get(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |c| {
        if (c.get(key)) |value| {
            log.debug("App cache hit for '{s}'", .{key});
            // Return a copy to avoid use-after-free
            return allocator.dupe(u8, value) catch null;
        }
    }
    return null;
}

/// Store a value in the cache
/// The key and value are duplicated, caller retains ownership of originals
pub fn put(key: []const u8, value: []const u8) !void {
    mutex.lock();
    defer mutex.unlock();

    const alloc = cache_allocator orelse return error.CacheNotInitialized;
    var c = &(cache orelse return error.CacheNotInitialized);

    // Check if key already exists
    if (c.getPtr(key)) |existing| {
        // Free old value and update
        alloc.free(existing.*);
        existing.* = try alloc.dupe(u8, value);
        log.debug("App cache updated for '{s}'", .{key});
    } else {
        // New entry - duplicate both key and value
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);

        const value_copy = try alloc.dupe(u8, value);
        errdefer alloc.free(value_copy);

        try c.put(key_copy, value_copy);
        log.debug("App cache stored for '{s}'", .{key});
    }
}

/// Remove a value from the cache
pub fn remove(key: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |*c| {
        if (c.fetchRemove(key)) |entry| {
            if (cache_allocator) |alloc| {
                alloc.free(entry.key);
                alloc.free(entry.value);
            }
            log.debug("App cache removed for '{s}'", .{key});
        }
    }
}

/// Check if a key exists in the cache
pub fn contains(key: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();

    if (cache) |c| {
        return c.contains(key);
    }
    return false;
}
