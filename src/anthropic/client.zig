const std = @import("std");
const Anthropic = @import("types.zig");
const config_mod = @import("../config.zig");

pub const ApiError = error{
    InvalidStatusCode,
    InvalidResponse,
    NetworkError,
    AuthenticationError,
    RateLimitError,
    ServerError,
};

pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    config: *const config_mod.ProviderConfig,
    client: std.http.Client,

    const ANTHROPIC_API_URL = "https://api.anthropic.com";
    const ANTHROPIC_VERSION = "2023-06-01";

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !AnthropicClient {
        const api_key = provider_config.getString("api_key") orelse {
            std.debug.print("ERROR: Anthropic provider config missing 'api_key' field\n", .{});
            return error.MissingApiKey;
        };

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .config = provider_config,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *AnthropicClient) void {
        self.client.deinit();
    }

    /// Send a request to Anthropic Messages API (non-streaming)
    pub fn sendRequest(
        self: *AnthropicClient,
        request: Anthropic.Request,
    ) ![]const u8 {
        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})});

        const url = ANTHROPIC_API_URL ++ "/v1/messages";
        const uri = try std.Uri.parse(url);

        // Build extra headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
        };

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request using lower-level API for better control
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = &extra_headers,
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
            return try self.handleErrorResponse(response.head.status);
        }

        // Read response body
        const max_size = 10 * 1024 * 1024; // 10MB max
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        
        return try reader.readAlloc(self.allocator, max_size);
    }

    fn handleErrorResponse(self: *AnthropicClient, status: std.http.Status) ![]const u8 {
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

test "AnthropicClient.init creates client with correct fields" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = 
        \\{"api_key": "sk-ant-test-key-123"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    var provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed,
    };
    defer provider_config.deinit();

    var client = try AnthropicClient.init(allocator, &provider_config);
    defer client.deinit();

    try testing.expectEqualStrings("sk-ant-test-key-123", client.api_key);
}

test "AnthropicClient constants are correct" {
    const testing = std.testing;

    try testing.expectEqualStrings("https://api.anthropic.com", AnthropicClient.ANTHROPIC_API_URL);
    try testing.expectEqualStrings("2023-06-01", AnthropicClient.ANTHROPIC_VERSION);
}

test "AnthropicClient.handleErrorResponse maps status codes correctly" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = 
        \\{"api_key": "test-key"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    var provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed,
    };
    defer provider_config.deinit();

    var client = try AnthropicClient.init(allocator, &provider_config);
    defer client.deinit();

    // Test authentication error
    try testing.expectError(
        error.AuthenticationError,
        client.handleErrorResponse(.unauthorized),
    );

    // Test rate limit error
    try testing.expectError(
        error.RateLimitError,
        client.handleErrorResponse(.too_many_requests),
    );

    // Test server errors
    try testing.expectError(
        error.ServerError,
        client.handleErrorResponse(.internal_server_error),
    );
    try testing.expectError(
        error.ServerError,
        client.handleErrorResponse(.bad_gateway),
    );
    try testing.expectError(
        error.ServerError,
        client.handleErrorResponse(.service_unavailable),
    );
    try testing.expectError(
        error.ServerError,
        client.handleErrorResponse(.gateway_timeout),
    );

    // Test other errors
    try testing.expectError(
        error.InvalidStatusCode,
        client.handleErrorResponse(.bad_request),
    );
    try testing.expectError(
        error.InvalidStatusCode,
        client.handleErrorResponse(.not_found),
    );
}

test "AnthropicClient stores allocator correctly" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = 
        \\{"api_key": "test-key"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    var provider_config = config_mod.ProviderConfig{
        .allocator = allocator,
        .raw = parsed,
    };
    defer provider_config.deinit();

    var client = try AnthropicClient.init(allocator, &provider_config);
    defer client.deinit();

    // Verify allocator is stored
    try testing.expect(client.allocator.ptr == allocator.ptr);
}

test "AnthropicClient can be initialized with different API keys" {
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
        var provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed,
        };
        defer provider_config.deinit();

        var client = try AnthropicClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("short", client.api_key);
    }

    // Test with long key
    {
        const json_str = 
            \\{"api_key": "sk-ant-api03-very-long-key-with-many-characters-0123456789"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        var provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed,
        };
        defer provider_config.deinit();

        var client = try AnthropicClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("sk-ant-api03-very-long-key-with-many-characters-0123456789", client.api_key);
    }

    // Test with key containing special characters
    {
        const json_str = 
            \\{"api_key": "sk-ant_test.key-with$pecial#chars"}
        ;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        var provider_config = config_mod.ProviderConfig{
            .allocator = allocator,
            .raw = parsed,
        };
        defer provider_config.deinit();

        var client = try AnthropicClient.init(allocator, &provider_config);
        defer client.deinit();
        try testing.expectEqualStrings("sk-ant_test.key-with$pecial#chars", client.api_key);
    }
}