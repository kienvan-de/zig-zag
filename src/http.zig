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
const errors = @import("zag-core").errors;

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
/// The event is dynamically allocated, so events of any size are supported.
///
/// Use `sendSseDone` to emit the final `data: [DONE]\n\n` sentinel event.
pub fn sendSseEvent(connection: net.Connection, allocator: std.mem.Allocator, data: []const u8) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "data: {s}\n\n", .{data});
    try sendSseChunk(connection, buf.items);
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
/// **Status line**: built from the status code and its reason phrase
/// (`errors.reasonPhrase`), so every `std.http.Status` — including the full
/// range of upstream error statuses (401/403/409/422/501/503/504/…) — is wired
/// through faithfully rather than collapsed to 500.
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
    const headers = try std.fmt.bufPrint(
        &buffer,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ @intFromEnum(status), errors.reasonPhrase(status), json_body.len },
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
// Error reply — map a completion error to an HTTP/SSE error response
// ============================================================================
//
// Shared by the /v1/chat/completions, /v1/messages, and /v1/responses handlers,
// which differ only in the "invalid model format" message (it embeds a
// protocol-appropriate example model). The error→status/type/message/code
// mapping itself lives in `errors.classifyError`; these helpers just render its
// result to the wire, so the handlers stay thin HTTP wrappers.

/// Send a completion error as a JSON HTTP response, before any response bytes
/// have been written (non-streaming, or a streaming failure that occurred
/// before SSE headers were committed).
///
/// If the pipeline already captured an upstream error body (`upstream_body`),
/// it is sent verbatim with the classified status. Otherwise a fresh
/// OpenAI-style error body is built from the classification.
/// `invalid_model_message` is the full message for a malformed model string
/// (it embeds a protocol-appropriate example, the sole per-handler difference).
pub fn sendSyncError(
    connection: net.Connection,
    allocator: std.mem.Allocator,
    err: anyerror,
    upstream_body: []const u8,
    invalid_model_message: []const u8,
) !void {
    const classified = errors.classifyError(err, invalid_model_message);
    if (upstream_body.len > 0) {
        try sendJsonResponse(connection, classified.status, upstream_body);
        return;
    }
    const error_json = try errors.createErrorResponse(
        allocator,
        classified.message,
        classified.error_type,
        classified.code,
    );
    defer allocator.free(error_json);
    try sendJsonResponse(connection, classified.status, error_json);
}

/// Send a completion error as an SSE `data:` event, after streaming has already
/// begun (SSE headers committed, so the HTTP status is locked to 200). Best
/// effort — a write failure here (e.g. client disconnected) is swallowed.
pub fn sendStreamingError(
    sse: *SseWriter,
    allocator: std.mem.Allocator,
    err: anyerror,
    invalid_model_message: []const u8,
) !void {
    const classified = errors.classifyError(err, invalid_model_message);
    const error_json = errors.createErrorResponse(
        allocator,
        classified.message,
        classified.error_type,
        null,
    ) catch return;
    defer allocator.free(error_json);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    buffer.print(allocator, "data: {s}\n\n", .{error_json}) catch return;
    sse.writeAll(buffer.items) catch {};
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

/// A writer that sends SSE response headers (200 OK) lazily on the first
/// `writeAll`, then frames all subsequent data as HTTP chunked-encoding.
///
/// **Purpose:** lets the streaming pipeline defer committing the HTTP status
/// until the first successful byte. If the upstream fails *before* any data is
/// written (`headers_sent == false`), the handler can still send a proper HTTP
/// error status. Once `headers_sent` is true, the status is locked to 200 and
/// further errors must be delivered as SSE `data:` events.
///
/// **Lifecycle:**
///   1. `SseWriter.init(connection)`
///   2. Write data via `writeAll` — headers are sent automatically on the first call.
///   3. `finish()` sends the chunked terminator (only if headers were sent).
pub const SseWriter = struct {
    stream: net.Connection,
    headers_sent: bool = false,

    pub fn init(stream: net.Connection) SseWriter {
        return .{ .stream = stream };
    }

    /// Send SSE headers if not already sent. Idempotent.
    pub fn ensureHeaders(self: *SseWriter) !void {
        if (self.headers_sent) return;
        try sendSseHeaders(self.stream);
        self.headers_sent = true;
    }

    /// Write `data` as a single chunked frame, sending SSE headers first if needed.
    pub fn writeAll(self: *SseWriter, data: []const u8) anyerror!void {
        if (data.len == 0) return;
        try self.ensureHeaders();
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch unreachable;
        try self.stream.writeAll(size_str);
        try self.stream.writeAll(data);
        try self.stream.writeAll("\r\n");
        metrics.addNetworkTx(size_str.len + data.len + 2);
    }

    /// Send the zero-length terminating chunk — only if headers were sent.
    /// A no-op when no data was ever written (headers never committed), so the
    /// handler can send a normal HTTP error response instead.
    pub fn finish(self: *SseWriter) !void {
        if (!self.headers_sent) return;
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

    /// Reset the buffer to empty, keeping capacity. Used by the error-body
    /// channel so each pipeline attempt overwrites the previous attempt's body.
    pub fn clearRetainingCapacity(self: *ArrayListWriter) void {
        self.list.clearRetainingCapacity();
    }

    /// Format and append to the buffer (supplies the allocator internally).
    pub fn print(self: *ArrayListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================
