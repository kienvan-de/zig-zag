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
const Anthropic = @import("types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");
const app_cache = @import("../../cache/app_cache.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_url: []const u8,
    api_version: []const u8,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    const DEFAULT_API_URL = "https://api.anthropic.com";
    const DEFAULT_API_VERSION = "2023-06-01";
    const DEFAULT_TIMEOUT_MS = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !AnthropicClient {
        const api_key = provider_config.getString("api_key") orelse {
            log.err("Anthropic provider config missing 'api_key' field", .{});
            return error.MissingApiKey;
        };

        const api_url = provider_config.getString("api_url") orelse DEFAULT_API_URL;
        const api_version = provider_config.getString("api_version") orelse DEFAULT_API_VERSION;
        const timeout_ms = provider_config.getInt("timeout_ms") orelse DEFAULT_TIMEOUT_MS;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse DEFAULT_MAX_RESPONSE_SIZE_MB;

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_url = api_url,
            .api_version = api_version,
            .config = provider_config,
            .client = http_client.HttpClient.initWithOptions(
                allocator,
                @intCast(timeout_ms),
                @intCast(max_response_size_mb * 1024 * 1024),
                null,
            ),
        };
    }

    pub fn deinit(self: *AnthropicClient) void {
        self.client.deinit();
    }

    /// Build headers for Anthropic API
    fn buildHeaders(self: *AnthropicClient, headers_buf: []std.http.Header) []std.http.Header {
        headers_buf[0] = .{ .name = "x-api-key", .value = self.api_key };
        headers_buf[1] = .{ .name = "anthropic-version", .value = self.api_version };
        headers_buf[2] = .{ .name = "Content-Type", .value = "application/json" };
        return headers_buf[0..3];
    }

    /// Fetch list of available models from Anthropic API
    pub fn listModels(self: *AnthropicClient) !std.json.Parsed(Anthropic.AnthropicModelsResponse) {
        // Build cache key using provider name from config
        var cache_key_buf: [128]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "models:{s}", .{self.config.name}) catch "models:anthropic";

        // Check cache
        if (app_cache.get(self.allocator, cache_key)) |cached_body| {
            defer self.allocator.free(cached_body);
            log.debug("Models cache hit for '{s}'", .{self.config.name});

            if (std.json.parseFromSlice(
                Anthropic.AnthropicModelsResponse,
                self.allocator,
                cached_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )) |parsed| {
                return parsed;
            } else |_| {
                log.warn("Failed to parse cached models for '{s}', fetching fresh", .{self.config.name});
            }
        }

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/models", .{self.api_url});

        // Build headers
        var headers_buf: [3]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

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
            Anthropic.AnthropicModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse Anthropic models response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Send a request to Anthropic Messages API (non-streaming)
    /// Returns parsed Anthropic.Response
    pub fn sendRequest(
        self: *AnthropicClient,
        request: Anthropic.Request,
    ) !std.json.Parsed(Anthropic.Response) {
        return self.sendRequestOnce(request);
    }

    /// Internal method to send a single request without retry logic
    fn sendRequestOnce(
        self: *AnthropicClient,
        request: Anthropic.Request,
    ) !std.json.Parsed(Anthropic.Response) {
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/messages", .{self.api_url});

        // Build headers
        var headers_buf: [3]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

        // Make POST request with JSON body and parse response
        return self.client.postJson(Anthropic.Response, url, headers, request) catch |err| {
            log.err("Failed to send Anthropic request: {}", .{err});
            return err;
        };
    }

    const HttpError = @import("../../errors.zig").HttpError;

    fn handleErrorResponse(self: *AnthropicClient, status: std.http.Status) HttpError {
        _ = self;
        return switch (status) {
            .unauthorized => error.AuthenticationError,
            .too_many_requests => error.RateLimitError,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.ServerError,
            else => error.InvalidStatusCode,
        };
    }

    /// Send a streaming request to Anthropic Messages API
    /// Returns a StreamingResult with an iterator for processing events
    /// Reads from socket on-demand - does not buffer full response
    pub fn sendStreamingRequest(
        self: *AnthropicClient,
        request: Anthropic.Request,
    ) !*StreamingResult {
        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/messages", .{self.api_url});

        // Build headers
        var headers_buf: [3]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

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
    pub fn freeStreamingResult(self: *AnthropicClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================
