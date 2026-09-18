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

//! Responses Pipeline
//!
//! Provider-dispatch pipeline for OpenAI /v1/responses.
//! Called by dispatcher.complete — do not call directly.
//!
//! ## Public API
//!
//!   run — resolve provider, transform, call client, write response

const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const provider_mod = @import("provider.zig");
const utils = @import("utils.zig");
const responses_types = @import("providers/openai/responses_types.zig");
const responses_content = @import("providers/openai/responses_content.zig");

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
            .anthropic => try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            .openai => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
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

        if (std.mem.eql(u8, compatible, "openai")) {
            switch (openai.client.transformerFor(provider_config)) {
                .responses => try dispatchToProvider(openai.client.OpenAIClient, openai.responses_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
                .chat      => try dispatchToProvider(openai.client.OpenAIClient, openai.chat_transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config),
            }
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            try dispatchToProvider(anthropic.client.AnthropicClient, anthropic.transformer, writer, is_streaming, allocator, request, model_info.model, model_info.provider, provider_config);
        } else {
            log.err("Unknown compatible provider type: '{s}'", .{compatible});
            return error.UnknownCompatibleType;
        }
    }
}

fn dispatchToProvider(
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
    request: responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
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
    utils.recordTokenUsage(
        if (resp.usage) |u| u.input_tokens else 0,
        if (resp.usage) |u| u.output_tokens else 0,
        model,
        provider_name,
    );
}

fn streaming(
    comptime Client: type,
    comptime Transformer: type,
    writer: anytype,
    allocator: std.mem.Allocator,
    request: responses_types.Request,
    model: []const u8,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
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

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    while (true) {
        const maybe_line = stream_result.iterator.next() catch break;
        const line = maybe_line orelse break;
        if (std.mem.startsWith(u8, line, "data: [DONE]")) break;
        switch (Transformer.transformResponsesStreamLine(line, &stream_state, allocator)) {
            .events => |events| {
                defer allocator.free(events);
                buf.clearRetainingCapacity();
                for (events) |event| {
                    responses_content.writeResponsesSSE(event, &buf, allocator) catch continue;
                }
                writer.writeAll(buf.items) catch {};
            },
            .skip => {},
        }
    }
    if (Transformer.flushResponsesStream(&stream_state, allocator)) |flush_events| {
        defer allocator.free(flush_events);
        buf.clearRetainingCapacity();
        for (flush_events) |event| {
            responses_content.writeResponsesSSE(event, &buf, allocator) catch continue;
        }
        writer.writeAll(buf.items) catch {};
    }
    if (Transformer.appendsDoneMarker) {
        try writer.writeAll("data: [DONE]\n\n");
    }
    utils.recordTokenUsage(
        stream_state.input_tokens,
        stream_state.output_tokens,
        model,
        provider_name,
    );
}
