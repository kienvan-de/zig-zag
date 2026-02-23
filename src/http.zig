const std = @import("std");

/// Send SSE (Server-Sent Events) headers to start a streaming response
pub fn sendSseHeaders(connection: std.net.Server.Connection) !void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";
    _ = try connection.stream.writeAll(headers);
}

/// Send a single SSE event line (data: <json>\n\n)
pub fn sendSseEvent(connection: std.net.Server.Connection, data: []const u8) !void {
    _ = try connection.stream.writeAll("data: ");
    _ = try connection.stream.writeAll(data);
    _ = try connection.stream.writeAll("\n\n");
}

/// Send SSE done marker
pub fn sendSseDone(connection: std.net.Server.Connection) !void {
    _ = try connection.stream.writeAll("data: [DONE]\n\n");
}

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
