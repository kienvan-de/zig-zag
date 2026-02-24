const std = @import("std");
const SapAiCore = @import("types.zig");
const config_mod = @import("../../config.zig");

/// Model object for models listing
pub const Model = struct {
    id: []const u8,
    object: []const u8 = "model",
    created: ?i64 = null,
    owned_by: ?[]const u8 = null,
};

/// Response from models endpoint
pub const ModelsResponse = struct {
    object: []const u8 = "list",
    data: []const Model,
};

/// Iterator for SAP AI Core SSE streaming responses
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

/// OAuth token response
const OAuthTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
};

/// Cached OAuth token
const CachedToken = struct {
    access_token: []const u8,
    expires_at: i64,
};

pub const SapAiCoreClient = struct {
    allocator: std.mem.Allocator,
    api_domain: []const u8,
    deployment_id: []const u8,
    resource_group: []const u8,
    oauth_domain: []const u8,
    oauth_client_id: []const u8,
    oauth_client_secret: []const u8,
    timeout_ms: u64,
    max_response_size: usize,
    retry_count: u32,
    retry_delay_ms: u64,
    config: *const config_mod.ProviderConfig,
    client: std.http.Client,
    cached_token: ?CachedToken = null,

    const DEFAULT_TIMEOUT_MS = 30000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;
    const DEFAULT_RETRY_COUNT = 0;
    const DEFAULT_RETRY_DELAY_MS = 1000;
    const TOKEN_EXPIRY_BUFFER_SECONDS = 60; // Refresh token 60 seconds before expiry

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !SapAiCoreClient {
        const api_domain = provider_config.getString("api_domain") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'api_domain' field\n", .{});
            return error.MissingApiDomain;
        };

        const deployment_id = provider_config.getString("deployment_id") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'deployment_id' field\n", .{});
            return error.MissingDeploymentId;
        };

        const resource_group = provider_config.getString("resource_group") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'resource_group' field\n", .{});
            return error.MissingResourceGroup;
        };

        const oauth_domain = provider_config.getString("oauth_domain") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'oauth_domain' field\n", .{});
            return error.MissingOAuthDomain;
        };

        const oauth_client_id = provider_config.getString("oauth_client_id") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'oauth_client_id' field\n", .{});
            return error.MissingOAuthClientId;
        };

        const oauth_client_secret = provider_config.getString("oauth_client_secret") orelse {
            std.debug.print("ERROR: SAP AI Core provider config missing 'oauth_client_secret' field\n", .{});
            return error.MissingOAuthClientSecret;
        };

        const timeout_ms = provider_config.getInt("timeout_ms") orelse DEFAULT_TIMEOUT_MS;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse DEFAULT_MAX_RESPONSE_SIZE_MB;
        const retry_count = provider_config.getInt("retry_count") orelse DEFAULT_RETRY_COUNT;
        const retry_delay_ms = provider_config.getInt("retry_delay_ms") orelse DEFAULT_RETRY_DELAY_MS;

        return .{
            .allocator = allocator,
            .api_domain = api_domain,
            .deployment_id = deployment_id,
            .resource_group = resource_group,
            .oauth_domain = oauth_domain,
            .oauth_client_id = oauth_client_id,
            .oauth_client_secret = oauth_client_secret,
            .timeout_ms = @intCast(timeout_ms),
            .max_response_size = @intCast(max_response_size_mb * 1024 * 1024),
            .retry_count = @intCast(retry_count),
            .retry_delay_ms = @intCast(retry_delay_ms),
            .config = provider_config,
            .client = std.http.Client{ .allocator = allocator },
            .cached_token = null,
        };
    }

    pub fn deinit(self: *SapAiCoreClient) void {
        if (self.cached_token) |token| {
            self.allocator.free(token.access_token);
        }
        self.client.deinit();
    }

    /// SAP AI Core doesn't have a standard models listing endpoint
    /// Returns null to indicate no models list available
    pub fn listModels(self: *SapAiCoreClient) !?ModelsResponse {
        _ = self;
        return null;
    }

    /// Get current timestamp in seconds
    fn getCurrentTimestamp() i64 {
        return @divTrunc(std.time.milliTimestamp(), 1000);
    }

    /// Get a valid OAuth access token, refreshing if necessary
    fn getAccessToken(self: *SapAiCoreClient) ![]const u8 {
        const now = getCurrentTimestamp();

        // Check if cached token is still valid
        if (self.cached_token) |token| {
            if (now < token.expires_at - TOKEN_EXPIRY_BUFFER_SECONDS) {
                return token.access_token;
            }
            // Token expired or about to expire, free it
            self.allocator.free(token.access_token);
            self.cached_token = null;
        }

        // Fetch new token
        const new_token = try self.fetchOAuthToken();
        self.cached_token = .{
            .access_token = new_token.access_token,
            .expires_at = now + new_token.expires_in,
        };

        return self.cached_token.?.access_token;
    }

    /// Fetch OAuth token from the OAuth server
    fn fetchOAuthToken(self: *SapAiCoreClient) !struct { access_token: []const u8, expires_in: i64 } {
        // Build OAuth URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/oauth/token", .{self.oauth_domain});
        const uri = try std.Uri.parse(url);

        // Build Basic Auth header (client_id:client_secret base64 encoded)
        var credentials_buffer: [512]u8 = undefined;
        const credentials = try std.fmt.bufPrint(&credentials_buffer, "{s}:{s}", .{ self.oauth_client_id, self.oauth_client_secret });

        var base64_buffer: [1024]u8 = undefined;
        const base64_encoder = std.base64.standard;
        const encoded_len = base64_encoder.Encoder.calcSize(credentials.len);
        const encoded_credentials = base64_buffer[0..encoded_len];
        _ = base64_encoder.Encoder.encode(encoded_credentials, credentials);

        var auth_buffer: [1100]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Basic {s}", .{encoded_credentials});

        // Request body
        const request_body = "grant_type=client_credentials";

        // Build headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/x-www-form-urlencoded" };

        // Make request
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            std.debug.print("OAuth token request failed with status: {}\n", .{response.head.status});
            return error.OAuthTokenError;
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        // Parse response
        const parsed = std.json.parseFromSlice(
            OAuthTokenResponse,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("Failed to parse OAuth response: {}\n", .{err});
            return error.OAuthParseError;
        };
        defer parsed.deinit();

        // Copy the access token since parsed will be freed
        const access_token = try self.allocator.dupe(u8, parsed.value.access_token);

        return .{
            .access_token = access_token,
            .expires_in = parsed.value.expires_in,
        };
    }

    /// Build the API endpoint URL
    fn buildApiUrl(self: *SapAiCoreClient, buffer: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buffer, "{s}/v2/inference/deployments/{s}/chat/completions?api-version=2024-02-01", .{
            self.api_domain,
            self.deployment_id,
        });
    }

    /// Send a request to SAP AI Core Orchestration API (non-streaming)
    pub fn sendRequest(
        self: *SapAiCoreClient,
        request: SapAiCore.Request,
    ) !std.json.Parsed(SapAiCore.Response) {
        var attempts: u32 = 0;
        const max_attempts = self.retry_count + 1;

        while (attempts < max_attempts) : (attempts += 1) {
            const result = self.sendRequestOnce(request) catch |err| {
                const is_retryable = switch (err) {
                    error.ServerError, error.RateLimitError => true,
                    error.AuthenticationError, error.InvalidStatusCode => false,
                    else => true,
                };

                if (!is_retryable or attempts + 1 >= max_attempts) {
                    return err;
                }

                std.debug.print("Request failed with error {}, retrying ({d}/{d}) after {d}ms...\n", .{
                    err,
                    attempts + 1,
                    self.retry_count,
                    self.retry_delay_ms,
                });

                std.Thread.sleep(self.retry_delay_ms * std.time.ns_per_ms);
                continue;
            };

            return result;
        }

        unreachable;
    }

    /// Internal method to send a single request without retry logic
    fn sendRequestOnce(
        self: *SapAiCoreClient,
        request: SapAiCore.Request,
    ) !std.json.Parsed(SapAiCore.Response) {
        // Get access token
        const access_token = try self.getAccessToken();

        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})});

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try self.buildApiUrl(&url_buffer);
        const uri = try std.Uri.parse(url);

        // Build Authorization header
        var auth_buffer: [2048]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{access_token});

        // Build extra headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "ai-resource-group", .value = self.resource_group },
        };

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            return self.handleErrorResponse(response.head.status);
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
        defer self.allocator.free(response_body);

        return std.json.parseFromSlice(
            SapAiCore.Response,
            self.allocator,
            response_body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("Failed to parse SAP AI Core response: {}\n", .{err});
            return error.InvalidResponse;
        };
    }

    fn handleErrorResponse(self: *SapAiCoreClient, status: std.http.Status) error{ AuthenticationError, RateLimitError, ServerError, InvalidStatusCode } {
        _ = self;
        return switch (status) {
            .unauthorized => error.AuthenticationError,
            .too_many_requests => error.RateLimitError,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.ServerError,
            else => error.InvalidStatusCode,
        };
    }

    /// Send a streaming request to SAP AI Core Orchestration API
    pub fn sendStreamingRequest(
        self: *SapAiCoreClient,
        request: SapAiCore.Request,
    ) !StreamingResult {
        // Get access token
        const access_token = try self.getAccessToken();

        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);

        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})});

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try self.buildApiUrl(&url_buffer);
        const uri = try std.Uri.parse(url);

        // Build Authorization header
        var auth_buffer: [2048]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{access_token});

        // Build extra headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "ai-resource-group", .value = self.resource_group },
        };

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request
        var req = try self.client.request(.POST, uri, .{
            .headers = headers,
            .extra_headers = &extra_headers,
        });
        errdefer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body.items);
        try body_writer.end();
        try req.connection.?.flush();

        // Wait for response headers
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

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