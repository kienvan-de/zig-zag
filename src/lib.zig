const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const worker_pool = @import("worker_pool.zig");

// ============================================================================
// Global state
// All access is serialized through state_mutex except where noted.
// ============================================================================

const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    cfg: config.Config,
    thread: std.Thread,
    port: u16,
};

var state: ?*State = null;
var state_mutex: std.Thread.Mutex = .{};

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
        std.debug.print("Failed to init worker pool: {}\n", .{err});
        return;
    };
    defer worker_pool.deinit();

    log.init(.{
        .level = s.cfg.log.level,
        .path = s.cfg.log.path,
    }, allocator) catch |err| {
        std.debug.print("Failed to init logging: {}\n", .{err});
        return;
    };
    defer log.deinit();

    // server.start() blocks until server.shutdown() closes the listener.
    server.start(allocator, &s.cfg) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}

// ============================================================================
// Public C API
// ============================================================================

/// Start the server. Returns true on success, false if already running or
/// if startup fails.
export fn startServer() bool {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (state != null) return false; // already running

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
        std.debug.print("Failed to load config: {}\n", .{err});
        _ = s.gpa.deinit();
        bootstrap.destroy(s);
        return false;
    };
    errdefer s.cfg.deinit();

    s.port = s.cfg.server.port;

    // Spawn server thread.
    s.thread = std.Thread.spawn(.{}, serverThreadFn, .{s}) catch |err| {
        std.debug.print("Failed to spawn server thread: {}\n", .{err});
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
    // Clear state pointer before unlocking so isServerRunning() returns false
    // immediately while we wait for the thread to join.
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

/// Returns true if the server is currently running.
export fn isServerRunning() bool {
    state_mutex.lock();
    defer state_mutex.unlock();
    return state != null;
}

/// Returns the port the server is listening on, or 0 if not running.
export fn getServerPort() u16 {
    state_mutex.lock();
    defer state_mutex.unlock();
    return if (state) |s| s.port else 0;
}
