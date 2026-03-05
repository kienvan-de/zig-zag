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
var rwlock: std.Thread.RwLock = .{};

/// Initialize the global app cache
pub fn init(allocator: std.mem.Allocator) void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache == null) {
        cache = std.StringHashMap([]const u8).init(allocator);
        cache_allocator = allocator;
        log.debug("App cache initialized", .{});
    }
}

/// Deinitialize the global app cache
pub fn deinit() void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache) |*c| {
        // Free all cached values and keys
        var iter = c.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |a| {
                a.free(entry.key_ptr.*);
                a.free(entry.value_ptr.*);
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
/// Uses shared lock — multiple readers can access concurrently
pub fn get(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    rwlock.lockShared();
    defer rwlock.unlockShared();

    if (cache) |c| {
        if (c.get(key)) |value| {
            log.debug("App cache hit for '{s}'", .{key});
            // Return a copy so caller is safe after lock release
            return allocator.dupe(u8, value) catch null;
        }
    }
    return null;
}

/// Store a value in the cache
/// Uses exclusive lock — blocks all readers and other writers
pub fn put(key: []const u8, value: []const u8) !void {
    rwlock.lock();
    defer rwlock.unlock();

    const a = cache_allocator orelse return error.CacheNotInitialized;
    var c = &(cache orelse return error.CacheNotInitialized);

    // Check if key already exists
    if (c.getPtr(key)) |existing| {
        // Free old value and update
        a.free(existing.*);
        existing.* = try a.dupe(u8, value);
        log.debug("App cache updated for '{s}'", .{key});
    } else {
        // New entry - duplicate both key and value
        const key_copy = try a.dupe(u8, key);
        errdefer a.free(key_copy);

        const value_copy = try a.dupe(u8, value);
        errdefer a.free(value_copy);

        try c.put(key_copy, value_copy);
        log.debug("App cache stored for '{s}'", .{key});
    }
}

/// Remove a value from the cache
/// Uses exclusive lock — blocks all readers and other writers
pub fn remove(key: []const u8) void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache) |*c| {
        if (c.fetchRemove(key)) |entry| {
            if (cache_allocator) |a| {
                a.free(entry.key);
                a.free(entry.value);
            }
            log.debug("App cache removed for '{s}'", .{key});
        }
    }
}

/// Check if a key exists in the cache
/// Uses shared lock — multiple readers can check concurrently
pub fn contains(key: []const u8) bool {
    rwlock.lockShared();
    defer rwlock.unlockShared();

    if (cache) |c| {
        return c.contains(key);
    }
    return false;
}
