const std = @import("std");
const OpenAI = @import("types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_url: []const u8,
    organization: ?[]const u8,
    retry_count: u32,
    retry_delay_ms: u64,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    const DEFAULT_API_URL = "https://api.openai.com";
    const DEFAULT_TIMEOUT_MS = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;
    const DEFAULT_RETRY_COUNT = 0;
    const DEFAULT_RETRY_DELAY_MS = 1000;

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !OpenAIClient {
        const api_key = provider_config.getString("api_key") orelse {
            log.err("OpenAI provider config missing 'api_key' field", .{});
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
            .retry_count = @intCast(retry_count),
            .retry_delay_ms = @intCast(retry_delay_ms),
            .config = provider_config,
            .client = http_client.HttpClient.initWithOptions(
                allocator,
                @intCast(timeout_ms),
                @intCast(max_response_size_mb * 1024 * 1024),
                null,
            ),
        };
    }

    pub fn deinit(self: *OpenAIClient) void {
        self.client.deinit();
    }

    /// Build authorization headers for OpenAI API
    fn buildHeaders(self: *OpenAIClient, auth_buffer: []u8, headers_buf: []std.http.Header) ![]std.http.Header {
        const auth_value = try std.fmt.bufPrint(auth_buffer, "Bearer {s}", .{self.api_key});

        var headers_count: usize = 1;
        headers_buf[0] = .{ .name = "Authorization", .value = auth_value };

        if (self.organization) |org| {
            headers_buf[1] = .{ .name = "OpenAI-Organization", .value = org };
            headers_count = 2;
        }

        return headers_buf[0..headers_count];
    }

    /// Fetch list of available models from OpenAI API
    pub fn listModels(self: *OpenAIClient) !std.json.Parsed(OpenAI.ModelsResponse) {
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/models", .{self.api_url});

        // Build headers
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);

        // Make GET request
        var response = try self.client.get(url, headers);
        defer response.deinit();

        // Check status code
        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        // Parse response
        return std.json.parseFromSlice(
            OpenAI.ModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse OpenAI models response: {}", .{err});
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
                // If out of attempts, return error
                if (attempts + 1 >= max_attempts) {
                    return err;
                }

                // Log retry attempt
                log.warn("OpenAI request failed with error {}, retrying ({d}/{d}) after {d}ms...", .{
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
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/chat/completions", .{self.api_url});

        // Build headers
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);

        // Make POST request with JSON body and parse response
        return self.client.postJson(OpenAI.Response, url, headers, request) catch |err| {
            log.err("Failed to send OpenAI request: {}", .{err});
            return err;
        };
    }

    fn handleErrorResponse(self: *OpenAIClient, status: std.http.Status) error{ AuthenticationError, RateLimitError, ServerError, InvalidStatusCode } {
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
    /// Reads from socket on-demand - does not buffer full response
    pub fn sendStreamingRequest(
        self: *OpenAIClient,
        request: OpenAI.Request,
    ) !*StreamingResult {
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/chat/completions", .{self.api_url});

        // Build headers
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);

        // Make streaming POST request
        const result = try self.client.postStreaming(SSEIterator, url, headers, request);

        // Check status code
        if (result.response.head.status != .ok) {
            self.client.freeStreamingResult(SSEIterator, result);
            return self.handleErrorResponse(result.response.head.status);
        }

        return result;
    }

    /// Free a streaming result allocated by sendStreamingRequest
    pub fn freeStreamingResult(self: *OpenAIClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================