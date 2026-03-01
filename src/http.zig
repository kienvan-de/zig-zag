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
pub fn sendSseHeaders(connection: std.net.Server.Connection) !void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";
    _ = try connection.stream.writeAll(headers);
    metrics.addNetworkTx(headers.len);
}

/// Send a single SSE event line (data: <json>\n\n)
pub fn sendSseEvent(connection: std.net.Server.Connection, data: []const u8) !void {
    _ = try connection.stream.writeAll("data: ");
    _ = try connection.stream.writeAll(data);
    _ = try connection.stream.writeAll("\n\n");
    metrics.addNetworkTx(6 + data.len + 2); // "data: " + data + "\n\n"
}

/// Send SSE done marker
pub fn sendSseDone(connection: std.net.Server.Connection) !void {
    const done_msg = "data: [DONE]\n\n";
    _ = try connection.stream.writeAll(done_msg);
    metrics.addNetworkTx(done_msg.len);
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
    metrics.addNetworkTx(headers.len + json_body.len);
}

// ============================================================================
// Unit Tests
// ============================================================================
