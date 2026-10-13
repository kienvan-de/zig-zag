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
const errors = core.errors;
const http = @import("http.zig");
const log = core.log;
const metrics = core.metrics;
const app_config = @import("config.zig");
const router = @import("router.zig");
const net = core.net;

// HTTP response constants
const NOT_FOUND_RESPONSE =
    \\HTTP/1.1 404 Not Found
    \\Content-Type: application/json
    \\Content-Length: 22
    \\Connection: close
    \\
    \\{"error": "Not Found"}
;

// ============================================================================
// Shutdown support
// ============================================================================

/// Global server pointer and mutex for shutdown support.
/// Protected by server_mutex — set while server is running, null otherwise.
var global_server: ?*std.Io.net.Server = null;
var server_mutex: core.sync.Mutex = .{};

/// Explicit shutdown flag. Set by shutdown(), checked by the accept loop.
/// This is the authoritative stop signal: we do NOT rely on accept() returning
/// a specific error after deinit(), because the error is platform-dependent
/// (e.g. macOS returns error.Unexpected rather than SocketNotListening, which
/// would otherwise fall into the `else` branch and busy-loop forever).
var shutdown_requested: std.atomic.Value(bool) = .init(false);

/// Signal the running server to stop.
/// Sets the shutdown flag and deinits the Io net Server, which together cause
/// the blocking accept() call to return (with any error) and the accept loop to
/// exit cleanly.
pub fn shutdown() void {
    shutdown_requested.store(true, .release);

    server_mutex.lock();
    defer server_mutex.unlock();

    if (global_server) |s| {
        s.deinit(core.time.io());
        global_server = null;
    }
}

// ============================================================================
// Server entry point
// ============================================================================

pub fn start(allocator: std.mem.Allocator, cfg: *const app_config.AppConfig) !void {
    const host = cfg.server.host;
    const port = cfg.server.port;

    // Reset shutdown flag in case the server is restarted within the same process.
    shutdown_requested.store(false, .release);

    log.info("Starting zig-zag proxy server on {s}:{d}...", .{ host, port });
    log.info("Loaded providers: {d}", .{cfg.core.providers.count()});

    const io = core.time.io();

    // Parse the listen address using a stack buffer — no allocation needed.
    var addr_buf: [64]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch
        return error.InvalidAddress;
    const address = std.Io.net.IpAddress.parseLiteral(addr_str) catch
        return error.InvalidAddress;

    var server = try std.Io.net.IpAddress.listen(&address, io, .{
        .reuse_address = true,
    });
    // NOTE: We do NOT defer server.deinit() here.
    // shutdown() owns deinit when called externally.
    // If we exit normally (no shutdown), we deinit below after the loop.

    // Register in global state so shutdown() can close the socket.
    {
        server_mutex.lock();
        global_server = &server;
        server_mutex.unlock();
    }

    log.info("Listening on http://{s}:{d}", .{ host, port });
    log.info("Endpoints:", .{});
    log.info("  POST /v1/chat/completions", .{});
    log.info("  POST /v1/responses", .{});
    log.info("  POST /v1/messages", .{});
    log.info("  GET  /v1/models", .{});
    log.info("Server started on {s}:{d}", .{ host, port });

    // Accept loop: dispatch each connection concurrently via the Io runtime.
    // The loop exits when shutdown() sets shutdown_requested and tears down the
    // listener (any resulting accept() error breaks the loop), or when accept()
    // returns SocketNotListening/Canceled. All in-flight connections run to
    // completion before we return.
    var group: std.Io.Group = .init;
    while (true) {
        const stream = server.accept(io) catch |err| {
            // If shutdown was requested, any accept() error means the listener
            // was torn down — exit cleanly regardless of the specific error.
            // (The error is platform-dependent: SocketNotListening/Canceled on
            // some platforms, error.Unexpected on macOS.)
            if (shutdown_requested.load(.acquire)) break;

            switch (err) {
                error.SocketNotListening, error.Canceled => break,
                else => {
                    // Not shutting down but accept() failed. Log and back off
                    // briefly so a persistent error cannot busy-loop and flood
                    // the log with thousands of identical warnings.
                    log.warn("Failed to accept connection: {}", .{err});
                    core.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
            }
        };

        // Wrap the Io stream into our Connection type (same handle type) so
        // all existing handlers are untouched.
        const connection = net.Connection{ .handle = stream.socket.handle };

        group.@"async"(io, handleConnectionTask, .{ allocator, connection, cfg.server });
    }

    // Wait for all in-flight connections to finish before returning.
    group.@"await"(io) catch {};

    // Clear global server reference.
    // If shutdown() already called deinit(), global_server is already null.
    {
        server_mutex.lock();
        defer server_mutex.unlock();
        if (global_server != null) {
            global_server = null;
            server.deinit(io);
        }
    }

    log.info("Server stopped", .{});
}

// ============================================================================
// Connection handling
// ============================================================================

fn handleConnectionTask(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    server_cfg: app_config.ServerConfig,
) void {
    handleConnection(allocator, connection, server_cfg) catch |err| {
        log.warn("Error handling connection: {}", .{err});
    };
}

fn handleConnection(allocator: std.mem.Allocator, connection: net.Connection, server_cfg: app_config.ServerConfig) !void {
    defer connection.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    // Size limits from config
    const max_header_size: usize = @intCast(server_cfg.max_header_size);
    const max_body_size: usize = @intCast(server_cfg.max_body_size);

    // Read the full request into a dynamically grown buffer so large bodies
    // are not silently truncated.
    var request_buf: std.ArrayList(u8) = .empty;

    var read_buf: [16384]u8 = undefined;
    var header_end: ?usize = null;
    var content_length: ?usize = null;

    // Phase 1: read until we have the full headers (find \r\n\r\n).
    while (true) {
        const n = connection.read(&read_buf) catch |err| {
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
                _ = try connection.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n");
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
                    _ = try connection.writeAll("HTTP/1.1 413 Content Too Large\r\nConnection: close\r\n\r\n");
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

        try route.handler(request_allocator, connection, route.method, route.path, body);
    } else {
        _ = try connection.writeAll(NOT_FOUND_RESPONSE);
    }
}

fn parseContentLength(headers: []const u8) ?usize {
    // Case-insensitive search for Content-Length header.
    // Split on \n and trim \r to handle both CRLF and LF-only line endings.
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
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
