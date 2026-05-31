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
const metrics = @import("zag-core").metrics;
const net = @import("zag-core").net;

/// Send SSE (Server-Sent Events) headers to initiate a streaming response.
///
/// Writes the following HTTP/1.1 response headers to the connection:
///   - `Content-Type: text/event-stream` — marks the response as an SSE stream.
///   - `Cache-Control: no-cache` — prevents intermediaries from buffering events.
///   - `Connection: keep-alive` — keeps the TCP connection open for streaming.
///   - `Transfer-Encoding: chunked` — enables HTTP/1.1 chunked framing so the
///     total content length does not need to be known in advance.
///
/// **Call sequence**: Call this once at the start of a streaming response, then
/// send individual events via `sendSseEvent` / `sendSseChunk`, and finally
/// terminate the stream with `sendSseEnd`. Every byte written after this call
/// **must** be wrapped in chunked encoding (use the `sendSse*` helpers or
/// `ChunkedWriter`).
///
/// Network TX metrics are updated with the header bytes written.
pub fn sendSseHeaders(connection: net.Connection) !void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    _ = try connection.writeAll(headers);
    metrics.addNetworkTx(headers.len);
}

/// Send a single SSE data block as an HTTP chunked-encoded frame.
///
/// Wraps `data` in the HTTP/1.1 chunked transfer encoding format:
/// ```
/// {data.len in lowercase hex}\r\n
/// {data}\r\n
/// ```
/// For example, sending 13 bytes of payload produces:
/// ```
/// d\r\n
/// data: hello\n\n\r\n
/// ```
///
/// This is a low-level primitive — prefer `sendSseEvent` for sending
/// `data: {json}\n\n` formatted SSE events, or use `ChunkedWriter` when
/// integrating with `std.io.Writer`-based APIs.
///
/// Network TX metrics are updated with all bytes written (size line + data + trailing CRLF).
pub fn sendSseChunk(connection: net.Connection, data: []const u8) !void {
    var size_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;
    _ = try connection.writeAll(size_str);
    _ = try connection.writeAll(data);
    _ = try connection.writeAll("\r\n");
    metrics.addNetworkTx(size_str.len + data.len + 2);
}

/// Send the terminating chunk to end an HTTP chunked-encoded response.
///
/// Writes the zero-length terminating chunk (`0\r\n\r\n`) as required by
/// RFC 7230 §4.1 to signal the end of the chunked transfer. After this call
/// the response is complete and no further data should be written.
///
/// **Must** be called exactly once after all `sendSseChunk` / `sendSseEvent`
/// calls for a given response, otherwise the client will hang waiting for
/// more data.
///
/// Network TX metrics are updated with the terminator bytes.
pub fn sendSseEnd(connection: net.Connection) !void {
    const terminator = "0\r\n\r\n";
    _ = try connection.writeAll(terminator);
    metrics.addNetworkTx(terminator.len);
}

/// Send a single SSE event formatted as `data: {json}\n\n` inside a chunked frame.
///
/// This is a convenience wrapper around `sendSseChunk` that formats `data`
/// into the standard SSE event wire format:
/// ```
/// data: {"id":"chatcmpl-...","choices":[...]}\n\n
/// ```
/// The formatted event must fit within an 8 KiB internal buffer. If the
/// formatted output exceeds the buffer, the event is silently dropped
/// (returns without error) — this guards against unexpectedly large payloads
/// in a streaming context.
///
/// Use `sendSseDone` to emit the final `data: [DONE]\n\n` sentinel event.
pub fn sendSseEvent(connection: net.Connection, data: []const u8) !void {
    var buf: [8192]u8 = undefined;
    const event = std.fmt.bufPrint(&buf, "data: {s}\n\n", .{data}) catch return;
    try sendSseChunk(connection, event);
}

/// Send the SSE stream termination sentinel `data: [DONE]\n\n` as a chunked frame.
///
/// This is the OpenAI-convention end-of-stream marker. Clients watching the
/// SSE stream use this event to know that no more data chunks will follow.
///
/// **Call order**: Send this *after* the last real data event and *before*
/// `sendSseEnd` (which closes the HTTP chunked encoding).
pub fn sendSseDone(connection: net.Connection) !void {
    try sendSseChunk(connection, "data: [DONE]\n\n");
}

/// Send a complete HTTP JSON response with the given status code and body.
///
/// Writes a full HTTP/1.1 response (status line + headers + body) in one go.
/// The response includes `Content-Type: application/json`, a computed
/// `Content-Length`, and `Connection: close`.
///
/// **Supported status codes** (mapped to human-readable reason phrases):
///   - `200 OK`
///   - `400 Bad Request`
///   - `404 Not Found`
///   - `429 Too Many Requests`
///   - `500 Internal Server Error`
///   - `502 Bad Gateway`
///
/// Any other `std.http.Status` value falls back to `500 Internal Server Error`.
///
/// The internal header buffer is 512 bytes, which is sufficient for all
/// supported status lines plus the two fixed headers and the content-length
/// digit string. Returns an error if `json_body` is so large that the
/// header line overflows the buffer (extremely unlikely in practice).
///
/// Network TX metrics are updated with all bytes written (headers + body).
pub fn sendJsonResponse(
    connection: net.Connection,
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

    _ = try connection.writeAll(headers);
    _ = try connection.writeAll(json_body);
    metrics.addNetworkTx(headers.len + json_body.len);
}

// ============================================================================
// Convenience response helpers
// ============================================================================

/// Send a `404 Not Found` JSON error response.
///
/// Convenience helper that sends `{"error":"Not Found"}` with a 404 status.
/// Typically used by the router when no handler matches the request path.
pub fn sendNotFound(connection: net.Connection) !void {
    try sendJsonResponse(connection, .not_found, "{\"error\":\"Not Found\"}");
}

/// Send a `500 Internal Server Error` JSON error response.
///
/// Convenience helper that sends `{"error":"Internal Server Error"}` with a
/// 500 status. Used as a catch-all when an unexpected error occurs during
/// request handling.
pub fn sendInternalError(connection: net.Connection) !void {
    try sendJsonResponse(connection, .internal_server_error, "{\"error\":\"Internal Server Error\"}");
}

// ============================================================================
// ChunkedWriter — wraps a stream to add HTTP chunked transfer encoding
// ============================================================================

/// A writer adapter that wraps a raw `net.Connection` with HTTP/1.1 chunked
/// transfer encoding (RFC 7230 §4.1).
///
/// **Purpose**: Allows any code that accepts a `std.io.GenericWriter` (e.g.
/// `std.json.stringify`) to write directly to an HTTP response while
/// transparently framing each `write()` call as a single chunked frame.
///
/// **Write contract**: Every call to `write(data)` emits exactly one chunk:
/// ```
/// {data.len in lowercase hex}\r\n
/// {data}\r\n
/// ```
/// Zero-length writes are no-ops (return 0 immediately).
///
/// **Lifecycle**:
///   1. Create via `ChunkedWriter.init(connection.stream)`.
///   2. Obtain a `std.io.GenericWriter` via `writer()` and write data.
///   3. Call `finish()` to send the terminating zero-length chunk (`0\r\n\r\n`).
///
/// Network TX metrics are tracked automatically for every chunk and the
/// terminating frame.
pub const ChunkedWriter = struct {
    stream: net.Connection,

    /// Create a new `ChunkedWriter` wrapping the given TCP stream.
    pub fn init(stream: net.Connection) ChunkedWriter {
        return .{ .stream = stream };
    }

    /// Write `data` as a single HTTP chunked frame.
    ///
    /// Returns the number of payload bytes written (i.e. `data.len`), which
    /// matches the `std.io.GenericWriter` contract. Zero-length slices are
    /// no-ops. The framing overhead (hex size line + CRLFs) is not counted
    /// in the return value but *is* tracked in network TX metrics.
    pub fn write(self: *ChunkedWriter, data: []const u8) anyerror!usize {
        if (data.len == 0) return 0;
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;
        try self.stream.writeAll(size_str);
        try self.stream.writeAll(data);
        try self.stream.writeAll("\r\n");
        metrics.addNetworkTx(size_str.len + data.len + 2);
        return data.len;
    }

    /// Write all bytes as a single chunked frame (convenience wrapper).
    pub fn writeAll(self: *ChunkedWriter, data: []const u8) anyerror!void {
        if (data.len == 0) return;
        _ = try self.write(data);
    }

    /// Send the zero-length terminating chunk (`0\r\n\r\n`) to finalize the
    /// HTTP chunked response.
    ///
    /// **Must** be called exactly once after all data has been written.
    /// After this call the response is complete and the stream should not
    /// be written to again for this response.
    pub fn finish(self: *ChunkedWriter) !void {
        const terminator = "0\r\n\r\n";
        try self.stream.writeAll(terminator);
        metrics.addNetworkTx(terminator.len);
    }
};

// ============================================================================
// ArrayList Writer Adapter
// ============================================================================

/// A writer adapter that wraps an `ArrayList(u8)` + allocator and provides
/// a `.writeAll()` method, suitable for passing as `writer: anytype` to
/// functions like `chatComplete` / `messagesComplete`.
pub const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *ArrayListWriter, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================
