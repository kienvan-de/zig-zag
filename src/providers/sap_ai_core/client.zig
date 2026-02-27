const std = @import("std");
const SapAiCore = @import("types.zig");
const config_mod = @import("../../config.zig");
const token_cache = @import("../../cache/token_cache.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

/// OAuth token response
const OAuthTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
};

pub const SapAiCoreClient = struct {
    allocator: std.mem.Allocator,
    api_domain: []const u8,
    deployment_id: []const u8,
    resource_group: []const u8,
    oauth_domain: []const u8,
    oauth_client_id: []const u8,
    oauth_client_secret: []const u8,
    retry_count: u32,
    retry_delay_ms: u64,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    const DEFAULT_TIMEOUT_MS = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;
    const DEFAULT_RETRY_COUNT = 0;
    const DEFAULT_RETRY_DELAY_MS = 1000;
    const TOKEN_EXPIRY_BUFFER_SECONDS: i64 = 60;

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !SapAiCoreClient {
        const api_domain = provider_config.getString("api_domain") orelse {
            log.err("SAP AI Core provider config missing 'api_domain' field", .{});
            return error.MissingApiDomain;
        };

        const deployment_id = provider_config.getString("deployment_id") orelse {
            log.err("SAP AI Core provider config missing 'deployment_id' field", .{});
            return error.MissingDeploymentId;
        };

        const resource_group = provider_config.getString("resource_group") orelse {
            log.err("SAP AI Core provider config missing 'resource_group' field", .{});
            return error.MissingResourceGroup;
        };

        const oauth_domain = provider_config.getString("oauth_domain") orelse {
            log.err("SAP AI Core provider config missing 'oauth_domain' field", .{});
            return error.MissingOAuthDomain;
        };

        const oauth_client_id = provider_config.getString("oauth_client_id") orelse {
            log.err("SAP AI Core provider config missing 'oauth_client_id' field", .{});
            return error.MissingOAuthClientId;
        };

        const oauth_client_secret = provider_config.getString("oauth_client_secret") orelse {
            log.err("SAP AI Core provider config missing 'oauth_client_secret' field", .{});
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

    pub fn deinit(self: *SapAiCoreClient) void {
        self.client.deinit();
    }

    /// Build headers for SAP AI Core API (requires access token)
    fn buildHeaders(self: *SapAiCoreClient, auth_buffer: []u8, headers_buf: []std.http.Header, access_token: []const u8) ![]std.http.Header {
        const auth_value = try std.fmt.bufPrint(auth_buffer, "Bearer {s}", .{access_token});

        headers_buf[0] = .{ .name = "Authorization", .value = auth_value };
        headers_buf[1] = .{ .name = "ai-resource-group", .value = self.resource_group };
        headers_buf[2] = .{ .name = "Content-Type", .value = "application/json" };

        return headers_buf[0..3];
    }

    /// Fetch list of available models from SAP AI Core
    pub fn listModels(self: *SapAiCoreClient) !std.json.Parsed(SapAiCore.SapModelsResponse) {
        // Get access token
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v2/lm/scenarios/foundation-models/models", .{self.api_domain});

        // Build headers (JWT tokens can be 7000+ chars)
        var auth_buffer: [8192]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf, access_token);

        // Make GET request
        var response = try self.client.get(url, headers);
        defer response.deinit();

        // Check status code
        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        // Parse response
        return std.json.parseFromSlice(
            SapAiCore.SapModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse SAP AI Core models response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Get a valid OAuth access token, using global cache
    /// Returns owned memory that the caller must free
    fn getAccessToken(self: *SapAiCoreClient) ![]const u8 {
        // Check global cache first
        if (token_cache.get(self.allocator, self.oauth_domain, TOKEN_EXPIRY_BUFFER_SECONDS)) |cached_token| {
            return cached_token;
        }

        // Acquire fetch lock to prevent thundering herd
        const fetch_mutex = try token_cache.acquireFetchLock(self.oauth_domain);
        defer token_cache.releaseFetchLock(fetch_mutex);

        // Check cache again (another thread may have fetched while we waited)
        if (token_cache.get(self.allocator, self.oauth_domain, TOKEN_EXPIRY_BUFFER_SECONDS)) |cached_token| {
            log.debug("Token found in cache after acquiring lock for '{s}'", .{self.oauth_domain});
            return cached_token;
        }

        // Fetch new token
        log.info("Fetching new OAuth token for '{s}'", .{self.oauth_domain});
        const new_token = try self.fetchOAuthToken();
        defer self.allocator.free(new_token.access_token);

        // Store in global cache
        try token_cache.put(self.oauth_domain, new_token.access_token, new_token.expires_in);

        // Return from cache (returns a copy that caller must free)
        return token_cache.get(self.allocator, self.oauth_domain, TOKEN_EXPIRY_BUFFER_SECONDS) orelse error.TokenCacheError;
    }

    /// Fetch OAuth token from the OAuth server
    fn fetchOAuthToken(self: *SapAiCoreClient) !struct { access_token: []const u8, expires_in: i64 } {
        // Build OAuth URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/oauth/token", .{self.oauth_domain});

        // Build Basic Auth header (client_id:client_secret base64 encoded)
        var credentials_buffer: [1024]u8 = undefined;
        const credentials = try std.fmt.bufPrint(&credentials_buffer, "{s}:{s}", .{ self.oauth_client_id, self.oauth_client_secret });

        var base64_buffer: [2048]u8 = undefined;
        const base64_encoder = std.base64.standard;
        const encoded_len = base64_encoder.Encoder.calcSize(credentials.len);
        const encoded_credentials = base64_buffer[0..encoded_len];
        _ = base64_encoder.Encoder.encode(encoded_credentials, credentials);

        var auth_buffer: [2048]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_buffer, "Basic {s}", .{encoded_credentials});

        // Request body
        const request_body = "grant_type=client_credentials";

        // Build headers
        const extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        };

        // Make POST request
        var response = try self.client.post(url, &extra_headers, request_body);
        defer response.deinit();

        if (response.status != .ok) {
            log.err("OAuth token request failed with status: {}", .{response.status});
            return error.OAuthTokenError;
        }

        // Parse response
        const parsed = std.json.parseFromSlice(
            OAuthTokenResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse OAuth response: {}", .{err});
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
        return try std.fmt.bufPrint(buffer, "{s}/v2/inference/deployments/{s}/v2/completion", .{
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

                log.warn("Request failed with error {}, retrying ({d}/{d}) after {d}ms...", .{
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
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try self.buildApiUrl(&url_buffer);

        // Build headers
        var auth_buffer: [8192]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf, access_token);

        // Serialize request to JSON
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);
        try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})});

        // Make POST request
        var response = try self.client.post(url, headers, request_body.items);
        defer response.deinit();

        // Check status code
        if (response.status != .ok) {
            log.err("SAP AI Core request failed. Status: {} | URL: {s} | Request: {s} | Response: {s}", .{ response.status, url, request_body.items, response.body });
            return self.handleErrorResponse(response.status);
        }

        // Parse response JSON
        return std.json.parseFromSlice(
            SapAiCore.Response,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse SAP AI Core response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    fn handleErrorResponse(self: *SapAiCoreClient, status: std.http.Status) error{ AuthenticationError, RateLimitError, ServerError, InvalidStatusCode } {
        _ = self;
        log.debug("SAP AI Core response status: {} ({})", .{ @intFromEnum(status), status });
        return switch (status) {
            .unauthorized => error.AuthenticationError,
            .too_many_requests => error.RateLimitError,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.ServerError,
            else => {
                log.err("SAP AI Core unexpected status code: {} ({})", .{ @intFromEnum(status), status });
                return error.InvalidStatusCode;
            },
        };
    }

    /// Send a streaming request to SAP AI Core Orchestration API
    pub fn sendStreamingRequest(
        self: *SapAiCoreClient,
        request: SapAiCore.Request,
    ) !*StreamingResult {
        // Get access token
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try self.buildApiUrl(&url_buffer);
        log.debug("SAP AI Core streaming request URL: {s}", .{url});

        // Build headers
        var auth_buffer: [8192]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf, access_token);



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
    pub fn freeStreamingResult(self: *SapAiCoreClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};