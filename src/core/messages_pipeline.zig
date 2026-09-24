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

//! Messages Pipeline
//!
//! Provider-dispatch pipeline for Anthropic /v1/messages.
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
const messages_types = @import("providers/anthropic/types.zig");
const anthropic_content = @import("providers/anthropic/content.zig");

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

/// Perform an Anthropic Messages API completion (`/v1/messages`).
/// Resolve provider, transform request, call client, write response.
/// Called by dispatcher.complete with the effective model after smart-routing.
pub fn run(
    writer: anytype,
    err_writer: anytype,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    request: messages_types.Request,
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
            .anthropic => try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .hai => switch (hai.client.transformerFor(model_info.model, provider_config)) {
                .messages  => try dispatchToProvider(hai.client.HaiClient, anthropic.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchToProvider(hai.client.HaiClient, openai.responses_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini    => try dispatchToProvider(hai.client.HaiClient, google_ai_studio.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(hai.client.HaiClient, openai.chat_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(openai.client.OpenAIClient, openai.chat_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .copilot => switch (copilot.client.transformerFor(model_info.model)) {
                .messages  => try dispatchToProvider(copilot.client.CopilotClient, anthropic.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .responses => try dispatchToProvider(copilot.client.CopilotClient, openai.responses_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .gemini, .chat => try dispatchToProvider(copilot.client.CopilotClient, openai.chat_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            .sap_ai_core => try dispatchToProvider(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .google_ai_studio => try dispatchToProvider(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
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
            .anthropic => try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(openai.client.OpenAIClient, openai.chat_transformer, writer, err_writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            },
            else => unreachable,
        }
    }
}

fn dispatchToProvider(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    err_writer: anytype,
    is_streaming: bool,
    allocator: std.mem.Allocator,
    request: messages_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    if (is_streaming) {
        streaming(Client, Transformer, writer, err_writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and utils.tryAutoReauth(allocator, provider_name)) {
                return streaming(Client, Transformer, writer, err_writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    } else {
        sync(Client, Transformer, writer, err_writer, allocator, request, model, provider_name, provider_config) catch |err| {
            if (err == error.AuthRequired and utils.tryAutoReauth(allocator, provider_name)) {
                return sync(Client, Transformer, writer, err_writer, allocator, request, model, provider_name, provider_config);
            }
            return err;
        };
    }
}

fn sync(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    err_writer: anytype,
    allocator: std.mem.Allocator,
    request: messages_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[SYNC] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    const transform_start = start_time;
    const provider_request = Transformer.transformMessagesRequest(request, model, allocator) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupMessagesRequest(provider_request, allocator);
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
    const result = client.sendRequest(provider_request) catch |err| {
        log.err("[SYNC] Provider API error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return err;
    };
    const provider_request_time = time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    const provider_response = switch (result) {
        .ok => |r| r,
        .err => |e| {
            defer e.body.deinit();
            return utils.writeUpstreamError(err_writer, "[SYNC]", provider_name, Transformer.transformToMessagesError(e.body.value), e.status);
        },
    };
    defer provider_response.deinit();

    const transform_response_start = time.milliTimestamp();
    const anthropic_response = Transformer.transformMessagesResponse(provider_response.value, request, allocator) catch |err| {
        log.err("[SYNC] Transform response error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformResponseFailed;
    };
    defer Transformer.cleanupMessagesResponse(anthropic_response, allocator);
    const transform_response_time = time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    utils.recordMessagesTokenUsage(anthropic_response.usage, provider_name, model);

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

fn streaming(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    err_writer: anytype,
    allocator: std.mem.Allocator,
    request: messages_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const start_time = time.milliTimestamp();
    log.info("[STREAM] POST /v1/messages - request received for model '{s}/{s}'", .{ provider_name, model });

    const transform_start = start_time;
    var mutable_request = request;
    mutable_request.stream = true;
    const provider_request = Transformer.transformMessagesRequest(mutable_request, model, allocator) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        return error.TransformFailed;
    };
    defer Transformer.cleanupMessagesRequest(provider_request, allocator);
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
    const start_result = client.sendStreamingRequest(provider_request) catch |err| {
        log.err("[STREAM] Provider streaming error: {} for model '{s}/{s}'", .{ err, provider_name, model });
        if (err == error.AuthRequired) return error.AuthRequired;
        return err;
    };
    // Connection-time non-2xx: no SSE headers sent yet, return a proper HTTP error.
    const stream_result = switch (start_result) {
        .ok => |r| r,
        .err => |e| {
            defer e.body.deinit();
            return utils.writeUpstreamError(err_writer, "[STREAM]", provider_name, Transformer.transformToMessagesError(e.body.value), e.status);
        },
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    const process_start = time.milliTimestamp();
    var chunk_count: u32 = 0;
    var had_error = false;

    var stream_state = Transformer.MessagesStreamState.init(allocator, request.model);
    defer stream_state.deinit();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

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
            .events => |events| {
                defer allocator.free(events);

                buf.clearRetainingCapacity();
                for (events) |event| {
                    anthropic_content.writeMessagesSSE(event, &buf, allocator) catch continue;
                }
                if (buf.items.len > 0) {
                    chunk_count += 1;
                    writer.writeAll(buf.items) catch |write_err| {
                        log.err("[STREAM] Failed to write to client: {}", .{write_err});
                        had_error = true;
                        break;
                    };
                }
            },
            .skip => {},
        }
    }

    utils.recordMessagesStreamTokenUsage(stream_state, provider_name, model);

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
