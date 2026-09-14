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
const smart_routing = @import("smart_routing.zig");
const chat_types = @import("providers/openai/chat_types.zig");
const responses_types = @import("providers/openai/responses_types.zig");
const messages_types = @import("providers/anthropic/types.zig");
const openai_common = @import("providers/openai/types.zig");

// Provider modules — direct imports for comptime dispatch
// The OpenAI wire formats are treated as two separate sub-providers:
//   - chat_transformer: legacy /v1/chat/completions wire format
//   - responses_transformer: Responses API wire format (api_schema=latest)
const openai = struct {
    const client = @import("providers/openai/client.zig");
    const chat_transformer = @import("providers/openai/chat_transformer.zig");
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
const google_ai_studio = struct {
    const client = @import("providers/google_ai_studio/client.zig");
    const transformer = @import("providers/google_ai_studio/transformer.zig");
};

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
    request: chat_types.Request,
) !void {
    const cfg = config_mod.get();

    // Budget enforcement
    try utils.enforceBudget(cfg);

    // Smart routing: acquire a read-lock guard that prevents concurrent reload()
    // from freeing the SmartRouting while this request is in flight.
    const sr_handle = smart_routing.acquire();
    defer if (sr_handle) |h| h.release();
    const sr = if (sr_handle) |h| h.sr else null;
    const sr_group = if (sr) |s| s.lookup(request.model) else null;
    var current_model_buf: ?[]u8 = if (sr_group) |g| try sr.?.getCurrentModel(g, allocator) else null;
    defer if (current_model_buf) |buf| allocator.free(buf);
    var did_rollover = false;

    while (true) {
        const effective_model = if (current_model_buf) |buf| buf else request.model;

        const dispatch_err = chatCompleteInner(writer, allocator, cfg, request, effective_model);
        if (dispatch_err) |_| {
            // Persist working model to config on first successful rollover
            if (did_rollover and sr != null) {
                sr.?.writeBack(allocator) catch |e| {
                    log.warn("[smart_routing] writeBack failed: {}", .{e});
                };
            }
            return;
        } else |err| {
            const retryable = (err == error.RateLimitError or
                err == error.AuthenticationError or
                err == error.ServerError);
            if (retryable and sr_group != null) {
                log.warn("[smart_routing] Model '{s}' failed ({s}), attempting rollover...", .{ effective_model, @errorName(err) });
                const next = sr.?.rollover(sr_group.?, allocator) catch null;
                if (next) |n| {
                    if (current_model_buf) |old| allocator.free(old);
                    current_model_buf = n;
                    did_rollover = true;
                    log.info("[smart_routing] Rolling over to '{s}'", .{n});
                    continue;
                } else {
                    log.err("[smart_routing] All alternatives exhausted for '{s}'", .{request.model});
                }
            }
            return err;
        }
    }
    unreachable;
}

fn chatCompleteInner(
    writer: anytype,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    request: chat_types.Request,
    model_str: []const u8,
) !void {
    // Parse model
    const model_info = utils.parseModelString(model_str, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, model_str });
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
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchChat(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchChat(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .sap_ai_core => try dispatchChat(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => switch (hai.client.transformerFor(model_info.model, provider_config)) {
                .messages  => try dispatchChat(hai.client.HaiClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchChat(hai.client.HaiClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini    => try dispatchChat(hai.client.HaiClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchChat(hai.client.HaiClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .copilot => switch (copilot.client.transformerFor(model_info.model)) {
                .messages  => try dispatchChat(copilot.client.CopilotClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchChat(copilot.client.CopilotClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini, .chat => try dispatchChat(copilot.client.CopilotClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .google_ai_studio => try dispatchChat(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };

        if (std.mem.eql(u8, compatible, "openai")) {
            switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchChat(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchChat(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
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
    const result = config_mod.initiateAuth(allocator, provider_name, .{});
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
    request: chat_types.Request,
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
    request: chat_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[SYNC] POST /v1/chat/completions - request received for model '{s}'", .{request.model});

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transformChatRequest(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupChatRequest(provider_request, allocator);
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
        if (err == error.RateLimitError) return error.RateLimitError;
        if (err == error.AuthenticationError) return error.AuthenticationError;
        if (err == error.ServerError) return error.ServerError;
        return error.UpstreamError;
    };
    defer provider_response.deinit();
    const provider_request_time = time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // Transform response
    const transform_response_start = time.milliTimestamp();
    const openai_response = Transformer.transformChatResponse(provider_response.value, request, allocator) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}'", .{ err, request.model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupChatResponse(openai_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // Track tokens and costs
    if (openai_response.usage) |usage| {
        recordTokenUsage(
            @intCast(usage.prompt_tokens),
            @intCast(usage.completion_tokens),
            model,
            provider_name,
        );
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
    request: chat_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[STREAM] POST /v1/chat/completions - request received for model '{s}'", .{request.model});

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transformChatRequest(request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupChatRequest(provider_request, allocator);
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
        if (err == error.RateLimitError) return error.RateLimitError;
        if (err == error.AuthenticationError) return error.AuthenticationError;
        if (err == error.ServerError) return error.ServerError;
        return error.UpstreamError;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Initialize streaming state
    var state = Transformer.ChatStreamState.init(allocator, request.model);
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
        const result = Transformer.transformChatStreamLine(line, &state, allocator);
        switch (result) {
            .output => |output| {
                defer allocator.free(output);

                if (first_chunk_time == null) {
                    first_chunk_time = time.milliTimestamp() - process_start;
                    log.debug("[STREAM] Time to first chunk: {d}ms", .{first_chunk_time.?});
                }
                chunk_count += 1;

                // P4: the transformer renders ready-to-write bytes; usage was
                // already accumulated into `state` (metrics recorded below).
                try writer.writeAll(output);
            },
            .skip => {},
        }
    }

    // Always send [DONE] marker (OpenAI format)
    try writer.writeAll("data: [DONE]\n\n");

    // Track tokens and costs from the stream state (P3: uniform fields; usage
    // arrives on the final chunk for include_usage-injected upstreams and is
    // accumulated there — no per-chunk scraping anymore).
    recordTokenUsage(state.input_tokens, state.output_tokens, model, provider_name);

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
/// Anthropic types (`messages_types.Request` / `messages_types.Response`).
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
    request: messages_types.Request,
) !void {
    const cfg = config_mod.get();

    // Budget enforcement
    try utils.enforceBudget(cfg);

    // Smart routing: acquire a read-lock guard that prevents concurrent reload()
    // from freeing the SmartRouting while this request is in flight.
    const sr_handle = smart_routing.acquire();
    defer if (sr_handle) |h| h.release();
    const sr = if (sr_handle) |h| h.sr else null;
    const sr_group = if (sr) |s| s.lookup(request.model) else null;
    var current_model_buf: ?[]u8 = if (sr_group) |g| try sr.?.getCurrentModel(g, allocator) else null;
    defer if (current_model_buf) |buf| allocator.free(buf);
    var did_rollover = false;

    while (true) {
        const effective_model = if (current_model_buf) |buf| buf else request.model;

        const dispatch_err = messagesCompleteInner(writer, allocator, cfg, request, effective_model);
        if (dispatch_err) |_| {
            if (did_rollover and sr != null) {
                sr.?.writeBack(allocator) catch |e| {
                    log.warn("[smart_routing] writeBack failed: {}", .{e});
                };
            }
            return;
        } else |err| {
            const retryable = (err == error.RateLimitError or
                err == error.AuthenticationError or
                err == error.ServerError);
            if (retryable and sr_group != null) {
                log.warn("[smart_routing] Model '{s}' failed ({s}), attempting rollover...", .{ effective_model, @errorName(err) });
                const next = sr.?.rollover(sr_group.?, allocator) catch null;
                if (next) |n| {
                    if (current_model_buf) |old| allocator.free(old);
                    current_model_buf = n;
                    did_rollover = true;
                    log.info("[smart_routing] Rolling over to '{s}'", .{n});
                    continue;
                } else {
                    log.err("[smart_routing] All alternatives exhausted for '{s}'", .{request.model});
                }
            }
            return err;
        }
    }
    unreachable;
}

fn messagesCompleteInner(
    writer: anytype,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    request: messages_types.Request,
    model_str: []const u8,
) !void {
    // Parse model
    const model_info = utils.parseModelString(model_str, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, model_str });
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
    // Note: HAI uses anthropic.transformer for /v1/messages (not openai.chat_transformer)
    if (provider_mod.Provider.fromString(model_info.provider)) |native_provider| {
        switch (native_provider) {
            .anthropic => try dispatchMessages(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => switch (hai.client.transformerFor(model_info.model, provider_config)) {
                .messages  => try dispatchMessages(hai.client.HaiClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchMessages(hai.client.HaiClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini    => try dispatchMessages(hai.client.HaiClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchMessages(hai.client.HaiClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchMessages(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchMessages(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .copilot => switch (copilot.client.transformerFor(model_info.model)) {
                .messages  => try dispatchMessages(copilot.client.CopilotClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchMessages(copilot.client.CopilotClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini, .chat => try dispatchMessages(copilot.client.CopilotClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .sap_ai_core => try dispatchMessages(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .google_ai_studio => try dispatchMessages(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };

        if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchMessages(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else if (std.mem.eql(u8, compatible, "openai")) {
            switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchMessages(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchMessages(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
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
    request: messages_types.Request,
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
    request: messages_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[SYNC] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    // Transform
    const transform_start = time.milliTimestamp();
    const provider_request = Transformer.transformMessagesRequest(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupMessagesRequest(provider_request, allocator);
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
        if (err == error.RateLimitError) return error.RateLimitError;
        if (err == error.AuthenticationError) return error.AuthenticationError;
        if (err == error.ServerError) return error.ServerError;
        return error.UpstreamError;
    };
    defer provider_response.deinit();
    const provider_request_time = time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // Transform response
    const transform_response_start = time.milliTimestamp();
    const anthropic_response = Transformer.transformMessagesResponse(provider_response.value, request, allocator) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupMessagesResponse(anthropic_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // Track tokens and costs
    recordTokenUsage(
        @intCast(anthropic_response.usage.input_tokens),
        @intCast(anthropic_response.usage.output_tokens),
        model,
        provider_name,
    );

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
    request: messages_types.Request,
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
    const provider_request = Transformer.transformMessagesRequest(mutable_request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupMessagesRequest(provider_request, allocator);
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
        if (err == error.RateLimitError) return error.RateLimitError;
        if (err == error.AuthenticationError) return error.AuthenticationError;
        if (err == error.ServerError) return error.ServerError;
        return error.UpstreamError;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Process upstream SSE lines through transformer
    const process_start = time.milliTimestamp();
    var chunk_count: u32 = 0;
    var had_error = false;

    var stream_state = Transformer.MessagesStreamState.init(allocator, request.model);
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

        const result = Transformer.transformMessagesStreamLine(line, &stream_state, allocator);
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

    // Track tokens and costs from stream state (P3: uniform state fields;
    // getUsage() is gone — the states expose input_tokens/output_tokens directly)
    recordTokenUsage(stream_state.input_tokens, stream_state.output_tokens, model, provider_name);

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
    models: ?[]openai_common.Model,
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
pub fn listModels(allocator: std.mem.Allocator) ![]openai_common.Model {
    const cfg = config_mod.get();
    const provider_count = cfg.providers.count();

    log.info("GET /v1/models - starting fetch from {d} providers", .{provider_count});

    if (provider_count == 0) {
        return try allocator.alloc(openai_common.Model, 0);
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
    var all_models = std.ArrayList(openai_common.Model).empty;
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

    // Append smart routing group models (api_key as id, owned_by = "zig-zag")
    appendGroupModels(safe_allocator, &all_models) catch |err| {
        log.warn("Failed to append smart routing models: {}", .{err});
    };

    // Sort alphabetically by id
    const sorted = try allocator.alloc(openai_common.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_common.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_common.Model, b: openai_common.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return sorted;
}

/// Free a model slice previously returned by `listModels`.
pub fn freeModels(allocator: std.mem.Allocator, models: []openai_common.Model) void {
    for (models) |m| {
        allocator.free(m.id);
        allocator.free(m.owned_by);
    }
    allocator.free(models);
}

fn isStaticOwnedBy(owned_by: []const u8) bool {
    _ = owned_by;
    return false; // all owned_by strings are now heap-allocated
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

/// Append smart routing group models to an existing model list.
/// Each group with a non-empty api_key gets an entry with owned_by = "zig-zag".
/// id and owned_by are heap-allocated so freeModels() can free them uniformly.
fn appendGroupModels(allocator: std.mem.Allocator, list: *std.ArrayList(openai_common.Model)) !void {
    const handle = smart_routing.acquire() orelse return;
    defer handle.release();
    for (handle.sr.groups) |*g| {
        if (g.api_key.len == 0) continue;
        try list.append(allocator, openai_common.Model{
            .id = try allocator.dupe(u8, g.api_key),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, "zig-zag"),
        });
    }
}

fn listModelsSequential(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ![]openai_common.Model {
    var all_models = std.ArrayList(openai_common.Model).empty;
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

    // Append smart routing group models (api_key as id, owned_by = "zig-zag")
    appendGroupModels(allocator, &all_models) catch |err| {
        log.warn("Failed to append smart routing models: {}", .{err});
    };

    // Sort alphabetically by id
    const sorted = try allocator.alloc(openai_common.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_common.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_common.Model, b: openai_common.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return sorted;
}

fn fetchModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_common.Model {
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
) !?[]openai_common.Model {
    // Check for "compatible" field first (takes precedence)
    if (provider_config.getString("compatible")) |compatible| {
        if (std.mem.eql(u8, compatible, "openai")) {
            return try fetchModels(openai.client.OpenAIClient, openai.chat_transformer, allocator, provider_name, provider_config);
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            return try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config);
        }
        return null;
    }

    if (provider_mod.Provider.fromString(provider_name)) |native_provider| {
        return switch (native_provider) {
            .openai => try fetchModels(openai.client.OpenAIClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .anthropic => try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config),
            .sap_ai_core => try fetchModels(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, allocator, provider_name, provider_config),
            .hai => try fetchModels(hai.client.HaiClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .copilot => try fetchModels(copilot.client.CopilotClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .google_ai_studio => try fetchModels(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, allocator, provider_name, provider_config),
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
) !?[]openai_common.Model {
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
//
// Usage/cost tracking: all dispatch paths below feed their token usage
// into `metrics` via the shared recordTokenUsage helper so tokens and costs
// stay correct for every API schema.
// ============================================================================

// ----------------------------------------------------------------------------
// Shared usage recording helper
// ----------------------------------------------------------------------------

/// Record token usage and (if pricing data is available) cost for a completed
/// LLM call. Zero-usage calls are ignored so failed/empty streams don't skew
/// the counters. The single metering point for every pipeline in this file —
/// callers extract the token counts from their response objects or stream
/// states (both expose `input_tokens`/`output_tokens` per the P3 state core)
/// and pass them here.
fn recordTokenUsage(
    input_tokens: u64,
    output_tokens: u64,
    model: []const u8,
    provider_name: []const u8,
) void {
    if (input_tokens == 0 and output_tokens == 0) return;
    metrics.addInputTokens(input_tokens);
    metrics.addOutputTokens(output_tokens);
    if (pricing.getCost(provider_name, model)) |cost_entry| {
        const cost = pricing.calculateCost(cost_entry, input_tokens, output_tokens);
        metrics.addInputCost(cost.input_cost);
        metrics.addOutputCost(cost.output_cost);
    }
}

/// Perform a completion using the OpenAI Responses API schema.
///
/// This is the canonical entry point going forward. `chatComplete` and
/// `messagesComplete` normalize their inbound schemas and delegate here.
///
/// Dispatch rules:
///   - anthropic → anthropic.transformer messages face → AnthropicClient
///   - openai/compatible with api_schema=latest → pass-through to /v1/responses
///   - openai/compatible with api_schema=legacy  → openai.chat_transformer → /v1/chat/completions
///   - sap_ai_core → sap_ai_core.transformer responses face → SapAiCoreClient
///   - hai/copilot → openai.chat_transformer → respective client
pub fn responsesComplete(
    writer: anytype,
    allocator: std.mem.Allocator,
    request: responses_types.Request,
) !void {
    const cfg = config_mod.get();
    try utils.enforceBudget(cfg);

    // Smart routing: acquire a read-lock guard that prevents concurrent reload()
    // from freeing the SmartRouting while this request is in flight.
    const sr_handle = smart_routing.acquire();
    defer if (sr_handle) |h| h.release();
    const sr = if (sr_handle) |h| h.sr else null;
    const sr_group = if (sr) |s| s.lookup(request.model) else null;
    var current_model_buf: ?[]u8 = if (sr_group) |g| try sr.?.getCurrentModel(g, allocator) else null;
    defer if (current_model_buf) |buf| allocator.free(buf);
    var did_rollover = false;

    while (true) {
        const effective_model = if (current_model_buf) |buf| buf else request.model;

        const dispatch_err = responsesCompleteInner(writer, allocator, cfg, request, effective_model);
        if (dispatch_err) |_| {
            if (did_rollover and sr != null) {
                sr.?.writeBack(allocator) catch |e| {
                    log.warn("[smart_routing] writeBack failed: {}", .{e});
                };
            }
            return;
        } else |err| {
            const retryable = (err == error.RateLimitError or
                err == error.AuthenticationError or
                err == error.ServerError);
            if (retryable and sr_group != null) {
                log.warn("[smart_routing] Model '{s}' failed ({s}), attempting rollover...", .{ effective_model, @errorName(err) });
                const next = sr.?.rollover(sr_group.?, allocator) catch null;
                if (next) |n| {
                    if (current_model_buf) |old| allocator.free(old);
                    current_model_buf = n;
                    did_rollover = true;
                    log.info("[smart_routing] Rolling over to '{s}'", .{n});
                    continue;
                } else {
                    log.err("[smart_routing] All alternatives exhausted for '{s}'", .{request.model});
                }
            }
            return err;
        }
    }
    unreachable;
}

fn responsesCompleteInner(
    writer: anytype,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    request: responses_types.Request,
    model_str: []const u8,
) !void {
    const model_info = utils.parseModelString(model_str, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, model_str });
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
            .openai => try dispatchResponses(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .sap_ai_core => try dispatchResponses(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => switch (hai.client.transformerFor(model_info.model, provider_config)) {
                .messages  => try dispatchResponses(hai.client.HaiClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchResponses(hai.client.HaiClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini    => try dispatchResponses(hai.client.HaiClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchResponses(hai.client.HaiClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .copilot => switch (copilot.client.transformerFor(model_info.model)) {
                .messages  => try dispatchResponses(copilot.client.CopilotClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchResponses(copilot.client.CopilotClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini, .chat => try dispatchResponses(copilot.client.CopilotClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .google_ai_studio => try dispatchResponses(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };

        if (std.mem.eql(u8, compatible, "openai")) {
            switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchResponses(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchResponses(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            }
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchResponses(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        }
    }
}

/// Dispatch a /v1/responses request through a provider's responses method set.
/// Transformer must implement: transformResponsesRequest, cleanupResponsesRequest,
/// transformToResponse, cleanupResponse,
/// ResponsesStreamState (init/deinit), transformResponsesStreamLine, flushResponsesStream.
fn dispatchResponses(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    responsesInner(Client, Transformer, writer, is_streaming, allocator, request, model, provider_name, provider_config) catch |err| {
        if (err == error.AuthRequired and tryAutoReauth(allocator, provider_name)) {
            return responsesInner(Client, Transformer, writer, is_streaming, allocator, request, model, provider_name, provider_config);
        }
        return err;
    };
}

fn responsesInner(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    // Transform Request → provider wire format
    const provider_req = Transformer.transformResponsesRequest(request, model, allocator) catch |err| {
        log.err("[RESPONSES] transformResponsesRequest failed: {}", .{err});
        return error.TransformFailed;
    };
    defer Transformer.cleanupResponsesRequest(provider_req, allocator);

    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[RESPONSES] Client init failed: {}", .{err});
        return error.ClientInitFailed;
    };
    defer client.deinit();

    if (is_streaming) {
        const stream_result = client.sendStreamingRequest(provider_req) catch |err| {
            if (err == error.AuthRequired) return error.AuthRequired;
            if (err == error.RateLimitError) return error.RateLimitError;
            if (err == error.AuthenticationError) return error.AuthenticationError;
            if (err == error.ServerError) return error.ServerError;
            return error.UpstreamError;
        };
        defer client.freeStreamingResult(stream_result);

        var stream_state = Transformer.ResponsesStreamState.init(allocator, request.model);
        defer stream_state.deinit();

        while (true) {
            const maybe_line = stream_result.iterator.next() catch break;
            const line = maybe_line orelse break;
            if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
            switch (Transformer.transformResponsesStreamLine(line, &stream_state, allocator)) {
                .output => |out| {
                    defer allocator.free(out);
                    writer.writeAll(out) catch {};
                },
                .skip => {},
            }
        }
        if (Transformer.flushResponsesStream(&stream_state, allocator)) |out| {
            defer allocator.free(out);
            writer.writeAll(out) catch {};
        }
        // Only the chat↔responses bridge synthesizes a terminal sentinel; a
        // native Responses upstream ends its own stream (no [DONE] in spec).
        if (Transformer.appendsDoneMarker) {
            try writer.writeAll("data: [DONE]\n\n");
        }
        recordTokenUsage(
            stream_state.input_tokens,
            stream_state.output_tokens,
            model,
            provider_name,
        );
    } else {
        const provider_response = client.sendRequest(provider_req) catch |err| {
            if (err == error.AuthRequired) return error.AuthRequired;
            if (err == error.RateLimitError) return error.RateLimitError;
            if (err == error.AuthenticationError) return error.AuthenticationError;
            if (err == error.ServerError) return error.ServerError;
            return error.UpstreamError;
        };
        defer provider_response.deinit();

        const resp = Transformer.transformResponsesResponse(provider_response.value, request, allocator) catch |err| {
            log.err("[RESPONSES] transformToResponse failed: {}", .{err});
            return error.TransformResponseFailed;
        };
        defer Transformer.cleanupResponsesResponse(resp, allocator);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(resp, .{})});
        try writer.writeAll(buf.items);
        recordTokenUsage(
            if (resp.usage) |u| u.input_tokens else 0,
            if (resp.usage) |u| u.output_tokens else 0,
            model,
            provider_name,
        );
    }
}
