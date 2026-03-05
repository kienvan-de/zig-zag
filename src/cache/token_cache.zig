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
    refresh_token: ?[]const u8,
    expires_at: i64, // Unix timestamp in seconds

    pub fn isValid(self: CachedToken, buffer_seconds: i64) bool {
        const now = @divTrunc(std.time.milliTimestamp(), 1000);
        return now < self.expires_at - buffer_seconds;
    }
};

/// Global token cache
var cache: ?std.StringHashMap(CachedToken) = null;
var cache_allocator: ?std.mem.Allocator = null;
var rwlock: std.Thread.RwLock = .{};

/// Fetch mutexes per domain to prevent thundering herd
var fetch_mutexes: ?std.StringHashMap(*std.Thread.Mutex) = null;
var fetch_mutex_lock: std.Thread.Mutex = .{};

/// Initialize the global token cache
pub fn init(allocator: std.mem.Allocator) void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache == null) {
        cache = std.StringHashMap(CachedToken).init(allocator);
        fetch_mutexes = std.StringHashMap(*std.Thread.Mutex).init(allocator);
        cache_allocator = allocator;
        log.debug("Token cache initialized", .{});
    }
}

/// Deinitialize the global token cache
pub fn deinit() void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache) |*c| {
        // Free all cached tokens and keys
        var iter = c.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |a| {
                a.free(entry.key_ptr.*);
                a.free(entry.value_ptr.access_token);
                if (entry.value_ptr.refresh_token) |rt| a.free(rt);
            }
        }
        c.deinit();
        cache = null;
    }

    // Free fetch mutexes
    if (fetch_mutexes) |*fm| {
        var iter = fm.iterator();
        while (iter.next()) |entry| {
            if (cache_allocator) |a| {
                a.free(entry.key_ptr.*);
                a.destroy(entry.value_ptr.*);
            }
        }
        fm.deinit();
        fetch_mutexes = null;
    }

    cache_allocator = null;
    log.debug("Token cache deinitialized", .{});
}

/// Result of getting a cached token
pub const GetResult = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,

    pub fn deinit(self: *GetResult, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        if (self.refresh_token) |rt| allocator.free(rt);
        self.* = undefined;
    }
};

/// Get a cached token if valid
/// Returns duplicated tokens that the caller must free, or null if not found/expired
/// Uses shared lock — multiple readers can access concurrently
pub fn get(allocator: std.mem.Allocator, key: []const u8, expiry_buffer_seconds: i64) ?GetResult {
    rwlock.lockShared();
    defer rwlock.unlockShared();

    if (cache) |c| {
        if (c.get(key)) |token| {
            if (token.isValid(expiry_buffer_seconds)) {
                log.debug("Token cache hit for '{s}'", .{key});
                // Return copies so caller is safe after lock release
                const access_token = allocator.dupe(u8, token.access_token) catch return null;
                const refresh_token = if (token.refresh_token) |rt|
                    allocator.dupe(u8, rt) catch {
                        allocator.free(access_token);
                        return null;
                    }
                else
                    null;
                return .{
                    .access_token = access_token,
                    .refresh_token = refresh_token,
                };
            } else {
                log.debug("Token cache expired for '{s}'", .{key});
            }
        }
    }
    return null;
}

/// Get refresh token even if access token is expired
/// Used for token refresh flow
/// Uses shared lock — multiple readers can access concurrently
pub fn getRefreshToken(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    rwlock.lockShared();
    defer rwlock.unlockShared();

    if (cache) |c| {
        if (c.get(key)) |token| {
            if (token.refresh_token) |rt| {
                log.debug("Token cache refresh_token found for '{s}'", .{key});
                return allocator.dupe(u8, rt) catch null;
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
/// Uses exclusive lock — blocks all readers and other writers
pub fn put(key: []const u8, access_token: []const u8, refresh_token: ?[]const u8, expires_in_seconds: i64) !void {
    rwlock.lock();
    defer rwlock.unlock();

    const a = cache_allocator orelse return error.CacheNotInitialized;
    var c = &(cache orelse return error.CacheNotInitialized);

    const now = @divTrunc(std.time.milliTimestamp(), 1000);
    const expires_at = now + expires_in_seconds;

    // Check if key already exists
    if (c.getPtr(key)) |existing| {
        // Free old tokens and update
        a.free(existing.access_token);
        if (existing.refresh_token) |rt| a.free(rt);

        existing.access_token = try a.dupe(u8, access_token);
        existing.refresh_token = if (refresh_token) |rt| try a.dupe(u8, rt) else null;
        existing.expires_at = expires_at;
        log.debug("Token cache updated for '{s}', expires in {d}s", .{ key, expires_in_seconds });
    } else {
        // New entry - duplicate key and tokens
        const key_copy = try a.dupe(u8, key);
        errdefer a.free(key_copy);

        const access_token_copy = try a.dupe(u8, access_token);
        errdefer a.free(access_token_copy);

        const refresh_token_copy = if (refresh_token) |rt| try a.dupe(u8, rt) else null;

        try c.put(key_copy, .{
            .access_token = access_token_copy,
            .refresh_token = refresh_token_copy,
            .expires_at = expires_at,
        });
        log.debug("Token cache stored for '{s}', expires in {d}s", .{ key, expires_in_seconds });
    }
}

/// Remove a token from the cache
/// Uses exclusive lock — blocks all readers and other writers
pub fn remove(key: []const u8) void {
    rwlock.lock();
    defer rwlock.unlock();

    if (cache) |*c| {
        if (c.fetchRemove(key)) |entry| {
            if (cache_allocator) |a| {
                a.free(entry.key);
                a.free(entry.value.access_token);
                if (entry.value.refresh_token) |rt| a.free(rt);
            }
            log.debug("Token cache removed for '{s}'", .{key});
        }
    }
}
