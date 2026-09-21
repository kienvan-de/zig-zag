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

//! Global metrics tracking for the zig-zag proxy server.
//!
//! Token usage is tracked in a two-layer map (provider → model → TokenUsage),
//! which is the single source of truth for token counts and cost calculations.
//! Network I/O and process stats (memory, CPU) use atomic counters.
//! All state is persisted to ~/.config/zig-zag/metrics.json on shutdown.

const std = @import("std");
const fs = @import("fs.zig");
const time = @import("time.zig");
const builtin = @import("builtin");
const env = @import("env.zig");
const log = @import("log.zig");

// ============================================================================
// Network I/O Counters (atomics — no per-model breakdown needed)
// ============================================================================

/// Total bytes received from clients
var network_rx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total bytes sent to clients
var network_tx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Budget period start timestamp (seconds since epoch). 0 = not set.
var period_start: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

// ============================================================================
// Per-provider/model token usage map
// ============================================================================

/// Token usage breakdown for a provider+model pair.
pub const TokenUsage = struct {
    input: u64 = 0,
    cache_write: u64 = 0,
    cache_read: u64 = 0,
    output: u64 = 0,
};

/// Per-provider usage snapshot (for reporting).
pub const ProviderUsage = struct {
    provider: []const u8,
    models: []ModelUsage,
};

/// Per-model usage snapshot entry (model name + counts).
pub const ModelUsage = struct {
    model: []const u8,
    usage: TokenUsage,
};

var usage_map: std.StringHashMap(std.StringHashMap(TokenUsage)) = undefined;
var usage_map_lock: @import("sync.zig").RwLock = .{};
var usage_map_alloc: std.mem.Allocator = undefined;
var usage_map_initialized: bool = false;

// ============================================================================
// Public API - Counters
// ============================================================================

/// Increment the cumulative network receive counter by the given number of bytes.
///
/// Called from the HTTP server layer each time data is read from a client connection.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addNetworkRx(bytes: u64) void {
    _ = network_rx_bytes.fetchAdd(bytes, .monotonic);
}

/// Increment the cumulative network transmit counter by the given number of bytes.
///
/// Called from the HTTP server layer each time data is written to a client connection.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addNetworkTx(bytes: u64) void {
    _ = network_tx_bytes.fetchAdd(bytes, .monotonic);
}

/// Reset token counters and the per-model usage map for the new budget period.
///
/// Called by `utils.checkAndResetBudgetPeriod()` when the budget period configured in
/// `cost_controls.days_duration` has expired. Zeroes all `TokenUsage` entries in
/// `usage_map` (values zeroed, keys kept) and advances `period_start`.
///
/// Network I/O counters are **not** affected.
pub fn resetCosts() void {
    // Acquire the usage map write lock first so map zeroing and period_start update
    // are atomic with respect to recordUsage.
    if (usage_map_initialized) {
        usage_map_lock.lock();
        var outer = usage_map.iterator();
        while (outer.next()) |provider_entry| {
            var inner = provider_entry.value_ptr.iterator();
            while (inner.next()) |model_entry| {
                model_entry.value_ptr.* = .{};
            }
        }
        period_start.store(time.timestamp(), .monotonic);
        usage_map_lock.unlock();
    } else {
        period_start.store(time.timestamp(), .monotonic);
    }
}

/// Return the budget period start timestamp as seconds since the Unix epoch.
///
/// A return value of `0` means the period has never been initialised — callers
/// (e.g. `utils.checkAndResetBudgetPeriod`) should treat this as "period starts now"
/// and call `resetCosts()` to anchor the timestamp.
/// Thread-safe: uses an atomic load with monotonic ordering.
pub fn getPeriodStart() i64 {
    return period_start.load(.monotonic);
}

/// Initialize the per-provider/model usage map. Must be called once at startup.
pub fn initUsageMap(allocator: std.mem.Allocator) void {
    usage_map_alloc = allocator;
    usage_map = std.StringHashMap(std.StringHashMap(TokenUsage)).init(allocator);
    usage_map_initialized = true;
}

/// Deinitialize the usage map, freeing all keys and nested maps.
pub fn deinitUsageMap() void {
    if (!usage_map_initialized) return;
    var outer = usage_map.iterator();
    while (outer.next()) |provider_entry| {
        var inner = provider_entry.value_ptr.iterator();
        while (inner.next()) |model_entry| {
            usage_map_alloc.free(model_entry.key_ptr.*);
        }
        provider_entry.value_ptr.deinit();
        usage_map_alloc.free(provider_entry.key_ptr.*);
    }
    usage_map.deinit();
    usage_map_initialized = false;
}

/// Record token usage for a provider+model pair. Thread-safe.
/// Updates usage_map under write lock.
pub fn recordUsage(
    provider_name: []const u8,
    model: []const u8,
    input: u64,
    cache_write: u64,
    cache_read: u64,
    output: u64,
) void {
    if (!usage_map_initialized) return;

    usage_map_lock.lock();
    defer usage_map_lock.unlock();

    // Get or create the inner map for this provider.
    const provider_result = usage_map.getOrPut(provider_name) catch return;
    if (!provider_result.found_existing) {
        const key = usage_map_alloc.dupe(u8, provider_name) catch {
            _ = usage_map.remove(provider_name);
            return;
        };
        provider_result.key_ptr.* = key;
        provider_result.value_ptr.* = std.StringHashMap(TokenUsage).init(usage_map_alloc);
    }
    const inner = provider_result.value_ptr;

    // Get or create the TokenUsage entry for this model.
    const model_result = inner.getOrPut(model) catch return;
    if (!model_result.found_existing) {
        const key = usage_map_alloc.dupe(u8, model) catch {
            _ = inner.remove(model);
            return;
        };
        model_result.key_ptr.* = key;
        model_result.value_ptr.* = .{};
    }
    const entry = model_result.value_ptr;
    entry.input += input;
    entry.cache_write += cache_write;
    entry.cache_read += cache_read;
    entry.output += output;
}

/// Look up token usage for a single provider+model pair.
/// Returns a copy of the TokenUsage (or null if not found). Thread-safe, no allocation.
pub fn getModelUsage(provider_name: []const u8, model: []const u8) ?TokenUsage {
    if (!usage_map_initialized) return null;
    usage_map_lock.lockShared();
    defer usage_map_lock.unlockShared();
    const inner = usage_map.get(provider_name) orelse return null;
    return inner.get(model);
}

/// Iterate all provider+model usage entries under a shared read lock.
/// The callback receives (ctx, provider, model, usage) and must not block or allocate.
pub fn iterateUsage(ctx: anytype, comptime cb: fn (@TypeOf(ctx), []const u8, []const u8, TokenUsage) void) void {
    if (!usage_map_initialized) return;
    usage_map_lock.lockShared();
    defer usage_map_lock.unlockShared();
    var outer = usage_map.iterator();
    while (outer.next()) |provider_entry| {
        var inner = provider_entry.value_ptr.iterator();
        while (inner.next()) |model_entry| {
            cb(ctx, provider_entry.key_ptr.*, model_entry.key_ptr.*, model_entry.value_ptr.*);
        }
    }
}

/// Snapshot the usage map into an owned slice of ProviderUsage.
/// Caller must free with freeUsageSnapshot.
pub fn snapshotUsageByProvider(allocator: std.mem.Allocator) ![]ProviderUsage {
    if (!usage_map_initialized) return &.{};

    usage_map_lock.lockShared();
    defer usage_map_lock.unlockShared();

    var providers = std.ArrayList(ProviderUsage).empty;
    errdefer {
        for (providers.items) |p| {
            allocator.free(p.models);
            allocator.free(p.provider);
        }
        providers.deinit(allocator);
    }

    var outer = usage_map.iterator();
    while (outer.next()) |provider_entry| {
        const provider_name = try allocator.dupe(u8, provider_entry.key_ptr.*);
        errdefer allocator.free(provider_name);

        var models = std.ArrayList(ModelUsage).empty;
        errdefer {
            for (models.items) |m| allocator.free(m.model);
            models.deinit(allocator);
        }

        var inner = provider_entry.value_ptr.iterator();
        while (inner.next()) |model_entry| {
            try models.append(allocator, .{
                .model = try allocator.dupe(u8, model_entry.key_ptr.*),
                .usage = model_entry.value_ptr.*,
            });
        }

        try providers.append(allocator, .{
            .provider = provider_name,
            .models = try models.toOwnedSlice(allocator),
        });
    }

    return providers.toOwnedSlice(allocator);
}

/// Free a snapshot returned by snapshotUsageByProvider.
pub fn freeUsageSnapshot(allocator: std.mem.Allocator, snapshot_slice: []ProviderUsage) void {
    for (snapshot_slice) |p| {
        for (p.models) |m| allocator.free(m.model);
        allocator.free(p.models);
        allocator.free(p.provider);
    }
    allocator.free(snapshot_slice);
}

// ============================================================================
// Process Stats from OS
// ============================================================================

/// task_vm_info struct for getting phys_footprint (what `top` shows as MEM).
/// We only need the first few fields up to phys_footprint.
const TaskVmInfo = extern struct {
    virtual_size: u64,
    region_count: i32,
    page_size: i32,
    resident_size: u64,
    resident_size_peak: u64,
    device: u64,
    device_peak: u64,
    internal: u64,
    internal_peak: u64,
    external: u64,
    external_peak: u64,
    reusable: u64,
    reusable_peak: u64,
    purgeable_volatile_pmap: u64,
    purgeable_volatile_resident: u64,
    purgeable_volatile_virtual: u64,
    compressed: u64,
    compressed_peak: u64,
    compressed_lifetime: u64,
    phys_footprint: u64, // This is what `top` shows as MEM
};

const TASK_VM_INFO: i32 = 22;

/// Get process stats (memory footprint and CPU time) from OS.
/// - macOS: Mach task_info for phys_footprint (like `top` MEM), getrusage for CPU time
/// - Linux: /proc/self/statm for RSS, getrusage for CPU time
/// - Windows: GetProcessTimes + K32GetProcessMemoryInfo
/// - Other POSIX: falls back to getrusage (peak RSS, CPU time)
fn getProcessStats() struct { memory_bytes: u64, cpu_time_us: u64 } {
    if (builtin.os.tag == .macos) {
        const c = std.c;
        var memory_bytes: u64 = 0;
        var cpu_time_us: u64 = 0;

        // Memory: phys_footprint via TASK_VM_INFO (matches `top` MEM column)
        var vm_info: TaskVmInfo = std.mem.zeroes(TaskVmInfo);
        var vm_count: c.mach_msg_type_number_t = @sizeOf(TaskVmInfo) / @sizeOf(u32);
        const vm_result = c.task_info(
            c.mach_task_self(),
            TASK_VM_INFO,
            @ptrCast(&vm_info),
            &vm_count,
        );
        if (vm_result == 0) {
            memory_bytes = vm_info.phys_footprint;
        }

        // CPU time via getrusage(RUSAGE_SELF) — same source as the Linux path.
        // NOTE: do NOT use MACH_TASK_BASIC_INFO here: since macOS 26 the kernel
        // reports 0 user/system time through that flavor (verified empirically),
        // which made the menu-bar CPU read-out permanently 0%. getrusage returns
        // the correct aggregate on every macOS version.
        var usage: std.posix.rusage = undefined;
        const ru_result = std.posix.system.getrusage(std.posix.system.rusage.SELF, &usage);
        if (ru_result == 0) {
            const user_us: u64 = @intCast(usage.utime.sec * 1_000_000 + usage.utime.usec);
            const system_us: u64 = @intCast(usage.stime.sec * 1_000_000 + usage.stime.usec);
            cpu_time_us = user_us + system_us;
        }

        return .{ .memory_bytes = memory_bytes, .cpu_time_us = cpu_time_us };
    } else if (builtin.os.tag == .linux) {
        // Linux: Read /proc/self/statm for RSS
        var memory_bytes: u64 = 0;
        if (fs.openFileAbsolute("/proc/self/statm", .{})) |file| {
            defer file.close();
            var buf: [128]u8 = undefined;
            if (file.readAll(&buf)) |bytes_read| {
                const content = buf[0..bytes_read];
                var iter = std.mem.splitScalar(u8, content, ' ');
                _ = iter.next(); // skip size
                if (iter.next()) |rss_pages_str| {
                    if (std.fmt.parseInt(u64, rss_pages_str, 10)) |rss_pages| {
                        memory_bytes = rss_pages * std.heap.pageSize();
                    } else |_| {}
                }
            } else |_| {}
        } else |_| {}

        // Use rusage for CPU time
        var usage: std.posix.rusage = undefined;
        const result = std.posix.system.getrusage(std.posix.system.rusage.SELF, &usage);
        var cpu_time_us: u64 = 0;
        if (result == 0) {
            const user_us: u64 = @intCast(usage.utime.sec * 1_000_000 + usage.utime.usec);
            const system_us: u64 = @intCast(usage.stime.sec * 1_000_000 + usage.stime.usec);
            cpu_time_us = user_us + system_us;
        }

        return .{ .memory_bytes = memory_bytes, .cpu_time_us = cpu_time_us };
    } else if (builtin.os.tag == .windows) {
        // Windows: GetProcessTimes for CPU time, K32GetProcessMemoryInfo for the
        // working set (closest user-mode equivalent of RSS/footprint). Both are
        // declared locally to avoid depending on std internals.
        const win = struct {
            const ProcessMemoryCounters = extern struct {
                cb: u32,
                page_fault_count: u32,
                peak_working_set_size: usize,
                working_set_size: usize,
                quota_peak_paged_pool_usage: usize,
                quota_paged_pool_usage: usize,
                quota_peak_non_paged_pool_usage: usize,
                quota_non_paged_pool_usage: usize,
                pagefile_usage: usize,
                peak_pagefile_usage: usize,
            };
            extern "kernel32" fn GetCurrentProcess() callconv(.c) std.os.windows.HANDLE;
            extern "kernel32" fn GetProcessTimes(
                process: std.os.windows.HANDLE,
                creation: *std.os.windows.FILETIME,
                exit: *std.os.windows.FILETIME,
                kernel: *std.os.windows.FILETIME,
                user: *std.os.windows.FILETIME,
            ) callconv(.c) c_int; // BOOL
            extern "kernel32" fn K32GetProcessMemoryInfo(
                process: std.os.windows.HANDLE,
                counters: *ProcessMemoryCounters,
                cb: u32,
            ) callconv(.c) c_int; // BOOL
        };

        var memory_bytes: u64 = 0;
        var cpu_time_us: u64 = 0;
        const handle = win.GetCurrentProcess();

        // CPU time: user + system, both FILETIME (100 ns units)
        var creation: std.os.windows.FILETIME = undefined;
        var exit_time: std.os.windows.FILETIME = undefined;
        var kernel_time: std.os.windows.FILETIME = undefined;
        var user_time: std.os.windows.FILETIME = undefined;
        if (win.GetProcessTimes(handle, &creation, &exit_time, &kernel_time, &user_time) != 0) {
            const filetime_us = struct {
                fn f(t: std.os.windows.FILETIME) u64 {
                    const raw = (@as(u64, t.dwHighDateTime) << 32) | @as(u64, t.dwLowDateTime);
                    return raw / 10; // 100 ns -> µs
                }
            }.f;
            cpu_time_us = filetime_us(kernel_time) + filetime_us(user_time);
        }

        var pmc: win.ProcessMemoryCounters = std.mem.zeroes(win.ProcessMemoryCounters);
        pmc.cb = @sizeOf(win.ProcessMemoryCounters);
        if (win.K32GetProcessMemoryInfo(handle, &pmc, pmc.cb) != 0) {
            memory_bytes = pmc.working_set_size;
        }

        return .{ .memory_bytes = memory_bytes, .cpu_time_us = cpu_time_us };
    } else {
        // Other POSIX (FreeBSD, ...): rusage. Note maxrss units vary by platform
        // (bytes on FreeBSD, KiB on NetBSD/OpenBSD) — Linux and macOS are handled above.
        var usage: std.posix.rusage = undefined;
        const result = std.posix.system.getrusage(std.posix.system.rusage.SELF, &usage);
        if (result != 0) {
            return .{ .memory_bytes = 0, .cpu_time_us = 0 };
        }

        const user_us: u64 = @intCast(usage.utime.sec * 1_000_000 + usage.utime.usec);
        const system_us: u64 = @intCast(usage.stime.sec * 1_000_000 + usage.stime.usec);

        return .{
            .memory_bytes = @intCast(@max(0, usage.maxrss)),
            .cpu_time_us = user_us + system_us,
        };
    }
}

// ============================================================================
// Snapshot for stats reporting
// ============================================================================

/// A point-in-time capture of every tracked metric.
///
/// Returned by `snapshot()` and consumed by the macOS menu-bar app (via C FFI).
/// Token totals are derived by iterating usage_map under a shared read lock.
/// Network and process stats are read from atomic counters.
pub const Snapshot = struct {
    /// Memory footprint of the process in bytes.
    /// macOS: `phys_footprint` from `TASK_VM_INFO` (matches the `top` MEM column).
    /// Linux: RSS from `/proc/self/statm`.
    /// Windows: working set from `K32GetProcessMemoryInfo`.
    memory_bytes: u64,
    /// Total CPU time (user + system) consumed by the process, in **microseconds**.
    cpu_time_us: u64,
    /// Cumulative bytes received from downstream clients since the process started.
    network_rx_bytes: u64,
    /// Cumulative bytes sent to downstream clients since the process started.
    network_tx_bytes: u64,
/// Cumulative input (prompt) tokens across all LLM requests in the current budget period.
    input_tokens: u64,
    /// Cumulative output (completion) tokens across all LLM requests in the current budget period.
    output_tokens: u64,
    /// Cumulative cache read tokens in the current budget period.
    cache_read_tokens: u64,
    /// Cumulative cache write tokens in the current budget period.
    cache_write_tokens: u64,
};

/// Capture a point-in-time `Snapshot` of all tracked metrics.
/// Token totals are derived by iterating `usage_map` under a shared read lock.
/// Process stats (RSS, CPU) are obtained from the OS.
pub fn snapshot() Snapshot {
    const process_stats = getProcessStats();

    var input: u64 = 0;
    var output: u64 = 0;
    var cache_read: u64 = 0;
    var cache_write: u64 = 0;

    if (usage_map_initialized) {
        usage_map_lock.lockShared();
        defer usage_map_lock.unlockShared();
        var outer = usage_map.iterator();
        while (outer.next()) |provider_entry| {
            var inner = provider_entry.value_ptr.iterator();
            while (inner.next()) |model_entry| {
                const u = model_entry.value_ptr.*;
                input       += u.input;
                output      += u.output;
                cache_read  += u.cache_read;
                cache_write += u.cache_write;
            }
        }
    }

    return .{
        .memory_bytes     = process_stats.memory_bytes,
        .cpu_time_us      = process_stats.cpu_time_us,
        .network_rx_bytes = network_rx_bytes.load(.monotonic),
        .network_tx_bytes = network_tx_bytes.load(.monotonic),
        .input_tokens     = input,
        .output_tokens    = output,
        .cache_read_tokens  = cache_read,
        .cache_write_tokens = cache_write,
    };
}

// ============================================================================
// Persistence — load/save accumulated metrics to ~/.config/zig-zag/metrics.json
// ============================================================================

const METRICS_FILENAME = "metrics.json";

fn getMetricsPath(buf: []u8) ?[]const u8 {
    if (env.get("ZIG_ZAG_METRICS")) |p| return p;
    const home = env.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zig-zag/{s}", .{ home, METRICS_FILENAME }) catch null;
}

/// Load persisted metrics from `~/.config/zig-zag/metrics.json`.
///
/// Restores `usage_map` (provider → model → TokenUsage) and `period_start`.
/// Must be called after `initUsageMap` and before `checkBudgetPeriodOnStartup`.
pub fn load() void {
    if (!usage_map_initialized) return;

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = getMetricsPath(&path_buf) orelse return;

    const file = fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug("No persisted metrics file, starting fresh", .{}),
            else => log.warn("Failed to open metrics file: {}", .{err}),
        }
        return;
    };
    defer file.close();

    // Read up to 1 MiB — usage maps with many models can be large.
    const content = file.readToEndAlloc(usage_map_alloc, 1024 * 1024) catch |err| {
        log.warn("Failed to read metrics file: {}", .{err});
        return;
    };
    defer usage_map_alloc.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, usage_map_alloc, content, .{}) catch |err| {
        log.warn("Failed to parse metrics file: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    // Restore period_start
    if (root.object.get("period_start")) |v| {
        if (v == .integer) period_start.store(v.integer, .monotonic);
    }

    // Restore usage map
    const usage_val = root.object.get("usage") orelse return;
    if (usage_val != .object) return;

    var total_input: u64 = 0;
    var total_output: u64 = 0;
    var provider_iter = usage_val.object.iterator();
    while (provider_iter.next()) |provider_entry| {
        const provider_name = provider_entry.key_ptr.*;
        if (provider_entry.value_ptr.* != .object) continue;

        var model_iter = provider_entry.value_ptr.object.iterator();
        while (model_iter.next()) |model_entry| {
            const model_name = model_entry.key_ptr.*;
            if (model_entry.value_ptr.* != .object) continue;
            const obj = model_entry.value_ptr.object;

            var usage = TokenUsage{};
            if (obj.get("input"))       |v| { if (v == .integer and v.integer >= 0) usage.input       = @intCast(v.integer); }
            if (obj.get("cache_write")) |v| { if (v == .integer and v.integer >= 0) usage.cache_write = @intCast(v.integer); }
            if (obj.get("cache_read"))  |v| { if (v == .integer and v.integer >= 0) usage.cache_read  = @intCast(v.integer); }
            if (obj.get("output"))      |v| { if (v == .integer and v.integer >= 0) usage.output      = @intCast(v.integer); }

            // Insert into usage_map (write lock not needed — called before server starts)
            const provider_result = usage_map.getOrPut(provider_name) catch continue;
            if (!provider_result.found_existing) {
                const key = usage_map_alloc.dupe(u8, provider_name) catch continue;
                provider_result.key_ptr.* = key;
                provider_result.value_ptr.* = std.StringHashMap(TokenUsage).init(usage_map_alloc);
            }
            const inner = provider_result.value_ptr;
            const model_result = inner.getOrPut(model_name) catch continue;
            if (!model_result.found_existing) {
                const key = usage_map_alloc.dupe(u8, model_name) catch continue;
                model_result.key_ptr.* = key;
            }
            model_result.value_ptr.* = usage;
            total_input  += usage.input;
            total_output += usage.output;
        }
    }

    log.info("Loaded persisted metrics: in_tokens={d}, out_tokens={d}, period_start={d}", .{
        total_input, total_output, period_start.load(.monotonic),
    });
}

/// Persist `usage_map` and `period_start` to `~/.config/zig-zag/metrics.json`.
/// Format: `{"period_start": N, "usage": {"provider": {"model": {input, cache_write, cache_read, output}}}}`
/// Atomic write: temp file + rename.
pub fn persist() void {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = getMetricsPath(&path_buf) orelse return;

    // Build JSON into a dynamic buffer — map size is unbounded.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(usage_map_alloc);

    buf.print(usage_map_alloc, "{{\"period_start\":{d},\"usage\":{{", .{period_start.load(.monotonic)}) catch return;

    if (usage_map_initialized) {
        usage_map_lock.lockShared();
        defer usage_map_lock.unlockShared();

        var first_provider = true;
        var outer = usage_map.iterator();
        while (outer.next()) |provider_entry| {
            if (!first_provider) buf.append(usage_map_alloc, ',') catch return;
            first_provider = false;

            buf.print(usage_map_alloc, "{f}:{{", .{std.json.fmt(provider_entry.key_ptr.*, .{})}) catch return;

            var first_model = true;
            var inner = provider_entry.value_ptr.iterator();
            while (inner.next()) |model_entry| {
                if (!first_model) buf.append(usage_map_alloc, ',') catch return;
                first_model = false;
                const u = model_entry.value_ptr.*;
                buf.print(usage_map_alloc,
                    "{f}:{{\"input\":{d},\"cache_write\":{d},\"cache_read\":{d},\"output\":{d}}}",
                    .{ std.json.fmt(model_entry.key_ptr.*, .{}), u.input, u.cache_write, u.cache_read, u.output },
                ) catch return;
            }
            buf.append(usage_map_alloc, '}') catch return;
        }
    }

    buf.appendSlice(usage_map_alloc, "}}") catch return;

    // Atomic write: write to temp file then rename
    var tmp_path_buf: [fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch return;

    const file = fs.cwd().createFile(tmp_path, .{}) catch |err| {
        log.warn("Failed to create metrics temp file: {}", .{err});
        return;
    };
    file.writeAll(buf.items) catch |err| {
        file.close();
        fs.cwd().deleteFile(tmp_path) catch {};
        log.warn("Failed to write metrics temp file: {}", .{err});
        return;
    };
    file.close();

    fs.cwd().rename(tmp_path, path) catch |err| {
        log.warn("Failed to rename metrics temp file: {}", .{err});
        fs.cwd().deleteFile(tmp_path) catch {};
    };
}


