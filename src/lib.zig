const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const worker_pool = @import("worker_pool.zig");
const metrics = @import("metrics.zig");

// ============================================================================
// Global state
// All access is serialized through state_mutex except where noted.
// ============================================================================

const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    cfg: config.Config,
    thread: std.Thread,
    port: u16,
    start_timestamp: i64,
};

var state: ?*State = null;
var state_mutex: std.Thread.Mutex = .{};

// Server lifecycle status - accessed atomically, no mutex needed
var server_status: std.atomic.Value(ServerStatus) = std.atomic.Value(ServerStatus).init(.stopped);
var server_error_code: std.atomic.Value(ServerErrorCode) = std.atomic.Value(ServerErrorCode).init(.none);

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
    llm_provider_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    total_cost: f32,
    input_cost: f32,
    output_cost: f32,
};

// ============================================================================
// Server thread entry point
// ============================================================================

fn serverThreadFn(s: *State) void {
    const allocator = s.gpa.allocator();

    // Initialize subsystems in dependency order (same as main.zig).
    token_cache.init(allocator);
    defer token_cache.deinit();

    const io_pool_size: usize = if (s.cfg.server.io_pool_size) |size|
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

    log.init(.{
        .level = s.cfg.log.level,
        .path = s.cfg.log.path,
        .output = .file, // lib mode always writes to file
    }, allocator) catch |err| {
        log.err("Failed to init logging: {}", .{err});
        server_status.store(.err, .release);
        server_error_code.store(.log_init_failed, .release);
        return;
    };
    defer log.deinit();

    // All init successful - transition to running state
    server_status.store(.running, .release);
    server_error_code.store(.none, .release);

    // server.start() blocks until server.shutdown() closes the listener.
    server.start(allocator, &s.cfg) catch |err| {
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

/// Start the server. Returns true on success, false if already running or
/// if startup fails.
export fn startServer() bool {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (state != null) return false; // already running

    // Set status to starting immediately
    server_status.store(.starting, .release);
    server_error_code.store(.none, .release);

    // Reset metrics for fresh start
    metrics.reset();

    // We need a stable allocator before we can allocate State itself.
    // Use the process allocator just for bootstrapping, then switch to GPA.
    // Instead: allocate State on the heap using a temporary GPA on the stack,
    // then transfer ownership.
    //
    // The trick: create State directly via std.heap.page_allocator for the
    // outer shell, then the GPA inside State owns all subsequent allocations.
    const bootstrap = std.heap.page_allocator;
    const s = bootstrap.create(State) catch {
        server_status.store(.err, .release);
        server_error_code.store(.config_load_failed, .release);
        return false;
    };
    errdefer bootstrap.destroy(s);

    // Initialize GPA inside State (it lives at a stable address now).
    s.gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = s.gpa.allocator();

    // Load config using GPA.
    s.cfg = config.Config.load(allocator) catch |err| {
        log.err("Failed to load config: {}", .{err});
        _ = s.gpa.deinit();
        bootstrap.destroy(s);
        server_status.store(.err, .release);
        server_error_code.store(.config_load_failed, .release);
        return false;
    };
    errdefer s.cfg.deinit();

    s.port = s.cfg.server.port;
    s.start_timestamp = std.time.timestamp();

    // Spawn server thread.
    s.thread = std.Thread.spawn(.{}, serverThreadFn, .{s}) catch |err| {
        log.err("Failed to spawn server thread: {}", .{err});
        s.cfg.deinit();
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

    // Tear down config and GPA.
    s.cfg.deinit();
    _ = s.gpa.deinit();

    // Free the State shell using the same allocator we used to create it.
    std.heap.page_allocator.destroy(s);

    // Set status to stopped after cleanup
    server_status.store(.stopped, .release);
    server_error_code.store(.none, .release);
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
            .llm_provider_count = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .total_cost = 0.0,
            .input_cost = 0.0,
            .output_cost = 0.0,
        };
    };

    const now = std.time.timestamp();
    const uptime: u64 = if (now > s.start_timestamp)
        @intCast(now - s.start_timestamp)
    else
        0;

    const snap = metrics.snapshot();

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
        .llm_provider_count = @intCast(s.cfg.providers.count()),
        .input_tokens = snap.input_tokens,
        .output_tokens = snap.output_tokens,
        .total_cost = snap.input_cost + snap.output_cost,
        .input_cost = snap.input_cost,
        .output_cost = snap.output_cost,
    };
}
