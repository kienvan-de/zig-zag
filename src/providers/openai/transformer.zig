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
const testing = std.testing;
const OpenAI = @import("types.zig");
const Anthropic = @import("../anthropic/types.zig");
const log = @import("../../log.zig");

/// OpenAI transformer is a pass-through since the proxy accepts OpenAI format
/// and the OpenAI API also expects OpenAI format - no transformation needed!

// ============================================================================
// Streaming State (stateless for OpenAI - just holds original_model)
// ============================================================================

/// State for OpenAI streaming (minimal - just tracks original model name)
pub const StreamState = struct {
    original_model: []const u8,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) StreamState {
        _ = allocator;
        return .{ .original_model = original_model };
    }

    pub fn deinit(self: *StreamState) void {
        _ = self;
    }
};

/// Transform OpenAI ModelsResponse to OpenAI.Model array with provider prefix
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(OpenAI.ModelsResponse),
    provider_name: []const u8,
) ![]OpenAI.Model {
    var models = try allocator.alloc(OpenAI.Model, response.value.data.len);
    errdefer allocator.free(models);

    for (response.value.data, 0..) |upstream_model, i| {
        // Create prefixed model ID: {provider_name}/{model_id}
        const prefixed_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, upstream_model.id });

        models[i] = OpenAI.Model{
            .id = prefixed_id,
            .object = "model",
            .created = upstream_model.created,
            .owned_by = try allocator.dupe(u8, upstream_model.owned_by),
        };
    }

    return models;
}

/// Transform OpenAI request to OpenAI format (pass-through)
/// Since the input is already in OpenAI format, we just return it as-is.
/// For streaming requests, always injects `stream_options: { include_usage: true }`
/// so the upstream returns usage data in the final chunk — required for token/cost tracking.
pub fn transform(
    request: OpenAI.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !OpenAI.Request {
    _ = allocator; // No allocation needed for pass-through

    // Create a copy with the correct model name (without provider prefix)
    return OpenAI.Request{
        .model = model,
        .messages = request.messages,
        .stream = request.stream,
        .stream_options = if (request.stream orelse false)
            OpenAI.StreamOptions{ .include_usage = true }
        else
            request.stream_options,
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .max_completion_tokens = request.max_completion_tokens,
        .top_p = request.top_p,
        .n = request.n,
        .presence_penalty = request.presence_penalty,
        .frequency_penalty = request.frequency_penalty,
        .tools = request.tools,
        .tool_choice = request.tool_choice,
        .parallel_tool_calls = request.parallel_tool_calls,
        .functions = request.functions,
        .function_call = request.function_call,
        .response_format = request.response_format,
        .stop = request.stop,
        .logit_bias = request.logit_bias,
        .logprobs = request.logprobs,
        .top_logprobs = request.top_logprobs,
        .user = request.user,
        .seed = request.seed,
    };
}

/// Transform OpenAI response to OpenAI format
/// For compatible providers, we need to set the model back to the original format
pub fn transformResponse(
    response: OpenAI.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !OpenAI.Response {
    // Allocate model string to return original_model (e.g., "groq/llama-3.1-70b")
    const model_str = try allocator.dupe(u8, original_model);

    return OpenAI.Response{
        .id = response.id,
        .object = response.object,
        .created = response.created,
        .model = model_str,
        .choices = response.choices,
        .usage = response.usage,
        .system_fingerprint = response.system_fingerprint,
        .service_tier = response.service_tier,
    };
}

/// Cleanup transformed request (no-op for pass-through)
pub fn cleanupRequest(request: OpenAI.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
    // No cleanup needed - request is just a shallow copy of the original
}

/// Cleanup transformed response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    // Free the model string allocated in transformResponse
    allocator.free(response.model);
}

// ============================================================================
// Error Response Transformation
// ============================================================================

/// Transform OpenAI error response (pass-through, already in correct format)
pub fn transformErrorResponse(error_response: OpenAI.ErrorResponse) OpenAI.ErrorResponse {
    return error_response;
}

/// Try to parse JSON as OpenAI error response
fn tryParseError(json_part: []const u8, allocator: std.mem.Allocator) ?OpenAI.ErrorResponse {
    const parsed = std.json.parseFromSlice(
        OpenAI.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    // Copy the error details since parsed will be freed
    return OpenAI.ErrorResponse{
        .@"error" = OpenAI.ErrorDetails{
            .message = parsed.value.@"error".message,
            .type = parsed.value.@"error".type,
            .param = parsed.value.@"error".param,
            .code = parsed.value.@"error".code,
        },
    };
}

/// Transform a single SSE line for streaming responses
/// Replaces the model field in the JSON chunk with the original model name
/// Returns StreamLineResult with chunk, error, or skip
/// Caller must check for [DONE] before calling
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) OpenAI.StreamLineResult {
    const original_model = state.original_model;

    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return .{ .skip = {} };
    }

    const json_part = line["data: ".len..];
    log.debug("[OpenAI] [STREAM] raw chunk: {s}", .{json_part});

    // Parse the JSON chunk
    const parsed = std.json.parseFromSlice(
        OpenAI.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        // Failed to parse as stream chunk - try parsing as error response
        if (tryParseError(json_part, allocator)) |error_response| {
            log.warn("[OpenAI] [STREAM] Provider returned error: {s}", .{error_response.@"error".message});
            return .{ .@"error" = error_response };
        }
        log.debug("[OpenAI] Failed to parse stream chunk: {} | raw: {s}", .{ err, json_part });
        return .{ .skip = {} };
    };

    // Create new chunk with original model, serialize, then parse back
    // This ensures consistent ownership model (Parsed owns all data)
    const new_chunk = OpenAI.StreamChunk{
        .id = parsed.value.id,
        .object = parsed.value.object,
        .created = parsed.value.created,
        .model = original_model,
        .choices = parsed.value.choices,
        .usage = parsed.value.usage,
        .system_fingerprint = parsed.value.system_fingerprint,
        .service_tier = parsed.value.service_tier,
    };

    // Serialize to JSON
    var buffer = std.ArrayList(u8){};
    buffer.writer(allocator).print("{f}", .{std.json.fmt(new_chunk, .{})}) catch {
        parsed.deinit();
        return .{ .skip = {} };
    };
    defer buffer.deinit(allocator);

    // Parse back to get new Parsed that owns the data
    const new_parsed = std.json.parseFromSlice(
        OpenAI.StreamChunk,
        allocator,
        buffer.items,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        parsed.deinit();
        return .{ .skip = {} };
    };

    // Clean up original parsed data
    parsed.deinit();

    return .{ .chunk = new_parsed };
}

// ============================================================================
// Anthropic <-> OpenAI Reverse Transforms (for /v1/messages endpoint)
// ============================================================================

/// Transform Anthropic request to OpenAI request
/// Used when /v1/messages receives an Anthropic-format request but the
/// provider speaks OpenAI (openai, copilot, compatible:"openai").
pub fn transformFromAnthropic(
    request: Anthropic.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !OpenAI.Request {
    // Build OpenAI messages array
    var messages = std.ArrayList(OpenAI.Message){};
    errdefer {
        for (messages.items) |msg| {
            freeAnthropicTransformedMessage(msg, allocator);
        }
        messages.deinit(allocator);
    }

    // Add system message if present
    if (request.system) |system_text| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = system_text },
        });
    }

    // Convert Anthropic messages to OpenAI messages
    for (request.messages) |msg| {
        const role: OpenAI.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
        };

        switch (msg.content) {
            .text => |text| {
                const duped_text = try allocator.dupe(u8, text);
                try messages.append(allocator, .{
                    .role = role,
                    .content = .{ .text = duped_text },
                });
            },
            .blocks => |blocks| {
                // Check for tool_result blocks (user role) - each becomes a separate tool message
                // Check for tool_use blocks (assistant role) - become tool_calls on a single message
                var text_parts = std.ArrayList([]const u8){};
                defer text_parts.deinit(allocator);

                var tool_use_blocks = std.ArrayList(OpenAI.ToolCall){};
                defer tool_use_blocks.deinit(allocator);

                var tool_results = std.ArrayList(struct { id: []const u8, content: ?[]const u8 }){};
                defer tool_results.deinit(allocator);

                for (blocks) |block| {
                    switch (block) {
                        .text => |t| {
                            try text_parts.append(allocator, t.text);
                        },
                        .tool_use => |tu| {
                            // Stringify tool input JSON
                            var args_list = std.ArrayList(u8){};
                            defer args_list.deinit(allocator);
                            try args_list.writer(allocator).print("{f}", .{std.json.fmt(tu.input, .{})});
                            const args_str = try allocator.dupe(u8, args_list.items);

                            try tool_use_blocks.append(allocator, .{
                                .id = tu.id,
                                .type = "function",
                                .function = .{
                                    .name = tu.name,
                                    .arguments = args_str,
                                },
                            });
                        },
                        .tool_result => |tr| {
                            try tool_results.append(allocator, .{
                                .id = tr.tool_use_id,
                                .content = tr.content,
                            });
                        },
                        .image => {},
                        .document => {},
                        .thinking => {},
                        .redacted_thinking => {},
                    }
                }

                // Emit tool result messages first (each as separate tool message)
                for (tool_results.items) |tr| {
                    try messages.append(allocator, .{
                        .role = .tool,
                        .content = if (tr.content) |c| .{ .text = try allocator.dupe(u8, c) } else null,
                        .tool_call_id = tr.id,
                    });
                }

                // Emit assistant message with text + tool_calls
                if (text_parts.items.len > 0 or tool_use_blocks.items.len > 0) {
                    const content_text: ?OpenAI.MessageContent = if (text_parts.items.len > 0) blk: {
                        const joined = try std.mem.join(allocator, "", text_parts.items);
                        break :blk .{ .text = joined };
                    } else null;

                    const tool_calls: ?[]const OpenAI.ToolCall = if (tool_use_blocks.items.len > 0)
                        try tool_use_blocks.toOwnedSlice(allocator)
                    else
                        null;

                    try messages.append(allocator, .{
                        .role = role,
                        .content = content_text,
                        .tool_calls = tool_calls,
                    });
                }
            },
        }
    }

    const owned_messages = try messages.toOwnedSlice(allocator);

    // Transform tools if present
    const tools: ?[]const OpenAI.Tool = if (request.tools) |anthro_tools| blk: {
        const oai_tools = try allocator.alloc(OpenAI.Tool, anthro_tools.len);
        for (anthro_tools, 0..) |at, i| {
            oai_tools[i] = .{
                .type = "function",
                .function = .{
                    .name = at.name,
                    .description = at.description,
                    .parameters = at.input_schema,
                    .strict = null,
                },
            };
        }
        break :blk oai_tools;
    } else null;

    // Transform tool_choice if present
    const tool_choice: ?std.json.Value = if (request.tool_choice) |tc| switch (tc) {
        .auto => std.json.Value{ .string = "auto" },
        .any => std.json.Value{ .string = "required" },
        .tool => |t| blk: {
            // Build {"type": "function", "function": {"name": "..."}}
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("type", std.json.Value{ .string = "function" });
            var func_obj = std.json.ObjectMap.init(allocator);
            try func_obj.put("name", std.json.Value{ .string = t.name });
            try obj.put("function", std.json.Value{ .object = func_obj });
            break :blk std.json.Value{ .object = obj };
        },
    } else null;

    return OpenAI.Request{
        .model = model,
        .messages = owned_messages,
        .stream = request.stream,
        .stream_options = if (request.stream orelse false)
            OpenAI.StreamOptions{ .include_usage = true }
        else
            null,
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .top_p = request.top_p,
        .stop = request.stop_sequences,
        .tools = tools,
        .tool_choice = tool_choice,
        .user = if (request.metadata) |m| m.user_id else null,
    };
}

/// Cleanup a request created by transformFromAnthropic
pub fn cleanupFromAnthropicRequest(request: OpenAI.Request, allocator: std.mem.Allocator) void {
    for (request.messages) |msg| {
        freeAnthropicTransformedMessage(msg, allocator);
    }
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
}

/// Free allocated fields in a message created by transformFromAnthropic
fn freeAnthropicTransformedMessage(msg: OpenAI.Message, allocator: std.mem.Allocator) void {
    // Free text content — all text is now owned (duped or joined) except system messages
    if (msg.content) |content| {
        switch (content) {
            .text => |text| {
                if (msg.role != .system) {
                    allocator.free(text);
                }
            },
            .parts => {},
        }
    }
    if (msg.tool_calls) |tool_calls| {
        for (tool_calls) |tc| {
            allocator.free(tc.function.arguments);
        }
        allocator.free(tool_calls);
    }
}

/// Transform OpenAI response to Anthropic response
/// Used when the provider returned an OpenAI response but the client expects Anthropic format.
pub fn transformToAnthropicResponse(
    response: OpenAI.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !Anthropic.Response {
    // Build content blocks from the first choice
    var content_blocks = std.ArrayList(Anthropic.ContentBlock){};
    defer content_blocks.deinit(allocator);

    var stop_reason: ?[]const u8 = null;

    if (response.choices.len > 0) {
        const choice = response.choices[0];

        // Map finish_reason to Anthropic stop_reason
        stop_reason = reverseStopReason(choice.finish_reason);

        // Add text content block if present
        if (choice.message.content) |content_text| {
            try content_blocks.append(allocator, .{ .text = .{
                .type = "text",
                .text = try allocator.dupe(u8, content_text),
            } });
        }

        // Add tool_use content blocks if present
        if (choice.message.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                // Parse arguments string back to JSON value
                const input = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    tc.function.arguments,
                    .{},
                ) catch blk: {
                    break :blk std.json.Parsed(std.json.Value){
                        .value = .{ .object = std.json.ObjectMap.init(allocator) },
                        .arena = undefined,
                    };
                };

                try content_blocks.append(allocator, .{ .tool_use = .{
                    .type = "tool_use",
                    .id = try allocator.dupe(u8, tc.id),
                    .name = try allocator.dupe(u8, tc.function.name),
                    .input = input.value,
                } });
            }
        }
    }

    // If no content blocks, add empty text block
    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{
            .type = "text",
            .text = "",
        } });
    }

    const owned_content = try content_blocks.toOwnedSlice(allocator);

    // Map usage
    const usage = if (response.usage) |u| Anthropic.Usage{
        .input_tokens = @intCast(u.prompt_tokens),
        .output_tokens = @intCast(u.completion_tokens),
    } else Anthropic.Usage{
        .input_tokens = 0,
        .output_tokens = 0,
    };

    // Duplicate id string
    const id_str = try allocator.dupe(u8, response.id);
    const model_str = try allocator.dupe(u8, original_model);

    return Anthropic.Response{
        .id = id_str,
        .type = "message",
        .role = "assistant",
        .content = owned_content,
        .model = model_str,
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = usage,
    };
}

/// Cleanup a response created by transformToAnthropicResponse
pub fn cleanupAnthropicResponse(response: Anthropic.Response, allocator: std.mem.Allocator) void {
    // Free owned strings inside content blocks
    for (response.content) |block| {
        switch (block) {
            .text => |t| {
                if (t.text.len > 0) allocator.free(t.text);
            },
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                // input is a parsed JSON value — its arena is not tracked here
            },
        }
    }
    allocator.free(response.id);
    allocator.free(response.model);
    allocator.free(response.content);
}

/// Reverse map OpenAI finish_reason to Anthropic stop_reason
pub fn reverseStopReason(finish_reason: []const u8) []const u8 {
    if (std.mem.eql(u8, finish_reason, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish_reason, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish_reason, "tool_calls")) return "tool_use";
    return "end_turn";
}

// ============================================================================
// Anthropic SSE Streaming (OpenAI chunks → Anthropic SSE events)
// Used by /v1/messages when the upstream provider speaks OpenAI format.
// ============================================================================

/// Result of transforming a single SSE line to Anthropic format
pub const AnthropicStreamLineResult = Anthropic.AnthropicStreamLineResult;

/// State machine for converting an OpenAI SSE stream into Anthropic SSE events.
pub const AnthropicStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    sent_message_start: bool = false,
    sent_content_block_start: bool = false,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    last_stop_reason: []const u8 = "end_turn",

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) AnthropicStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *AnthropicStreamState) void {
        _ = self;
    }

    pub fn getUsage(self: *const AnthropicStreamState) Anthropic.StreamUsage {
        return .{ .input_tokens = self.input_tokens, .output_tokens = self.output_tokens };
    }
};

/// Convert a single OpenAI SSE line into Anthropic SSE event bytes.
/// The caller writes the returned `.output` bytes directly to the client connection
/// and must free them with the same allocator.
pub fn transformStreamLineToAnthropic(
    line: []const u8,
    state: *AnthropicStreamState,
    allocator: std.mem.Allocator,
) AnthropicStreamLineResult {
    // Only process "data: " lines
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return .{ .skip = {} };
    }

    const json_part = line["data: ".len..];

    // Handle [DONE] — emit closing events
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        return emitClosingEvents(state, allocator);
    }

    // Parse the OpenAI stream chunk using existing transformer
    var inner_state = StreamState.init(allocator, state.original_model);
    defer inner_state.deinit();
    const result = transformStreamLine(line, &inner_state, allocator);

    switch (result) {
        .chunk => |parsed| {
            var chunk = parsed;
            defer chunk.deinit();

            // Track usage from final chunk
            if (chunk.value.usage) |usage| {
                state.input_tokens = @intCast(usage.prompt_tokens);
                state.output_tokens = @intCast(usage.completion_tokens);
            }

            var buf = std.ArrayList(u8){};

            // Emit message_start + content_block_start on first chunk
            if (!state.sent_message_start) {
                state.sent_message_start = true;
                buf.writer(allocator).print(
                    "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_proxy\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"{s}\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}}}}}}\n\n",
                    .{state.original_model},
                ) catch return .{ .skip = {} };
            }

            if (!state.sent_content_block_start) {
                state.sent_content_block_start = true;
                buf.writer(allocator).print(
                    "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n",
                    .{},
                ) catch {
                    buf.deinit(allocator);
                    return .{ .skip = {} };
                };
            }

            // Extract text delta and finish_reason from first choice
            if (chunk.value.choices.len > 0) {
                const choice = chunk.value.choices[0];

                if (choice.finish_reason) |fr| {
                    state.last_stop_reason = reverseStopReason(fr);
                }

                if (choice.delta.content) |text| {
                    if (text.len > 0) {
                        const delta = Anthropic.TextDelta{ .type = "text_delta", .text = text };
                        const block_delta = Anthropic.ContentBlockDeltaData{
                            .type = "content_block_delta",
                            .index = 0,
                            .delta = delta,
                        };
                        buf.writer(allocator).print("event: content_block_delta\ndata: {f}\n\n", .{
                            std.json.fmt(block_delta, .{}),
                        }) catch {
                            buf.deinit(allocator);
                            return .{ .skip = {} };
                        };
                    }
                }
            }

            if (buf.items.len == 0) {
                buf.deinit(allocator);
                return .{ .skip = {} };
            }

            return .{ .output = buf.toOwnedSlice(allocator) catch {
                buf.deinit(allocator);
                return .{ .skip = {} };
            } };
        },
        .@"error" => {
            return .{ .skip = {} };
        },
        .skip => {
            return .{ .skip = {} };
        },
    }
}

/// Emit content_block_stop + message_delta + message_stop at end of stream
fn emitClosingEvents(state: *AnthropicStreamState, allocator: std.mem.Allocator) AnthropicStreamLineResult {
    var buf = std.ArrayList(u8){};

    // If we never sent content_block_start, emit both start and stop
    if (!state.sent_content_block_start and state.sent_message_start) {
        buf.writer(allocator).print(
            "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n",
            .{},
        ) catch return .{ .skip = {} };
    }

    if (!state.sent_message_start) {
        // Never received any chunks — emit minimal message
        buf.writer(allocator).print(
            "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_proxy\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"{s}\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}}}}}}\n\n" ++
                "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n",
            .{state.original_model},
        ) catch return .{ .skip = {} };
    }

    buf.writer(allocator).print(
        "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\",\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}\n\n" ++
            "event: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
        .{ state.last_stop_reason, state.output_tokens },
    ) catch {
        buf.deinit(allocator);
        return .{ .skip = {} };
    };

    return .{ .output = buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return .{ .skip = {} };
    } };
}

// ============================================================================
// Unit Tests
// ============================================================================
