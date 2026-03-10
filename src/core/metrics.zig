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
const log = @import("log.zig");

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

/// Budget period start timestamp (seconds since epoch). 0 = not set (uses server start time).
var period_start: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

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

/// Increment the cumulative input (prompt) token counter.
///
/// Called after each LLM response is received, using the `prompt_tokens` (or equivalent)
/// value reported by the upstream provider. These counts persist across restarts via `persist()`.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addInputTokens(tokens: u64) void {
    _ = input_tokens.fetchAdd(tokens, .monotonic);
}

/// Increment the cumulative output (completion) token counter.
///
/// Called after each LLM response is received, using the `completion_tokens` (or equivalent)
/// value reported by the upstream provider. These counts persist across restarts via `persist()`.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addOutputTokens(tokens: u64) void {
    _ = output_tokens.fetchAdd(tokens, .monotonic);
}

/// Add to the cumulative input (prompt) cost.
///
/// Accepts the cost in **dollars** (e.g. `0.003`) and converts it internally to
/// micro-dollars (millionths of a dollar) so the value can be stored in an atomic `u64`.
/// The conversion is: `micros = dollars * 1_000_000`.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addInputCost(dollars: f64) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = input_cost_micros.fetchAdd(micros, .monotonic);
}

/// Add to the cumulative output (completion) cost.
///
/// Accepts the cost in **dollars** (e.g. `0.012`) and converts it internally to
/// micro-dollars (millionths of a dollar) so the value can be stored in an atomic `u64`.
/// The conversion is: `micros = dollars * 1_000_000`.
/// Thread-safe: uses an atomic fetch-add with monotonic ordering.
pub fn addOutputCost(dollars: f64) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = output_cost_micros.fetchAdd(micros, .monotonic);
}

/// Reset **all** counters to zero, including network I/O, tokens, costs, and `period_start`.
///
/// Primarily used in tests or when the server is fully restarted from a clean state.
/// For budget-period resets (which preserve network counters), use `resetCosts()` instead.
/// Thread-safe: each counter is stored atomically with monotonic ordering.
pub fn reset() void {
    network_rx_bytes.store(0, .monotonic);
    network_tx_bytes.store(0, .monotonic);
    input_tokens.store(0, .monotonic);
    output_tokens.store(0, .monotonic);
    input_cost_micros.store(0, .monotonic);
    output_cost_micros.store(0, .monotonic);
    period_start.store(0, .monotonic);
}

/// Reset cost **and** token counters, and set `period_start` to the current wall-clock time.
///
/// Called by `utils.checkAndResetBudgetPeriod()` when the budget period configured in
/// `cost_controls.days_duration` has expired. This zeroes:
/// - `input_tokens` and `output_tokens`
/// - `input_cost_micros` and `output_cost_micros`
///
/// Network I/O counters are **not** affected.
///
/// After resetting, `period_start` is updated to `std.time.timestamp()` (seconds since
/// epoch) so the next budget window begins immediately. The new values are subsequently
/// written to disk by `persist()`.
pub fn resetCosts() void {
    input_tokens.store(0, .monotonic);
    output_tokens.store(0, .monotonic);
    input_cost_micros.store(0, .monotonic);
    output_cost_micros.store(0, .monotonic);
    period_start.store(std.time.timestamp(), .monotonic);
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
                        rss_bytes = rss_pages * std.heap.pageSize();
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

/// A point-in-time capture of every tracked metric.
///
/// Returned by `snapshot()` and consumed by the macOS menu-bar app (via C FFI)
/// and by any future REST metrics endpoint. All monetary values are expressed in
/// **dollars** (converted from the internal micro-dollar representation).
///
/// Because each field is read from a separate atomic counter, a `Snapshot` is
/// *nearly* consistent — individual fields are each atomic, but the aggregate is
/// not captured under a single lock. This is acceptable for display purposes.
pub const Snapshot = struct {
    /// Resident memory (physical footprint) of the process in bytes.
    /// macOS: `phys_footprint` from `TASK_VM_INFO` (matches the `top` MEM column).
    /// Linux: RSS from `/proc/self/statm`.
    rss_bytes: u64,
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
    /// Cumulative input (prompt) cost in **dollars** for the current budget period.
    input_cost: f64,
    /// Cumulative output (completion) cost in **dollars** for the current budget period.
    output_cost: f64,
};

/// Capture a point-in-time `Snapshot` of all tracked metrics, including live
/// process stats (RSS, CPU) obtained from the OS.
///
/// Each atomic counter is loaded individually with monotonic ordering, so the
/// snapshot is *nearly* consistent — suitable for human-readable dashboards but
/// not for transactional accounting. Cost values are converted from internal
/// micro-dollars back to dollars before being stored in the returned struct.
///
/// This function is called frequently by the macOS app's polling timer and is
/// designed to be cheap (no allocations, no syscall failures propagated).
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

// ============================================================================
// Persistence — load/save accumulated metrics to ~/.config/zig-zag/metrics.json
// ============================================================================

const METRICS_FILENAME = "metrics.json";

/// JSON structure for persisted metrics
const PersistedMetrics = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    input_cost_micros: u64 = 0,
    output_cost_micros: u64 = 0,
    period_start: i64 = 0,
};

/// Get the metrics file path: ~/.config/zig-zag/metrics.json
fn getMetricsPath(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zig-zag/{s}", .{ home, METRICS_FILENAME }) catch null;
}

/// Load persisted metrics from `~/.config/zig-zag/metrics.json` and restore the
/// atomic counters (tokens, costs, and `period_start`).
///
/// **Must be called once at startup**, before the server accepts any requests and
/// before `utils.checkBudgetPeriodOnStartup()` runs, so that the budget logic
/// sees the correct accumulated totals and period timestamp.
///
/// If the file does not exist (first run) or cannot be parsed, all counters
/// remain at their initial zero values — no error is propagated.
///
/// Network I/O counters (`network_rx_bytes`, `network_tx_bytes`) are **not**
/// persisted and always start at zero on each process launch.
pub fn load() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getMetricsPath(&path_buf) orelse return;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => log.debug("No persisted metrics file, starting fresh", .{}),
            else => log.warn("Failed to open metrics file: {}", .{err}),
        }
        return;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch |err| {
        log.warn("Failed to read metrics file: {}", .{err});
        return;
    };

    const parsed = std.json.parseFromSlice(PersistedMetrics, std.heap.page_allocator, buf[0..bytes_read], .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse metrics file: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const data = parsed.value;
    input_tokens.store(data.input_tokens, .monotonic);
    output_tokens.store(data.output_tokens, .monotonic);
    input_cost_micros.store(data.input_cost_micros, .monotonic);
    output_cost_micros.store(data.output_cost_micros, .monotonic);
    period_start.store(data.period_start, .monotonic);

    log.info("Loaded persisted metrics: in_tokens={d}, out_tokens={d}, in_cost=${d:.6}, out_cost=${d:.6}, period_start={d}", .{
        data.input_tokens,
        data.output_tokens,
        @as(f64, @floatFromInt(data.input_cost_micros)) / 1_000_000.0,
        @as(f64, @floatFromInt(data.output_cost_micros)) / 1_000_000.0,
        data.period_start,
    });
}

/// Persist current token counts, costs, and `period_start` to
/// `~/.config/zig-zag/metrics.json`.
///
/// The write is **atomic**: data is first written to a temporary `.tmp` file and
/// then renamed over the target path, so a crash mid-write never corrupts the
/// existing file.
///
/// Called after every request that modifies cost/token counters, after a budget
/// period reset, and on graceful shutdown. Network I/O counters are intentionally
/// **not** persisted (they reset each process launch).
///
/// If any step fails (serialisation, file creation, rename), a warning is logged
/// and the function returns silently — the next successful call will capture the
/// latest values.
pub fn persist() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getMetricsPath(&path_buf) orelse return;

    const data = PersistedMetrics{
        .input_tokens = input_tokens.load(.monotonic),
        .output_tokens = output_tokens.load(.monotonic),
        .input_cost_micros = input_cost_micros.load(.monotonic),
        .output_cost_micros = output_cost_micros.load(.monotonic),
        .period_start = period_start.load(.monotonic),
    };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })}) catch |err| {
        log.warn("Failed to serialize metrics: {}", .{err});
        return;
    };
    const json_bytes = fbs.getWritten();

    // Atomic write: write to temp file then rename
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch return;

    const file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        log.warn("Failed to create metrics temp file: {}", .{err});
        return;
    };

    file.writeAll(json_bytes) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
        log.warn("Failed to write metrics temp file: {}", .{err});
        return;
    };
    file.close();

    std.fs.cwd().rename(tmp_path, path) catch |err| {
        log.warn("Failed to rename metrics temp file: {}", .{err});
        std.fs.cwd().deleteFile(tmp_path) catch {};
        return;
    };
}


