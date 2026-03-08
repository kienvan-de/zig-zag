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
const metrics = @import("metrics.zig");

/// Send SSE (Server-Sent Events) headers to start a streaming response
/// Uses Transfer-Encoding: chunked for proper HTTP/1.1 streaming framing.
/// All subsequent writes MUST use sendSseChunk() and end with sendSseEnd().
pub fn sendSseHeaders(connection: std.net.Server.Connection) !void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    _ = try connection.stream.writeAll(headers);
    metrics.addNetworkTx(headers.len);
}

/// Send a single SSE data block as an HTTP chunked-encoded frame.
/// Format: <hex-size>\r\n<data>\r\n
pub fn sendSseChunk(connection: std.net.Server.Connection, data: []const u8) !void {
    var size_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;
    _ = try connection.stream.writeAll(size_str);
    _ = try connection.stream.writeAll(data);
    _ = try connection.stream.writeAll("\r\n");
    metrics.addNetworkTx(size_str.len + data.len + 2);
}

/// Send the terminating chunk (0\r\n\r\n) to end a chunked response.
pub fn sendSseEnd(connection: std.net.Server.Connection) !void {
    const terminator = "0\r\n\r\n";
    _ = try connection.stream.writeAll(terminator);
    metrics.addNetworkTx(terminator.len);
}

/// Send a single SSE event line (data: <json>\n\n) as a chunked frame.
pub fn sendSseEvent(connection: std.net.Server.Connection, data: []const u8) !void {
    var buf: [8192]u8 = undefined;
    const event = std.fmt.bufPrint(&buf, "data: {s}\n\n", .{data}) catch return;
    try sendSseChunk(connection, event);
}

/// Send SSE done marker as a chunked frame.
pub fn sendSseDone(connection: std.net.Server.Connection) !void {
    try sendSseChunk(connection, "data: [DONE]\n\n");
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
        .not_found => "HTTP/1.1 404 Not Found\r\n",
        .too_many_requests => "HTTP/1.1 429 Too Many Requests\r\n",
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
    metrics.addNetworkTx(headers.len + json_body.len);
}

// ============================================================================
// Convenience response helpers
// ============================================================================

/// Send a 404 Not Found JSON response
pub fn sendNotFound(connection: std.net.Server.Connection) !void {
    try sendJsonResponse(connection, .not_found, "{\"error\":\"Not Found\"}");
}

/// Send a 500 Internal Server Error JSON response
pub fn sendInternalError(connection: std.net.Server.Connection) !void {
    try sendJsonResponse(connection, .internal_server_error, "{\"error\":\"Internal Server Error\"}");
}

// ============================================================================
// Unit Tests
// ============================================================================
