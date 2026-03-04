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
const build_options = @import("build_options");
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const app_cache = @import("cache/app_cache.zig");
const worker_pool = @import("worker_pool.zig");
const metrics = @import("metrics.zig");
const provider = @import("provider.zig");
const pricing = @import("pricing.zig");

const version = build_options.version;

// ============================================================================
// Global state
// All access is serialized through state_mutex except where noted.
// ============================================================================

const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    cfg: ?config.Config, // null until loaded in serverThreadFn
    thread: std.Thread,
    port: u16,
    start_timestamp: i64,
};

var state: ?*State = null;
var state_mutex: std.Thread.Mutex = .{};

// Server lifecycle status - accessed atomically, no mutex needed
var server_status: std.atomic.Value(ServerStatus) = std.atomic.Value(ServerStatus).init(.stopped);
var server_error_code: std.atomic.Value(ServerErrorCode) = std.atomic.Value(ServerErrorCode).init(.none);

// Provider init results - written once by server thread, read by stats polling
var active_provider_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ============================================================================
// C-compatible types (must match include/zig-zag.h)
// ============================================================================

/// Server lifecycle status
pub const ServerStatus = enum(c_int) {
    stopped = 0, // Server is not running
    starting = 1, // Server is initializing (loading config, auth flows, etc.)
    running = 2, // Server is running and accepting requests
    err = 3, // Server encountered an error during startup
};

/// Error codes for server startup failures
pub const ServerErrorCode = enum(c_int) {
    none = 0, // No error
    config_load_failed = 1, // Failed to load/parse config.json
    port_in_use = 2, // Server port already in use
    worker_pool_init_failed = 3, // Failed to initialize worker pool
    log_init_failed = 4, // Failed to initialize logging
    thread_spawn_failed = 5, // Failed to spawn server thread
    auth_failed = 6, // Provider authentication failed
};

pub const CServerStats = extern struct {
    status: ServerStatus,
    error_code: ServerErrorCode,
    port: u16,
    uptime_seconds: u64,
    memory_bytes: u64,
    cpu_percent: f32,
    cpu_time_us: u64,
    network_rx_bytes: u64,
    network_tx_bytes: u64,
    llm_provider_configured: u32,
    llm_provider_active: u32,
    input_tokens: u64,
    output_tokens: u64,
    total_cost: f32,
    input_cost: f32,
    output_cost: f32,
    // Statistics display options
    show_performance: bool,
    show_llm: bool,
    show_cost: bool,
    // Cost controls
    cost_controls_enabled: bool,
    cost_budget: f32,
};

// ============================================================================
// Server thread entry point
// ============================================================================

fn serverThreadFn(s: *State) void {
    const allocator = s.gpa.allocator();

    // Initialize subsystems in dependency order (same as main.zig).
    // All initialization happens in this thread to avoid blocking UI.

    // 1. Load config
    const cfg = config.Config.load(allocator) catch {
        server_status.store(.err, .release);
        server_error_code.store(.config_load_failed, .release);
        return;
    };

    // Store config in state (protected by the fact that we're the only writer)
    state_mutex.lock();
    s.cfg = cfg;
    s.port = cfg.server.port;
    state_mutex.unlock();

    // Ensure config is cleaned up on any exit path
    defer {
        state_mutex.lock();
        if (s.cfg) |*c| c.deinit();
        s.cfg = null;
        state_mutex.unlock();
    }

    // 2. Initialize app cache (for OIDC discovery configs, etc.)
    app_cache.init(allocator);
    defer app_cache.deinit();

    // 3. Initialize token cache
    token_cache.init(allocator);
    defer token_cache.deinit();

    // 4. Initialize worker pool
    const io_pool_size: usize = if (cfg.server.io_pool_size) |size|
        @intCast(size)
    else
        4;

    worker_pool.init(allocator, io_pool_size) catch |err| {
        log.err("Failed to init worker pool: {}", .{err});
        server_status.store(.err, .release);
        server_error_code.store(.worker_pool_init_failed, .release);
        return;
    };
    defer worker_pool.deinit();

    // 5. Initialize logging
    log.init(.{
        .level = cfg.log.level,
        .path = cfg.log.path,
        .output = .file, // lib mode always writes to file
    }, allocator) catch |err| {
        log.err("Failed to init logging: {}", .{err});
        server_status.store(.err, .release);
        server_error_code.store(.log_init_failed, .release);
        return;
    };
    defer log.deinit();

    // 6. Initialize providers (auth flows for HAI, SAP AI Core, etc.)
    log.info("Initializing providers...", .{});

    // 6a. Initialize pricing engine (load cost CSVs for configured providers)
    var provider_names_buf: [32][]const u8 = undefined;
    var provider_name_count: usize = 0;
    {
        var piter = cfg.providers.keyIterator();
        while (piter.next()) |key_ptr| {
            if (provider_name_count < provider_names_buf.len) {
                provider_names_buf[provider_name_count] = key_ptr.*;
                provider_name_count += 1;
            }
        }
    }
    pricing.init(allocator, provider_names_buf[0..provider_name_count]);
    defer pricing.deinit();

    const init_result = provider.initProviders(allocator, &cfg);
    log.info("Provider initialization complete: {d}/{d} succeeded", .{ init_result.succeeded, init_result.total });

    // Store active provider count for stats
    active_provider_count.store(init_result.succeeded, .release);

    // Exit if all providers failed (but allow starting with no providers configured)
    if (init_result.succeeded == 0 and init_result.total > 0) {
        log.err("All providers failed to initialize", .{});
        server_status.store(.err, .release);
        server_error_code.store(.auth_failed, .release);
        return;
    }

    // All init successful - transition to running state
    server_status.store(.running, .release);
    server_error_code.store(.none, .release);

    // server.start() blocks until server.shutdown() closes the listener.
    server.start(allocator, &cfg) catch |err| {
        log.err("Server error: {}", .{err});
        // Check if it's a port-in-use error
        if (err == error.AddressInUse) {
            server_status.store(.err, .release);
            server_error_code.store(.port_in_use, .release);
        }
    };
}

// ============================================================================
// Helper functions
// ============================================================================

// ============================================================================
// Public C API
// ============================================================================

/// Start the server. Returns true on success, false if already running.
/// This function returns immediately - all initialization happens in background thread.
/// Check getServerStats().status for progress (starting → running or err).
export fn startServer() bool {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (state != null) return false; // already running

    // Set status to starting immediately
    server_status.store(.starting, .release);
    server_error_code.store(.none, .release);

    // Reset metrics for fresh start
    metrics.reset();

    // Allocate State shell using page_allocator (stable address for GPA inside)
    const bootstrap = std.heap.page_allocator;
    const s = bootstrap.create(State) catch {
        server_status.store(.err, .release);
        server_error_code.store(.config_load_failed, .release);
        return false;
    };
    errdefer bootstrap.destroy(s);

    // Initialize GPA inside State
    s.* = .{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .cfg = null,
        .thread = undefined,
        .port = 0,
        .start_timestamp = std.time.timestamp(),
    };

    // Spawn server thread - all initialization happens there (non-blocking)
    s.thread = std.Thread.spawn(.{}, serverThreadFn, .{s}) catch {
        _ = s.gpa.deinit();
        bootstrap.destroy(s);
        server_status.store(.err, .release);
        server_error_code.store(.thread_spawn_failed, .release);
        return false;
    };

    state = s;
    return true;
}

/// Stop the server. Blocks until the server thread has exited.
/// Safe to call if server is not running.
export fn stopServer() void {
    state_mutex.lock();

    const s = state orelse {
        state_mutex.unlock();
        return;
    };
    // Clear state pointer before unlocking so getServerStats() returns
    // status=stopped immediately while we wait for the thread to join.
    state = null;
    state_mutex.unlock();

    // Signal server.zig to close the listener socket.
    // This unblocks all accept() calls and lets worker threads exit.
    server.shutdown();

    // Wait for the server thread to finish all cleanup.
    s.thread.join();

    // Config is cleaned up in serverThreadFn via defer, so just clean up GPA and State
    _ = s.gpa.deinit();

    // Free the State shell using the same allocator we used to create it.
    std.heap.page_allocator.destroy(s);

    // Set status to stopped after cleanup
    server_status.store(.stopped, .release);
    server_error_code.store(.none, .release);
    active_provider_count.store(0, .release);
}

/// Get current server statistics and metrics.
/// Returns zeroed struct if server is not running.
export fn getServerStats() CServerStats {
    // Read atomic status/error first (no lock needed)
    const status = server_status.load(.acquire);
    const error_code = server_error_code.load(.acquire);

    state_mutex.lock();
    defer state_mutex.unlock();

    const s = state orelse {
        // Server not running - return stats with current status
        return CServerStats{
            .status = status,
            .error_code = error_code,
            .port = 0,
            .uptime_seconds = 0,
            .memory_bytes = 0,
            .cpu_percent = 0.0,
            .cpu_time_us = 0,
            .network_rx_bytes = 0,
            .network_tx_bytes = 0,
            .llm_provider_configured = 0,
            .llm_provider_active = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .total_cost = 0.0,
            .input_cost = 0.0,
            .output_cost = 0.0,
            .show_performance = true,
            .show_llm = true,
            .show_cost = true,
            .cost_controls_enabled = false,
            .cost_budget = 0.0,
        };
    };

    const now = std.time.timestamp();
    const uptime: u64 = if (now > s.start_timestamp)
        @intCast(now - s.start_timestamp)
    else
        0;

    const snap = metrics.snapshot();

    // Config may be null if still loading
    const configured: u32 = if (s.cfg) |cfg| @intCast(cfg.providers.count()) else 0;
    const active: u32 = active_provider_count.load(.acquire);

    // Read display config (defaults if config not loaded yet)
    const stats_cfg = if (s.cfg) |cfg| cfg.statistics else config.StatisticsConfig{};
    const cost_cfg = if (s.cfg) |cfg| cfg.cost_controls else config.CostControlsConfig{};

    return CServerStats{
        .status = status,
        .error_code = error_code,
        .port = s.port,
        .uptime_seconds = uptime,
        .memory_bytes = snap.rss_bytes,
        .cpu_percent = 0.0, // Placeholder - calculated by Swift from cpu_time_us
        .cpu_time_us = snap.cpu_time_us,
        .network_rx_bytes = snap.network_rx_bytes,
        .network_tx_bytes = snap.network_tx_bytes,
        .llm_provider_configured = configured,
        .llm_provider_active = active,
        .input_tokens = snap.input_tokens,
        .output_tokens = snap.output_tokens,
        .total_cost = snap.input_cost + snap.output_cost,
        .input_cost = snap.input_cost,
        .output_cost = snap.output_cost,
        .show_performance = stats_cfg.show_performance,
        .show_llm = stats_cfg.show_llm,
        .show_cost = stats_cfg.show_cost,
        .cost_controls_enabled = cost_cfg.enabled,
        .cost_budget = cost_cfg.budget,
    };
}

/// Get the zig-zag core version string.
/// Returns a null-terminated string pointer (static lifetime, never freed).
export fn getVersion() [*:0]const u8 {
    return version.ptr[0..version.len :0];
}
