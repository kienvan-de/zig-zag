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

//! Messages Handler
//!
//! Handles POST /v1/messages requests (Anthropic Messages API format).
//! All providers follow the same unified flow:
//!   1. Parse request as Anthropic schema
//!   2. Transformer converts Anthropic -> provider-native (pass-through for anthropic/hai)
//!   3. Client sends to upstream provider
//!   4. Transformer converts provider-native response -> Anthropic
//!   5. Track metrics (tokens, costs)

const std = @import("std");
const Anthropic = @import("../providers/anthropic/types.zig");
const errors = @import("../errors.zig");
const http = @import("../http.zig");
const utils = @import("../utils.zig");
const provider_mod = @import("../provider.zig");
const log = @import("../log.zig");
const metrics = @import("../metrics.zig");
const pricing = @import("../pricing.zig");
const config_mod = @import("../config.zig");

// Provider modules
const anthropic = struct {
    const client = @import("../providers/anthropic/client.zig");
    const transformer = @import("../providers/anthropic/transformer.zig");
};

const openai = struct {
    const client = @import("../providers/openai/client.zig");
    const transformer = @import("../providers/openai/transformer.zig");
};

const sap_ai_core = struct {
    const client = @import("../providers/sap_ai_core/client.zig");
    const transformer = @import("../providers/sap_ai_core/transformer.zig");
};

const hai = struct {
    const client = @import("../providers/hai/client.zig");
    const transformer = @import("../providers/anthropic/transformer.zig");
};

const copilot = struct {
    const client = @import("../providers/copilot/client.zig");
    const transformer = @import("../providers/openai/transformer.zig");
};

/// Handle POST /v1/messages requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    config: *const config_mod.Config,
) !void {
    _ = method;
    _ = path;

    // Parse Anthropic request
    const anthropic_request = std.json.parseFromSlice(
        Anthropic.Request,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("JSON parse error: {}", .{err});
        log.err("Raw request payload:\n{s}", .{body});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Invalid JSON in request body",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer anthropic_request.deinit();

    // Check if streaming
    const is_streaming = anthropic_request.value.stream orelse false;

    // Parse model string to extract provider
    const model_info = utils.parseModelString(anthropic_request.value.model, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, anthropic_request.value.model });
        const error_json = try errors.createErrorResponse(
            allocator,
            "Invalid model format. Expected 'provider/model-name' (e.g., 'anthropic/claude-3-5-sonnet-latest')",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer allocator.free(model_info.model);
    defer allocator.free(model_info.provider);

    // Try to get provider config by name
    const provider_config = config.providers.getPtr(model_info.provider) orelse {
        log.err("Provider not configured: '{s}'", .{model_info.provider});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Provider not configured",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };

    // Budget enforcement
    if (try utils.enforceBudget(config, allocator, connection)) return;

    // Route to provider
    if (provider_mod.Provider.fromString(model_info.provider)) |native_provider| {
        switch (native_provider) {
            .anthropic => try dispatch(anthropic.client.AnthropicClient, anthropic.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config),
            .hai => try dispatch(hai.client.HaiClient, hai.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config),
            .openai => try dispatch(openai.client.OpenAIClient, openai.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config),
            .copilot => try dispatch(copilot.client.CopilotClient, copilot.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config),
            .sap_ai_core => try dispatch(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        // Not a native provider - check for "compatible" field
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            const error_json = try errors.createErrorResponse(
                allocator,
                "Provider not supported and no 'compatible' field specified",
                .invalid_request_error,
                null,
            );
            defer allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
        };

        if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatch(anthropic.client.AnthropicClient, anthropic.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config);
        } else if (std.mem.eql(u8, compatible, "openai")) {
            try dispatch(openai.client.OpenAIClient, openai.transformer, is_streaming, allocator, connection, anthropic_request.value, model_info.model, model_info.provider, provider_config);
        } else {
            log.err("Unknown compatible provider type: '{s}'. Must be 'openai' or 'anthropic'", .{compatible});
            const error_json = try errors.createErrorResponse(
                allocator,
                "Unknown compatible provider type. Must be 'openai' or 'anthropic'",
                .invalid_request_error,
                null,
            );
            defer allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
        }
    }
}

/// Helper to dispatch to streaming or non-streaming handler
fn dispatch(
    comptime Client: type,
    comptime Transformer: type,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    request: Anthropic.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    if (is_streaming) {
        try handleProviderStreaming(Client, Transformer, allocator, connection, request, model, provider_name, provider_config);
    } else {
        try handleProvider(Client, Transformer, allocator, connection, request, model, provider_name, provider_config);
    }
}

// ============================================================================
// Unified provider handler (works for all providers via comptime duck typing)
//
// Transformer must have:
//   - transformFromAnthropic(Anthropic.Request, model, allocator) -> !ProviderRequest
//   - transformToAnthropicResponse(ProviderResponse, allocator, model) -> !Anthropic.Response
//   - cleanupFromAnthropicRequest(ProviderRequest, allocator) -> void
//   - cleanupAnthropicResponse(Anthropic.Response, allocator) -> void
//
// Client must have:
//   - init(allocator, provider_config) -> !Client
//   - deinit(*Client) -> void
//   - sendRequest(ProviderRequest) -> !Parsed(ProviderResponse)
// ============================================================================

fn handleProvider(
    comptime Client: type,
    comptime Transformer: type,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    request: Anthropic.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = std.time.milliTimestamp();
    log.info("[SYNC] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    // 1. Transform Anthropic request -> provider-native request
    const transform_start = std.time.milliTimestamp();
    const provider_request = Transformer.transformFromAnthropic(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to transform request", .invalid_request_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer Transformer.cleanupFromAnthropicRequest(provider_request, allocator);
    const transform_request_time = std.time.milliTimestamp() - transform_start;
    log.debug("[SYNC] Transform request completed in {d}ms", .{transform_request_time});

    // 2. Initialize client
    const client_init_start = std.time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[SYNC] Client initialization error: {} for model '{s}'", .{ err, request.model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to initialize provider client", .invalid_request_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer client.deinit();
    const client_init_time = std.time.milliTimestamp() - client_init_start;
    log.debug("[SYNC] Client init completed in {d}ms", .{client_init_time});

    // 3. Send request to provider
    const provider_request_start = std.time.milliTimestamp();
    const provider_response = client.sendRequest(provider_request) catch |err| {
        log.err("[SYNC] Provider API error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        const error_json = try errors.createErrorFromStatus(allocator, .bad_gateway, "Failed to communicate with upstream API");
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_gateway, error_json);
        return;
    };
    defer provider_response.deinit();
    const provider_request_time = std.time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // 4. Transform provider-native response -> Anthropic response
    const transform_response_start = std.time.milliTimestamp();
    const anthropic_response = Transformer.transformToAnthropicResponse(provider_response.value, allocator, request.model) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to transform response", .server_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .internal_server_error, error_json);
        return;
    };
    defer Transformer.cleanupAnthropicResponse(anthropic_response, allocator);
    const transform_response_time = std.time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // 5. Track tokens and costs
    const usage = anthropic_response.usage;
    const in_tokens: u64 = @intCast(usage.input_tokens);
    const out_tokens: u64 = @intCast(usage.output_tokens);
    metrics.addInputTokens(in_tokens);
    metrics.addOutputTokens(out_tokens);
    if (pricing.getCost(provider_name, model)) |cost_entry| {
        const cost = pricing.calculateCost(cost_entry, in_tokens, out_tokens);
        metrics.addInputCost(cost.input_cost);
        metrics.addOutputCost(cost.output_cost);
    }

    // 6. Serialize and send response
    const serialize_start = std.time.milliTimestamp();
    var response_buffer = std.ArrayList(u8){};
    defer response_buffer.deinit(allocator);
    try response_buffer.writer(allocator).print("{f}", .{std.json.fmt(anthropic_response, .{})});
    const serialize_time = std.time.milliTimestamp() - serialize_start;
    log.debug("[SYNC] Response serialization completed in {d}ms", .{serialize_time});

    const send_start = std.time.milliTimestamp();
    try http.sendJsonResponse(connection, .ok, response_buffer.items);
    const send_time = std.time.milliTimestamp() - send_start;
    log.debug("[SYNC] Response sent in {d}ms", .{send_time});

    const total_elapsed = std.time.milliTimestamp() - start_time;
    log.info("[SYNC] POST /v1/messages - completed | model='{s}/{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | provider_req={d}ms | transform_resp={d}ms | serialize={d}ms | send={d}ms", .{
        provider_name, model, total_elapsed, transform_request_time, client_init_time, provider_request_time, transform_response_time, serialize_time, send_time,
    });
}

// ============================================================================
// Unified streaming handler
//
// Additional Transformer requirements for streaming:
//   - AnthropicStreamState (struct with init/deinit/getUsage)
//   - transformStreamLineToAnthropic(line, *state, allocator) -> AnthropicStreamLineResult
// ============================================================================

fn handleProviderStreaming(
    comptime Client: type,
    comptime Transformer: type,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    request: Anthropic.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = std.time.milliTimestamp();
    log.info("[STREAM] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    // 1. Transform request (with stream=true)
    const transform_start = std.time.milliTimestamp();
    var mutable_request = request;
    mutable_request.stream = true;
    const provider_request = Transformer.transformFromAnthropic(mutable_request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to transform request", .invalid_request_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer Transformer.cleanupFromAnthropicRequest(provider_request, allocator);
    const transform_time = std.time.milliTimestamp() - transform_start;
    log.debug("[STREAM] Transform request completed in {d}ms", .{transform_time});

    // 2. Initialize client
    const client_init_start = std.time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[STREAM] Client initialization error: {} for model '{s}'", .{ err, request.model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to initialize provider client", .invalid_request_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer client.deinit();
    const client_init_time = std.time.milliTimestamp() - client_init_start;
    log.debug("[STREAM] Client init completed in {d}ms", .{client_init_time});

    // 3. Start streaming request
    const stream_connect_start = std.time.milliTimestamp();
    const stream_result = client.sendStreamingRequest(provider_request) catch |err| {
        log.err("[STREAM] Provider streaming error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        const error_json = try errors.createErrorResponse(allocator, "Failed to communicate with upstream API", .server_error, null);
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_gateway, error_json);
        return;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = std.time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Send SSE headers
    try http.sendSseHeaders(connection);

    // 4. Process upstream SSE lines through transformer -> Anthropic SSE events
    const process_start = std.time.milliTimestamp();
    var chunk_count: u32 = 0;
    var had_error = false;

    var stream_state = Transformer.AnthropicStreamState.init(allocator, request.model);
    defer stream_state.deinit();

    while (true) {
        const maybe_line = stream_result.iterator.next() catch |err| {
            had_error = true;
            const body_err = stream_result.response.bodyErr();
            if (body_err) |underlying| {
                log.err("[STREAM] Upstream read failed for model '{s}/{s}': {} (underlying: {})", .{ provider_name, model, err, underlying });
            } else {
                log.err("[STREAM] Upstream read failed for model '{s}/{s}': {} (after {d} chunks)", .{ provider_name, model, err, chunk_count });
            }
            break;
        };

        const line = maybe_line orelse break;

        const result = Transformer.transformStreamLineToAnthropic(line, &stream_state, allocator);
        switch (result) {
            .output => |output| {
                defer allocator.free(output);
                chunk_count += 1;
                http.sendSseChunk(connection, output) catch |write_err| {
                    log.err("[STREAM] Failed to write to client: {}", .{write_err});
                    had_error = true;
                    break;
                };
            },
            .skip => {},
        }
    }

    // Send chunked transfer terminator
    http.sendSseEnd(connection) catch |err| {
        log.err("[STREAM] Failed to send chunked terminator: {}", .{err});
    };

    // 5. Track tokens and costs from stream state
    const usage = stream_state.getUsage();
    if (usage.input_tokens > 0 or usage.output_tokens > 0) {
        metrics.addInputTokens(usage.input_tokens);
        metrics.addOutputTokens(usage.output_tokens);
        if (pricing.getCost(provider_name, model)) |cost_entry| {
            const cost = pricing.calculateCost(cost_entry, usage.input_tokens, usage.output_tokens);
            metrics.addInputCost(cost.input_cost);
            metrics.addOutputCost(cost.output_cost);
        }
    }

    const process_time = std.time.milliTimestamp() - process_start;
    log.debug("[STREAM] Processed {d} chunks in {d}ms", .{ chunk_count, process_time });

    const total_elapsed = std.time.milliTimestamp() - start_time;
    if (had_error) {
        log.warn("[STREAM] POST /v1/messages - completed with error | model='{s}/{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | stream_connect={d}ms | process={d}ms | chunks={d}", .{
            provider_name, model, total_elapsed, transform_time, client_init_time, stream_connect_time, process_time, chunk_count,
        });
    } else {
        log.info("[STREAM] POST /v1/messages - completed | model='{s}/{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | stream_connect={d}ms | process={d}ms | chunks={d}", .{
            provider_name, model, total_elapsed, transform_time, client_init_time, stream_connect_time, process_time, chunk_count,
        });
    }
}

