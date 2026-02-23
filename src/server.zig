const std = @import("std");
const config = @import("config.zig");
const router = @import("router.zig");
const errors = @import("errors.zig");
const http = @import("http.zig");

// HTTP response constants
const NOT_FOUND_RESPONSE =
    \\HTTP/1.1 404 Not Found
    \\Content-Type: application/json
    \\Content-Length: 22
    \\Connection: close
    \\
    \\{"error": "Not Found"}
;

pub fn start(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const host = cfg.server.host;
    const port = cfg.server.port;

    std.debug.print("Starting zig-zag proxy server on {s}:{d}...\n", .{ host, port });
    std.debug.print("Loaded providers: {d}\n", .{cfg.providers.count()});

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

    // Accept connections in a loop
    while (true) {
        const connection = try listener.accept();

        // Handle each connection (for now, single-threaded)
        handleConnection(allocator, connection, cfg) catch |err| {
            std.debug.print("Error handling connection: {}\n", .{err});
        };
    }
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
        const body = extractRequestBody(request_data) orelse {
            const error_json = try errors.createErrorResponse(
                request_allocator,
                "No request body found",
                .invalid_request_error,
                null,
            );
            defer request_allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
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
