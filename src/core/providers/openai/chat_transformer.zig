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

//! Transformer for OpenAI-format providers (openai, compatible, copilot, hai).
//!
//! The proxy accepts OpenAI format and these upstreams speak OpenAI format,
//! so the Chat flow is a pinned pass-through. The Messages and Responses
//! flows convert between the inbound schema and the chat wire.
//!
//! Four flows, named after the *inbound* schema. Every pub symbol is defined
//! here. Conversion helpers live in chat_content.zig only.
//! Stream functions return typed event slices — callers own serialization.

const std = @import("std");

const Chat = @import("chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Responses = @import("responses_types.zig");
const common = @import("types.zig");
const content = @import("chat_content.zig");
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the upstream models listing to inbound Model entries, prefixing ids
/// with the provider name. OpenAI listings already carry created and owned_by.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(common.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var models = try allocator.alloc(common.Model, response.value.data.len);
    errdefer allocator.free(models);
    for (response.value.data, 0..) |m, i| {
        models[i] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, m.id }),
            .object = "model",
            .created = m.created,
            .owned_by = try allocator.dupe(u8, m.owned_by),
        };
    }
    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — pinned pass-through
// ============================================================================

pub const ChatStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ChatStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *ChatStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Chat wire request → chat wire request, pinned to model.
/// Pass-through — model overridden, stream_options.include_usage injected when streaming.
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Chat.Request {
    _ = allocator;
    var result = request;
    result.model = model;
    if (request.stream orelse false) result.stream_options = .{ .include_usage = true };
    return result;
}

/// No-op: transformChatRequest allocates nothing (pure borrow).
pub fn cleanupChatRequest(request: Chat.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
}

/// Chat wire response → inbound chat response.
/// Pass-through — model rewritten to the provider-prefixed name the client sent.
pub fn transformChatResponse(
    upstream: Chat.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    var result = upstream;
    result.model = try allocator.dupe(u8, original_req.model);
    return result;
}

/// Free what transformChatResponse allocated: the model string.
pub fn cleanupChatResponse(inbound_response: Chat.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.model);
}

/// One chat wire SSE line → Chat.ChatStreamLineResult (typed StreamChunk slice).
/// Pass-through — model rewritten to original_model, id/usage/finish_reason captured into state.
/// All strings embedded in the returned chunk are freshly duped so the parse arena can be freed.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) Chat.ChatStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        if (content.tryParseError(json_part, allocator)) |err| {
                return .{ .@"error" = err };
            }
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    const v = parsed.value;

    // Capture id into state (owned, survives the parse arena).
    if (state.response_id.len == 0 and v.id.len > 0) {
        state.response_id = allocator.dupe(u8, v.id) catch return .{ .skip = {} };
    }

    if (v.usage) |u| {
        state.input_tokens = u.prompt_tokens;
        state.output_tokens = u.completion_tokens;
    }

    if (v.choices.len > 0) {
        if (v.choices[0].finish_reason) |reason| {
            if (reason.len > 0) {
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, reason) catch null;
            }
        }
    }

    // Deep-dupe the delta so all string leaves survive parsed.deinit().
    const src_delta: Chat.Delta = if (v.choices.len > 0) v.choices[0].delta else .{};
    var owned_delta = src_delta;
    if (src_delta.content) |c| {
        owned_delta.content = allocator.dupe(u8, c) catch return .{ .skip = {} };
    }
    // tool_calls delta strings (arguments, id, name) — dupe each.
    if (src_delta.tool_calls) |tcs| {
        const owned_tcs = allocator.alloc(Chat.DeltaToolCall, tcs.len) catch return .{ .skip = {} };
        for (tcs, 0..) |tc, i| {
            owned_tcs[i] = tc;
            if (tc.id) |s| owned_tcs[i].id = allocator.dupe(u8, s) catch null;
            if (tc.function) |f| {
                var owned_f = f;
                if (f.name) |s| owned_f.name = allocator.dupe(u8, s) catch null;
                if (f.arguments) |s| owned_f.arguments = allocator.dupe(u8, s) catch null;
                owned_tcs[i].function = owned_f;
            }
        }
        owned_delta.tool_calls = owned_tcs;
    }
    // audio is std.json.Value — cannot safely own without deep-dupe; dropped.
    owned_delta.audio = null;

    const finish_reason: ?[]const u8 = if (v.choices.len > 0)
        if (v.choices[0].finish_reason) |r| allocator.dupe(u8, r) catch null else null
    else null;

    const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
    choices[0] = .{
        .index = if (v.choices.len > 0) v.choices[0].index else 0,
        .delta = owned_delta,
        .finish_reason = finish_reason,
        .logprobs = null, // ChoiceLogprobs contains arena slices — cannot safely own; dropped.
    };

    const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
    chunks[0] = .{
        .id = state.response_id,
        .object = "chat.completion.chunk",
        .created = v.created,
        .model = state.original_model,
        .choices = choices,
        .usage = v.usage,
        .system_fingerprint = if (v.system_fingerprint) |s| allocator.dupe(u8, s) catch null else null,
        .service_tier = if (v.service_tier) |s| allocator.dupe(u8, s) catch null else null,
        .obfuscation = if (v.obfuscation) |s| allocator.dupe(u8, s) catch null else null,
        .moderation = null, // std.json.Value — cannot safely own without deep-dupe; dropped in pass-through
    };
    return .{ .events = chunks };
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → chat wire
// ============================================================================

pub const MessagesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    sent_open: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Inbound messages request → chat wire request, pinned to model.
///
/// Messages.Request fields mapped:
///   model (pinned), system→system message (duped), messages (role map +
///   text/tool_use/tool_result blocks), stream, stream_options (include_usage
///   injected when streaming), temperature, max_tokens, top_p,
///   stop_sequences→stop, tools (name/description/input_schema→parameters),
///   tool_choice (.auto→"auto", .any→"required", .none→"none",
///   .tool→{type:"function",function:{name:...}}),
///   metadata.user_id→user.
/// Skipped: top_k (no Chat equivalent), thinking, betas, service_tier,
///   output_config, container, inference_geo, cache_control, fallbacks.
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Chat.Request {
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer {
        for (messages.items) |msg| content.freeMessageOwnedText(msg, allocator);
        messages.deinit(allocator);
    }

    if (request.system) |system_text| {
        const text: []const u8 = switch (system_text) {
            .text => |t| try allocator.dupe(u8, t),
            .blocks => |blks| blk: {
                var parts: std.ArrayList([]const u8) = .empty;
                defer parts.deinit(allocator);
                for (blks) |b| try parts.append(allocator, b.text);
                if (parts.items.len == 0) break :blk try allocator.dupe(u8, "");
                break :blk try std.mem.join(allocator, "\n\n", parts.items);
            },
        };
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = text },
        });
    }

    for (request.messages) |msg| {
        const role: Chat.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system => .system,
        };

        switch (msg.content) {
            .text => |text| try messages.append(allocator, .{
                .role = role,
                .content = .{ .text = try allocator.dupe(u8, text) },
            }),
            .blocks => |blocks| {
                var text_parts: std.ArrayList([]const u8) = .empty;
                defer text_parts.deinit(allocator);

                var tool_use_blocks: std.ArrayList(Chat.ToolCall) = .empty;
                errdefer {
                    for (tool_use_blocks.items) |tc| allocator.free(tc.function.arguments);
                    tool_use_blocks.deinit(allocator);
                }

                var tool_results: std.ArrayList(struct { id: []const u8, content: ?[]const u8, content_owned: bool }) = .empty;
                defer {
                    for (tool_results.items) |tr| {
                        if (tr.content_owned) if (tr.content) |c| allocator.free(c);
                    }
                    tool_results.deinit(allocator);
                }

                for (blocks) |block| {
                    switch (block) {
                        .text => |tb| try text_parts.append(allocator, tb.text),
                        .tool_use => |tu| {
                            var args_list: std.ArrayList(u8) = .empty;
                            defer args_list.deinit(allocator);
                            try args_list.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});
                            try tool_use_blocks.append(allocator, .{
                                .id = tu.id,
                                .type = "function",
                                .function = .{
                                    .name = tu.name,
                                    .arguments = try allocator.dupe(u8, args_list.items),
                                },
                            });
                        },
                        .tool_result => |tr| {
                            const c_text: ?[]const u8 = if (tr.content) |c| switch (c) {
                                .text => |s| s,
                                .blocks => |blks| blk: {
                                    var parts: std.ArrayList([]const u8) = .empty;
                                    defer parts.deinit(allocator);
                                    for (blks) |b| try parts.append(allocator, b.text);
                                    break :blk if (parts.items.len > 0)
                                        try std.mem.join(allocator, "", parts.items)
                                    else
                                        null;
                                },
                            } else null;
                            const owned = if (tr.content) |c| c == .blocks else false;
                            try tool_results.append(allocator, .{
                                .id = tr.tool_use_id,
                                .content = c_text,
                                .content_owned = owned,
                            });
                        },
                        .image, .document, .thinking, .redacted_thinking,
                        .server_tool_use, .web_search_tool_result, .web_fetch_tool_result,
                        .code_execution_tool_result, .bash_code_execution_tool_result,
                        .text_editor_code_execution_tool_result, .tool_search_tool_result,
                        .search_result, .container_upload => {},
                    }
                }

                // Tool results first — one tool message per result.
                for (tool_results.items) |tr| {
                    // If content_owned, the string is already allocated — use directly.
                    // If borrowed (from inbound arena), dupe it so the message owns it.
                    const msg_content: ?Chat.MessageContent = if (tr.content) |c|
                        .{ .text = if (tr.content_owned) c else try allocator.dupe(u8, c) }
                    else
                        null;
                    try messages.append(allocator, .{
                        .role = .tool,
                        .content = msg_content,
                        .tool_call_id = tr.id,
                    });
                }

                // Assistant message with text + tool_calls.
                if (text_parts.items.len > 0 or tool_use_blocks.items.len > 0) {
                    const content_text: ?Chat.MessageContent = if (text_parts.items.len > 0)
                        .{ .text = try std.mem.join(allocator, "", text_parts.items) }
                    else
                        null;
                    try messages.append(allocator, .{
                        .role = role,
                        .content = content_text,
                        .tool_calls = if (tool_use_blocks.items.len > 0)
                            try tool_use_blocks.toOwnedSlice(allocator)
                        else
                            null,
                    });
                }
            },
        }
    }

    const tools: ?[]Chat.Tool = if (request.tools) |anthro_tools| blk: {
        const oai_tools = try allocator.alloc(Chat.Tool, anthro_tools.len);
        for (anthro_tools, 0..) |at, i| {
            oai_tools[i] = .{
                .type = "function",
                .function = .{
                    .name = at.name orelse "",
                    .description = at.description,
                    .parameters = at.input_schema,
                    .strict = null,
                },
            };
        }
        break :blk oai_tools;
    } else null;
    errdefer if (tools) |ts| allocator.free(ts);

    const tool_choice: ?std.json.Value = if (request.tool_choice) |tc| switch (tc) {
        .auto => .{ .string = "auto" },
        .any => .{ .string = "required" },
        .none => .{ .string = "none" },
        .tool => |tl| blk: {
            var obj: std.json.ObjectMap = .{};
            try obj.put(allocator, "type", .{ .string = "function" });
            var func_obj: std.json.ObjectMap = .{};
            try func_obj.put(allocator, "name", .{ .string = tl.name });
            try obj.put(allocator, "function", .{ .object = func_obj });
            break :blk .{ .object = obj };
        },
    } else null;
    errdefer if (tool_choice) |tc| content.freeBuiltToolChoice(tc, allocator);

    return .{
        .model = model,
        .messages = try messages.toOwnedSlice(allocator),
        .stream = request.stream,
        .stream_options = if (request.stream orelse false)
            .{ .include_usage = true }
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

/// Free what transformMessagesRequest allocated.
pub fn cleanupMessagesRequest(request: Chat.Request, allocator: std.mem.Allocator) void {
    for (request.messages) |msg| content.freeMessageOwnedText(msg, allocator);
    allocator.free(request.messages);
    if (request.tools) |ts| allocator.free(ts);
    if (request.tool_choice) |tc| content.freeBuiltToolChoice(tc, allocator);
}

/// Chat wire response → inbound messages response.
///
/// Chat.Response fields mapped:
///   choices[0].message.content → content[].text block (duped)
///   choices[0].message.tool_calls → content[].tool_use blocks (id/name duped,
///     arguments leaky-parsed)
///   choices[0].finish_reason → stop_reason (transformStopReasonToMessages)
///   id → id (duped)
///   original_req.model → model (duped)
///   usage.prompt_tokens → usage.input_tokens
///   usage.completion_tokens → usage.output_tokens
/// Skipped: choices[0].message.refusal, annotations, audio, logprobs,
///   system_fingerprint, service_tier, metadata, moderation (no Messages equivalent).
pub fn transformMessagesResponse(
    upstream: Chat.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer {
        content.freeMessageOwnedBlocks(content_blocks.items, allocator);
        content_blocks.deinit(allocator);
    }

    var stop_reason: ?[]const u8 = null;

    if (upstream.choices.len > 0) {
        const choice = upstream.choices[0];
        stop_reason = content.transformStopReasonToMessages(choice.finish_reason);

        if (choice.message.content) |text| {
            try content_blocks.append(allocator, .{ .text = .{
                .type = "text",
                .text = try allocator.dupe(u8, text),
            } });
        }

        if (choice.message.tool_calls) |tool_calls| for (tool_calls) |tc| {
            try content_blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.function.name),
                .input = try content.parseToolArguments(tc.function.arguments, allocator),
            } });
        };
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{
            .type = "text",
            .text = try allocator.dupe(u8, ""),
        } });
    }

    return .{
        .id = try allocator.dupe(u8, upstream.id),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, original_req.model),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = if (upstream.usage) |u| .{
            .input_tokens = u.prompt_tokens,
            .output_tokens = u.completion_tokens,
        } else .{ .input_tokens = 0, .output_tokens = 0 },
    };
}

/// Free what transformMessagesResponse allocated.
pub fn cleanupMessagesResponse(inbound_response: Messages.Response, allocator: std.mem.Allocator) void {
    content.freeMessageOwnedBlocks(inbound_response.content, allocator);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    allocator.free(inbound_response.content);
}

/// One chat wire SSE line → Messages.MessagesStreamLineResult (typed SseEvent slice).
///
/// Synthesizes Anthropic SSE protocol from chat chunks:
///   first chunk → message_start + content_block_start
///   text delta  → content_block_delta
///   [DONE]      → content_block_stop + message_delta + message_stop
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) Messages.MessagesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    // [DONE] — close the synthesized message.
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        var events: std.ArrayList(Messages.SseEvent) = .empty;
        defer events.deinit(allocator);

        // Emit open if stream ended before we got any chunks.
        if (!state.sent_open) {
            events.append(allocator, .{ .message_start = .{
                .type = "message_start",
                .message = .{
                    .id = "msg_proxy",
                    .type = "message",
                    .role = "assistant",
                    .content = &.{},
                    .model = state.original_model,
                    .stop_reason = null,
                    .stop_sequence = null,
                    .usage = .{ .input_tokens = 0, .output_tokens = 0 },
                },
            }}) catch return .{ .skip = {} };
            events.append(allocator, .{ .content_block_start = .{
                .type = "content_block_start",
                .index = 0,
                .content_block = .{ .type = "text", .text = "" },
            }}) catch return .{ .skip = {} };
            state.sent_open = true;
        }

        const stop_reason = content.transformStopReasonToMessages(
            state.finish_reason orelse "stop"
        );
        events.append(allocator, .{ .content_block_stop = .{
            .type = "content_block_stop", .index = 0,
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .message_delta = .{
            .type = "message_delta",
            .delta = .{ .stop_reason = stop_reason, .stop_sequence = null },
            .usage = .{ .output_tokens = state.output_tokens },
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .message_stop = .{ .type = "message_stop" } }) catch
            return .{ .skip = {} };
        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);

    // Synthetic protocol opening, once per stream.
    if (!state.sent_open) {
        events.append(allocator, .{ .message_start = .{
            .type = "message_start",
            .message = .{
                .id = "msg_proxy",
                .type = "message",
                .role = "assistant",
                .content = &.{},
                .model = state.original_model,
                .stop_reason = null,
                .stop_sequence = null,
                .usage = .{ .input_tokens = 0, .output_tokens = 0 },
            },
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .content_block_start = .{
            .type = "content_block_start",
            .index = 0,
            .content_block = .{ .type = "text", .text = "" },
        }}) catch return .{ .skip = {} };
        state.sent_open = true;
    }

    if (parsed.value.choices.len > 0) {
        const choice = parsed.value.choices[0];

        if (parsed.value.usage) |u| {
            state.input_tokens = u.prompt_tokens;
            state.output_tokens = u.completion_tokens;
        }

        if (choice.finish_reason) |reason| {
            if (reason.len > 0) {
                // Dupe — reason borrows from parsed which dies below.
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, reason) catch null;
            }
        }

        if (choice.delta.content) |text| {
            if (text.len > 0) {
                // Dupe — text borrows from parsed which dies after this function returns.
                const owned_text = allocator.dupe(u8, text) catch return .{ .skip = {} };
                events.append(allocator, .{ .content_block_delta = .{
                    .type = "content_block_delta",
                    .index = 0,
                    .delta = .{ .type = "text_delta", .text = owned_text },
                }}) catch {
                    allocator.free(owned_text);
                    return .{ .skip = {} };
                };
            }
        }
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — inbound responses schema → chat wire
// ============================================================================

pub const ResponsesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    sequence_number: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Inbound responses request → chat wire request, pinned to model.
///
/// Responses.Request fields mapped:
///   model (pinned), instructions→system message (borrows),
///   input.text→user message, input.items→messages (role, content, tool_call_id),
///   stream, stream_options (include_usage injected when streaming),
///   temperature, top_p, top_logprobs, max_output_tokens→max_completion_tokens,
///   tools (.function only→Chat.Tool; others skipped),
///   tool_choice, parallel_tool_calls, store, metadata, user, service_tier,
///   stop, text.format→response_format,
///   reasoning.effort→reasoning_effort.
/// Skipped: previous_response_id, include, truncation, background,
///   max_tool_calls, conversation, context_management, moderation,
///   safety_identifier, prompt_cache_*, prompt, verbosity (no Chat equivalent).
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Chat.Request {
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer {
        for (messages.items) |msg| {
            if (msg.tool_calls) |tcs| {
                for (tcs) |tc| {
                    allocator.free(tc.id);
                    allocator.free(tc.function.name);
                    allocator.free(tc.function.arguments);
                }
                allocator.free(tcs);
            }
        }
        messages.deinit(allocator);
    }

    if (request.instructions) |inst| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = inst },
        });
    }

    switch (request.input) {
        .text => |text| try messages.append(allocator, .{
            .role = .user,
            .content = .{ .text = text },
        }),
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const item_type_val = obj.get("type") orelse continue;
            if (item_type_val != .string) continue;
            const item_type = item_type_val.string;

            if (std.mem.eql(u8, item_type, "message")) {
                const role_val = obj.get("role") orelse continue;
                if (role_val != .string) continue;
                const role = std.meta.stringToEnum(Chat.Role, role_val.string) orelse continue;

                const message_content: ?Chat.MessageContent = blk: {
                    const cv = obj.get("content") orelse break :blk null;
                    switch (cv) {
                        .string => |s| break :blk .{ .text = s },
                        .array => |arr| {
                            for (arr.items) |part| {
                                if (part != .object) continue;
                                const text_val = part.object.get("text") orelse continue;
                                if (text_val == .string and text_val.string.len > 0) {
                                    break :blk .{ .text = text_val.string };
                                }
                            }
                            break :blk null;
                        },
                        else => break :blk null,
                    }
                };

                try messages.append(allocator, .{
                    .role = role,
                    .content = message_content,
                    .tool_call_id = if (obj.get("tool_call_id")) |v|
                        if (v == .string) v.string else null
                    else
                        null,
                });
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                // function_call → assistant message with tool_calls
                const name_val = obj.get("name") orelse continue;
                if (name_val != .string) continue;
                const id_val = obj.get("call_id") orelse obj.get("id") orelse continue;
                if (id_val != .string) continue;
                const args_str: []const u8 = if (obj.get("arguments")) |a|
                    if (a == .string) a.string else "{}"
                else "{}";

                const tcs = try allocator.alloc(Chat.ToolCall, 1);
                tcs[0] = .{
                    .id = try allocator.dupe(u8, id_val.string),
                    .type = "function",
                    .function = .{
                        .name = try allocator.dupe(u8, name_val.string),
                        .arguments = try allocator.dupe(u8, args_str),
                    },
                };
                try messages.append(allocator, .{
                    .role = .assistant,
                    .content = null,
                    .tool_calls = tcs,
                });
            } else if (std.mem.eql(u8, item_type, "function_call_output")) {
                // function_call_output → tool message
                const call_id_val = obj.get("call_id") orelse continue;
                if (call_id_val != .string) continue;
                const output_text: ?[]const u8 = if (obj.get("output")) |o|
                    if (o == .string) o.string else null
                else null;

                try messages.append(allocator, .{
                    .role = .tool,
                    .content = if (output_text) |t| .{ .text = t } else null,
                    .tool_call_id = call_id_val.string,
                });
            }
            // reasoning items: dropped (no Chat equivalent).
        },
    }

    const chat_tools: ?[]const Chat.Tool = if (request.tools) |rt| blk: {
        var list: std.ArrayList(Chat.Tool) = .empty;
        errdefer list.deinit(allocator);
        for (rt) |t| switch (t) {
            .function => |f| try list.append(allocator, .{ .type = "function", .function = f.function }),
            .web_search_preview, .file_search, .code_interpreter_tool, .mcp_tool, .other => {},
        };
        if (list.items.len == 0) {
            list.deinit(allocator);
            break :blk null;
        }
        break :blk try list.toOwnedSlice(allocator);
    } else null;

    return .{
        .model = model,
        .messages = try messages.toOwnedSlice(allocator),
        .stream = request.stream,
        .stream_options = if (request.stream orelse false)
            .{ .include_usage = true }
        else
            null,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_logprobs = request.top_logprobs,
        .max_completion_tokens = request.max_output_tokens,
        .tools = chat_tools,
        .tool_choice = request.tool_choice,
        .parallel_tool_calls = request.parallel_tool_calls,
        .store = request.store,
        .metadata = request.metadata,
        .user = request.user,
        .service_tier = request.service_tier,
        .response_format = if (request.text) |txt| txt.format else null,
        .reasoning_effort = if (request.reasoning_effort) |re| re
        else if (request.reasoning) |r| blk: {
            if (r == .object) {
                const effort = r.object.get("effort") orelse break :blk null;
                if (effort == .string) break :blk effort.string;
            }
            break :blk null;
        } else null,
    };
}

/// Free what transformResponsesRequest allocated: messages (including tool_calls slices
/// and their duped strings) and tools slice.
/// Note: message content strings and tool_call_id borrow from the inbound request arena.
pub fn cleanupResponsesRequest(request: Chat.Request, allocator: std.mem.Allocator) void {
    for (request.messages) |msg| {
        if (msg.tool_calls) |tcs| {
            for (tcs) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            allocator.free(tcs);
        }
    }
    allocator.free(request.messages);
    if (request.tools) |t| allocator.free(t);
}

/// Chat wire response → inbound responses response.
///
/// Chat.Response fields mapped:
///   choices[0].message.content → output[0].message.content[output_text] (duped)
///   choices[0].message.tool_calls → output[N].function_call (id/name/arguments duped)
///   choices[0].finish_reason="length" → status="incomplete"
///   id → id (duped), output[0].message.id (duped)
///   upstream.service_tier → service_tier
///   original_req.model → model (duped)
///   usage.prompt_tokens → usage.input_tokens
///   usage.completion_tokens → usage.output_tokens
///   usage.total_tokens → usage.total_tokens
/// Echo fields from original_req: temperature, top_p, parallel_tool_calls,
///   store, max_output_tokens, metadata, user, service_tier (upstream takes precedence),
///   truncation, previous_response_id, background, max_tool_calls.
pub fn transformResponsesResponse(
    upstream: Chat.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer output_items.deinit(allocator);

    if (upstream.choices.len > 0) {
        const choice = upstream.choices[0];
        const message = choice.message;

        var content_parts: std.ArrayList(Responses.OutputContent) = .empty;
        errdefer content_parts.deinit(allocator);

        if (message.content) |c| {
            if (c.len > 0) {
                try content_parts.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, c),
                } });
            }
        }

        const msg_status: []const u8 = if (std.mem.eql(u8, choice.finish_reason, "length"))
            "incomplete"
        else
            "completed";

        try output_items.append(allocator, .{ .message = .{
            .id = try allocator.dupe(u8, upstream.id),
            .type = "message",
            .role = "assistant",
            .content = try content_parts.toOwnedSlice(allocator),
            .status = msg_status,
        } });

        if (message.tool_calls) |tool_calls| for (tool_calls) |tc| {
            try output_items.append(allocator, .{ .function_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .type = "function_call",
                .name = try allocator.dupe(u8, tc.function.name),
                .arguments = try allocator.dupe(u8, tc.function.arguments),
                .status = "completed",
            } });
        };
    } else {
        try output_items.append(allocator, .{ .message = .{
            .id = try allocator.dupe(u8, upstream.id),
            .type = "message",
            .role = "assistant",
            .content = try allocator.alloc(Responses.OutputContent, 0),
            .status = "completed",
        } });
    }

    const top_status: []const u8 = if (upstream.choices.len > 0 and
        std.mem.eql(u8, upstream.choices[0].finish_reason, "length"))
        "incomplete"
    else
        "completed";

    const now: f64 = @floatFromInt(time.timestamp());

    return .{
        .id = try allocator.dupe(u8, upstream.id),
        .object = "response",
        .created_at = now,
        .completed_at = now,
        .model = try allocator.dupe(u8, original_req.model),
        .status = top_status,
        .output = try output_items.toOwnedSlice(allocator),
        .usage = .{
            .input_tokens = if (upstream.usage) |u| u.prompt_tokens else 0,
            .output_tokens = if (upstream.usage) |u| u.completion_tokens else 0,
            .total_tokens = if (upstream.usage) |u| u.total_tokens else 0,
        },
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
        .user = original_req.user,
        .service_tier = upstream.service_tier,
        .truncation = original_req.truncation,
        .previous_response_id = original_req.previous_response_id,
        .background = original_req.background,
        .max_tool_calls = original_req.max_tool_calls,
    };
}

/// Free what transformResponsesResponse allocated.
pub fn cleanupResponsesResponse(inbound_response: Responses.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    for (inbound_response.output) |item| {
        switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |txt| allocator.free(txt.text),
                    .refusal => {},
                    .other => {},
                };
                allocator.free(m.content);
            },
            .function_call => |f| {
                allocator.free(f.id);
                allocator.free(f.name);
                allocator.free(f.arguments);
            },
            .reasoning, .web_search_call, .file_search_call, .code_interpreter_call,
            .mcp_list_tools_item, .mcp_call_item, .image_generation_call,
            .local_shell_call, .other => {},
        }
    }
    allocator.free(inbound_response.output);
}

/// One chat wire SSE line → Responses.ResponsesStreamLineResult (typed StreamEvent slice).
///
/// Chat.StreamChunk fields read: id, choices[0].delta.content,
///   choices[0].delta.tool_calls, choices[0].finish_reason,
///   usage (prompt_tokens→input_tokens, completion_tokens→output_tokens).
/// Text delta → response.output_text.delta
/// Tool-call argument deltas → response.function_call_arguments.delta (per tc)
/// finish_reason → captured into state for flushResponsesStream
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) Responses.ResponsesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    // Capture id on first sight (owned by state).
    if (state.response_id.len == 0 and parsed.value.id.len > 0) {
        state.response_id = allocator.dupe(u8, parsed.value.id) catch return .{ .skip = {} };
    }

    // Track usage (final chunk via include_usage injection).
    if (parsed.value.usage) |u| {
        state.input_tokens = u.prompt_tokens;
        state.output_tokens = u.completion_tokens;
    }

    if (parsed.value.choices.len == 0) return .{ .skip = {} };
    const choice = parsed.value.choices[0];
    const delta = choice.delta;

    // Capture finish_reason (dupe — parsed dies below).
    if (choice.finish_reason) |reason| {
        if (reason.len > 0) {
            if (state.finish_reason) |prev| allocator.free(prev);
            state.finish_reason = allocator.dupe(u8, reason) catch null;
        }
    }

    var events: std.ArrayList(Responses.StreamEvent) = .empty;
    defer events.deinit(allocator);

    // Text delta → output_text.delta (dupe — text borrows from parsed arena)
    if (delta.content) |text| {
        if (text.len > 0) {
            const owned = allocator.dupe(u8, text) catch return .{ .skip = {} };
            events.append(allocator, .{ .output_text_delta = .{
                .sequence_number = state.sequence_number,
                .item_id = state.response_id,
                .delta = owned,
            }}) catch {
                allocator.free(owned);
                return .{ .skip = {} };
            };
            state.sequence_number += 1;
        }
    }

    // Tool-call argument deltas → function_call_arguments.delta (dupe — args borrow from parsed arena)
    if (delta.tool_calls) |tcs| {
        for (tcs) |tc| {
            const args = if (tc.function) |f| f.arguments orelse "" else "";
            if (args.len == 0) continue;
            const owned = allocator.dupe(u8, args) catch continue;
            events.append(allocator, .{ .function_call_arguments_delta = .{
                .sequence_number = state.sequence_number,
                .item_id = state.response_id,
                .delta = owned,
            }}) catch {
                allocator.free(owned);
                continue;
            };
            state.sequence_number += 1;
        }
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

/// Emit the terminal Responses events after the upstream stream ends.
/// Returns null when there is nothing to flush (no finish_reason captured).
/// Returns a slice: output_item_done + response_completed/incomplete.
/// Caller serializes and frees.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "length")) "incomplete" else "completed";

    const events = allocator.alloc(Responses.StreamEvent, 2) catch return null;

    events[0] = .{ .output_item_done = .{
        .sequence_number = state.sequence_number,
        .output_index = 0,
        .item = .{ .message = .{
            .id = state.response_id,
            .type = "message",
            .role = "assistant",
            .content = &.{},
            .status = status,
        }},
    }};

    const terminal_response = Responses.Response{
        .id = state.response_id,
        .object = "response",
        .created_at = @floatFromInt(time.timestamp()),
        .model = state.original_model,
        .status = status,
        .output = &.{},
        .usage = .{
            .input_tokens = state.input_tokens,
            .output_tokens = state.output_tokens,
            .total_tokens = state.input_tokens + state.output_tokens,
        },
        .parallel_tool_calls = true,
    };

    events[1] = if (std.mem.eql(u8, status, "incomplete"))
        .{ .response_incomplete = .{
            .sequence_number = state.sequence_number + 1,
            .response = terminal_response,
        }}
    else
        .{ .response_completed = .{
            .sequence_number = state.sequence_number + 1,
            .response = terminal_response,
        }};

    return events;
}
