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
const builtin = @import("builtin");
const time = @import("time.zig");
const log = @import("log.zig");

/// Allocate a decompression buffer sized for the given content encoding.
/// Returns an empty slice for identity (no compression).
/// Caller must free the returned buffer.
fn decompressBuffer(allocator: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

/// Configure an outbound provider socket for dead-connection detection.
///
/// We deliberately do NOT use `SO_RCVTIMEO`/`SO_SNDTIMEO`: the app's Io backend
/// is `std.Io.Threaded` (blocking, single-threaded), whose `netReadPosix` treats
/// `EAGAIN` — which a socket read timeout produces — as an impossible errno and
/// PANICS (`errnoBug` → abort). See the Sep-2026 SIGABRT crash.
///
/// Instead we enable TCP keepalive with an idle interval derived from
/// `timeout_ms`, so a genuinely-dead peer (vanished with no FIN/RST) is detected
/// and the read fails with `ETIMEDOUT`/`ECONNRESET` — both of which std handles
/// gracefully (no panic). Trade-off: keepalive bounds DEAD connections, not a
/// slow-but-alive upstream that stalls without disconnecting; that case relies on
/// the provider's server-side duration cap.
pub fn configureSocket(handle: std.posix.socket_t, timeout_ms: u64) void {
    if (timeout_ms == 0) return;

    // Enable keepalive probes on the connection. Use raw libc setsockopt: the
    // std wrapper panics (`unreachable`) on EBADF/ENOTSOCK/EINVAL/EFAULT, which
    // are possible if the fd raced closed. Best-effort, non-fatal on failure.
    const on: c_int = 1;
    if (std.c.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, @ptrCast(&on), @sizeOf(c_int)) != 0) {
        log.debug("Failed to enable SO_KEEPALIVE", .{});
        return;
    }

    // Idle seconds before the first keepalive probe, tuned by timeout_ms
    // (default provider timeout 300_000ms → 300s). Without this the OS default
    // idle (~2h on macOS) makes keepalive useless for timely detection.
    const idle_secs: c_int = @intCast(@max(1, timeout_ms / 1000));
    // macOS exposes the idle interval as TCP_KEEPALIVE (not in std); Linux uses
    // TCP_KEEPIDLE. Both live at the IPPROTO_TCP level.
    const idle_opt: u32 = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x10, // TCP_KEEPALIVE (macOS)
        .linux => std.posix.TCP.KEEPIDLE,
        else => {
            log.debug("Keepalive idle interval not configured: unsupported OS {s}", .{@tagName(builtin.os.tag)});
            return;
        },
    };
    if (std.c.setsockopt(handle, std.posix.IPPROTO.TCP, idle_opt, @ptrCast(&idle_secs), @sizeOf(c_int)) != 0) {
        log.debug("Failed to set keepalive idle interval", .{});
    }
}

/// Iterator for SSE streaming responses - reads from socket on-demand
pub const SSEIterator = struct {
    reader: *std.Io.Reader,
    done: bool,
    delimiter: u8,
    allocator: std.mem.Allocator,
    line_buffer: std.ArrayList(u8),

    pub fn init(reader: *std.Io.Reader, delimiter: u8, allocator: std.mem.Allocator) SSEIterator {
        return .{
            .reader = reader,
            .done = false,
            .delimiter = delimiter,
            .allocator = allocator,
            .line_buffer = std.ArrayList(u8).empty,
        };
    }

    /// Inert iterator for non-2xx responses — deinit-safe, never reads from socket.
    pub fn initDone(allocator: std.mem.Allocator) SSEIterator {
        return .{
            .reader = undefined,
            .done = true,
            .delimiter = '\n',
            .allocator = allocator,
            .line_buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *SSEIterator) void {
        self.line_buffer.deinit(self.allocator);
    }

    /// Get the next SSE data line (full line including "data: " prefix)
    /// Returns null when stream is complete
    /// Returns error on read/write/allocation failure
    /// Reads directly from socket - dynamically allocates for any line size
    pub fn next(self: *SSEIterator) !?[]const u8 {
        if (self.done) return null;

        while (true) {
            // Clear buffer for next line
            self.line_buffer.clearRetainingCapacity();

            // Read one line using streamDelimiterEnding (no size limit)
            var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.line_buffer);
            _ = self.reader.streamDelimiterEnding(&writer.writer, self.delimiter) catch |err| {
                writer.deinit();
                self.done = true;
                return err;
            };

            // Get written data from the writer (fromArrayList takes ownership)
            const written = writer.written();

            // Check if we got any data
            if (written.len == 0) {
                // Check if stream ended (reader buffer is empty)
                if (self.reader.end == self.reader.seek) {
                    // Transfer ownership back to line_buffer before returning
                    self.line_buffer = writer.toArrayList();
                    self.done = true;
                    return null;
                }
                // Consume the delimiter (streamDelimiterEnding leaves buffer starting with delimiter)
                _ = self.reader.takeDelimiterInclusive(self.delimiter) catch {
                    self.line_buffer = writer.toArrayList();
                    self.done = true;
                    return null;
                };
                // Transfer ownership back and continue
                self.line_buffer = writer.toArrayList();
                continue;
            }

            // Trim carriage return if present
            var line = written;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            if (line.len == 0) {
                self.line_buffer = writer.toArrayList();
                continue;
            }

            // Only return lines with "data: " prefix
            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line["data: ".len..];
                // Check for [DONE] marker
                if (std.mem.eql(u8, data, "[DONE]")) {
                    self.done = true;
                }
                // Transfer ownership back to line_buffer and return
                self.line_buffer = writer.toArrayList();
                return line;
            }
            // Transfer ownership back and continue
            self.line_buffer = writer.toArrayList();
        }
    }
};

/// Generic result of starting a streaming request
pub fn StreamingResult(comptime Iterator: type) type {
    return struct {
        iterator: Iterator,
        request: std.http.Client.Request,
        response: std.http.Client.Response,
        transfer_buffer: [8192]u8,

        pub fn deinit(self: *@This()) void {
            self.iterator.deinit();
            self.request.deinit();
        }
    };
}

/// SSE streaming result type alias
pub const SSEResult = StreamingResult(SSEIterator);

/// Tagged union returned by postJsonResult.
/// .ok owns a successfully parsed response; .err owns a parsed provider error body.
/// Caller must call .deinit() on whichever branch they hold.
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: std.json.Parsed(T),
        err: struct {
            status: std.http.Status,
            body: std.json.Parsed(E),
        },

        pub fn deinit(self: @This()) void {
            switch (self) {
                .ok => |v| v.deinit(),
                .err => |v| v.body.deinit(),
            }
        }
    };
}

/// Streaming start result — mirrors Result(T, E) for the streaming path.
/// .ok owns the live StreamingResult; .err owns the parsed upstream error body
/// captured when the initial response was non-2xx (before any streaming began).
pub fn StreamStart(comptime Iterator: type, comptime E: type) type {
    return union(enum) {
        ok: *StreamingResult(Iterator),
        err: struct {
            status: std.http.Status,
            body: std.json.Parsed(E),
        },
    };
}

/// Response from get/post requests
pub const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// HTTP Client wrapper for std.http.Client
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    timeout_ms: u64,
    max_response_size: usize,
    delimiter: u8,

    const DEFAULT_TIMEOUT_MS: u64 = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024; // 10MB
    const DEFAULT_DELIMITER: u8 = '\n';

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator, .io = time.io() },
            .timeout_ms = DEFAULT_TIMEOUT_MS,
            .max_response_size = DEFAULT_MAX_RESPONSE_SIZE,
            .delimiter = DEFAULT_DELIMITER,
        };
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        timeout_ms: u64,
        max_response_size: usize,
        delimiter: ?u8,
    ) HttpClient {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator, .io = time.io() },
            .timeout_ms = timeout_ms,
            .max_response_size = max_response_size,
            .delimiter = delimiter orelse DEFAULT_DELIMITER,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Options for GET requests
    pub const GetOptions = struct {
        /// Override Accept-Encoding. Null = default (gzip, deflate, zstd).
        /// Set to "identity" for servers whose responses Zig cannot auto-decompress
        /// (e.g. GitHub API with the low-level request/receiveHead path).
        accept_encoding: ?[]const u8 = null,
    };

    /// Generic GET request — full control via GetOptions.
    /// Returns HttpResponse. Caller must call response.deinit() when done.
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        options: GetOptions,
    ) !HttpResponse {
        const uri = try std.Uri.parse(url);

        log.debug("HTTP GET: {s}", .{url});

        const req_headers: std.http.Client.Request.Headers = if (options.accept_encoding) |enc|
            .{ .accept_encoding = .{ .override = enc } }
        else
            .{};

        var req = self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
            .headers = req_headers,
        }) catch |err| {
            log.err("HTTP GET request creation failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        defer req.deinit();
        log.debug("HTTP GET: request created successfully", .{});

        if (req.connection) |conn| {
            configureSocket(conn.stream_reader.stream.socket.handle, self.timeout_ms);
        }

        log.debug("HTTP GET: sending request...", .{});
        req.sendBodiless() catch |err| {
            log.err("HTTP GET sendBodiless failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP GET: request sent, waiting for response...", .{});

        const redirect_buffer: [0]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            log.err("HTTP GET receiveHead failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP GET: response received, status: {}", .{response.head.status});

        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try decompressBuffer(self.allocator, response.head.content_encoding);
        defer self.allocator.free(decompress_buf);
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
        const body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_response_size));

        return .{
            .status = response.head.status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// GET with default options (allows gzip/deflate compression).
    /// Use for most providers.
    pub fn getJson(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !HttpResponse {
        return self.get(url, extra_headers, .{});
    }

    /// GET with Accept-Encoding: identity (no compression).
    /// Use when the server may return compressed responses that Zig cannot auto-decompress
    /// (e.g. GitHub API via the low-level request/receiveHead path).
    pub fn getUncompressed(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !HttpResponse {
        return self.get(url, extra_headers, .{ .accept_encoding = "identity" });
    }

    /// Options for POST requests
    pub const PostOptions = struct {
        /// Override Accept-Encoding. Null = default (gzip, deflate, zstd).
        /// Set to "identity" for servers whose responses Zig cannot auto-decompress.
        accept_encoding: ?[]const u8 = null,
    };

    /// Generic POST request with raw body — full control via PostOptions.
    /// Returns HttpResponse. Caller must call response.deinit() when done.
    pub fn post(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        request_body: []const u8,
        options: PostOptions,
    ) !HttpResponse {
        const uri = try std.Uri.parse(url);

        log.debug("HTTP POST: {s}", .{url});

        const req_headers: std.http.Client.Request.Headers = if (options.accept_encoding) |enc|
            .{ .accept_encoding = .{ .override = enc } }
        else
            .{};

        var req = self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
            .headers = req_headers,
        }) catch |err| {
            log.err("HTTP POST request creation failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        defer req.deinit();
        log.debug("HTTP POST: request created successfully", .{});

        // Apply socket timeout
        if (req.connection) |conn| {
            configureSocket(conn.stream_reader.stream.socket.handle, self.timeout_ms);
        }

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.len };
        var buf: [4096]u8 = undefined;
        log.debug("HTTP POST: sending body ({d} bytes)...", .{request_body.len});
        var body_writer = req.sendBodyUnflushed(&buf) catch |err| {
            log.err("HTTP POST sendBodyUnflushed failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        body_writer.writer.writeAll(request_body) catch |err| {
            log.err("HTTP POST writeAll failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        body_writer.end() catch |err| {
            log.err("HTTP POST body_writer.end() failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        const flush_conn = req.connection orelse return error.UpstreamError;
        flush_conn.flush() catch |err| {
            log.err("HTTP POST flush failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP POST: body sent, waiting for response...", .{});

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            log.err("HTTP POST receiveHead failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP POST: response received, status: {}", .{response.head.status});

        // Read response body (with decompression for gzip/deflate/zstd)
        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try decompressBuffer(self.allocator, response.head.content_encoding);
        defer self.allocator.free(decompress_buf);
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
        const body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_response_size));

        return .{
            .status = response.head.status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// POST with default options (allows gzip/deflate compression).
    /// Use for most providers.
    pub fn postForm(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        request_body: []const u8,
    ) !HttpResponse {
        return self.post(url, extra_headers, request_body, .{});
    }

    /// POST with Accept-Encoding: identity (no compression).
    /// Use when the server may return compressed responses that Zig cannot auto-decompress
    /// (e.g. GitHub API device flow endpoints).
    pub fn postFormUncompressed(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        request_body: []const u8,
    ) !HttpResponse {
        return self.post(url, extra_headers, request_body, .{ .accept_encoding = "identity" });
    }

    /// Send a POST request with JSON body and parse JSON response
    /// Returns parsed JSON response of type T
    pub fn postJson(
        self: *HttpClient,
        comptime T: type,
        url: []const u8,
        extra_headers: []const std.http.Header,
        json_body: anytype,
    ) !std.json.Parsed(T) {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        try request_body.print(self.allocator, "{f}", .{std.json.fmt(json_body, .{ .emit_null_optional_fields = false })});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        // Apply socket timeout
        if (req.connection) |conn| {
            configureSocket(conn.stream_reader.stream.socket.handle, self.timeout_ms);
        }

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        (req.connection orelse return error.UpstreamError).flush() catch |err| return err;

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Read response body (with decompression for gzip/deflate/zstd)
        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try decompressBuffer(self.allocator, response.head.content_encoding);
        defer self.allocator.free(decompress_buf);
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);

        const response_body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        log.debug("[HTTP] postJson response: status={} body={s}", .{ response.head.status, response_body });

        if (response.head.status != .ok) {
            log.err("[HTTP] postJson non-200 | Status: {} | URL: {s}", .{ response.head.status, url });
            log.err("[HTTP] postJson non-200 | Request body: {s}", .{request_body.items});
            log.err("[HTTP] postJson non-200 | Response body: {s}", .{response_body});
        }

        // Parse response JSON
        return std.json.parseFromSlice(
            T,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("[HTTP] Failed to parse response: {} | body: {s}", .{ err, response_body });
            return err;
        };
    }

    /// Like postJson but returns Result(T, E) instead of erroring on non-200.
    /// On 200: parses body as T, returns .ok.
    /// On non-200: parses body as E, returns .err.
    /// Transport errors (connection failure, parse failure) are still returned as Zig errors.
    pub fn postJsonResult(
        self: *HttpClient,
        comptime T: type,
        comptime E: type,
        url: []const u8,
        extra_headers: []const std.http.Header,
        json_body: anytype,
    ) !Result(T, E) {
        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        try request_body.print(self.allocator, "{f}", .{std.json.fmt(json_body, .{ .emit_null_optional_fields = false })});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        if (req.connection) |conn| {
            configureSocket(conn.stream_reader.stream.socket.handle, self.timeout_ms);
        }

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        (req.connection orelse return error.UpstreamError).flush() catch |err| return err;

        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var transfer_buf: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const decompress_buf = try decompressBuffer(self.allocator, response.head.content_encoding);
        defer self.allocator.free(decompress_buf);
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);

        const response_body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        if (response.head.status != .ok) {
            log.err("[HTTP] postJsonResult non-200 | Status: {} | URL: {s}", .{ response.head.status, url });
            log.err("[HTTP] postJsonResult non-200 | Request body: {s}", .{request_body.items});
            log.err("[HTTP] postJsonResult non-200 | Response body: {s}", .{response_body});
            const parsed_err = std.json.parseFromSlice(
                E,
                self.allocator,
                response_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            ) catch |err| {
                log.err("[HTTP] Failed to parse error response: {} | body: {s}", .{ err, response_body });
                return error.HttpRequestFailed;
            };
            return .{ .err = .{ .status = response.head.status, .body = parsed_err } };
        }

        log.debug("[HTTP] postJsonResult response: status={} body={s}", .{ response.head.status, response_body });

        const parsed_ok = std.json.parseFromSlice(
            T,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("[HTTP] Failed to parse response: {} | body: {s}", .{ err, response_body });
            return err;
        };
        return .{ .ok = parsed_ok };
    }

    /// Send a POST request with JSON body for streaming response.
    /// Returns StreamStart(Iterator, E): .ok on 2xx (live stream), .err on non-2xx
    /// (parsed upstream error body + status). Caller must free the .ok result via
    /// freeStreamingResult() or deinit the .err body.
    pub fn postStreamingResult(
        self: *HttpClient,
        comptime Iterator: type,
        comptime E: type,
        url: []const u8,
        extra_headers: []const std.http.Header,
        json_body: anytype,
    ) !StreamStart(Iterator, E) {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        try request_body.print(self.allocator, "{f}", .{std.json.fmt(json_body, .{ .emit_null_optional_fields = false })});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        // Own `req` until it is moved into the heap `result` below. Once moved,
        // `result` (and its errdefer) owns teardown, so this defer is disarmed.
        var req_moved = false;
        defer if (!req_moved) req.deinit();

        // Apply socket timeout
        if (req.connection) |conn| {
            configureSocket(conn.stream_reader.stream.socket.handle, self.timeout_ms);
        }

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        (req.connection orelse return error.UpstreamError).flush() catch |err| return err;

        // Allocate the result on the heap and move `req` into it BEFORE calling
        // receiveHead. `Response.request` (set by receiveHead) and the body
        // reader (`&request.reader.interface`) both point into the request, so
        // receiveHead/reader MUST run against the heap-resident `result.request`
        // — not the stack `req` — or those pointers dangle once this function
        // returns. (Mirrors the pre-refactor postStreaming ordering.)
        const result = try self.allocator.create(StreamingResult(Iterator));
        var result_owned = false;
        // On an early error after `req` is moved into `result` (receiveHead or the
        // error-body decompress below), tear down BOTH the request (connection) and
        // the heap slot — deinit-ing the request too, so a failure here never leaks
        // the connection.
        errdefer if (!result_owned) {
            result.request.deinit();
            self.allocator.destroy(result);
        };
        result.request = req;
        req_moved = true; // result now owns req; disarm the req defer above.

        const redirect_buffer: [0]u8 = undefined;
        result.response = try result.request.receiveHead(&redirect_buffer);

        // On non-2xx: read + parse the error body from the heap-stable response,
        // then tear down `result` (request + heap slot). No streaming iterator is
        // created, so `result.deinit()` must not touch `iterator` — free the
        // request directly and destroy the slot.
        if (result.response.head.status != .ok) {
            const status = result.response.head.status;
            log.err("HTTP POST streaming failed | Status: {} | URL: {s}", .{ status, url });
            log.err("HTTP POST streaming failed | Request body: {s}", .{request_body.items});
            // Decompress the error body per Content-Encoding (providers such as
            // OpenRouter gzip their error responses). Reading it raw would fail to
            // parse and collapse a real 403/429/etc. into HttpRequestFailed with an
            // unreadable log — mirror the decompressing read used on the other paths.
            var err_transfer_buf: [4096]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const decompress_buf = try decompressBuffer(self.allocator, result.response.head.content_encoding);
            defer self.allocator.free(decompress_buf);
            const err_reader = result.response.readerDecompressing(&err_transfer_buf, &decompress, decompress_buf);
            const err_body = err_reader.allocRemaining(self.allocator, std.Io.Limit.limited(65536)) catch null;
            result.request.deinit();
            self.allocator.destroy(result);
            result_owned = true; // errdefer disarmed; `result` is gone.
            if (err_body) |b| {
                defer self.allocator.free(b);
                log.err("HTTP POST streaming failed | Response body: {s}", .{b});
                const parsed_err = std.json.parseFromSlice(
                    E,
                    self.allocator,
                    b,
                    .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
                ) catch return error.HttpRequestFailed;
                return .{ .err = .{ .status = status, .body = parsed_err } };
            }
            return error.HttpRequestFailed;
        }

        // 2xx: the reader points into result.request.reader — stable on the heap.
        result_owned = true; // handing `result` to the caller; disarm errdefer.
        const reader = result.response.reader(&result.transfer_buffer);
        result.iterator = Iterator.init(reader, self.delimiter, self.allocator);

        return .{ .ok = result };
    }

    /// Free a streaming result allocated by postStreaming
    pub fn freeStreamingResult(self: *HttpClient, comptime Iterator: type, result: *StreamingResult(Iterator)) void {
        result.deinit();
        self.allocator.destroy(result);
    }
};
