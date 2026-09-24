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
const common = @import("../openai/types.zig"); // shared primitives
const OpenAIChat = @import("chat_types.zig");
const OpenAIResponses = @import("responses_types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");
const app_cache = @import("../../cache/app_cache.zig");

// ============================================================================
// Transformer routing
// ============================================================================

pub const TransformerTag = enum {
    /// OpenAI Chat wire — /v1/chat/completions
    chat,
    /// OpenAI Responses wire — /v1/responses
    responses,
};

/// Return the transformer tag for an OpenAI provider config.
/// Reads "api_schema" from config: "latest" → .responses, anything else → .chat.
pub fn transformerFor(provider_config: *const config_mod.ProviderConfig) TransformerTag {
    const schema = provider_config.getString("api_schema") orelse "legacy";
    return if (std.mem.eql(u8, schema, "latest")) .responses else .chat;
}

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_url: []const u8,
    organization: ?[]const u8,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    const DEFAULT_API_URL = "https://api.openai.com";

    pub fn init(allocator: std.mem.Allocator, provider_config: *const config_mod.ProviderConfig) !OpenAIClient {
        const api_key = provider_config.getString("api_key") orelse {
            log.err("OpenAI provider config missing 'api_key' field", .{});
            return error.MissingApiKey;
        };

        const api_url = provider_config.getString("api_url") orelse DEFAULT_API_URL;
        const organization = provider_config.getString("organization");
        const timeout_ms = provider_config.getInt("timeout_ms") orelse config_mod.defaults.provider_timeout_ms;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse config_mod.defaults.provider_max_response_size_mb;

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_url = api_url,
            .organization = organization,
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

        var headers_count: usize = 2;
        headers_buf[0] = .{ .name = "Authorization", .value = auth_value };
        headers_buf[1] = .{ .name = "Content-Type", .value = "application/json" };

        if (self.organization) |org| {
            headers_buf[2] = .{ .name = "OpenAI-Organization", .value = org };
            headers_count = 3;
        }

        return headers_buf[0..headers_count];
    }

    /// Pick the upstream URL based on request type at comptime.
    /// OpenAIChat.Request → /v1/chat/completions
    /// OpenAIResponses.Request → /v1/responses
    fn urlForRequest(self: *OpenAIClient, buf: []u8, comptime Req: type) ![]const u8 {
        const path = if (Req == OpenAIResponses.Request) "/v1/responses" else "/v1/chat/completions";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ self.api_url, path });
    }

    /// Response type for a given request type
    fn ResponseType(comptime Req: type) type {
        if (Req == OpenAIResponses.Request) return OpenAIResponses.Response;
        return OpenAIChat.Response;
    }

    /// Fetch list of available models from OpenAI API
    pub fn listModels(self: *OpenAIClient) !std.json.Parsed(common.ModelsResponse) {
        var cache_key_buf: [128]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "models:{s}", .{self.config.name}) catch "models:openai";

        if (app_cache.get(self.allocator, cache_key)) |cached_body| {
            defer self.allocator.free(cached_body);
            log.debug("Models cache hit for '{s}'", .{self.config.name});
            if (std.json.parseFromSlice(
                common.ModelsResponse,
                self.allocator,
                cached_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )) |parsed| {
                return parsed;
            } else |_| {
                log.warn("Failed to parse cached models for '{s}', fetching fresh", .{self.config.name});
            }
        }

        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/models", .{self.api_url});
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);

        var response = try self.client.getJson(url, headers);
        defer response.deinit();

        if (response.status != .ok) return self.handleErrorResponse(response.status);

        app_cache.put(cache_key, response.body) catch |err| {
            log.warn("Failed to cache models for '{s}': {}", .{ self.config.name, err });
        };

        return std.json.parseFromSlice(
            common.ModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse OpenAI models response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Send a non-streaming request. Routes to /v1/chat/completions or /v1/responses
    /// based on request type at comptime.
    pub fn sendRequest(self: *OpenAIClient, request: anytype) !http_client.Result(ResponseType(@TypeOf(request)), common.ErrorResponse) {
        const Req = @TypeOf(request);
        const Resp = ResponseType(Req);
        var url_buffer: [512]u8 = undefined;
        const url = try self.urlForRequest(&url_buffer, Req);
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);
        return self.client.postJsonResult(Resp, common.ErrorResponse, url, headers, request) catch |err| {
            log.err("Failed to send OpenAI request: {}", .{err});
            return err;
        };
    }

    const errors_mod = @import("../../errors.zig");

    fn handleErrorResponse(self: *OpenAIClient, status: std.http.Status) errors_mod.UpstreamHttpError {
        _ = self;
        return errors_mod.statusToError(status);
    }

    /// Send a streaming request. Routes to /v1/chat/completions or /v1/responses
    /// based on request type at comptime.
    pub fn sendStreamingRequest(self: *OpenAIClient, request: anytype) !http_client.StreamStart(SSEIterator, common.ErrorResponse) {
        const Req = @TypeOf(request);
        var url_buffer: [512]u8 = undefined;
        const url = try self.urlForRequest(&url_buffer, Req);
        var auth_buffer: [512]u8 = undefined;
        var headers_buf: [3]std.http.Header = undefined;
        const headers = try self.buildHeaders(&auth_buffer, &headers_buf);
        return self.client.postStreamingResult(SSEIterator, common.ErrorResponse, url, headers, request);
    }

    /// Free a streaming result
    pub fn freeStreamingResult(self: *OpenAIClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================
