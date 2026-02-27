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

// ============================================================================
// C-compatible types (must match include/zig-zag.h)
// ============================================================================

pub const CServerStats = extern struct {
    running: bool,
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
        return;
    };
    defer worker_pool.deinit();

    log.init(.{
        .level = s.cfg.log.level,
        .path = s.cfg.log.path,
        .output = .file, // lib mode always writes to file
    }, allocator) catch |err| {
        log.err("Failed to init logging: {}", .{err});
        return;
    };
    defer log.deinit();

    // server.start() blocks until server.shutdown() closes the listener.
    server.start(allocator, &s.cfg) catch |err| {
        log.err("Server error: {}", .{err});
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
    const s = bootstrap.create(State) catch return false;
    errdefer bootstrap.destroy(s);

    // Initialize GPA inside State (it lives at a stable address now).
    s.gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = s.gpa.allocator();

    // Load config using GPA.
    s.cfg = config.Config.load(allocator) catch |err| {
        log.err("Failed to load config: {}", .{err});
        _ = s.gpa.deinit();
        bootstrap.destroy(s);
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
    // running=false immediately while we wait for the thread to join.
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
}

/// Get current server statistics and metrics.
/// Returns zeroed struct if server is not running.
export fn getServerStats() CServerStats {
    state_mutex.lock();
    defer state_mutex.unlock();

    const s = state orelse {
        // Server not running - return zeroed stats
        return CServerStats{
            .running = false,
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
        .running = true,
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
