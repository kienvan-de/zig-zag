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
const SapAiCore = @import("types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const auth = @import("../../auth/mod.zig");
const log = @import("../../log.zig");
const app_cache = @import("../../cache/app_cache.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

pub const SapAiCoreClient = struct {
    allocator: std.mem.Allocator,
    api_domain: []const u8,
    deployment_id: []const u8,
    resource_group: []const u8,
    oauth_client_secret: []const u8,
    token_endpoint: []const u8,
    retry_count: u32,
    retry_delay_ms: u64,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,
    oauth: auth.OAuth,

    // Owned memory for token_endpoint
    token_endpoint_buf: []u8,

    const DEFAULT_TIMEOUT_MS = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;
    const DEFAULT_RETRY_COUNT = 0;
    const DEFAULT_RETRY_DELAY_MS = 1000;

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

        // Build token endpoint URL (owned memory)
        const token_endpoint_buf = try std.fmt.allocPrint(allocator, "{s}/oauth/token", .{oauth_domain});

        return .{
            .allocator = allocator,
            .api_domain = api_domain,
            .deployment_id = deployment_id,
            .resource_group = resource_group,
            .oauth_client_secret = oauth_client_secret,
            .token_endpoint = token_endpoint_buf,
            .token_endpoint_buf = token_endpoint_buf,
            .retry_count = @intCast(retry_count),
            .retry_delay_ms = @intCast(retry_delay_ms),
            .config = provider_config,
            .client = http_client.HttpClient.initWithOptions(
                allocator,
                @intCast(timeout_ms),
                @intCast(max_response_size_mb * 1024 * 1024),
                null,
            ),
            // Use oauth_domain as cache key (unique per SAP AI Core instance)
            .oauth = auth.OAuth.init(allocator, oauth_domain, oauth_client_id),
        };
    }

    pub fn deinit(self: *SapAiCoreClient) void {
        self.allocator.free(self.token_endpoint_buf);
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
        // Build cache key using provider name from config
        var cache_key_buf: [128]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "models:{s}", .{self.config.name}) catch "models:sap_ai_core";

        // Check cache
        if (app_cache.get(self.allocator, cache_key)) |cached_body| {
            defer self.allocator.free(cached_body);
            log.debug("Models cache hit for '{s}'", .{self.config.name});

            if (std.json.parseFromSlice(
                SapAiCore.SapModelsResponse,
                self.allocator,
                cached_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )) |parsed| {
                return parsed;
            } else |_| {
                log.warn("Failed to parse cached models for '{s}', fetching fresh", .{self.config.name});
            }
        }

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
        var response = try self.client.getJson(url, headers);
        defer response.deinit();

        // Check status code
        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        // Cache the response body (best-effort)
        app_cache.put(cache_key, response.body) catch |err| {
            log.warn("Failed to cache models for '{s}': {}", .{ self.config.name, err });
        };

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
    pub fn getAccessToken(self: *SapAiCoreClient) ![]const u8 {
        // 1. Check if we have a valid cached token
        if (self.oauth.getCachedToken()) |token| {
            log.debug("SAP AI Core: Using cached access token", .{});
            return token;
        }

        // 2. Acquire fetch lock to prevent thundering herd
        const lock_handle = try self.oauth.acquireFetchLock();
        defer self.oauth.releaseFetchLock(lock_handle);

        // 3. Check cache again (another thread may have fetched while we waited)
        if (self.oauth.getCachedToken()) |token| {
            log.debug("SAP AI Core: Token found in cache after acquiring lock", .{});
            return token;
        }

        // 4. Fetch new token using client_credentials
        log.info("SAP AI Core: Fetching new OAuth token", .{});
        var tokens = try auth.oauth.fetchClientCredentials(self.allocator, &self.client, .{
            .token_endpoint = self.token_endpoint,
            .client_id = self.oauth.client_id,
            .client_secret = self.oauth_client_secret,
        });
        defer tokens.deinit();

        // 5. Cache token (no refresh_token for client_credentials)
        try self.oauth.cacheTokens(tokens.access_token, null, tokens.expires_in);

        // 6. Return duplicated token
        return self.allocator.dupe(u8, tokens.access_token);
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
        var response = try self.client.postForm(url, headers, request_body.items);
        defer response.deinit();

        // Log request for debugging
        log.debug("[SAP] [SYNC] Request payload: {s}", .{request_body.items});

        // Check status code
        if (response.status != .ok) {
            log.err("[SAP] [SYNC] Request failed. Status: {} | URL: {s} | Request: {s} | Response: {s}", .{ response.status, url, request_body.items, response.body });
            return self.handleErrorResponse(response.status);
        }

        // Log response for debugging
        log.debug("[SAP] [SYNC] Response payload: {s}", .{response.body});

        // Parse response JSON
        return std.json.parseFromSlice(
            SapAiCore.Response,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("[SAP] [SYNC] Failed to parse response: {} | Body: {s}", .{ err, response.body });
            return error.InvalidResponse;
        };
    }

    const HttpError = @import("../../errors.zig").HttpError;

    fn handleErrorResponse(self: *SapAiCoreClient, status: std.http.Status) HttpError {
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
        log.debug("[SAP] [STREAM] Request URL: {s}", .{url});

        // Log request payload for debugging
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit(self.allocator);
        request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})}) catch {};
        log.debug("[SAP] [STREAM] Request payload: {s}", .{request_body.items});

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
