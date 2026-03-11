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
const core = @import("zag-core");
const config = core.config;
const errors = core.errors;
const http = @import("http.zig");
const log = core.log;
const metrics = core.metrics;
const router = @import("router.zig");

// HTTP response constants
const NOT_FOUND_RESPONSE =
    \\HTTP/1.1 404 Not Found
    \\Content-Type: application/json
    \\Content-Length: 22
    \\Connection: close
    \\
    \\{"error": "Not Found"}
;



/// Thread pool worker context
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    listener: *std.net.Server,
    shutdown: *std.atomic.Value(bool),
};

// ============================================================================
// Shutdown support
// ============================================================================

/// Global listener pointer and mutex for shutdown support.
/// Protected by listener_mutex - set while server is running, null otherwise.
var global_listener: ?*std.net.Server = null;
var listener_mutex: std.Thread.Mutex = .{};

/// Signal the running server to stop.
/// Closes the listener socket which causes all accept() calls to return an
/// error, allowing worker threads to exit cleanly.
pub fn shutdown() void {
    listener_mutex.lock();
    defer listener_mutex.unlock();

    if (global_listener) |l| {
        l.deinit();
        global_listener = null;
    }
}

// ============================================================================
// Server entry point
// ============================================================================

pub fn start(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const host = cfg.server.host;
    const port = cfg.server.port;

    const pool_size: usize = @intCast(cfg.server.http_pool_size);

    log.info("Starting zig-zag proxy server on {s}:{d}...", .{ host, port });
    log.info("Loaded providers: {d}", .{cfg.providers.count()});
    log.info("HTTP pool size: {d}", .{pool_size});

    const address = try std.net.Address.parseIp(host, port);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    // NOTE: We do NOT defer listener.deinit() here.
    // shutdown() owns deinit when called externally.
    // If we exit normally (no shutdown), we deinit below after joining threads.

    // Register in global state so shutdown() can close the socket.
    {
        listener_mutex.lock();
        global_listener = &listener;
        listener_mutex.unlock();
    }

    log.info("Listening on http://{s}:{d}", .{ host, port });
    log.info("Endpoints:", .{});
    log.info("  POST /v1/chat/completions", .{});
    log.info("  GET  /v1/models", .{});

    log.info("Server started on {s}:{d} with {d} HTTP workers", .{ host, port, pool_size });

    var shutdown_flag = std.atomic.Value(bool).init(false);

    var worker_ctx = WorkerContext{
        .allocator = allocator,
        .cfg = cfg,
        .listener = &listener,
        .shutdown = &shutdown_flag,
    };

    var threads = try allocator.alloc(std.Thread, pool_size);
    defer allocator.free(threads);

    for (0..pool_size) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&worker_ctx});
        log.debug("Started worker thread {d}", .{i});
    }

    // Wait for all threads to exit (they exit when accept() fails after shutdown).
    for (threads) |thread| {
        thread.join();
    }

    // Clear global listener reference.
    // If shutdown() already called deinit(), global_listener is already null
    // and listener.deinit() would double-free, so only deinit if we still own it.
    {
        listener_mutex.lock();
        defer listener_mutex.unlock();
        if (global_listener != null) {
            global_listener = null;
            listener.deinit();
        }
        // else: shutdown() already called deinit(), nothing to do.
    }

    log.info("Server stopped", .{});
}

// ============================================================================
// Worker threads
// ============================================================================

fn workerThread(ctx: *WorkerContext) void {
    log.debug("Worker thread started", .{});

    while (!ctx.shutdown.load(.acquire)) {
        const connection = ctx.listener.accept() catch |err| {
            // Any error after shutdown is expected (socket closed).
            if (ctx.shutdown.load(.acquire)) break;
            // Check if the listener was closed externally via shutdown().
            {
                listener_mutex.lock();
                const still_valid = global_listener != null;
                listener_mutex.unlock();
                if (!still_valid) break;
            }
            log.warn("Failed to accept connection: {}", .{err});
            continue;
        };

        handleConnection(ctx.allocator, connection, ctx.cfg) catch |err| {
            log.warn("Error handling connection: {}", .{err});
        };
    }

    log.debug("Worker thread exiting", .{});
}

// ============================================================================
// Connection handling
// ============================================================================

fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection, cfg: *const config.Config) !void {
    defer connection.stream.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    // Size limits from config
    const max_header_size: usize = @intCast(cfg.server.max_header_size);
    const max_body_size: usize = @intCast(cfg.server.max_body_size);
    const read_timeout_ms: i64 = cfg.server.read_timeout_ms;

    // Set read timeout on the socket using SO_RCVTIMEO
    if (read_timeout_ms > 0) {
        const timeout_sec: i64 = @divTrunc(read_timeout_ms, 1000);
        const timeout_usec: i32 = @intCast(@rem(read_timeout_ms, 1000) * 1000);
        const timeval = std.posix.timeval{
            .sec = timeout_sec,
            .usec = timeout_usec,
        };
        std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch |err| {
            log.warn("Failed to set read timeout: {}", .{err});
        };
    }

    // Read the full request into a dynamically grown buffer so large bodies
    // are not silently truncated.
    var request_buf = std.ArrayListUnmanaged(u8){};

    var read_buf: [16384]u8 = undefined;
    var header_end: ?usize = null;
    var content_length: ?usize = null;

    // Phase 1: read until we have the full headers (find \r\n\r\n).
    while (true) {
        const n = connection.stream.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) {
                log.debug("Read timeout waiting for request", .{});
                return;
            }
            return err;
        };
        if (n == 0) return;

        // Track network receive bytes
        metrics.addNetworkRx(n);

        try request_buf.appendSlice(request_allocator, read_buf[0..n]);

        // Check if we now have the end of headers.
        if (header_end == null) {
            // Enforce max header size before finding header end
            if (request_buf.items.len > max_header_size) {
                log.warn("Request headers exceed max size ({d} bytes)", .{max_header_size});
                _ = try connection.stream.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n");
                return;
            }

            if (std.mem.indexOf(u8, request_buf.items, "\r\n\r\n")) |pos| {
                header_end = pos + 4;
            } else if (std.mem.indexOf(u8, request_buf.items, "\n\n")) |pos| {
                header_end = pos + 2;
            }
        }

        if (header_end) |hend| {
            // Parse Content-Length from headers if not yet done.
            if (content_length == null) {
                const headers = request_buf.items[0..hend];
                content_length = parseContentLength(headers) orelse 0;

                // Enforce max body size
                if (content_length.? > max_body_size) {
                    log.warn("Request body too large: {d} bytes (max: {d})", .{ content_length.?, max_body_size });
                    _ = try connection.stream.writeAll("HTTP/1.1 413 Content Too Large\r\nConnection: close\r\n\r\n");
                    return;
                }
            }

            // Check if we have the full body.
            const body_received = request_buf.items.len - hend;
            if (body_received >= content_length.?) break;
        }
    }

    const request_data = request_buf.items;

    if (router.match(request_data)) |route| {
        const body = extractRequestBody(request_data) orelse blk: {
            if (std.mem.eql(u8, route.method, "GET") or std.mem.eql(u8, route.method, "DELETE")) {
                break :blk "";
            } else {
                const error_json = try errors.createErrorResponse(
                    request_allocator,
                    "No request body found",
                    .invalid_request_error,
                    null,
                );
                try http.sendJsonResponse(connection, .bad_request, error_json);
                return;
            }
        };

        try route.handler(request_allocator, connection, route.method, route.path, body, cfg);
    } else {
        _ = try connection.stream.writeAll(NOT_FOUND_RESPONSE);
    }
}

fn parseContentLength(headers: []const u8) ?usize {
    // Case-insensitive search for Content-Length header.
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len < 16) continue;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line[15..], " \t");
            return std.fmt.parseUnsigned(usize, value, 10) catch null;
        }
    }
    return null;
}

fn extractRequestBody(request_data: []const u8) ?[]const u8 {
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
