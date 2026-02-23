const std = @import("std");
const OpenAI = @import("types.zig");
const config_mod = @import("../../config.zig");

/// Response from OpenAI /v1/models endpoint
pub const Model = struct {
    id: []const u8,
    object: []const u8,
    created: ?i64 = null,
    owned_by: ?[]const u8 = null,
};

pub const ModelsResponse = struct {
    object: []const u8,
    data: []const Model,
};

/// Iterator for SSE streaming responses
pub const StreamIterator = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    done: bool = false,

    /// Get the next SSE data line (full line including "data: " prefix)
    /// Returns null when stream is complete
    pub fn next(self: *StreamIterator) ?[]const u8 {
        if (self.done) return null;

        while (self.lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;

            // Only return lines with "data: " prefix
            if (std.mem.startsWith(u8, trimmed, "data: ")) {
                const data = trimmed["data: ".len..];
                // Check for [DONE] marker
                if (std.mem.eql(u8, data, "[DONE]")) {
                    self.done = true;
                }
                return trimmed;
            }
        }

        self.done = true;
        return null;
    }

    pub fn deinit(self: *StreamIterator) void {
        self.allocator.free(self.body);
    }
};

/// Result of starting a streaming request
pub const StreamingResult = struct {
    iterator: StreamIterator,
    request: std.http.Client.Request,

    pub fn deinit(self: *StreamingResult) void {
        self.iterator.deinit();
        self.request.deinit();
    }
};

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_url: []const u8,
    organization: ?[]const u8,
    timeout_ms: u64,
    max_response_size: usize,
    retry_count: u32,
    retry_delay_ms: u64,
    config: *const config_mod.ProviderConfig,
    client: std.http.Client,

    const DEFAULT_API_URL = "https://api.openai.com";
    const DEFAULT_TIMEOUT_MS = 30000; // Reserved for future implementation
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;
    const DEFAULT_RETRY_COUNT = 0;
    const DEFAULT_RETRY_DELAY_MS = 1000;

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !OpenAIClient {
        const api_key = provider_config.getString("api_key") orelse {
            std.debug.print("ERROR: OpenAI provider config missing 'api_key' field\n", .{});
            return error.MissingApiKey;
        };

        const api_url = provider_config.getString("api_url") orelse DEFAULT_API_URL;
        const organization = provider_config.getString("organization");
        const timeout_ms = provider_config.getInt("timeout_ms") orelse DEFAULT_TIMEOUT_MS;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse DEFAULT_MAX_RESPONSE_SIZE_MB;
        const retry_count = provider_config.getInt("retry_count") orelse DEFAULT_RETRY_COUNT;
        const retry_delay_ms = provider_config.getInt("retry_delay_ms") orelse DEFAULT_RETRY_DELAY_MS;

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_url = api_url,
            .organization = organization,
            .timeout_ms = @intCast(timeout_ms),
            .max_response_size = @intCast(max_response_size_mb * 1024 * 1024),
            .retry_count = @intCast(retry_count),
            .retry_delay_ms = @intCast(retry_delay_ms),
            .config = provider_config,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *OpenAIClient) void {
        self.client.deinit();
    }

    /// Fetch list of available models from OpenAI API
    pub fn listModels(self: *OpenAIClient) !std.json.Parsed(ModelsResponse) {
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/models", .{self.api_url});
        const uri = try std.Uri.parse(url);

        // Build Authorization header
        var auth_buffer: [512]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{self.api_key});

        // Build extra headers
        var extra_headers_buf: [2]std.http.Header = undefined;
        var extra_headers_count: usize = 1;
        extra_headers_buf[0] = .{ .name = "Authorization", .value = auth_value };

        if (self.organization) |org| {
            extra_headers_buf[1] = .{ .name = "OpenAI-Organization", .value = org };
            extra_headers_count = 2;
        }

        const extra_headers = extra_headers_buf[0..extra_headers_count];

        // Make GET request
        var req = try self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        // Send request (no body for GET)
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Check status code
        if (response.head.status != .ok) {
            return self.handleErrorResponse(response.head.status);
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        // Parse response
        return std.json.parseFromSlice(
            ModelsResponse,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("Failed to parse models response: {}\n", .{err});
            return error.InvalidResponse;
        };
    }

    /// Send a request to OpenAI Chat Completions API (non-streaming)
    /// Implements automatic retry logic based on retry_count and retry_delay_ms config
    /// Returns parsed OpenAI.Response
    pub fn sendRequest(
        self: *OpenAIClient,
        request: OpenAI.Request,
    ) !std.json.Parsed(OpenAI.Response) {
        var attempts: u32 = 0;
        const max_attempts = self.retry_count + 1;

        while (attempts < max_attempts) : (attempts += 1) {
            const result = self.sendRequestOnce(request) catch |err| {
                // Determine if error is retryable
                // Only retry on server errors and rate limits
                // Don't retry on auth errors or invalid status codes
                const is_retryable = switch (err) {
                    error.ServerError, error.RateLimitError => true,
                    error.AuthenticationError, error.InvalidStatusCode => false,
                    else => true, // Retry on other errors (network, allocation, etc.)
                };

                // If not retryable or out of attempts, return error
                if (!is_retryable or attempts + 1 >= max_attempts) {
                    return err;
                }

                // Log retry attempt
                std.debug.print("Request failed with error {}, retrying ({d}/{d}) after {d}ms...\n", .{
                    err,
                    attempts + 1,
                    self.retry_count,
                    self.retry_delay_ms,
                });

                // Wait before retry
                std.Thread.sleep(self.retry_delay_ms * std.time.ns_per_ms);
                continue;
            };

            return result;
        }

        unreachable;
    }

    /// Internal method to send a single request without retry logic
    fn sendRequestOnce(
        self: *OpenAIClient,
        request: OpenAI.Request,
    ) !std.json.Parsed(OpenAI.Response) {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{ .emit_null_optional_fields = false })});

        // Build URL from config
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/chat/completions", .{self.api_url});
        const uri = try std.Uri.parse(url);

        // Build Authorization header
        var auth_buffer: [512]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{self.api_key});

        // Build extra headers
        var extra_headers_buf: [2]std.http.Header = undefined;
        var extra_headers_count: usize = 1;
        extra_headers_buf[0] = .{ .name = "Authorization", .value = auth_value };

        // Add organization header if provided
        if (self.organization) |org| {
            extra_headers_buf[1] = .{ .name = "OpenAI-Organization", .value = org };
            extra_headers_count = 2;
        }

        const extra_headers = extra_headers_buf[0..extra_headers_count];

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request using lower-level API for better control
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = extra_headers,
        });
        defer req.deinit();

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
            return self.handleErrorResponse(response.head.status);
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        // Parse response JSON into OpenAI.Response
        // Use .alloc_always to ensure all strings are owned by the parsed result
        return std.json.parseFromSlice(
            OpenAI.Response,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            std.debug.print("Failed to parse OpenAI response: {}\n", .{err});
            return error.InvalidResponse;
        };
    }

    fn handleErrorResponse(self: *OpenAIClient, status: std.http.Status) error{AuthenticationError, RateLimitError, ServerError, InvalidStatusCode} {
        _ = self;
        return switch (status) {
            .unauthorized => error.AuthenticationError,
            .too_many_requests => error.RateLimitError,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.ServerError,
            else => error.InvalidStatusCode,
        };
    }

    /// Send a streaming request to OpenAI Chat Completions API
    /// Returns a StreamingResult with an iterator for processing chunks
    pub fn sendStreamingRequest(
        self: *OpenAIClient,
        request: OpenAI.Request,
    ) !StreamingResult {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{ .emit_null_optional_fields = false })});

        // Build URL from config
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/chat/completions", .{self.api_url});
        const uri = try std.Uri.parse(url);

        // Build Authorization header
        var auth_buffer: [512]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{self.api_key});

        // Build extra headers
        var extra_headers_buf: [2]std.http.Header = undefined;
        var extra_headers_count: usize = 1;
        extra_headers_buf[0] = .{ .name = "Authorization", .value = auth_value };

        // Add organization header if provided
        if (self.organization) |org| {
            extra_headers_buf[1] = .{ .name = "OpenAI-Organization", .value = org };
            extra_headers_count = 2;
        }

        const extra_headers = extra_headers_buf[0..extra_headers_count];

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = extra_headers,
        });
        errdefer req.deinit();

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response headers
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Check status code
        if (response.head.status != .ok) {
            return self.handleErrorResponse(response.head.status);
        }

        // Read entire response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));

        return StreamingResult{
            .iterator = StreamIterator{
                .allocator = self.allocator,
                .body = body,
                .lines = std.mem.splitScalar(u8, body, '\n'),
            },
            .request = req,
        };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

