const std = @import("std");
const log = @import("log.zig");

/// Set socket read/write timeout
pub fn setSocketTimeout(handle: std.posix.socket_t, timeout_ms: u64) void {
    if (timeout_ms == 0) return;

    const timeout_sec: i64 = @intCast(timeout_ms / 1000);
    const timeout_usec: i32 = @intCast((timeout_ms % 1000) * 1000);
    const timeval = std.posix.timeval{
        .sec = timeout_sec,
        .usec = timeout_usec,
    };

    // Set read timeout
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch |err| {
        log.debug("Failed to set socket read timeout: {}", .{err});
    };

    // Set write timeout
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeval)) catch |err| {
        log.debug("Failed to set socket write timeout: {}", .{err});
    };
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
            .line_buffer = std.ArrayList(u8){},
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
            .client = std.http.Client{ .allocator = allocator },
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
            .client = std.http.Client{ .allocator = allocator },
            .timeout_ms = timeout_ms,
            .max_response_size = max_response_size,
            .delimiter = delimiter orelse DEFAULT_DELIMITER,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Send a GET request
    /// Returns HttpResponse with status and body. Caller must call response.deinit() when done.
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !HttpResponse {
        const uri = try std.Uri.parse(url);

        log.debug("HTTP GET: {s}", .{url});
        var req = self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        }) catch |err| {
            log.err("HTTP GET request creation failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        defer req.deinit();
        log.debug("HTTP GET: request created successfully", .{});

        // Apply socket timeout
        if (req.connection) |conn| {
            setSocketTimeout(conn.stream_reader.getStream().handle, self.timeout_ms);
        }

        // Send request (no body for GET)
        log.debug("HTTP GET: sending request...", .{});
        req.sendBodiless() catch |err| {
            log.err("HTTP GET sendBodiless failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP GET: request sent, waiting for response...", .{});

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            log.err("HTTP GET receiveHead failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        log.debug("HTTP GET: response received, status: {}", .{response.head.status});

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));

        return .{
            .status = response.head.status,
            .body = body,
            .allocator = self.allocator,
        };
    }

    /// Send a POST request with raw body
    /// Returns HttpResponse with status and body. Caller must call response.deinit() when done.
    pub fn post(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        request_body: []const u8,
    ) !HttpResponse {
        const uri = try std.Uri.parse(url);

        log.debug("HTTP POST: {s}", .{url});
        var req = self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        }) catch |err| {
            log.err("HTTP POST request creation failed: {} for URL: {s}", .{ err, url });
            return err;
        };
        defer req.deinit();
        log.debug("HTTP POST: request created successfully", .{});

        // Apply socket timeout
        if (req.connection) |conn| {
            setSocketTimeout(conn.stream_reader.getStream().handle, self.timeout_ms);
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
        req.connection.?.flush() catch |err| {
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

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));

        return .{
            .status = response.head.status,
            .body = body,
            .allocator = self.allocator,
        };
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
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(json_body, .{ .emit_null_optional_fields = false })});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        // Apply socket timeout
        if (req.connection) |conn| {
            setSocketTimeout(conn.stream_reader.getStream().handle, self.timeout_ms);
        }

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Check status code
        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        // Parse response JSON
        return std.json.parseFromSlice(
            T,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        );
    }

    /// Send a POST request with JSON body for streaming response
    /// Returns StreamingResult with iterator of specified type
    /// Caller must call freeStreamingResult() when done
    pub fn postStreaming(
        self: *HttpClient,
        comptime Iterator: type,
        url: []const u8,
        extra_headers: []const std.http.Header,
        json_body: anytype,
    ) !*StreamingResult(Iterator) {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(json_body, .{ .emit_null_optional_fields = false })});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        });
        errdefer req.deinit();

        // Apply socket timeout
        if (req.connection) |conn| {
            setSocketTimeout(conn.stream_reader.getStream().handle, self.timeout_ms);
        }

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // Allocate result on heap to ensure stable pointers for reader
        const result = try self.allocator.create(StreamingResult(Iterator));
        errdefer self.allocator.destroy(result);

        result.request = req;

        // Wait for response headers
        const redirect_buffer: [0]u8 = undefined;
        result.response = try result.request.receiveHead(&redirect_buffer);

        // Log request/response details for debugging (only on error to avoid huge logs)
        if (result.response.head.status != .ok) {
            log.err("HTTP POST streaming failed | Status: {} | URL: {s}", .{ result.response.head.status, url });
            log.err("HTTP POST streaming failed | Request body: {s}", .{request_body.items});

        }

        // Get reader for streaming - reads from socket on-demand
        const reader = result.response.reader(&result.transfer_buffer);
        result.iterator = Iterator.init(reader, self.delimiter, self.allocator);

        return result;
    }

    /// Free a streaming result allocated by postStreaming
    pub fn freeStreamingResult(self: *HttpClient, comptime Iterator: type, result: *StreamingResult(Iterator)) void {
        result.deinit();
        self.allocator.destroy(result);
    }

};
