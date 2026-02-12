const std = @import("std");
const OpenAI = @import("types.zig");
const config_mod = @import("../../config.zig");

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

        try request_body.writer(self.allocator).print("{any}", .{std.json.fmt(request, .{})});

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
        return std.json.parseFromSlice(
            OpenAI.Response,
            self.allocator,
            response_body,
            .{},
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
};

// ============================================================================
// Unit Tests
// ============================================================================

test "OpenAIClient.init creates client with correct fields" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{"api_key": "sk-test-key-123"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    try testing.expectEqualStrings("sk-test-key-123", client.api_key);
}

test "OpenAIClient default constants are correct" {
    const testing = std.testing;

    try testing.expectEqualStrings("https://api.openai.com", OpenAIClient.DEFAULT_API_URL);
    try testing.expectEqual(30000, OpenAIClient.DEFAULT_TIMEOUT_MS);
    try testing.expectEqual(10, OpenAIClient.DEFAULT_MAX_RESPONSE_SIZE_MB);
    try testing.expectEqual(0, OpenAIClient.DEFAULT_RETRY_COUNT);
    try testing.expectEqual(1000, OpenAIClient.DEFAULT_RETRY_DELAY_MS);
}

test "OpenAIClient.handleErrorResponse maps status codes correctly" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{"api_key": "test-key"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    // Test authentication error
    try testing.expectEqual(
        error.AuthenticationError,
        client.handleErrorResponse(.unauthorized),
    );

    // Test rate limit error
    try testing.expectEqual(
        error.RateLimitError,
        client.handleErrorResponse(.too_many_requests),
    );

    // Test server errors
    try testing.expectEqual(
        error.ServerError,
        client.handleErrorResponse(.internal_server_error),
    );
    try testing.expectEqual(
        error.ServerError,
        client.handleErrorResponse(.bad_gateway),
    );
    try testing.expectEqual(
        error.ServerError,
        client.handleErrorResponse(.service_unavailable),
    );
    try testing.expectEqual(
        error.ServerError,
        client.handleErrorResponse(.gateway_timeout),
    );

    // Test other errors
    try testing.expectEqual(
        error.InvalidStatusCode,
        client.handleErrorResponse(.bad_request),
    );
    try testing.expectEqual(
        error.InvalidStatusCode,
        client.handleErrorResponse(.not_found),
    );
}

test "OpenAIClient stores allocator correctly" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{"api_key": "test-key"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    // Verify allocator is stored
    try testing.expect(client.allocator.ptr == allocator.ptr);
}

test "OpenAIClient can be initialized with different API keys" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with short key
    {
        const json_str =
            \\{"api_key": "short"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        const provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed.value,
        };

        var client = try OpenAIClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("short", client.api_key);
    }

    // Test with long key
    {
        const json_str =
            \\{"api_key": "sk-proj-very-long-key-with-many-characters-0123456789"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        const provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed.value,
        };

        var client = try OpenAIClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("sk-proj-very-long-key-with-many-characters-0123456789", client.api_key);
    }

    // Test with key containing special characters
    {
        const json_str =
            \\{"api_key": "sk-test_key.with$pecial#chars"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        const provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed.value,
        };

        var client = try OpenAIClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("sk-test_key.with$pecial#chars", client.api_key);
    }
}

test "OpenAIClient uses default values when not in config" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{"api_key": "test-key"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    try testing.expectEqualStrings(OpenAIClient.DEFAULT_API_URL, client.api_url);
    try testing.expectEqual(OpenAIClient.DEFAULT_TIMEOUT_MS, client.timeout_ms);
    try testing.expectEqual(OpenAIClient.DEFAULT_MAX_RESPONSE_SIZE_MB * 1024 * 1024, client.max_response_size);
    try testing.expectEqual(OpenAIClient.DEFAULT_RETRY_COUNT, client.retry_count);
    try testing.expectEqual(OpenAIClient.DEFAULT_RETRY_DELAY_MS, client.retry_delay_ms);
    try testing.expect(client.organization == null);
}

test "OpenAIClient uses custom config values when provided" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{
        \\  "api_key": "test-key",
        \\  "api_url": "https://custom.openai.com",
        \\  "organization": "org-test-123",
        \\  "timeout_ms": 60000,
        \\  "max_response_size_mb": 20,
        \\  "retry_count": 3,
        \\  "retry_delay_ms": 2000
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    try testing.expectEqualStrings("https://custom.openai.com", client.api_url);
    try testing.expectEqualStrings("org-test-123", client.organization.?);
    try testing.expectEqual(60000, client.timeout_ms);
    try testing.expectEqual(20 * 1024 * 1024, client.max_response_size);
    try testing.expectEqual(3, client.retry_count);
    try testing.expectEqual(2000, client.retry_delay_ms);
}

test "OpenAIClient.sendRequest retries on retryable errors" {
    // Note: This is a structural test - we can't easily test actual retry behavior
    // without mocking the HTTP client or network layer
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{
        \\  "api_key": "test-key",
        \\  "retry_count": 2,
        \\  "retry_delay_ms": 100
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    const provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed.value,
    };

    var client = try OpenAIClient.init(allocator, &provider_config);
    defer client.deinit();

    // Verify retry config is loaded
    try testing.expectEqual(2, client.retry_count);
    try testing.expectEqual(100, client.retry_delay_ms);
}

test "OpenAIClient handles organization header" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test without organization
    {
        const json_str =
            \\{"api_key": "test-key"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        const provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed.value,
        };

        var client = try OpenAIClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expect(client.organization == null);
    }

    // Test with organization
    {
        const json_str =
            \\{"api_key": "test-key", "organization": "org-123"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        const provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed.value,
        };

        var client = try OpenAIClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("org-123", client.organization.?);
    }
}