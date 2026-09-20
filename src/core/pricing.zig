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

const std = @import("std");
const sync = @import("sync.zig");
const config_mod = @import("config.zig");

pub const ModelRate = config_mod.ModelRate;

// ============================================================================
// Global state
// ============================================================================

var rates_map: std.StringHashMap(ModelRate) = undefined;
var rates_lock: sync.RwLock = .{};
var rates_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;

// ============================================================================
// Public API
// ============================================================================

pub fn init(allocator: std.mem.Allocator) void {
    rates_alloc = allocator;
    rates_map = std.StringHashMap(ModelRate).init(allocator);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    rates_lock.lock();
    defer rates_lock.unlock();
    freeMap();
    initialized = false;
}

/// Replace the entire rates map from the current config. Thread-safe.
pub fn loadFromConfig(cfg: *const config_mod.Config) void {
    if (!initialized) return;

    // Build a new map outside the lock to minimise lock hold time.
    var new_map = std.StringHashMap(ModelRate).init(rates_alloc);
    var it = cfg.rates.iterator();
    while (it.next()) |entry| {
        const duped = rates_alloc.dupe(u8, entry.key_ptr.*) catch continue;
        new_map.put(duped, entry.value_ptr.*) catch {
            rates_alloc.free(duped);
            continue;
        };
    }

    rates_lock.lock();
    defer rates_lock.unlock();
    freeMap();
    rates_map = new_map;
}

/// Look up the rate for a provider/model pair. Returns null if not configured.
/// Thread-safe: uses a shared read lock.
pub fn getRate(provider_name: []const u8, model: []const u8) ?ModelRate {
    if (!initialized) return null;

    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ provider_name, model }) catch return null;

    rates_lock.lockShared();
    defer rates_lock.unlockShared();
    return rates_map.get(key);
}

// ============================================================================
// Private helpers
// ============================================================================

fn freeMap() void {
    var kit = rates_map.keyIterator();
    while (kit.next()) |k| rates_alloc.free(k.*);
    rates_map.deinit();
}
