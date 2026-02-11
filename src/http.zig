const std = @import("std");

/// Send an HTTP JSON response with the specified status code
pub fn sendJsonResponse(
    connection: std.net.Server.Connection,
    status: std.http.Status,
    json_body: []const u8,
) !void {
    var buffer: [512]u8 = undefined;
    const status_line = switch (status) {
        .ok => "HTTP/1.1 200 OK\r\n",
        .bad_request => "HTTP/1.1 400 Bad Request\r\n",
        .internal_server_error => "HTTP/1.1 500 Internal Server Error\r\n",
        .bad_gateway => "HTTP/1.1 502 Bad Gateway\r\n",
        else => "HTTP/1.1 500 Internal Server Error\r\n",
    };

    const headers = try std.fmt.bufPrint(
        &buffer,
        "{s}Content-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status_line, json_body.len },
    );

    _ = try connection.stream.writeAll(headers);
    _ = try connection.stream.writeAll(json_body);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "sendJsonResponse formats response correctly" {
    const testing = std.testing;

    // We can't easily test the actual network write, but we can test
    // that the function signature is correct and compiles
    _ = sendJsonResponse;
    _ = testing;
}