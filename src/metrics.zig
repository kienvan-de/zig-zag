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
//! This module provides thread-safe atomic counters for tracking:
//! - Network I/O bytes (rx/tx)
//! - Input/output tokens from LLM responses
//! - Input/output costs from LLM responses
//! - Process stats (RSS, CPU time) from OS
//!
//! All counters are designed for high-frequency updates from multiple threads.
//! Cost values are stored as micro-dollars (millionths of a dollar) for precision
//! with atomic u64 operations.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Atomic Counters
// ============================================================================

/// Total bytes received from clients
var network_rx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total bytes sent to clients
var network_tx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total input/prompt tokens accumulated from LLM responses
var input_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total output/completion tokens accumulated from LLM responses
var output_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total input cost in micro-dollars (1/1,000,000 of a dollar)
var input_cost_micros: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total output cost in micro-dollars (1/1,000,000 of a dollar)
var output_cost_micros: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// ============================================================================
// Public API - Counters
// ============================================================================

/// Add to the network receive counter
pub fn addNetworkRx(bytes: u64) void {
    _ = network_rx_bytes.fetchAdd(bytes, .monotonic);
}

/// Add to the network transmit counter
pub fn addNetworkTx(bytes: u64) void {
    _ = network_tx_bytes.fetchAdd(bytes, .monotonic);
}

/// Add input tokens from an LLM response
pub fn addInputTokens(tokens: u64) void {
    _ = input_tokens.fetchAdd(tokens, .monotonic);
}

/// Add output tokens from an LLM response
pub fn addOutputTokens(tokens: u64) void {
    _ = output_tokens.fetchAdd(tokens, .monotonic);
}

/// Add input cost (in dollars, converted to micro-dollars internally)
pub fn addInputCost(dollars: f64) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = input_cost_micros.fetchAdd(micros, .monotonic);
}

/// Add output cost (in dollars, converted to micro-dollars internally)
pub fn addOutputCost(dollars: f64) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = output_cost_micros.fetchAdd(micros, .monotonic);
}

/// Reset all counters to zero (useful for testing or server restart)
pub fn reset() void {
    network_rx_bytes.store(0, .monotonic);
    network_tx_bytes.store(0, .monotonic);
    input_tokens.store(0, .monotonic);
    output_tokens.store(0, .monotonic);
    input_cost_micros.store(0, .monotonic);
    output_cost_micros.store(0, .monotonic);
}

// ============================================================================
// Process Stats from OS
// ============================================================================

/// Correct mach_task_basic_info struct layout for macOS.
/// Zig's std.c.mach_task_basic_info is missing `resident_size_max` field,
/// causing incorrect offsets.
const MachTaskBasicInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64, // Zig's std.c is missing this field!
    user_time_seconds: i32,
    user_time_microseconds: i32,
    system_time_seconds: i32,
    system_time_microseconds: i32,
    policy: i32,
    suspend_count: i32,
};

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
/// - macOS: Uses Mach task_info for phys_footprint (like `top` MEM) and CPU time
/// - Linux: Reads /proc/self/statm for RSS, rusage for CPU time
/// - Other: Falls back to rusage (peak RSS, CPU time)
fn getProcessStats() struct { rss_bytes: u64, cpu_time_us: u64 } {
    if (builtin.os.tag == .macos) {
        const c = std.c;
        var rss_bytes: u64 = 0;
        var cpu_time_us: u64 = 0;

        // Get phys_footprint using TASK_VM_INFO (matches `top` MEM column)
        var vm_info: TaskVmInfo = std.mem.zeroes(TaskVmInfo);
        var vm_count: c.mach_msg_type_number_t = @sizeOf(TaskVmInfo) / @sizeOf(u32);
        const vm_result = c.task_info(
            c.mach_task_self(),
            TASK_VM_INFO,
            @ptrCast(&vm_info),
            &vm_count,
        );
        if (vm_result == 0) {
            rss_bytes = vm_info.phys_footprint;
        }

        // Get CPU time using MACH_TASK_BASIC_INFO
        var basic_info: MachTaskBasicInfo = std.mem.zeroes(MachTaskBasicInfo);
        var basic_count: c.mach_msg_type_number_t = @sizeOf(MachTaskBasicInfo) / @sizeOf(u32);
        const basic_result = c.task_info(
            c.mach_task_self(),
            c.MACH_TASK_BASIC_INFO,
            @ptrCast(&basic_info),
            &basic_count,
        );
        if (basic_result == 0) {
            const user_us: u64 = @intCast(@as(i64, basic_info.user_time_seconds) * 1_000_000 + basic_info.user_time_microseconds);
            const system_us: u64 = @intCast(@as(i64, basic_info.system_time_seconds) * 1_000_000 + basic_info.system_time_microseconds);
            cpu_time_us = user_us + system_us;
        }

        return .{ .rss_bytes = rss_bytes, .cpu_time_us = cpu_time_us };
    } else if (builtin.os.tag == .linux) {
        // Linux: Read /proc/self/statm for RSS
        var rss_bytes: u64 = 0;
        if (std.fs.openFileAbsolute("/proc/self/statm", .{})) |file| {
            defer file.close();
            var buf: [128]u8 = undefined;
            if (file.read(&buf)) |bytes_read| {
                const content = buf[0..bytes_read];
                var iter = std.mem.splitScalar(u8, content, ' ');
                _ = iter.next(); // skip size
                if (iter.next()) |rss_pages_str| {
                    if (std.fmt.parseInt(u64, rss_pages_str, 10)) |rss_pages| {
                        rss_bytes = rss_pages * std.mem.page_size;
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

        return .{ .rss_bytes = rss_bytes, .cpu_time_us = cpu_time_us };
    } else {
        // Fallback: Use rusage (peak RSS, CPU time)
        var usage: std.posix.rusage = undefined;
        const result = std.posix.system.getrusage(std.posix.system.rusage.SELF, &usage);
        if (result != 0) {
            return .{ .rss_bytes = 0, .cpu_time_us = 0 };
        }

        const user_us: u64 = @intCast(usage.utime.sec * 1_000_000 + usage.utime.usec);
        const system_us: u64 = @intCast(usage.stime.sec * 1_000_000 + usage.stime.usec);

        return .{
            .rss_bytes = @intCast(@max(0, usage.maxrss)),
            .cpu_time_us = user_us + system_us,
        };
    }
}

// ============================================================================
// Snapshot for stats reporting
// ============================================================================

pub const Snapshot = struct {
    // Process stats from OS
    rss_bytes: u64,
    cpu_time_us: u64,
    // Network I/O
    network_rx_bytes: u64,
    network_tx_bytes: u64,
    // LLM metrics
    input_tokens: u64,
    output_tokens: u64,
    input_cost: f64,
    output_cost: f64,
};

/// Get a consistent snapshot of all metrics including process stats
pub fn snapshot() Snapshot {
    const process_stats = getProcessStats();
    return .{
        .rss_bytes = process_stats.rss_bytes,
        .cpu_time_us = process_stats.cpu_time_us,
        .network_rx_bytes = network_rx_bytes.load(.monotonic),
        .network_tx_bytes = network_tx_bytes.load(.monotonic),
        .input_tokens = input_tokens.load(.monotonic),
        .output_tokens = output_tokens.load(.monotonic),
        .input_cost = @as(f64, @floatFromInt(input_cost_micros.load(.monotonic))) / 1_000_000.0,
        .output_cost = @as(f64, @floatFromInt(output_cost_micros.load(.monotonic))) / 1_000_000.0,
    };
}
