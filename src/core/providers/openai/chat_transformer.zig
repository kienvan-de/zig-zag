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
//! flows convert between the inbound schema and the chat wire — each written
//! locally (P11).
//!
//! Four flows, named after the *inbound* schema (P2). Every `pub` symbol is
//! defined here (P5). Conversion code lives in this file and
//! `chat_content.zig` only.

const std = @import("std");

const Chat = @import("chat_types.zig"); // chat schema (proxy + upstream wire)
const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Responses = @import("responses_types.zig"); // inbound responses schema
const common = @import("types.zig"); // shared primitives
const content = @import("chat_content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

/// Re-export from responses_types.zig so callers can use `Transformer.StreamLineResult`.
pub const StreamLineResult = Responses.StreamLineResult;

/// Chat and Messages pipelines append their own `[DONE]` sentinel; the
/// Responses pipeline does not (native Responses upstreams end silently).
pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the upstream models listing to inbound `Model` entries, prefixing ids
/// with the provider name. Unlike the anthropic/google flows, OpenAI listings
/// already carry `created` and `owned_by`, which pass through.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(common.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var models = try allocator.alloc(common.Model, response.value.data.len);
    errdefer allocator.free(models);

    for (response.value.data, 0..) |upstream_model, i| {
        models[i] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, upstream_model.id }),
            .object = "model",
            .created = upstream_model.created,
            .owned_by = try allocator.dupe(u8, upstream_model.owned_by),
        };
    }

    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — pinned pass-through
// ============================================================================

/// Stream state for the chat flow. OpenAI chunks carry their own ids and
/// model fields, so the state only pins the requested model for rewriting.
pub const ChatStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ChatStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ChatStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
    }
};

/// Inbound chat request → chat wire request, pinned to `model`. Pure
/// pass-through: every field copies from the request (which borrows the
/// inbound parse — cleanup is a no-op), except streaming requests get
/// `stream_options.include_usage = true` injected so the upstream returns
/// usage on the final chunk (required for token/cost tracking).
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Chat.Request {
    _ = allocator; // nothing allocated — all fields borrow the inbound parse

    return .{
        .model = model,
        .messages = request.messages,
        .stream = request.stream,
        .stream_options = if (request.stream orelse false)
            .{ .include_usage = true }
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
        .response_format = request.response_format,
        .stop = request.stop,
        .logit_bias = request.logit_bias,
        .logprobs = request.logprobs,
        .top_logprobs = request.top_logprobs,
        .user = request.user,
        .seed = request.seed,
        .reasoning_effort = request.reasoning_effort,
        .modalities = request.modalities,
        .audio = request.audio,
        .store = request.store,
        .metadata = request.metadata,
        .prediction = request.prediction,
        .service_tier = request.service_tier,
    };
}

/// Free what `transformChatRequest` allocated: nothing (pure pass-through).
pub fn cleanupChatRequest(
    request: Chat.Request,
    allocator: std.mem.Allocator,
) void {
    _ = request;
    _ = allocator;
}

/// Chat wire response → inbound chat response: only the model field is
/// rewritten to the requested `provider/model` string (freshly allocated,
/// freed by cleanup). Everything else passes through.
pub fn transformChatResponse(
    upstream_response: Chat.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    return .{
        .id = upstream_response.id,
        .object = upstream_response.object,
        .created = upstream_response.created,
        .model = try allocator.dupe(u8, original_req.model),
        .choices = upstream_response.choices,
        .usage = upstream_response.usage,
        .system_fingerprint = upstream_response.system_fingerprint,
        .service_tier = upstream_response.service_tier,
    };
}

/// Free what `transformChatResponse` allocated (the model string).
pub fn cleanupChatResponse(
    inbound_response: Chat.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.model);
}

/// One chat wire SSE line → chat schema SSE line as ready bytes (P4): the
/// chunk is re-emitted with the model rewritten to the requested name; the
/// id is captured into `state` on the first chunk; usage (arrives on the
/// final chunk via the include_usage injection) and finish reasons
/// accumulate into `state`; upstream errors render inline. The old round-trip
/// (serialize → parse → serialize) is gone — one parse, one emit.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        // Not a chunk — maybe an error payload; render it inline (P4).
        const bytes = content.formatChatErrorLine(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    };
    defer parsed.deinit();

    // Capture the chunk id on first sight (owned by state, freed in deinit;
    // guarded so a repeat can't leak the previous dupe).
    if (state.response_id.len == 0 and parsed.value.id.len > 0) {
        state.response_id = allocator.dupe(u8, parsed.value.id) catch return .{ .skip = {} };
    }

    // Track usage from the final chunk (include_usage injection guarantees it).
    if (parsed.value.usage) |usage| {
        state.input_tokens = @intCast(usage.prompt_tokens);
        state.output_tokens = @intCast(usage.completion_tokens);
    }

    if (parsed.value.choices.len == 0) return .{ .skip = {} };
    const choice = parsed.value.choices[0];

    if (choice.finish_reason) |reason| {
        if (reason.len > 0) {
            // Own the reason: it borrows from `parsed`, which dies below (the
            // bug #6 class — dupe with a free-previous guard).
            if (state.finish_reason) |prev| allocator.free(prev);
            state.finish_reason = allocator.dupe(u8, reason) catch null;
        }
    }

    const bytes = content.buildChatChunk(.{
        .id = state.response_id,
        .created = parsed.value.created,
        .original_model = state.original_model,
        .system_fingerprint = parsed.value.system_fingerprint,
        .service_tier = parsed.value.service_tier,
    }, choice.delta, choice.finish_reason, parsed.value.usage, allocator) orelse
        return .{ .skip = {} };
    return .{ .output = bytes };
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → chat wire
// ============================================================================

/// Stream state for the messages flow: the chat wire has no message framing,
/// so the transformer synthesizes the Anthropic SSE protocol. The closing
/// triple is emitted when the upstream `[DONE]` sentinel arrives.
pub const MessagesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    // --- messages-flow specifics ---
    /// Whether the synthetic message_start was emitted.
    sent_message_start: bool = false,
    /// Whether the synthetic content_block_start was emitted.
    sent_content_block_start: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        _ = self; // all fields are static literals or value types
    }
};

/// Inbound messages request → chat wire request, pinned to `model`.
/// System → system message first; text is duped (owned); tool_use blocks
/// become tool_calls with stringified arguments; tool_result blocks become
/// one tool message per result (emitted before the assistant message);
/// tools pass through (strict = null); tool_choice maps to the JSON shapes.
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
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = system_text }, // borrows the inbound parse
        });
    }

    for (request.messages) |msg| {
        const role: common.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
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
                    for (tool_use_blocks.items) |tc| {
                        allocator.free(tc.function.arguments);
                    }
                    tool_use_blocks.deinit(allocator);
                }

                var tool_results: std.ArrayList(struct { id: []const u8, content: ?[]const u8 }) = .empty;
                defer tool_results.deinit(allocator);

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
                        .tool_result => |tr| try tool_results.append(allocator, .{
                            .id = tr.tool_use_id,
                            .content = tr.content,
                        }),
                        .image, .document, .thinking, .redacted_thinking,
                        .server_tool_use, .web_search_tool_result, .web_fetch_tool_result,
                        .code_execution_tool_result, .bash_code_execution_tool_result,
                        .text_editor_code_execution_tool_result, .tool_search_tool_result,
                        .search_result, .container_upload => {},
                    }
                }

                // Tool results first — one tool message per result.
                for (tool_results.items) |tr| {
                    try messages.append(allocator, .{
                        .role = .tool,
                        .content = if (tr.content) |c| .{ .text = try allocator.dupe(u8, c) } else null,
                        .tool_call_id = tr.id,
                    });
                }

                // Assistant message with text + tool_calls.
                if (text_parts.items.len > 0 or tool_use_blocks.items.len > 0) {
                    const content_text: ?Chat.MessageContent = if (text_parts.items.len > 0) blk: {
                        break :blk .{ .text = try std.mem.join(allocator, "", text_parts.items) };
                    } else null;

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
                    .parameters = at.input_schema, // borrows the inbound parse
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

/// Free what `transformMessagesRequest` allocated.
pub fn cleanupMessagesRequest(
    request: Chat.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.messages) |msg| content.freeMessageOwnedText(msg, allocator);
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
    if (request.tool_choice) |tc| content.freeBuiltToolChoice(tc, allocator);
}

/// Chat wire response → inbound messages response. Content blocks own their
/// strings (dupes) and leaky-parsed argument trees — freed by
/// `cleanupMessagesResponse` via `content.freeMessageOwnedBlocks` (bug #17 fix).
pub fn transformMessagesResponse(
    upstream_response: Chat.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer {
        content.freeMessageOwnedBlocks(content_blocks.items, allocator);
        content_blocks.deinit(allocator);
    }

    var stop_reason: ?[]const u8 = null;

    if (upstream_response.choices.len > 0) {
        const choice = upstream_response.choices[0];
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
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = "" } });
    }

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, original_req.model),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = if (upstream_response.usage) |u| .{
            .input_tokens = @intCast(u.prompt_tokens),
            .output_tokens = @intCast(u.completion_tokens),
        } else .{ .input_tokens = 0, .output_tokens = 0 },
    };
}

/// Free what `transformMessagesResponse` allocated.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    content.freeMessageOwnedBlocks(inbound_response.content, allocator);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    allocator.free(inbound_response.content);
}

/// One chat wire SSE line → Anthropic-format SSE events as ready bytes,
/// synthesizing the message protocol: the first chunk emits `message_start` +
/// `content_block_start`; text deltas emit `content_block_delta`; the
/// upstream `[DONE]` sentinel emits the closing triple
/// (`content_block_stop` + `message_delta` + `message_stop`) with the
/// accumulated usage — chat streams end with `[DONE]`, not a terminal
/// carrying usage. Never-opened streams still close minimally.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    // [DONE] — the chat stream's terminal sentinel: close the synthesized
    // message. States that never opened still close as a complete message.
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (!state.sent_message_start or !state.sent_content_block_start) {
            const open = content.messagesOpen(state.original_model, allocator) orelse
                return .{ .skip = {} };
            out.appendSlice(allocator, open) catch return .{ .skip = {} };
            allocator.free(open);
            state.sent_message_start = true;
            state.sent_content_block_start = true;
        }

        const close = content.messagesClose(
            state.finish_reason orelse "end_turn",
            state.output_tokens,
            allocator,
        ) orelse return .{ .skip = {} };
        out.appendSlice(allocator, close) catch return .{ .skip = {} };
        allocator.free(close);

        return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Synthetic protocol opening, once per stream (frames from content.zig).
    if (!state.sent_message_start or !state.sent_content_block_start) {
        const open = content.messagesOpen(state.original_model, allocator) orelse
            return .{ .skip = {} };
        out.appendSlice(allocator, open) catch return .{ .skip = {} };
        allocator.free(open);
        state.sent_message_start = true;
        state.sent_content_block_start = true;
    }

    if (parsed.value.choices.len > 0) {
        const choice = parsed.value.choices[0];

        // Usage from the final chunk (include_usage injection upstream).
        if (parsed.value.usage) |usage| {
            state.input_tokens = @intCast(usage.prompt_tokens);
            state.output_tokens = @intCast(usage.completion_tokens);
        }

        if (choice.finish_reason) |reason| {
            if (reason.len > 0) {
                state.finish_reason = content.transformStopReasonToMessages(reason);
            }
        }

        // Text deltas (chat wire tool_calls stream deltas are not forwarded —
        // the messages flow only streams text, matching the old behavior).
        if (choice.delta.content) |text| {
            if (text.len > 0) {
                const delta_ev = Messages.ContentBlockDelta{
                    .type = "content_block_delta",
                    .index = 0,
                    .delta = .{ .type = "text_delta", .text = text },
                };
                out.print(
                    allocator,
                    "event: content_block_delta\ndata: {f}\n\n",
                    .{std.json.fmt(delta_ev, .{})},
                ) catch return .{ .skip = {} };
            }
        }
    }

    if (out.items.len == 0) return .{ .skip = {} };
    return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — inbound responses schema → chat wire
// ============================================================================
// Written locally per human decision (duplication over coupling, P11): this
// mirrors the reverse-direction logic in responses_transformer.zig but is
// self-contained here.

/// Stream state for the responses flow: accumulates id / terminal reason /
/// usage so `flushResponsesStream` can synthesize the closing Responses events.
pub const ResponsesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    sequence_number: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
    }
};

/// Inbound responses request → chat wire request, pinned to `model`.
/// `instructions` → system message first; input text/items → messages
/// (roles parsed from the item objects; first non-empty text part wins;
/// `tool_call_id` passthrough for tool results). Most request fields pass
/// through; `text.format` → `response_format`; `reasoning.effort` →
/// `reasoning_effort`.
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Chat.Request {
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer messages.deinit(allocator);

    if (request.instructions) |inst| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = inst }, // borrows the inbound parse
        });
    }

    switch (request.input) {
        .text => |text| try messages.append(allocator, .{
            .role = .user,
            .content = .{ .text = text },
        }),
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const role_val = item.object.get("role") orelse continue;
            if (role_val != .string) continue;
            const role = std.meta.stringToEnum(common.Role, role_val.string) orelse continue;

            const content_val = item.object.get("content");
            const message_content: ?Chat.MessageContent = blk: {
                const cv = content_val orelse break :blk null;
                switch (cv) {
                    .string => |s| break :blk .{ .text = s },
                    .array => |arr| {
                        // First non-empty text part wins; no allocation needed.
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
                .tool_call_id = if (item.object.get("tool_call_id")) |v|
                    if (v == .string) v.string else null
                else
                    null,
            });
        },
    }

    const chat_tools: ?[]const Chat.Tool = if (request.tools) |rt| blk: {
        const tools = try allocator.alloc(Chat.Tool, rt.len);
        for (rt, 0..) |t, i| tools[i] = switch (t) {
            .function => |f| .{ .type = "function", .function = f.function },
            .other => .{ .type = "function", .function = .{ .name = "", .description = null, .parameters = null, .strict = null } },
        };
        break :blk tools;
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
        .stop = request.stop,
        .response_format = if (request.text) |txt| txt.format else null,
        .reasoning_effort = if (request.reasoning) |r| blk: {
            if (r == .object) {
                const effort = r.object.get("effort") orelse break :blk null;
                if (effort == .string) break :blk effort.string;
            }
            break :blk null;
        } else null,
    };
}

/// Free what `transformResponsesRequest` allocated: only the messages slice
/// (all fields borrow the inbound parse).
pub fn cleanupResponsesRequest(
    request: Chat.Request,
    allocator: std.mem.Allocator,
) void {
    allocator.free(request.messages);
    if (request.tools) |t| allocator.free(t);
}

/// Chat wire response → inbound responses response. The message item carries
/// the text; each tool call becomes a `function_call` output item;
/// `finish_reason=length` → `incomplete`. Echo fields come from
/// `original_req` (no upstream equivalent in the chat wire).
pub fn transformResponsesResponse(
    upstream_response: Chat.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer output_items.deinit(allocator);

    if (upstream_response.choices.len > 0) {
        const choice = upstream_response.choices[0];
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

        try output_items.append(allocator, .{ .message = .{
            .id = try allocator.dupe(u8, upstream_response.id),
            .type = "message",
            .role = "assistant",
            .content = try content_parts.toOwnedSlice(allocator),
            .status = "completed",
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

        // finish_reason → status
        if (std.mem.eql(u8, choice.finish_reason, "length")) {
            // completed → incomplete: flip the just-inserted message status
            output_items.items[0].message.status = "incomplete";
        }
    } else {
        try output_items.append(allocator, .{ .message = .{
            .id = try allocator.dupe(u8, upstream_response.id),
            .type = "message",
            .role = "assistant",
            .content = try allocator.alloc(Responses.OutputContent, 0),
            .status = "completed",
        } });
    }

    // finish_reason → top-level response status (§23).
    const top_status: []const u8 = if (upstream_response.choices.len > 0 and
        std.mem.eql(u8, upstream_response.choices[0].finish_reason, "length"))
        "incomplete"
    else
        "completed";

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "response",
        .created_at = @floatFromInt(upstream_response.created),
        .model = try allocator.dupe(u8, original_req.model),
        .status = top_status,
        .output = try output_items.toOwnedSlice(allocator),
        .usage = .{
            .input_tokens = if (upstream_response.usage) |u| u.prompt_tokens else 0,
            .output_tokens = if (upstream_response.usage) |u| u.completion_tokens else 0,
            .total_tokens = if (upstream_response.usage) |u| u.total_tokens else 0,
        },
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
    };
}

/// Free what `transformResponsesResponse` allocated.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
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
            .reasoning => {},
            .other => {},
        }
    }
    allocator.free(inbound_response.output);
}

/// One chat wire SSE line → Responses SSE events as ready bytes (P4): text
/// deltas become `response.output_text.delta`, tool-call argument deltas
/// become `response.function_call_arguments.delta`, the id is captured into
/// `state` (dupe), usage is tracked, and the terminal finish reason is
/// stored for `flushResponsesStream` (which emits the closing events).
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Chat.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    // Capture the id on first sight (owned by state; guarded vs. dup leaks).
    if (state.response_id.len == 0 and parsed.value.id.len > 0) {
        state.response_id = allocator.dupe(u8, parsed.value.id) catch return .{ .skip = {} };
    }

    // Track usage (final chunk, via the include_usage injection).
    if (parsed.value.usage) |usage| {
        state.input_tokens = @intCast(usage.prompt_tokens);
        state.output_tokens = @intCast(usage.completion_tokens);
    }

    if (parsed.value.choices.len == 0) return .{ .skip = {} };
    const choice = parsed.value.choices[0];
    const delta = choice.delta;

    // Terminal reason FIRST (a chunk may carry both a delta and its terminal
    // reason — bug #20: the old code returned on the delta and lost it).
    if (choice.finish_reason) |reason| {
        if (reason.len > 0) {
            if (state.finish_reason) |prev| allocator.free(prev);
            state.finish_reason = allocator.dupe(u8, reason) catch null;
        }
    }

    // Text delta → response.output_text.delta
    if (delta.content) |text| {
        if (text.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            const ev = Responses.StreamEvent{ .output_text_delta = .{
                .sequence_number = state.sequence_number,
                .item_id = state.response_id,
                .delta = text,
            }};
            ev.writeSSE(&buf, allocator) catch return .{ .skip = {} };
            state.sequence_number += 1;
            return .{ .output = buf.toOwnedSlice(allocator) catch return .{ .skip = {} } };
        }
    }

    // Tool-call argument deltas → response.function_call_arguments.delta.
    // Loop over all entries so parallel tool calls are fully forwarded.
    if (delta.tool_calls) |tcs| {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (tcs) |tc| {
            const args = if (tc.function) |f| (f.arguments orelse "") else "";
            if (args.len == 0) continue;
            const ev = Responses.StreamEvent{ .function_call_arguments_delta = .{
                .sequence_number = state.sequence_number,
                .item_id = state.response_id,
                .delta = args,
            }};
            ev.writeSSE(&buf, allocator) catch continue;
            state.sequence_number += 1;
        }
        if (buf.items.len > 0) {
            const owned = buf.toOwnedSlice(allocator) catch {
                buf.deinit(allocator);
                return .{ .skip = {} };
            };
            return .{ .output = owned };
        }
        buf.deinit(allocator);
    }

    return .{ .skip = {} };
}

/// Emit the terminal Responses events after the upstream stream ends
/// (`response.output_item.done` + `response.completed`, or
/// `response.incomplete` when the finish reason is `length`) with the usage
/// accumulated in `state`. Returns `null` when there is nothing to flush.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "length")) "incomplete" else "completed";
    const input_tok = state.input_tokens;
    const output_tok = state.output_tokens;

    var buf: std.ArrayList(u8) = .empty;
    const item_done = Responses.StreamEvent{ .output_item_done = .{
        .sequence_number = state.sequence_number,
        .item = .{ .message = .{ .id = state.response_id, .type = "message", .role = "assistant", .content = &.{}, .status = status } },
    }};
    item_done.writeSSE(&buf, allocator) catch return null;
    state.sequence_number += 1;
    const completed_ev = if (std.mem.eql(u8, status, "incomplete"))
        Responses.StreamEvent{ .response_incomplete = .{
            .sequence_number = state.sequence_number,
            .response = .{ .id = state.response_id, .model = state.original_model, .status = status, .output = &.{}, .usage = .{
                .input_tokens = input_tok,
                .output_tokens = output_tok,
                .total_tokens = input_tok + output_tok,
            }},
        }}
    else
        Responses.StreamEvent{ .response_completed = .{
            .sequence_number = state.sequence_number,
            .response = .{ .id = state.response_id, .model = state.original_model, .status = status, .output = &.{}, .usage = .{
                .input_tokens = input_tok,
                .output_tokens = output_tok,
                .total_tokens = input_tok + output_tok,
            }},
        }};
    completed_ev.writeSSE(&buf, allocator) catch { buf.deinit(allocator); return null; };
    return buf.toOwnedSlice(allocator) catch null;
}
