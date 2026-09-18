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

//! Chat Pipeline
//!
//! Provider-dispatch pipeline for OpenAI /v1/chat/completions.
//! Called by dispatcher.complete — do not call directly.
//!
//! ## Public API
//!
//!   run — resolve provider, transform, call client, write response

const std = @import("std");
const time = @import("time.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const provider_mod = @import("provider.zig");
const utils = @import("utils.zig");
const chat_types = @import("providers/openai/chat_types.zig");
const openai_common = @import("providers/openai/types.zig");
const chat_content = @import("providers/openai/chat_content.zig");

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

/// Resolve provider, transform request, call client, write response.
/// Called by dispatcher.complete with the effective model after smart-routing.
pub fn run(
    writer: anytype,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    request: chat_types.Request,
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
            .anthropic => try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .sap_ai_core => try dispatchToProvider(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => switch (hai.client.transformerFor(model_info.model, provider_config)) {
                .messages  => try dispatchToProvider(hai.client.HaiClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchToProvider(hai.client.HaiClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini    => try dispatchToProvider(hai.client.HaiClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(hai.client.HaiClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .copilot => switch (copilot.client.transformerFor(model_info.model)) {
                .messages  => try dispatchToProvider(copilot.client.CopilotClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchToProvider(copilot.client.CopilotClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini, .chat => try dispatchToProvider(copilot.client.CopilotClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .google_ai_studio => try dispatchToProvider(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
        }
    } else |_| {
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
            return error.CompatibleFieldMissing;
        };
        const resolved = provider_mod.resolveCompatible(compatible) catch {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        };
        switch (resolved) {
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .anthropic => try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            else => unreachable,
        }
    }
}

fn dispatchToProvider(
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
        streaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and utils.tryAutoReauth(allocator, provider_name)) {
                return streaming(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    } else {
        sync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and utils.tryAutoReauth(allocator, provider_name)) {
                return sync(Client, Transformer, writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    }
}

fn sync(
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

    const transform_start = start_time;
    const provider_request = Transformer.transformChatRequest(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupChatRequest(provider_request, allocator);
    const transform_request_time = time.milliTimestamp() - transform_start;
    log.debug("[SYNC] Transform request completed in {d}ms", .{transform_request_time});

    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[SYNC] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[SYNC] Client init completed in {d}ms", .{client_init_time});

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

    const transform_response_start = time.milliTimestamp();
    const openai_response = Transformer.transformChatResponse(provider_response.value, request, allocator) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}'", .{ err, request.model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupChatResponse(openai_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    if (openai_response.usage) |usage| {
        utils.recordTokenUsage(
            @intCast(usage.prompt_tokens),
            @intCast(usage.completion_tokens),
            model,
            provider_name,
        );
    }

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

fn streaming(
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

    const transform_start = start_time;
    const provider_request = Transformer.transformChatRequest(request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}'", .{ err, request.model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupChatRequest(provider_request, allocator);
    const transform_time = time.milliTimestamp() - transform_start;
    log.debug("[STREAM] Transform request completed in {d}ms", .{transform_time});

    const client_init_start = time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[STREAM] Client initialization error: {} for model '{s}'", .{ err, request.model });
        return error.ClientInitFailed;
    };
    defer client.deinit();
    const client_init_time = time.milliTimestamp() - client_init_start;
    log.debug("[STREAM] Client init completed in {d}ms", .{client_init_time});

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

    var state = Transformer.ChatStreamState.init(allocator, request.model);
    defer state.deinit();

    const process_start = time.milliTimestamp();
    var chunk_count: u32 = 0;
    var first_chunk_time: ?i64 = null;
    var had_error = false;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    while (true) {
        const maybe_line = stream_result.iterator.next() catch |err| {
            had_error = true;
            const body_err = stream_result.response.bodyErr();
            if (body_err) |underlying| {
                log.err("[STREAM] Upstream read failed for model '{s}': {} (underlying: {})", .{ request.model, err, underlying });
            } else {
                log.err("[STREAM] Upstream read failed for model '{s}': {} (after {d} chunks)", .{ request.model, err, chunk_count });
            }

            var err_buf = std.ArrayList(u8).empty;
            defer err_buf.deinit(allocator);
            const err_payload = openai_common.ErrorResponse{ .@"error" = .{
                .message = "Upstream connection lost while streaming response",
                .type = "server_error",
                .param = null,
                .code = null,
            }};
            err_buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(err_payload, .{ .emit_null_optional_fields = false })}) catch break;
            writer.writeAll(err_buf.items) catch {};
            break;
        };

        const line = maybe_line orelse break;

        if (std.mem.startsWith(u8, line, "data: [DONE]")) {
            break;
        }

        const result = Transformer.transformChatStreamLine(line, &state, allocator);
        switch (result) {
            .events => |chunks| {
                defer allocator.free(chunks);

                if (first_chunk_time == null) {
                    first_chunk_time = time.milliTimestamp() - process_start;
                    log.debug("[STREAM] Time to first chunk: {d}ms", .{first_chunk_time.?});
                }

                buf.clearRetainingCapacity();
                for (chunks) |chunk| {
                    chat_content.writeChatSSE(chunk, &buf, allocator) catch continue;
                }
                if (buf.items.len > 0) {
                    chunk_count += 1;
                    try writer.writeAll(buf.items);
                }
            },
            .skip => {},
        }
    }

    try writer.writeAll("data: [DONE]\n\n");

    utils.recordTokenUsage(state.input_tokens, state.output_tokens, model, provider_name);

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
