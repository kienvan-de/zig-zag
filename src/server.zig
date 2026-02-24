const std = @import("std");
const config = @import("config.zig");
const router = @import("router.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");
const log = @import("log.zig");

// HTTP response constants
const NOT_FOUND_RESPONSE =
    \\HTTP/1.1 404 Not Found
    \\Content-Type: application/json
    \\Content-Length: 22
    \\Connection: close
    \\
    \\{"error": "Not Found"}
;

const DEFAULT_THREAD_POOL_SIZE = 8;

/// Thread pool worker context
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    listener: *std.net.Server,
    shutdown: *std.atomic.Value(bool),
};

pub fn start(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const host = cfg.server.host;
    const port = cfg.server.port;

    // Get HTTP pool size from config or use default
    const pool_size: usize = if (cfg.server.http_pool_size) |size|
        @intCast(size)
    else
        DEFAULT_THREAD_POOL_SIZE;

    std.debug.print("Starting zig-zag proxy server on {s}:{d}...\n", .{ host, port });
    std.debug.print("Loaded providers: {d}\n", .{cfg.providers.count()});
    std.debug.print("HTTP pool size: {d}\n", .{pool_size});

    // Create server address
    const address = try std.net.Address.parseIp(host, port);

    // Create TCP listener
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.debug.print("Listening on http://{s}:{d}\n", .{ host, port });
    std.debug.print("Endpoints:\n", .{});
    std.debug.print("  POST /v1/chat/completions\n", .{});
    std.debug.print("  GET  /v1/models\n", .{});

    log.info("Server started on {s}:{d} with {d} HTTP workers", .{ host, port, pool_size });

    // Shutdown flag
    var shutdown = std.atomic.Value(bool).init(false);

    // Worker context shared by all threads
    var worker_ctx = WorkerContext{
        .allocator = allocator,
        .cfg = cfg,
        .listener = &listener,
        .shutdown = &shutdown,
    };

    // Create worker threads
    var threads = try allocator.alloc(std.Thread, pool_size);
    defer allocator.free(threads);

    for (0..pool_size) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&worker_ctx});
        log.debug("Started worker thread {d}", .{i});
    }

    // Wait for all threads (they run until shutdown)
    for (threads) |thread| {
        thread.join();
    }
}

fn workerThread(ctx: *WorkerContext) void {
    log.debug("Worker thread started", .{});

    while (!ctx.shutdown.load(.acquire)) {
        // Accept a connection (blocking)
        const connection = ctx.listener.accept() catch |err| {
            if (ctx.shutdown.load(.acquire)) break;
            log.warn("Failed to accept connection: {}", .{err});
            continue;
        };

        // Handle the connection
        handleConnection(ctx.allocator, connection, ctx.cfg) catch |err| {
            log.warn("Error handling connection: {}", .{err});
        };
    }

    log.debug("Worker thread exiting", .{});
}

fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection, cfg: *const config.Config) !void {
    defer connection.stream.close();

    // Use arena for per-request allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    var read_buffer: [16384]u8 = undefined;

    // Read HTTP request
    const bytes_read = try connection.stream.read(&read_buffer);
    if (bytes_read == 0) return;

    const request_data = read_buffer[0..bytes_read];

    // Try to match route
    if (router.match(request_data)) |route| {
        // Extract request body
        // GET requests don't need a body, POST requests do
        const body = extractRequestBody(request_data) orelse blk: {
            if (std.mem.eql(u8, route.method, "GET")) {
                break :blk "";
            } else {
                const error_json = try errors.createErrorResponse(
                    request_allocator,
                    "No request body found",
                    .invalid_request_error,
                    null,
                );
                defer request_allocator.free(error_json);
                try http.sendJsonResponse(connection, .bad_request, error_json);
                return;
            }
        };

        // Dispatch to handler
        try route.handler(request_allocator, connection, body, cfg);
    } else {
        // No route matched - return 404
        _ = try connection.stream.writeAll(NOT_FOUND_RESPONSE);
    }
}

fn extractRequestBody(request_data: []const u8) ?[]const u8 {
    // Find double CRLF or double LF (end of headers)
    if (std.mem.indexOf(u8, request_data, "\r\n\r\n")) |pos| {
        return request_data[pos + 4 ..];
    }
    if (std.mem.indexOf(u8, request_data, "\n\n")) |pos| {
        return request_data[pos + 2 ..];
    }
    return null;
}

// ============================================================================
// Unit Tests
// ============================================================================