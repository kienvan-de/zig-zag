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

//! Smart Routing — ordered model fallback groups with stable API key aliases.
//!
//! Each group has an `api_key` (e.g. "my-claude") that clients use as the model ID.
//! Requests arriving for a known api_key are transparently routed to `current_model`,
//! with automatic rollover to alternatives on retryable errors.
//!
//! Groups without an api_key are ignored for routing (and excluded from /v1/models).
//!
//! Thread-safety: each RouteGroup has its own mutex guarding `current_model`.
//! The global singleton is guarded by `g_mutex` for init/reload only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const openai_common = @import("providers/openai/types.zig");

// ============================================================================
// Data structures
// ============================================================================

pub const RouteGroup = struct {
    name: []const u8, // borrowed from _parsed JSON tree
    api_key: []const u8, // borrowed from _parsed; empty = excluded from routing
    enabled: bool,
    main_model: []const u8, // borrowed from _parsed JSON tree
    alternatives: []const []const u8, // heap-alloc'd slice; strings borrowed from _parsed
    current_model: []u8, // heap-allocated mutable copy; freed by deinit
    mutex: sync.Mutex = .{},

    fn deinit(self: *RouteGroup, allocator: Allocator) void {
        allocator.free(self.current_model);
        allocator.free(self.alternatives);
    }
};

pub const SmartRouting = struct {
    allocator: Allocator,
    groups: []RouteGroup,
    index: std.StringHashMap(*RouteGroup), // api_key -> *RouteGroup (only groups with non-empty api_key)
    _parsed: std.json.Parsed(std.json.Value), // owns all borrowed strings

    /// Parse `smart_routing` from a raw JSON config string.
    /// Returns null if the key is absent. Caller must call deinit().
    pub fn parse(allocator: Allocator, raw_json: []const u8) !?SmartRouting {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
        errdefer parsed.deinit();

        if (parsed.value != .object) return null;
        const root_obj = parsed.value.object;

        const sr_value = root_obj.get("smart_routing") orelse {
            parsed.deinit();
            return null;
        };
        if (sr_value != .array) {
            parsed.deinit();
            return null;
        }

        const items = sr_value.array.items;
        const groups = try allocator.alloc(RouteGroup, items.len);
        var groups_init: usize = 0;
        errdefer {
            for (groups[0..groups_init]) |*g| g.deinit(allocator);
            allocator.free(groups);
        }

        for (items, 0..) |item, i| {
            if (item != .object) {
                log.warn("[smart_routing] group[{d}] is not an object, skipping", .{i});
                groups[groups_init] = .{
                    .name = "",
                    .api_key = "",
                    .enabled = false,
                    .main_model = "",
                    .alternatives = &.{},
                    .current_model = try allocator.dupe(u8, ""),
                };
                groups_init += 1;
                continue;
            }
            const obj = item.object;

            const name = if (obj.get("name")) |v| (if (v == .string) v.string else "") else "";
            const api_key = if (obj.get("api_key")) |v| (if (v == .string) v.string else "") else "";
            const enabled = if (obj.get("enabled")) |v| (if (v == .bool) v.bool else true) else true;
            const main_model = if (obj.get("main_model")) |v| (if (v == .string) v.string else "") else "";
            const current_model_str = if (obj.get("current_model")) |v| (if (v == .string) v.string else main_model) else main_model;

            // Parse alternatives array
            var alts: []const []const u8 = &.{};
            errdefer if (alts.len > 0) allocator.free(alts);
            if (obj.get("alternatives")) |alts_val| {
                if (alts_val == .array) {
                    const alt_items = alts_val.array.items;
                    const alt_slice = try allocator.alloc([]const u8, alt_items.len);
                    errdefer allocator.free(alt_slice); // Bug #2 fix: free on any error below
                    var alt_count: usize = 0;
                    for (alt_items) |alt_item| {
                        if (alt_item == .string) {
                            alt_slice[alt_count] = alt_item.string;
                            alt_count += 1;
                        }
                    }
                    alts = alt_slice[0..alt_count];
                    if (alt_count < alt_items.len) {
                        // Shrink to only valid entries — reallocate to exact size
                        const trimmed = try allocator.alloc([]const u8, alt_count);
                        @memcpy(trimmed, alts);
                        allocator.free(alt_slice);
                        alts = trimmed;
                    }
                }
            }

            groups[groups_init] = .{
                .name = name,
                .api_key = api_key,
                .enabled = enabled,
                .main_model = main_model,
                .alternatives = alts,
                .current_model = try allocator.dupe(u8, current_model_str),
            };
            groups_init += 1;
            alts = &.{}; // transferred to group — disarm outer errdefer
        }

        // Build lookup index: api_key -> *RouteGroup (skip groups with empty api_key)
        var index = std.StringHashMap(*RouteGroup).init(allocator);
        errdefer index.deinit();
        for (groups[0..groups_init]) |*g| {
            if (g.api_key.len > 0) {
                try index.put(g.api_key, g);
            }
        }

        return SmartRouting{
            .allocator = allocator,
            .groups = groups[0..groups_init],
            .index = index,
            ._parsed = parsed,
        };
    }

    pub fn deinit(self: *SmartRouting) void {
        for (self.groups) |*g| g.deinit(self.allocator);
        self.allocator.free(self.groups);
        self.index.deinit();
        self._parsed.deinit();
    }

    /// Look up a group by api_key. Returns null if not found or disabled.
    pub fn lookup(self: *SmartRouting, model: []const u8) ?*RouteGroup {
        const g = self.index.get(model) orelse return null;
        if (!g.enabled) return null;
        return g;
    }

    /// Return a slice of Model entries for all groups that have a non-empty api_key.
    /// Caller owns the returned slice and must free it with freeGroupModels().
    pub fn listGroupModels(self: *SmartRouting, allocator: Allocator) ![]openai_common.Model {
        var list = std.ArrayList(openai_common.Model).empty;
        defer list.deinit(allocator);
        for (self.groups) |*g| {
            if (g.api_key.len == 0) continue;
            try list.append(allocator, openai_common.Model{
                .id = g.api_key,
                .object = "model",
                .created = 0,
                .owned_by = "zig-zag",
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Free the slice returned by listGroupModels.
    pub fn freeGroupModels(allocator: Allocator, models: []openai_common.Model) void {
        allocator.free(models);
    }

    /// Return a heap-allocated copy of the group's current_model. Caller frees.
    pub fn getCurrentModel(self: *SmartRouting, group: *RouteGroup, allocator: Allocator) ![]u8 {
        _ = self;
        group.mutex.lock();
        defer group.mutex.unlock();
        return allocator.dupe(u8, group.current_model);
    }

    /// Advance current_model to the next alternative.
    /// Returns a heap-allocated copy of the new model string (caller frees),
    /// or null if all alternatives are exhausted.
    pub fn rollover(self: *SmartRouting, group: *RouteGroup, allocator: Allocator) !?[]u8 {
        _ = self;
        group.mutex.lock();
        defer group.mutex.unlock();

        const cur = group.current_model;

        // Find position of current_model in the full chain [main_model, alt0, alt1, ...]
        // If current == main_model, next is alternatives[0]
        // If current == alternatives[i], next is alternatives[i+1]
        if (std.mem.eql(u8, cur, group.main_model)) {
            if (group.alternatives.len == 0) return null;
            const next = group.alternatives[0];
            const new_cur = try allocator.dupe(u8, next);
            const ret = allocator.dupe(u8, next) catch |e| { allocator.free(new_cur); return e; };
            allocator.free(group.current_model);
            group.current_model = new_cur;
            return @as(?[]u8, ret);
        }

        for (group.alternatives, 0..) |alt, i| {
            if (std.mem.eql(u8, cur, alt)) {
                const next_idx = i + 1;
                if (next_idx >= group.alternatives.len) return null; // exhausted
                const next = group.alternatives[next_idx];
                const new_cur = try allocator.dupe(u8, next);
                const ret = allocator.dupe(u8, next) catch |e| { allocator.free(new_cur); return e; };
                allocator.free(group.current_model);
                group.current_model = new_cur;
                return @as(?[]u8, ret);
            }
        }

        // current_model not found in chain (stale state after config rename) — reset to main_model
        if (group.main_model.len == 0) return null;
        const next = group.main_model;
        const new_cur = try allocator.dupe(u8, next);
        const ret = allocator.dupe(u8, next) catch |e| { allocator.free(new_cur); return e; };
        allocator.free(group.current_model);
        group.current_model = new_cur;
        return @as(?[]u8, ret);
    }

    /// Reset a group's current_model back to main_model and persist to config.
    pub fn resetGroup(self: *SmartRouting, group: *RouteGroup, allocator: Allocator) !void {
        {
            // Allocate before locking so OOM never holds the mutex
            const new_model = try allocator.dupe(u8, group.main_model);
            group.mutex.lock();
            defer group.mutex.unlock();
            allocator.free(group.current_model);
            group.current_model = new_model;
        }
        try self.writeBack(allocator);
    }

    /// Persist current_model values for all groups back to config.json.
    /// Reads the raw JSON, patches each group's "current_model" field, writes back.
    pub fn writeBack(self: *SmartRouting, allocator: Allocator) !void {
        g_config_mutex.lock();
        defer g_config_mutex.unlock();
        const raw = config_mod.readRaw(allocator) catch |err| {
            log.err("[smart_routing] writeBack: failed to read config: {}", .{err});
            return err;
        };
        defer allocator.free(raw);

        const patched = patchCurrentModels(allocator, raw, self.groups) catch |err| {
            log.err("[smart_routing] writeBack: failed to patch JSON: {}", .{err});
            return err;
        };
        defer allocator.free(patched);

        config_mod.writeRaw(allocator, patched) catch |err| {
            log.err("[smart_routing] writeBack: failed to write config: {}", .{err});
            return err;
        };

        log.info("[smart_routing] Persisted current_model for {d} group(s)", .{self.groups.len});
    }
};

/// Patch the "current_model" field in each smart_routing array entry.
/// Re-serialises only the smart_routing array; everything else is kept verbatim
/// by rebuilding the full JSON object with std.json.Value manipulation.
fn patchCurrentModels(allocator: Allocator, raw_json: []const u8, groups: []RouteGroup) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfigFormat;

    const sr_value = parsed.value.object.get("smart_routing") orelse return error.InvalidConfigFormat;
    if (sr_value != .array) return error.InvalidConfigFormat;

    const items = sr_value.array.items;
    const count = @min(items.len, groups.len);

    // Collect heap copies so we can free them after stringification (bug #10 fix)
    var copies = try allocator.alloc([]u8, count);
    var n_copies: usize = 0;
    defer {
        // Only free the n_copies entries that were actually initialised — freeing
        // the full `count` slots would call free() on uninitialised memory when
        // some items are skipped via `continue` below.
        for (copies[0..n_copies]) |c| allocator.free(c);
        allocator.free(copies);
    }

    for (0..count) |i| {
        if (items[i] != .object) continue;
        // Read current_model under the per-group mutex to avoid a data race with
        // concurrent rollover() / resetGroup() calls.
        groups[i].mutex.lock();
        const cur_copy = allocator.dupe(u8, groups[i].current_model) catch |e| {
            groups[i].mutex.unlock();
            return e;
        };
        groups[i].mutex.unlock();
        copies[n_copies] = cur_copy;
        n_copies += 1;
        try items[i].object.put(allocator, "current_model", std.json.Value{ .string = cur_copy });
    }

    // Stringify the patched tree
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// API key derivation
// ============================================================================

/// Derive a valid api_key from a group name.
/// Rules: lowercase, replace any char not in [a-z0-9_] with '-',
/// collapse consecutive '-' runs, strip leading/trailing '-'.
/// Caller owns the returned slice.
pub fn deriveApiKey(allocator: Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return allocator.dupe(u8, "");

    var buf = try allocator.alloc(u8, name.len);
    errdefer allocator.free(buf);

    var len: usize = 0;
    var last_was_dash = false;
    for (name) |c| {
        const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9') or lc == '_') {
            buf[len] = lc;
            len += 1;
            last_was_dash = false;
        } else if (!last_was_dash) {
            buf[len] = '-';
            len += 1;
            last_was_dash = true;
        }
    }
    // Strip trailing dash
    while (len > 0 and buf[len - 1] == '-') len -= 1;
    // Strip leading dash
    var start: usize = 0;
    while (start < len and buf[start] == '-') start += 1;

    const result = try allocator.dupe(u8, buf[start..len]);
    allocator.free(buf);
    return result;
}

// ============================================================================
// Global singleton
// ============================================================================

var g_routing: ?SmartRouting = null;
// RwLock: shared (read) for callers of acquire(); exclusive (write) for init/reload.
// This prevents use-after-free: reload() blocks until all in-flight handles release.
var g_rwlock: sync.RwLock = .{};
// Stored once at init() time; reload() always uses this stable allocator so
// deinit() of the previous SmartRouting never touches a freed arena.
// Read and written only while holding g_rwlock exclusive.
var g_allocator: ?Allocator = null;
// Serialises the readRaw/patchCurrentModels/writeRaw triple in writeBack() so
// concurrent rollovers and config saves cannot interleave file writes.
// Separate from g_rwlock to avoid a deadlock: callers hold g_rwlock shared
// while calling writeBack(), so writeBack() must not acquire g_rwlock exclusive.
var g_config_mutex: sync.Mutex = .{};

/// RAII guard returned by acquire(). Holds the shared read-lock for its lifetime.
/// Call release() (or defer handle.release()) when done with the SmartRouting pointer.
pub const SmartRoutingHandle = struct {
    sr: *SmartRouting,

    pub fn release(self: SmartRoutingHandle) void {
        _ = self;
        g_rwlock.unlockShared();
    }
};

/// Initialise the global smart routing state from raw config JSON.
/// Called once at server startup. Safe to call again (replaces state).
pub fn init(allocator: Allocator, raw_json: []const u8) void {
    g_rwlock.lock();
    defer g_rwlock.unlock();
    initLocked(allocator, raw_json);
}

/// Reload after a config save. Always uses the allocator from the initial
/// init() call so the previous SmartRouting is freed with the correct allocator,
/// not the per-request arena that triggered the save.
pub fn reload(raw_json: []const u8) void {
    g_rwlock.lock();
    defer g_rwlock.unlock();
    const allocator = g_allocator orelse {
        log.warn("[smart_routing] reload: skipped (not yet initialised)", .{});
        return;
    };
    initLocked(allocator, raw_json);
}

/// Must be called with g_rwlock held exclusively.
fn initLocked(allocator: Allocator, raw_json: []const u8) void {
    // g_allocator written under exclusive lock — no TOCTOU.
    g_allocator = allocator;

    const maybe_new = SmartRouting.parse(allocator, raw_json) catch |err| {
        log.err("[smart_routing] init: parse failed: {}", .{err});
        if (g_routing) |*old| old.deinit();
        g_routing = null;
        return;
    };

    // Preserve in-memory current_model values across reloads so a stale UI save
    // (with pre-failover current_model in its body) does not revert failover state.
    if (maybe_new) |*new_sr| {
        if (g_routing) |*old_sr| {
            for (new_sr.groups) |*new_g| {
                if (new_g.api_key.len == 0) continue;
                const old_g = old_sr.index.get(new_g.api_key) orelse continue;
                old_g.mutex.lock();
                const preserved = allocator.dupe(u8, old_g.current_model) catch {
                    old_g.mutex.unlock();
                    continue;
                };
                old_g.mutex.unlock();
                allocator.free(new_g.current_model);
                new_g.current_model = preserved;
            }
        }
    }

    if (g_routing) |*old| old.deinit();
    g_routing = maybe_new;

    if (g_routing) |sr| {
        log.info("[smart_routing] Loaded {d} group(s), {d} routable", .{ sr.groups.len, sr.index.count() });
    }
}

/// Acquire a read-lock on the global SmartRouting and return a RAII handle.
/// Returns null if smart routing is not initialised or has no groups configured.
/// The caller MUST call handle.release() (typically via defer) when done.
/// The handle prevents concurrent reload() from freeing the SmartRouting.
pub fn acquire() ?SmartRoutingHandle {
    g_rwlock.lockShared();
    if (g_routing) |*sr| {
        return SmartRoutingHandle{ .sr = sr };
    }
    g_rwlock.unlockShared();
    return null;
}
