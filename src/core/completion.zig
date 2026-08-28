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

//! Core Completion Module
//!
//! Transport-agnostic LLM completion functions. Writes results to a generic
//! `writer: anytype` — the caller (HTTP handler, CLI tool, etc.) provides the
//! writer and handles framing.
//!
//! ## Public API
//!
//!   chatComplete       — OpenAI /v1/chat/completions (streaming + non-streaming)
//!   messagesComplete   — Anthropic /v1/messages      (streaming + non-streaming)
//!   listModels         — Fetch models from all providers (parallel or sequential)
//!   freeModels         — Free the slice returned by listModels

const std = @import("std");
const time = @import("time.zig");
const sync = @import("sync.zig");
const config_mod = @import("config.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");
const metrics = @import("metrics.zig");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");
const utils = @import("utils.zig");
const worker_pool = @import("worker_pool.zig");
const openai_types = @import("providers/openai/chat_types.zig");
const openai_responses_types = @import("providers/openai/responses_types.zig");
const anthropic_types = @import("providers/anthropic/types.zig");

// Provider modules — direct imports for comptime dispatch
const openai = struct {
    const client = @import("providers/openai/client.zig");
    const transformer = @import("providers/openai/chat_transformer.zig");
    const responses_transformer = @import("providers/openai/responses_transformer.zig");
};
const anthropic = struct {
    const client = @import("providers/anthropic/client.zig");
    const transformer = @import("providers/anthropic/transformer.zig");
};
const sap_ai_core = struct {
    const client = @import("providers/sap_ai_core/client.zig");
    const transformer = @import("providers/sap_ai_core/transformer.zig");
    const types = @import("providers/sap_ai_core/types.zig");
};
const hai = struct {
    const client = @import("providers/hai/client.zig");
};
const copilot = struct {
    const client = @import("providers/copilot/client.zig");
};

/// Re-exported OpenAI type definitions (`Request`, `Response`, `Model`, etc.).
/// Callers use `completion.OpenAIChat.Request` instead of importing the provider types directly.
pub const OpenAI = openai_types;

/// Re-exported OpenAI Responses API type definitions.
pub const ResponsesAPI = openai_responses_types;

/// Re-exported Anthropic type definitions (`Request`, `Response`, etc.).
/// Callers use `completion.Anthropic.Request` instead of importing the provider types directly.
pub const Anthropic = anthropic_types;

/// Errors returned by the public completion functions (`chatComplete`, `messagesComplete`).
/// Re-exported from `errors.zig` — the single source of truth for all error sets.
///
/// These are **well-known** error conditions that the caller (e.g. an HTTP handler) should
/// map to transport-specific responses — typically HTTP status codes and JSON error bodies.
/// Use `switch (err)` for exhaustive handling.
pub const CompletionError = errors.CompletionError;

// ============================================================================
// chatComplete — OpenAI format
// ============================================================================

/// Perform an OpenAI-format chat completion (`/v1/chat/completions`).
///
/// Streaming or non-streaming mode is determined by `request.stream`:
///   - **Streaming**: writes Server-Sent Events lines (`data: {json}\n\n`) followed
///     by a `data: [DONE]\n\n` sentinel to `writer`.
///   - **Non-streaming**: writes a single complete JSON response body to `writer`.
///
/// The caller provides `writer` (e.g. a `ChunkedWriter` for HTTP responses, an
/// `ArrayList(u8).writer()` for buffering) and is responsible for any framing
/// (HTTP headers, chunked transfer encoding, etc.).
///
/// **Pipeline**: enforceBudget → parseModel → resolve provider → transform request →
/// init client → send upstream → transform response → track metrics → write to `writer`.
///
/// Returns `CompletionError` for well-known conditions (budget exceeded, model parsing
/// failure, provider not configured, upstream error, etc.). The caller should map
/// these to transport-specific responses (e.g. HTTP 429 for `BudgetExceeded`).
pub fn chatComplete(
    writer: anytype,
    allocator: std.mem.Allocator,
    request: openai_types.Request,
) !void {
    const cfg = config_mod.get();

    // Budget enforcement
    try utils.enforceBudget(cfg);

    // Parse model
    const model_info = utils.parseModelString(request.model, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, request.model });
        return error.InvalidModelFormat;
    };
    defer allocator.free(model_info.model);
    defer allocator.free(model_info.provider);

    // Get provider config
    const provider_config = cfg.providers.getPtr(model_info.provider) orelse {
        log.err("Provider not configured: '{s}'", .{model_info.provider});
        return error.ProviderNotConfigured;
    };

    const is_streaming = request.stream orelse false;

    // Dispatch to provider
    if (provider_mod.Provider.fromString(model_info.provider)) |native_provider| {
        switch (native_provider) {
            .anthropic => try dispatchChat(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => {
                const schema = provider_config.getString("api_schema") orelse "legacy";
                if (std.mem.eql(u8, schema, "latest")) {
                    try chatViaResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                } else {
                    try dispatchChat(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                }
            },
            .sap_ai_core => try dispatchChat(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => try dispatchChat(hai.client.HaiClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .copilot => try dispatchChat(copilot.client.CopilotClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };
        const schema = provider_config.getString("api_schema") orelse "legacy";

        if (std.mem.eql(u8, compatible, "openai")) {
            if (std.mem.eql(u8, schema, "latest")) {
                try chatViaResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            } else {
                try dispatchChat(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            }
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchChat(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        }
    }
}

/// Attempt automatic re-authentication for sync-auth providers (SAP AI Core, HAI).
/// Returns `true` if auth succeeded and the request should be retried.
/// Returns `false` for async-auth providers (Copilot device flow) or on failure —
/// the caller should propagate `error.AuthRequired` to the transport layer.
fn tryAutoReauth(allocator: std.mem.Allocator, provider_name: []const u8) bool {
    log.info("[AUTH] Attempting auto-reauth for provider '{s}'...", .{provider_name});
    const result = config_mod.initiateAuth(allocator, provider_name);
    return switch (result) {
        .authenticated => true,
        .device_flow => false, // Copilot — async, can't retry
        .err => |e| {
            log.err("[AUTH] Auto-reauth failed for '{s}': {s}", .{ provider_name, e.message });
            return false;
        },
    };
}

fn dispatchChat(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: openai_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    if (is_streaming) {
        chatStreaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                return chatStreaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    } else {
        chatSync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                return chatSync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    }
}

fn chatSync(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    allocator: std.mem.Allocator,
    request: openai_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[SYNC] POST /v1/chat/completions - request received for model '{s}'", .{request.model});

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transform(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupRequest(provider_request, allocator);
    const transform_request_time = time.milliTimestamp() - transform_start;
    log.debug("[SYNC] Transform request completed in {d}ms", .{transform_request_time});

    // Init client
    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[SYNC] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[SYNC] Client init completed in {d}ms", .{client_init_time});

    // Send request
    const provider_request_start = time.milliTimestamp();
    const provider_response = client.sendRequest(provider_request) catch |err| {
        log.err("[SYNC] Provider API error: {} for model '{s}'", .{ err, request.model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return error.UpstreamError;
    };
    defer provider_response.deinit();
    const provider_request_time = time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // Transform response
    const transform_response_start = time.milliTimestamp();
    const openai_response = Transformer.transformResponse(provider_response.value, allocator, request.model) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}'", .{ err, request.model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupResponse(openai_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // Track tokens and costs
    if (openai_response.usage) |usage| {
        const in_tokens: u64 = @intCast(usage.prompt_tokens);
        const out_tokens: u64 = @intCast(usage.completion_tokens);
        metrics.addInputTokens(in_tokens);
        metrics.addOutputTokens(out_tokens);
        if (pricing.getCost(provider_name, model)) |cost_entry| {
            const cost = pricing.calculateCost(cost_entry, in_tokens, out_tokens);
            metrics.addInputCost(cost.input_cost);
            metrics.addOutputCost(cost.output_cost);
        }
    }

    // Serialize and write to writer
    const serialize_start = time.milliTimestamp();
    var response_buffer = std.ArrayList(u8).empty;
    defer response_buffer.deinit(allocator);
    try response_buffer.print(allocator, "{f}", .{std.json.fmt(openai_response, .{})});
    const serialize_time = time.milliTimestamp() - serialize_start;
    log.debug("[SYNC] Response serialization completed in {d}ms", .{serialize_time});

    try writer.writeAll(response_buffer.items);

    const total_elapsed = time.milliTimestamp() - start_time;
    log.info("[SYNC] POST /v1/chat/completions - completed | model='{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | provider_req={d}ms | transform_resp={d}ms | serialize={d}ms", .{
        request.model,
        total_elapsed,
        transform_request_time,
        client_init_time,
        provider_request_time,
        transform_response_time,
        serialize_time,
    });
}

fn chatStreaming(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    allocator: std.mem.Allocator,
    request: openai_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[STREAM] POST /v1/chat/completions - request received for model '{s}'", .{request.model});

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transform(request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupRequest(provider_request, allocator);
    const transform_time = time.milliTimestamp() - transform_start;
    log.debug("[STREAM] Transform request completed in {d}ms", .{transform_time});

    // Init client
    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[STREAM] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[STREAM] Client init completed in {d}ms", .{client_init_time});

    // Start streaming
    const stream_connect_start = time.milliTimestamp();
    const stream_result = client.sendStreamingRequest(provider_request) catch |err| {
        log.err("[STREAM] Provider streaming error: {} for model '{s}'", .{ err, request.model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return error.UpstreamError;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Initialize streaming state
    var state = Transformer.StreamState.init(allocator, request.model);
    defer state.deinit();

    // Process chunks
    const process_start = time.milliTimestamp();
    var chunk_count: u32 = 0;
    var first_chunk_time: ?i64 = null;
    var had_error = false;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    while (true) {
        _ = scratch.reset(.free_all);
        const sa = scratch.allocator();
        const maybe_line = stream_result.iterator.next() catch |err| {
            had_error = true;
            const body_err = stream_result.response.bodyErr();
            if (body_err) |underlying| {
                log.err("[STREAM] Upstream read failed for model '{s}': {} (underlying: {})", .{ request.model, err, underlying });
            } else {
                log.err("[STREAM] Upstream read failed for model '{s}': {} (after {d} chunks)", .{ request.model, err, chunk_count });
            }

            // Write SSE error event to client
            var buffer = std.ArrayList(u8).empty;
            defer buffer.deinit(sa);
            buffer.print(sa, "data: {{\"error\":{{\"message\":\"Upstream connection lost while streaming response\",\"type\":\"server_error\",\"code\":null}}}}\n\n", .{}) catch break;
            writer.writeAll(buffer.items) catch {};
            break;
        };

        const line = maybe_line orelse break;

        // Check for [DONE] marker (OpenAI format)
        if (std.mem.startsWith(u8, line, "data: [DONE]")) {
            break;
        }

        // Transform the chunk
        const result = Transformer.transformStreamLine(line, &state, allocator);
        switch (result) {
            .chunk => |parsed| {
                var chunk = parsed;
                defer chunk.deinit();

                if (first_chunk_time == null) {
                    first_chunk_time = time.milliTimestamp() - process_start;
                    log.debug("[STREAM] Time to first chunk: {d}ms", .{first_chunk_time.?});
                }
                chunk_count += 1;

                // Track tokens and costs from usage (usually in final chunk)
                if (chunk.value.usage) |usage| {
                    const in_tokens: u64 = @intCast(usage.prompt_tokens);
                    const out_tokens: u64 = @intCast(usage.completion_tokens);
                    metrics.addInputTokens(in_tokens);
                    metrics.addOutputTokens(out_tokens);
                    if (pricing.getCost(provider_name, model)) |cost_entry| {
                        const cost = pricing.calculateCost(cost_entry, in_tokens, out_tokens);
                        metrics.addInputCost(cost.input_cost);
                        metrics.addOutputCost(cost.output_cost);
                    }
                }

                // Serialize chunk to SSE format — atomic writeAll
                var buffer = std.ArrayList(u8).empty;
                defer buffer.deinit(sa);
                buffer.print(sa, "data: {f}\n\n", .{std.json.fmt(chunk.value, .{})}) catch continue;
                try writer.writeAll(buffer.items);
            },
            .@"error" => |error_response| {
                had_error = true;
                log.warn("[STREAM] Provider returned error: {s}", .{error_response.@"error".message});

                var buffer = std.ArrayList(u8).empty;
                defer buffer.deinit(sa);
                buffer.print(sa, "data: {f}\n\n", .{std.json.fmt(error_response, .{})}) catch break;
                try writer.writeAll(buffer.items);
                break;
            },
            .skip => {},
        }
    }

    // Always send [DONE] marker (OpenAI format)
    try writer.writeAll("data: [DONE]\n\n");

    const process_time = time.milliTimestamp() - process_start;
    log.debug("[STREAM] Processed {d} chunks in {d}ms", .{ chunk_count, process_time });

    const total_elapsed = time.milliTimestamp() - start_time;
    if (had_error) {
        log.warn("[STREAM] POST /v1/chat/completions - completed with error | model='{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | stream_connect={d}ms | process={d}ms | chunks={d}", .{
            request.model, total_elapsed, transform_time, client_init_time, stream_connect_time, process_time, chunk_count,
        });
    } else {
        log.info("[STREAM] POST /v1/chat/completions - completed | model='{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | stream_connect={d}ms | process={d}ms | chunks={d}", .{
            request.model, total_elapsed, transform_time, client_init_time, stream_connect_time, process_time, chunk_count,
        });
    }
}

// ============================================================================
// messagesComplete — Anthropic format
// ============================================================================

/// Perform an Anthropic Messages API completion (`/v1/messages`).
///
/// Streaming or non-streaming mode is determined by `request.stream`:
///   - **Streaming**: writes Anthropic-format SSE event lines
///     (`event: <type>\ndata: {json}\n\n`) to `writer`.
///   - **Non-streaming**: writes a single complete JSON response body to `writer`.
///
/// The caller provides `writer` and is responsible for any transport framing,
/// exactly as with `chatComplete`. The difference is that input and output use
/// Anthropic types (`anthropic_types.Request` / `anthropic_types.Response`).
///
/// **Pipeline**: identical to `chatComplete` — enforceBudget → parseModel →
/// resolve provider → transform request → init client → send upstream →
/// transform response → track metrics → write to `writer`.
///
/// **Note**: HAI uses the Anthropic transformer for this endpoint, while
/// OpenAI-compatible providers use cross-protocol translation.
///
/// Returns `CompletionError` — see `chatComplete` for the full error contract.
pub fn messagesComplete(
    writer: anytype,
    allocator: std.mem.Allocator,
    request: anthropic_types.Request,
) !void {
    const cfg = config_mod.get();

    // Budget enforcement
    try utils.enforceBudget(cfg);

    // Parse model
    const model_info = utils.parseModelString(request.model, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, request.model });
        return error.InvalidModelFormat;
    };
    defer allocator.free(model_info.model);
    defer allocator.free(model_info.provider);

    // Get provider config
    const provider_config = cfg.providers.getPtr(model_info.provider) orelse {
        log.err("Provider not configured: '{s}'", .{model_info.provider});
        return error.ProviderNotConfigured;
    };

    const is_streaming = request.stream orelse false;

    // Dispatch to provider
    // Note: HAI uses anthropic.transformer for /v1/messages (not openai.transformer)
    if (provider_mod.Provider.fromString(model_info.provider)) |native_provider| {
        switch (native_provider) {
            .anthropic => try dispatchMessages(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => try dispatchMessages(hai.client.HaiClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => {
                const schema = provider_config.getString("api_schema") orelse "legacy";
                if (std.mem.eql(u8, schema, "latest")) {
                    try messagesViaResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                } else {
                    try dispatchMessages(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                }
            },
            .copilot => try dispatchMessages(copilot.client.CopilotClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .sap_ai_core => try dispatchMessages(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };
        const schema = provider_config.getString("api_schema") orelse "legacy";

        if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchMessages(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else if (std.mem.eql(u8, compatible, "openai")) {
            if (std.mem.eql(u8, schema, "latest")) {
                try messagesViaResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            } else {
                try dispatchMessages(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            }
        } else {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        }
    }
}

fn dispatchMessages(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: anthropic_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    if (is_streaming) {
        messagesStreaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                return messagesStreaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    } else {
        messagesSync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                return messagesSync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    }
}

fn messagesSync(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    allocator: std.mem.Allocator,
    request: anthropic_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[SYNC] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transformFromAnthropic(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupFromAnthropicRequest(provider_request, allocator);
    const transform_request_time = time.milliTimestamp() - transform_start;
    log.debug("[SYNC] Transform request completed in {d}ms", .{transform_request_time});

    // Init client
    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[SYNC] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[SYNC] Client init completed in {d}ms", .{client_init_time});

    // Send request
    const provider_request_start = time.milliTimestamp();
    const provider_response = client.sendRequest(provider_request) catch |err| {
        log.err("[SYNC] Provider API error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return error.UpstreamError;
    };
    defer provider_response.deinit();
    const provider_request_time = time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // Transform response
    const transform_response_start = time.milliTimestamp();
    const anthropic_response = Transformer.transformToAnthropicResponse(provider_response.value, allocator, request.model) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupAnthropicResponse(anthropic_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // Track tokens and costs
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

    // Serialize and write
    const serialize_start = time.milliTimestamp();
    var response_buffer = std.ArrayList(u8).empty;
    defer response_buffer.deinit(allocator);
    try response_buffer.print(allocator, "{f}", .{std.json.fmt(anthropic_response, .{})});
    const serialize_time = time.milliTimestamp() - serialize_start;
    log.debug("[SYNC] Response serialization completed in {d}ms", .{serialize_time});

    try writer.writeAll(response_buffer.items);

    const total_elapsed = time.milliTimestamp() - start_time;
    log.info("[SYNC] POST /v1/messages - completed | model='{s}/{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | provider_req={d}ms | transform_resp={d}ms | serialize={d}ms", .{
        provider_name, model, total_elapsed, transform_request_time, client_init_time, provider_request_time, transform_response_time, serialize_time,
    });
}

fn messagesStreaming(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    allocator: std.mem.Allocator,
    request: anthropic_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[STREAM] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    // Transform (with stream=true)
    const transform_start = time.milliTimestamp();
    var mutable_request = request;
    mutable_request.stream = true;
    const provider_request = Transformer.transformFromAnthropic(mutable_request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupFromAnthropicRequest(provider_request, allocator);
    const transform_time = time.milliTimestamp() - transform_start;
    log.debug("[STREAM] Transform request completed in {d}ms", .{transform_time});

    // Init client
    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[STREAM] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[STREAM] Client init completed in {d}ms", .{client_init_time});

    // Start streaming
    const stream_connect_start = time.milliTimestamp();
    const stream_result = client.sendStreamingRequest(provider_request) catch |err| {
        log.err("[STREAM] Provider streaming error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return error.UpstreamError;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Process upstream SSE lines through transformer
    const process_start = time.milliTimestamp();
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
                writer.writeAll(output) catch |write_err| {
                    log.err("[STREAM] Failed to write to client: {}", .{write_err});
                    had_error = true;
                    break;
                };
            },
            .skip => {},
        }
    }

    // Track tokens and costs from stream state
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

    const process_time = time.milliTimestamp() - process_start;
    log.debug("[STREAM] Processed {d} chunks in {d}ms", .{ chunk_count, process_time });

    const total_elapsed = time.milliTimestamp() - start_time;
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

// ============================================================================
// listModels / freeModels
// ============================================================================

/// Thread-safe allocator wrapper for parallel model fetching
const ThreadSafeAllocator = struct {
    backing_allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

    pub fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.alloc(self.backing_allocator.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.resize(self.backing_allocator.ptr, buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.remap(self.backing_allocator.ptr, buf, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.backing_allocator.vtable.free(self.backing_allocator.ptr, buf, alignment, ret_addr);
    }
};

/// Result from a provider fetch task
const FetchResult = struct {
    provider_name: []const u8,
    models: ?[]openai_types.Model,
    err: ?anyerror,
    elapsed_ms: i64,
};

/// Context passed to each fetch task
const FetchContext = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
    result: *FetchResult,
    wg: *worker_pool.WaitGroup,
};

/// Fetch the model catalogue from all configured providers.
///
/// When a worker pool is available, providers are queried **in parallel**;
/// otherwise the function falls back to sequential fetching. Individual
/// provider failures are logged and skipped — the returned slice contains
/// models from all providers that responded successfully, sorted
/// alphabetically by model `id`.
///
/// The returned slice is **caller-owned**. Free it with `freeModels()` when
/// done — that function handles freeing both the slice and the heap-allocated
/// strings inside each `Model`.
pub fn listModels(allocator: std.mem.Allocator) ![]openai_types.Model {
    const cfg = config_mod.get();
    const provider_count = cfg.providers.count();

    log.info("GET /v1/models - starting fetch from {d} providers", .{provider_count});

    if (provider_count == 0) {
        return try allocator.alloc(openai_types.Model, 0);
    }

    // If a pool backend is available, fetch in parallel; else sequential
    if (!worker_pool.isAvailable()) {
        log.warn("Worker pool not initialized, falling back to sequential fetch", .{});
        return try listModelsSequential(allocator, cfg);
    }

    // Wrap allocator with thread-safe wrapper
    var ts_alloc = ThreadSafeAllocator{ .backing_allocator = allocator };
    const safe_allocator = ts_alloc.allocator();

    // Allocate arrays for contexts and results
    var contexts = try safe_allocator.alloc(FetchContext, provider_count);
    defer safe_allocator.free(contexts);

    var results = try safe_allocator.alloc(FetchResult, provider_count);
    defer safe_allocator.free(results);

    for (results) |*result| {
        result.* = .{
            .provider_name = "",
            .models = null,
            .err = null,
            .elapsed_ms = 0,
        };
    }

    // Create wait group and submit tasks
    var wg = worker_pool.WaitGroup.init();

    var i: usize = 0;
    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const pname = entry.key_ptr.*;
        const pconfig = entry.value_ptr;

        contexts[i] = .{
            .allocator = safe_allocator,
            .provider_name = pname,
            .provider_config = pconfig,
            .result = &results[i],
            .wg = &wg,
        };

        wg.add(1);
        worker_pool.submit(&fetchTask, @ptrCast(&contexts[i])) catch |err| {
            log.warn("Failed to submit task for provider '{s}': {}", .{ pname, err });
            results[i].err = err;
            results[i].provider_name = pname;
            wg.done();
        };

        i += 1;
    }

    wg.wait();

    // Aggregate results
    var all_models = std.ArrayList(openai_types.Model).empty;
    defer all_models.deinit(safe_allocator);

    for (results[0..provider_count]) |result| {
        if (result.err) |err| {
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ result.provider_name, result.elapsed_ms, err });
            continue;
        }

        if (result.models) |model_list| {
            log.info("Provider '{s}' returned {d} models in {d}ms", .{ result.provider_name, model_list.len, result.elapsed_ms });
            for (model_list) |m| {
                try all_models.append(safe_allocator, m);
            }
            safe_allocator.free(model_list);
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ result.provider_name, result.elapsed_ms });
        }
    }

    log.info("GET /v1/models - total models: {d}", .{all_models.items.len});

    // Sort alphabetically by id
    const sorted = try allocator.alloc(openai_types.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_types.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_types.Model, b: openai_types.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return sorted;
}

/// Free a model slice previously returned by `listModels`.
///
/// Releases every heap-allocated `id` (and non-static `owned_by`) string
/// inside each `Model`, then frees the slice itself. Safe to call with a
/// zero-length slice.
pub fn freeModels(allocator: std.mem.Allocator, models: []openai_types.Model) void {
    for (models) |m| {
        allocator.free(m.id);
        if (!isStaticOwnedBy(m.owned_by)) {
            allocator.free(m.owned_by);
        }
    }
    allocator.free(models);
}

fn isStaticOwnedBy(owned_by: []const u8) bool {
    const static_values = [_][]const u8{ "anthropic", "model", "openai", "system" };
    for (static_values) |static_val| {
        if (std.mem.eql(u8, owned_by, static_val)) {
            return true;
        }
    }
    return false;
}

fn fetchTask(ctx_ptr: *anyopaque) void {
    const ctx: *FetchContext = @ptrCast(@alignCast(ctx_ptr));
    defer ctx.wg.done();

    const start_time = time.milliTimestamp();
    ctx.result.provider_name = ctx.provider_name;

    ctx.result.models = fetchModelsForProvider(
        ctx.allocator,
        ctx.provider_name,
        ctx.provider_config,
    ) catch |err| {
        ctx.result.err = err;
        ctx.result.elapsed_ms = time.milliTimestamp() - start_time;
        return;
    };

    ctx.result.elapsed_ms = time.milliTimestamp() - start_time;
}

fn listModelsSequential(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ![]openai_types.Model {
    var all_models = std.ArrayList(openai_types.Model).empty;
    defer all_models.deinit(allocator);

    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const pname = entry.key_ptr.*;
        const pconfig = entry.value_ptr;
        const provider_start = time.milliTimestamp();

        const models = fetchModelsForProvider(allocator, pname, pconfig) catch |err| {
            const elapsed = time.milliTimestamp() - provider_start;
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ pname, elapsed, err });
            continue;
        };

        const elapsed = time.milliTimestamp() - provider_start;

        if (models) |model_list| {
            log.info("Provider '{s}' returned {d} models in {d}ms", .{ pname, model_list.len, elapsed });
            for (model_list) |m| {
                try all_models.append(allocator, m);
            }
            allocator.free(model_list);
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ pname, elapsed });
        }
    }

    // Sort alphabetically by id
    const sorted = try allocator.alloc(openai_types.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_types.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_types.Model, b: openai_types.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return sorted;
}

fn fetchModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_types.Model {
    return fetchModelsForProviderInner(allocator, provider_name, provider_config) catch |err| {
        if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
            return fetchModelsForProviderInner(allocator, provider_name, provider_config);
        }
        return err;
    };
}

fn fetchModelsForProviderInner(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_types.Model {
    // Check for "compatible" field first (takes precedence)
    if (provider_config.getString("compatible")) |compatible| {
        if (std.mem.eql(u8, compatible, "openai")) {
            return try fetchModels(openai.client.OpenAIClient, openai.transformer, allocator, provider_name, provider_config);
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            return try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config);
        }
        return null;
    }

    if (provider_mod.Provider.fromString(provider_name)) |native_provider| {
        return switch (native_provider) {
            .openai => try fetchModels(openai.client.OpenAIClient, openai.transformer, allocator, provider_name, provider_config),
            .anthropic => try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config),
            .sap_ai_core => try fetchModels(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, allocator, provider_name, provider_config),
            .hai => try fetchModels(hai.client.HaiClient, openai.transformer, allocator, provider_name, provider_config),
            .copilot => try fetchModels(copilot.client.CopilotClient, openai.transformer, allocator, provider_name, provider_config),
        };
    } else |_| {
        return null;
    }
}

fn fetchModels(
    comptime ClientType: type,
    comptime transformer: type,
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_types.Model {
    var client = try ClientType.init(allocator, provider_config);
    defer client.deinit();

    const response = try client.listModels();

    if (@TypeOf(response) == ?void) {
        return null;
    }

    if (@typeInfo(@TypeOf(response)) == .optional) {
        if (response == null) {
            return null;
        }
    }

    const models = try transformer.transformModelsResponse(allocator, response, provider_name);

    var r = response;
    r.deinit();

    return models;
}

// ============================================================================
// responsesComplete — OpenAI Responses API format (/v1/responses)
// ============================================================================

/// Perform a completion using the OpenAI Responses API schema.
///
/// This is the canonical entry point going forward. `chatComplete` and
/// `messagesComplete` normalize their inbound schemas and delegate here.
///
/// Dispatch rules:
///   - anthropic → bridge via responses_transformer.toMessages → AnthropicClient
///   - openai/compatible with api_schema=latest → pass-through to /v1/responses
///   - openai/compatible with api_schema=legacy  → bridge via toChat → /v1/chat/completions
///   - sap_ai_core → bridge via toSap → SapAiCoreClient
///   - hai/copilot → bridge via toChat → respective client
pub fn responsesComplete(
    writer: anytype,
    allocator: std.mem.Allocator,
    request: openai_responses_types.Request,
) !void {
    const cfg = config_mod.get();
    try utils.enforceBudget(cfg);

    const model_info = utils.parseModelString(request.model, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, request.model });
        return error.InvalidModelFormat;
    };
    defer allocator.free(model_info.model);
    defer allocator.free(model_info.provider);

    const provider_config = cfg.providers.getPtr(model_info.provider) orelse {
        log.err("Provider not configured: '{s}'", .{model_info.provider});
        return error.ProviderNotConfigured;
    };

    const is_streaming = request.stream orelse false;

    if (provider_mod.Provider.fromString(model_info.provider)) |native_provider| {
        switch (native_provider) {
            .anthropic => try dispatchResponses(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => {
                const schema = provider_config.getString("api_schema") orelse "legacy";
                if (std.mem.eql(u8, schema, "latest")) {
                    try dispatchResponsesNative(openai.client.OpenAIClient, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                } else {
                    try dispatchResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
                }
            },
            .sap_ai_core => try dispatchResponses(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => try dispatchResponses(hai.client.HaiClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .copilot => try dispatchResponses(copilot.client.CopilotClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };
        const schema = provider_config.getString("api_schema") orelse "legacy";

        if (std.mem.eql(u8, compatible, "openai")) {
            if (std.mem.eql(u8, schema, "latest")) {
                try dispatchResponsesNative(openai.client.OpenAIClient, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            } else {
                try dispatchResponses(openai.client.OpenAIClient, openai.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
            }
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchResponses(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        }
    }
}

/// api_schema=latest: send Request directly to upstream /v1/responses.
/// OpenAIClient.sendRequest sees Request at comptime → routes to /v1/responses.
/// The response is already in ResponsesResponse format — write directly.
fn dispatchResponsesNative(
    comptime Client: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: openai_responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[RESPONSES] Client init failed: {}", .{err});
        return error.ClientInitFailed;
    };
    defer client.deinit();

    var req = request;
    req.model = model;

    if (is_streaming) {
        const stream_result = client.sendStreamingRequest(req) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry = client.sendStreamingRequest(req) catch return error.UpstreamError;
                _ = retry;
            }
            return error.UpstreamError;
        };
        defer client.freeStreamingResult(stream_result);
        while (true) {
            const maybe_line = stream_result.iterator.next() catch break;
            const line = maybe_line orelse break;
            if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
            writer.writeAll(line) catch {};
            writer.writeAll("\n\n") catch {};
        }
    } else {
        const response = client.sendRequest(req) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry_resp = client.sendRequest(req) catch return error.UpstreamError;
                defer retry_resp.deinit();
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(allocator);
                try buf.print(allocator, "{f}", .{std.json.fmt(retry_resp.value, .{})});
                return writer.writeAll(buf.items);
            }
            return error.UpstreamError;
        };
        defer response.deinit();
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(response.value, .{})});
        try writer.writeAll(buf.items);
    }
}

/// api_schema=latest: convert OpenAIChat.Request → Request, send to /v1/responses,
/// convert ResponsesResponse → OpenAIChat.Response for the chat response path.
fn chatViaResponses(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: openai_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    _ = Transformer;
    const rt = openai.responses_transformer;

    const responses_req = rt.fromChat(request, allocator) catch |err| {
        log.err("[CHAT→RESPONSES] fromChat failed: {}", .{err});
        return error.TransformFailed;
    };
    defer rt.cleanupFromChat(responses_req, allocator);

    var responses_req_with_model = responses_req;
    responses_req_with_model.model = model;

    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[CHAT→RESPONSES] Client init failed: {}", .{err});
        return error.ClientInitFailed;
    };
    defer client.deinit();

    if (is_streaming) {
        const stream_result = client.sendStreamingRequest(responses_req_with_model) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry = client.sendStreamingRequest(responses_req_with_model) catch return error.UpstreamError;
                _ = retry;
            }
            return error.UpstreamError;
        };
        defer client.freeStreamingResult(stream_result);
        // Upstream sends ResponsesStreamEvent lines; convert back to chat chunks
        var stream_state = openai.transformer.StreamState.init(allocator, request.model);
        defer stream_state.deinit();
        while (true) {
            const maybe_line = stream_result.iterator.next() catch break;
            const line = maybe_line orelse break;
            if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
            // For now pass through — full reverse streaming transform is a follow-up
            writer.writeAll(line) catch {};
            writer.writeAll("\n\n") catch {};
        }
        try writer.writeAll("data: [DONE]\n\n");
    } else {
        const resp = client.sendRequest(responses_req_with_model) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry_resp = client.sendRequest(responses_req_with_model) catch return error.UpstreamError;
                defer retry_resp.deinit();
                const chat_resp = rt.toChatResponse(retry_resp.value, allocator) catch return error.TransformResponseFailed;
                defer rt.cleanupToChatResponse(chat_resp, allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(allocator);
                try buf.print(allocator, "{f}", .{std.json.fmt(chat_resp, .{})});
                return writer.writeAll(buf.items);
            }
            return error.UpstreamError;
        };
        defer resp.deinit();
        const chat_resp = rt.toChatResponse(resp.value, allocator) catch |err| {
            log.err("[CHAT→RESPONSES] toChatResponse failed: {}", .{err});
            return error.TransformResponseFailed;
        };
        defer rt.cleanupToChatResponse(chat_resp, allocator);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(chat_resp, .{})});
        try writer.writeAll(buf.items);
    }
}

/// api_schema=latest: convert Anthropic.Request → Request, send to /v1/responses,
/// convert ResponsesResponse → Anthropic.Response for the messages response path.
fn messagesViaResponses(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: anthropic_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    _ = Transformer;
    const rt = openai.responses_transformer;

    const responses_req = rt.fromMessages(request, allocator) catch |err| {
        log.err("[MESSAGES→RESPONSES] fromMessages failed: {}", .{err});
        return error.TransformFailed;
    };
    defer rt.cleanupFromMessages(responses_req, allocator);

    var responses_req_with_model = responses_req;
    responses_req_with_model.model = model;

    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[MESSAGES→RESPONSES] Client init failed: {}", .{err});
        return error.ClientInitFailed;
    };
    defer client.deinit();

    if (is_streaming) {
        const stream_result = client.sendStreamingRequest(responses_req_with_model) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry = client.sendStreamingRequest(responses_req_with_model) catch return error.UpstreamError;
                _ = retry;
            }
            return error.UpstreamError;
        };
        defer client.freeStreamingResult(stream_result);
        // Pass through responses SSE lines — full reverse streaming transform is a follow-up
        while (true) {
            const maybe_line = stream_result.iterator.next() catch break;
            const line = maybe_line orelse break;
            if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
            writer.writeAll(line) catch {};
            writer.writeAll("\n\n") catch {};
        }
        try writer.writeAll("data: [DONE]\n\n");
    } else {
        const resp = client.sendRequest(responses_req_with_model) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry_resp = client.sendRequest(responses_req_with_model) catch return error.UpstreamError;
                defer retry_resp.deinit();
                const chat_resp = rt.toChatResponse(retry_resp.value, allocator) catch return error.TransformResponseFailed;
                defer rt.cleanupToChatResponse(chat_resp, allocator);
                const anthro_resp = openai.transformer.transformToAnthropicResponse(chat_resp, allocator, request.model) catch return error.TransformResponseFailed;
                defer openai.transformer.cleanupAnthropicResponse(anthro_resp, allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(allocator);
                try buf.print(allocator, "{f}", .{std.json.fmt(anthro_resp, .{})});
                return writer.writeAll(buf.items);
            }
            return error.UpstreamError;
        };
        defer resp.deinit();
        const chat_resp = rt.toChatResponse(resp.value, allocator) catch |err| {
            log.err("[MESSAGES→RESPONSES] toChatResponse failed: {}", .{err});
            return error.TransformResponseFailed;
        };
        defer rt.cleanupToChatResponse(chat_resp, allocator);
        const anthro_resp = openai.transformer.transformToAnthropicResponse(chat_resp, allocator, request.model) catch |err| {
            log.err("[MESSAGES→RESPONSES] transformToAnthropicResponse failed: {}", .{err});
            return error.TransformResponseFailed;
        };
        defer openai.transformer.cleanupAnthropicResponse(anthro_resp, allocator);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(anthro_resp, .{})});
        try writer.writeAll(buf.items);
    }
}

/// Dispatch a /v1/responses request through a provider's responses method set.
/// Transformer must implement: transformFromResponses, cleanupFromRequest,
/// transformToResponsesResponse, cleanupResponsesResponse,
/// ResponsesStreamState (init/deinit), transformStreamLineToResponses, flushResponsesStream.
fn dispatchResponses(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: openai_responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    // Transform Request → provider wire format
    const provider_req = Transformer.transformFromResponses(request, model, allocator) catch |err| {
        log.err("[RESPONSES] transformFromResponses failed: {}", .{err});
        return error.TransformFailed;
    };
    defer Transformer.cleanupFromRequest(provider_req, allocator);

    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[RESPONSES] Client init failed: {}", .{err});
        return error.ClientInitFailed;
    };
    defer client.deinit();

    if (is_streaming) {
        const stream_result = client.sendStreamingRequest(provider_req) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry = client.sendStreamingRequest(provider_req) catch return error.UpstreamError;
                _ = retry;
            }
            return error.UpstreamError;
        };
        defer client.freeStreamingResult(stream_result);

        var stream_state = Transformer.ResponsesStreamState.init(allocator, request.model);
        defer stream_state.deinit();

        while (true) {
            const maybe_line = stream_result.iterator.next() catch break;
            const line = maybe_line orelse break;
            if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
            if (Transformer.transformStreamLineToResponses(line, &stream_state, allocator)) |out| {
                defer allocator.free(out);
                writer.writeAll(out) catch {};
            }
        }
        if (Transformer.flushResponsesStream(&stream_state, allocator)) |out| {
            defer allocator.free(out);
            writer.writeAll(out) catch {};
        }
        try writer.writeAll("data: [DONE]\n\n");
    } else {
        const provider_response = client.sendRequest(provider_req) catch |err| {
            if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
                const retry_resp = client.sendRequest(provider_req) catch return error.UpstreamError;
                defer retry_resp.deinit();
                const resp = Transformer.transformToResponsesResponse(retry_resp.value, request, allocator) catch return error.TransformResponseFailed;
                defer Transformer.cleanupResponsesResponse(resp, allocator);
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(allocator);
                try buf.print(allocator, "{f}", .{std.json.fmt(resp, .{})});
                return writer.writeAll(buf.items);
            }
            return error.UpstreamError;
        };
        defer provider_response.deinit();

        const resp = Transformer.transformToResponsesResponse(provider_response.value, request, allocator) catch |err| {
            log.err("[RESPONSES] transformToResponsesResponse failed: {}", .{err});
            return error.TransformResponseFailed;
        };
        defer Transformer.cleanupResponsesResponse(resp, allocator);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(resp, .{})});
        try writer.writeAll(buf.items);
    }
}
