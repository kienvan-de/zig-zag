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
const Google = @import("types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");
const app_cache = @import("../../cache/app_cache.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

pub const GoogleAiStudioClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_url: []const u8,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    const DEFAULT_API_URL = "https://generativelanguage.googleapis.com";

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !GoogleAiStudioClient {
        const api_key = provider_config.getString("api_key") orelse {
            log.err("Google AI Studio provider config missing 'api_key' field", .{});
            return error.MissingApiKey;
        };

        const api_url = provider_config.getString("api_url") orelse DEFAULT_API_URL;
        const timeout_ms = provider_config.getInt("timeout_ms") orelse config_mod.defaults.provider_timeout_ms;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse config_mod.defaults.provider_max_response_size_mb;

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_url = api_url,
            .config = provider_config,
            .client = http_client.HttpClient.initWithOptions(
                allocator,
                @intCast(timeout_ms),
                @intCast(max_response_size_mb * 1024 * 1024),
                null,
            ),
        };
    }

    pub fn deinit(self: *GoogleAiStudioClient) void {
        self.client.deinit();
    }

    /// Build common headers (API key is passed as a URL query parameter, not a header).
    fn buildHeaders(_: *GoogleAiStudioClient, headers_buf: []std.http.Header) []std.http.Header {
        headers_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
        return headers_buf[0..1];
    }

    const HttpError = @import("../../errors.zig").HttpError;

    fn handleErrorResponse(self: *GoogleAiStudioClient, status: std.http.Status) HttpError {
        _ = self;
        return switch (status) {
            .unauthorized, .forbidden => error.AuthenticationError,
            .too_many_requests => error.RateLimitError,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.ServerError,
            else => error.InvalidStatusCode,
        };
    }

    /// Fetch the list of available Gemini models.
    /// GET /v1beta/models?key={api_key}
    pub fn listModels(self: *GoogleAiStudioClient) !std.json.Parsed(Google.ModelsResponse) {
        var cache_key_buf: [128]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "models:{s}", .{self.config.name}) catch "models:google_ai_studio";

        if (app_cache.get(self.allocator, cache_key)) |cached_body| {
            defer self.allocator.free(cached_body);
            log.debug("Models cache hit for '{s}'", .{self.config.name});
            if (std.json.parseFromSlice(
                Google.ModelsResponse,
                self.allocator,
                cached_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )) |parsed| {
                return parsed;
            } else |_| {
                log.warn("Failed to parse cached models for '{s}', fetching fresh", .{self.config.name});
            }
        }

        var url_buffer: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1beta/models?key={s}", .{ self.api_url, self.api_key });

        var headers_buf: [1]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

        var response = try self.client.getJson(url, headers);
        defer response.deinit();

        if (response.status != .ok) {
            return self.handleErrorResponse(response.status);
        }

        app_cache.put(cache_key, response.body) catch |err| {
            log.warn("Failed to cache models for '{s}': {}", .{ self.config.name, err });
        };

        return std.json.parseFromSlice(
            Google.ModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse Google AI Studio models response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Send a non-streaming generateContent request.
    ///
    /// `request.model` is used to build the URL path.
    /// `request.payload` is serialised as the POST body.
    ///
    /// POST /v1beta/models/{model}:generateContent?key={api_key}
    pub fn sendRequest(
        self: *GoogleAiStudioClient,
        request: Google.Request,
    ) !std.json.Parsed(Google.Response) {
        var url_buffer: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1beta/models/{s}:generateContent?key={s}", .{
            self.api_url, request.model, self.api_key,
        });

        var headers_buf: [1]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

        // Serialise only the payload (Request.jsonStringify delegates to payload).
        return self.client.postJson(Google.Response, url, headers, request) catch |err| {
            log.err("Failed to send Google AI Studio request: {}", .{err});
            return err;
        };
    }

    /// Send a streaming streamGenerateContent request.
    ///
    /// POST /v1beta/models/{model}:streamGenerateContent?alt=sse&key={api_key}
    pub fn sendStreamingRequest(
        self: *GoogleAiStudioClient,
        request: Google.Request,
    ) !*StreamingResult {
        var url_buffer: [1024]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}", .{
            self.api_url, request.model, self.api_key,
        });

        var headers_buf: [1]std.http.Header = undefined;
        const headers = self.buildHeaders(&headers_buf);

        const result = try self.client.postStreaming(SSEIterator, url, headers, request);

        if (result.response.head.status != .ok) {
            self.client.freeStreamingResult(SSEIterator, result);
            return self.handleErrorResponse(result.response.head.status);
        }

        return result;
    }

    /// Free a streaming result allocated by sendStreamingRequest.
    pub fn freeStreamingResult(self: *GoogleAiStudioClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================
