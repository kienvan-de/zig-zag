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

//! Transformer for the openai provider's native Responses API face: the
//! upstream speaks the Responses API wire; each inbound flow (chat, messages,
//! responses) is bridged onto it. Conversion is local (P11) — the helper
//! library that other providers used to call is being retired (sap_ai_core
//! now bridges locally).
//!
//! Four flows, named after the *inbound* schema (P2). Every `pub` symbol is
//! defined here (P5).

const std = @import("std");

const Chat = @import("chat_types.zig"); // chat schema
const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Responses = @import("responses_types.zig"); // Responses API wire types
const content = @import("responses_content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

/// Result of transforming one upstream SSE line (P4): already-formatted bytes
/// the pipeline writes verbatim, or nothing. Owned by the caller when `.output`.
pub const StreamLineResult = union(enum) {
    output: []const u8,
    skip: void,
};

/// The chat and messages faces must synthesize their own closing frames — the
/// Responses wire has no `[DONE]` sentinel, so the pipeline must not append
/// one. The native responses face forwards upstream events verbatim.
pub const appendsDoneMarker = false;

/// The subset of Responses SSE event payloads the transformer inspects
/// (shared by the chat and messages stream faces).
const ResponsesEventData = struct {
    type: []const u8 = "",
    /// response.output_text.delta
    delta: ?[]const u8 = null,
    /// response.function_call_arguments.delta
    arguments: ?[]const u8 = null,
    item_id: []const u8 = "",
    /// response.failed / error payloads
    @"error": ?std.json.Value = null,
    /// response.completed / response.incomplete: nested response object
    response: ?struct {
        usage: Responses.Usage = .{},
        /// response.incomplete: nested incomplete_details.reason
        incomplete_details: ?struct {
            reason: []const u8 = "",
        } = null,
    } = null,
};

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the upstream models listing to inbound `Model` entries, prefixing ids
/// with the provider name. OpenAI listings carry `created`/`owned_by`, which
/// pass through (identical to the chat transformer's face).
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Chat.ModelsResponse),
    provider_name: []const u8,
) ![]Chat.Model {
    var models = try allocator.alloc(Chat.Model, response.value.data.len);
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
// Flow: /v1/chat/completions — chat wire in, Responses wire out
// ============================================================================

/// Stream state for the chat face. The Responses terminal events
/// (`response.completed` / `response.incomplete`) arrive as ordinary lines
/// and emit the final chat chunk inline — the chat pipeline has no post-loop
/// flush hook and appends `[DONE]` itself.
pub const ChatStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    // --- chat-flow specifics ---
    created: i64,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ChatStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            .created = time.timestamp(),
        };
    }

    pub fn deinit(self: *ChatStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
    }
};

/// Inbound chat request → Responses wire request, pinned to `model`.
/// system/developer messages become `instructions` (joined with blank lines);
/// every other message is serialized into `input[]`; `response_format` →
/// `text.format`; `reasoning_effort` → `reasoning.effort`.
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Responses.Request {
    var instructions_parts: std.ArrayList([]const u8) = .empty;
    defer instructions_parts.deinit(allocator);

    var input_items: std.ArrayList(std.json.Value) = .empty;
    errdefer {
        for (input_items.items) |item| content.freeInputItem(item, allocator);
        input_items.deinit(allocator);
    }

    for (request.messages) |msg| {
        if (msg.role == .system or msg.role == .developer) {
            if (msg.content) |c| switch (c) {
                .text => |t| if (t.len > 0) try instructions_parts.append(allocator, t),
                .parts => {},
            };
            continue;
        }
        try input_items.append(allocator, try content.chatMessageToInputItem(msg, allocator));
    }

    const instructions: ?[]const u8 = if (instructions_parts.items.len > 0)
        try std.mem.join(allocator, "\n\n", instructions_parts.items)
    else
        null;
    errdefer if (instructions) |s| allocator.free(s);

    const input: Responses.InputParam = if (input_items.items.len > 0)
        .{ .items = try input_items.toOwnedSlice(allocator) }
    else
        .{ .text = "" };

    return .{
        .model = model,
        .input = input,
        .instructions = instructions,
        .stream = request.stream,
        .tools = request.tools,
        .tool_choice = request.tool_choice,
        .parallel_tool_calls = request.parallel_tool_calls,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_logprobs = request.top_logprobs,
        .store = request.store,
        .metadata = request.metadata,
        .moderation = request.moderation,
        .safety_identifier = request.safety_identifier,
        .prompt_cache_key = request.prompt_cache_key,
        .prompt_cache_options = request.prompt_cache_options,
        .user = request.user,
        .service_tier = request.service_tier,
        .max_output_tokens = request.max_completion_tokens orelse request.max_tokens,
        .text = if (request.response_format) |rf| .{ .format = rf } else null,
        .reasoning = if (request.reasoning_effort) |re| blk: {
            var obj: std.json.ObjectMap = .{};
            try obj.put(allocator, "effort", .{ .string = re });
            break :blk std.json.Value{ .object = try obj.clone(allocator) };
        } else null,
        .truncation = null,
        .background = null,
        .max_tool_calls = null,
        .conversation = null,
        .context_management = null,
        .include = null,
        .previous_response_id = null,
    };
}

/// Free what `transformChatRequest` allocated.
pub fn cleanupChatRequest(
    request: Responses.Request,
    allocator: std.mem.Allocator,
) void {
    if (request.instructions) |s| allocator.free(s);
    switch (request.input) {
        .items => |items| {
            for (items) |item| content.freeInputItem(item, allocator);
            allocator.free(items);
        },
        .text => {},
    }
    if (request.reasoning) |r| {
        var obj = r.object;
        obj.deinit(allocator);
    }
}

/// Responses wire response → inbound chat response. Text parts join; each
/// function_call becomes a tool call; `status=incomplete` → `length`.
pub fn transformChatResponse(
    upstream_response: Responses.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    _ = original_req; // the Responses wire echoes the requested model already

    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var tool_calls: std.ArrayList(Chat.ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            if (tc == .function) {
                allocator.free(tc.function.id);
                allocator.free(tc.function.function.name);
                allocator.free(tc.function.function.arguments);
            }
        }
        tool_calls.deinit(allocator);
    }

    for (upstream_response.output) |item| {
        switch (item) {
            .message => |m| {
                for (m.content) |c| {
                    switch (c) {
                        .output_text => |t| try text_parts.append(allocator, t.text),
                        .refusal, .other => {},
                    }
                }
            },
            .function_call => |f| try tool_calls.append(allocator, .{ .function = .{
                .id = try allocator.dupe(u8, f.id),
                .type = "function",
                .function = .{
                    .name = try allocator.dupe(u8, f.name),
                    .arguments = try allocator.dupe(u8, f.arguments),
                },
            } }),
            .reasoning, .other => {},
        }
    }

    const message_text: ?[]const u8 = if (text_parts.items.len > 0)
        try std.mem.join(allocator, "", text_parts.items)
    else
        null;
    errdefer if (message_text) |t| allocator.free(t);

    const tc_slice: ?[]const Chat.ToolCall = if (tool_calls.items.len > 0)
        try tool_calls.toOwnedSlice(allocator)
    else
        null;
    errdefer if (tc_slice) |tcs| content.freeChatToolCallList(tcs, allocator);

    const finish_reason: []const u8 = if (std.mem.eql(u8, upstream_response.status, "incomplete"))
        "length"
    else if (tc_slice != null)
        "tool_calls"
    else
        "stop";

    const choices = try allocator.alloc(Chat.ResponseChoice, 1);
    errdefer allocator.free(choices);
    choices[0] = .{
        .index = 0,
        .message = .{
            .role = .assistant,
            .content = message_text,
            .tool_calls = tc_slice,
        },
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .logprobs = null,
    };

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "chat.completion",
        .created = @intFromFloat(upstream_response.created_at),
        .model = try allocator.dupe(u8, upstream_response.model),
        .choices = choices,
        .usage = .{
            .prompt_tokens = upstream_response.usage.input_tokens,
            .completion_tokens = upstream_response.usage.output_tokens,
            .total_tokens = upstream_response.usage.total_tokens,
        },
        .service_tier = upstream_response.service_tier,
    };
}

/// Free what `transformChatResponse` allocated.
pub fn cleanupChatResponse(
    inbound_response: Chat.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    for (inbound_response.choices) |choice| {
        if (choice.message.content) |c| allocator.free(c);
        if (choice.message.tool_calls) |tcs| content.freeChatToolCallList(tcs, allocator);
        allocator.free(choice.finish_reason);
    }
    allocator.free(inbound_response.choices);
}

/// One Responses SSE line → zero or one chat-format SSE chunk as ready bytes
/// (P4). Terminal events (`response.completed`/`response.incomplete`) emit
/// the final chunk with finish_reason + usage inline — the chat pipeline has
/// no post-loop flush hook; `response.failed` renders as chat error bytes.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        ResponsesEventData,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const event = parsed.value;

    // Own the id: it borrows from `parsed`, which dies below (bug #18 class).
    if (state.response_id.len == 0 and event.item_id.len > 0) {
        state.response_id = state.allocator.dupe(u8, event.item_id) catch
            return .{ .skip = {} };
    }

    const ctx = content.ChatChunkContext{
        .id = state.response_id,
        .created = state.created,
        .original_model = state.original_model,
    };

    if (std.mem.eql(u8, event.type, "response.output_text.delta")) {
        const text = event.delta orelse return .{ .skip = {} };
        if (text.len == 0) return .{ .skip = {} };
        const bytes = content.buildChatChunk(ctx, .{ .content = text }, null, null, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event.type, "response.function_call_arguments.delta")) {
        const args = event.arguments orelse return .{ .skip = {} };
        if (args.len == 0) return .{ .skip = {} };
        const tcs = [_]Chat.DeltaToolCall{.{ .index = 0, .function = .{ .arguments = args } }};
        const bytes = content.buildChatChunk(ctx, .{ .tool_calls = &tcs }, null, null, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event.type, "response.failed")) {
        const bytes = content.formatFailedEvent(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event.type, "response.incomplete")) {
        const reason: []const u8 = if (event.response) |r|
            (if (r.incomplete_details) |d| d.reason else "")
        else
            "";
        // Static literal from a small mapping — safe without duping.
        state.finish_reason = if (std.mem.eql(u8, reason, "max_output_tokens")) "length" else "stop";
        if (event.response) |r| {
            state.input_tokens = r.usage.input_tokens;
            state.output_tokens = r.usage.output_tokens;
        }
        // Terminal event: the final chunk carries finish_reason + usage (the
        // chat pipeline has no flush hook; it appends [DONE] itself).
        const bytes = content.buildChatChunk(
            ctx,
            .{},
            state.finish_reason,
            .{
                .prompt_tokens = state.input_tokens,
                .completion_tokens = state.output_tokens,
                .total_tokens = state.input_tokens + state.output_tokens,
            },
            allocator,
        ) orelse return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event.type, "response.completed")) {
        if (event.response) |r| {
            state.input_tokens = r.usage.input_tokens;
            state.output_tokens = r.usage.output_tokens;
        }
        state.finish_reason = "stop";
        const bytes = content.buildChatChunk(
            ctx,
            .{},
            "stop",
            .{
                .prompt_tokens = state.input_tokens,
                .completion_tokens = state.output_tokens,
                .total_tokens = state.input_tokens + state.output_tokens,
            },
            allocator,
        ) orelse return .{ .skip = {} };
        return .{ .output = bytes };
    }

    return .{ .skip = {} };
}

// ============================================================================
// Flow: /v1/messages — messages wire in, Responses wire out
// ============================================================================

/// Stream state for the messages face: the Responses wire has no message
/// framing, so the transformer synthesizes the Anthropic SSE protocol lazily
/// on the first text delta; `response.completed` emits the closing triple.
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

/// Inbound messages request → Responses wire request, pinned to `model`.
/// Text-first conversion: input text/items become messages with plain text
/// content (first non-empty part wins); `instructions` → the Responses
/// `instructions` field; `max_output_tokens` defaults to 4096.
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Responses.Request {
    var input_items: std.ArrayList(std.json.Value) = .empty;
    errdefer {
        for (input_items.items) |item| content.freeInputItem(item, allocator);
        input_items.deinit(allocator);
    }

    // Messages.Request.messages → input items (roles user/assistant).
    for (request.messages) |msg| {
        const role_str: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
        };

        const text: []const u8 = switch (msg.content) {
            .text => |t| t,
            .blocks => |blocks| blk: {
                for (blocks) |block| {
                    switch (block) {
                        .text => |tb| break :blk tb.text,
                        else => {},
                    }
                }
                break :blk "";
            },
        };
        if (text.len == 0) continue;

        var obj: std.json.ObjectMap = .{};
        errdefer obj.deinit(allocator);
        // All strings are duped so `freeInputItem` can free the tree uniformly
        // (keys via the map entry pass, values via the string branch).
        try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role_str) });
        try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, text) });
        try input_items.append(allocator, .{ .object = obj });
    }

    return .{
        .model = model,
        .input = .{ .items = try input_items.toOwnedSlice(allocator) },
        .instructions = request.system,
        .stream = request.stream,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .max_output_tokens = request.max_tokens, // non-optional on Messages.Request
        .thinking = request.thinking,
        .betas = request.betas,
        .service_tier = request.service_tier,
        .truncation = null,
        .background = null,
        .max_tool_calls = null,
        .conversation = null,
        .context_management = null,
        .include = null,
        .previous_response_id = null,
        .tools = null,
        .tool_choice = null,
        .parallel_tool_calls = null,
        .top_logprobs = null,
        .store = null,
        .metadata = null,
        .moderation = null,
        .safety_identifier = null,
        .prompt_cache_key = null,
        .prompt_cache_options = null,
        .user = null,
        .text = null,
        .reasoning = null,
    };
}

/// Free what `transformMessagesRequest` allocated: the input item trees
/// (role/content keys are dupes) and the items slice.
pub fn cleanupMessagesRequest(
    request: Responses.Request,
    allocator: std.mem.Allocator,
) void {
    switch (request.input) {
        .items => |items| {
            for (items) |item| content.freeInputItem(item, allocator);
            allocator.free(items);
        },
        .text => {},
    }
}

/// Responses wire response → inbound messages response (direct, no chat hop).
pub fn transformMessagesResponse(
    upstream_response: Responses.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer {
        content.freeMessageOwnedBlocks(content_blocks.items, allocator);
        content_blocks.deinit(allocator);
    }

    for (upstream_response.output) |item| {
        switch (item) {
            .message => |m| {
                for (m.content) |c| {
                    switch (c) {
                        .output_text => |t| {
                            if (t.text.len > 0) {
                                try content_blocks.append(allocator, .{ .text = .{
                                    .type = "text",
                                    .text = try allocator.dupe(u8, t.text),
                                } });
                            }
                        },
                        .refusal, .other => {},
                    }
                }
            },
            .function_call => |f| {
                // BUG #22 fix: leaky parse (freed by freeMessageOwnedBlocks)
                // instead of the arena parse whose tree dangled after cleanup.
                try content_blocks.append(allocator, .{ .tool_use = .{
                    .type = "tool_use",
                    .id = try allocator.dupe(u8, f.id),
                    .name = try allocator.dupe(u8, f.name),
                    .input = try content.parseToolArguments(f.arguments, allocator),
                } });
            },
            .reasoning, .other => {},
        }
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = "" } });
    }

    // status → stop_reason
    const stop_reason: ?[]const u8 = if (std.mem.eql(u8, upstream_response.status, "incomplete"))
        "max_tokens"
    else if (std.mem.eql(u8, upstream_response.status, "failed"))
        "refusal"
    else
        "end_turn";

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, original_req.model),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = .{
            .input_tokens = upstream_response.usage.input_tokens,
            .output_tokens = upstream_response.usage.output_tokens,
        },
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

/// One Responses SSE line → Anthropic-format SSE events as ready bytes.
/// The first text delta lazily emits the protocol opening;
/// `response.completed` emits the closing triple (the Responses wire has no
/// `[DONE]`, so the terminal event must close the message itself). A stream
/// that ends without any delta still closes as a complete minimal message.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        ResponsesEventData,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const event = parsed.value;

    // Terminal event: capture usage and close the message (no [DONE] upstream).
    if (std.mem.eql(u8, event.type, "response.completed") or
        std.mem.eql(u8, event.type, "response.incomplete"))
    {
        if (event.response) |r| {
            state.input_tokens = r.usage.input_tokens;
            state.output_tokens = r.usage.output_tokens;
        }
        if (std.mem.eql(u8, event.type, "response.incomplete")) {
            state.finish_reason = "max_tokens";
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // Lazy open: a stream that never emitted a delta still closes complete.
        if (!state.sent_message_start or !state.sent_content_block_start) {
            const open = content.messagesOpen(state.original_model, state.input_tokens, allocator) orelse
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

    if (std.mem.eql(u8, event.type, "response.output_text.delta")) {
        const text = event.delta orelse return .{ .skip = {} };
        if (text.len == 0) return .{ .skip = {} };

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        // Lazy protocol opening (carries the input tokens we know so far).
        if (!state.sent_message_start or !state.sent_content_block_start) {
            const open = content.messagesOpen(state.original_model, state.input_tokens, allocator) orelse
                return .{ .skip = {} };
            out.appendSlice(allocator, open) catch return .{ .skip = {} };
            allocator.free(open);
            state.sent_message_start = true;
            state.sent_content_block_start = true;
        }

        out.print(
            allocator,
            "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n",
            .{std.json.fmt(text, .{})},
        ) catch return .{ .skip = {} };

        return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    return .{ .skip = {} };
}

// ============================================================================
// Flow: /v1/responses — pass-through (upstream speaks the same wire)
// ============================================================================

/// Inbound responses request → Responses wire request: pin the model only.
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Responses.Request {
    _ = allocator;
    var req = request;
    req.model = model;
    return req;
}

/// No-op: the request is owned (and cleaned up) by the caller.
pub fn cleanupResponsesRequest(
    request: Responses.Request,
    allocator: std.mem.Allocator,
) void {
    _ = request;
    _ = allocator;
}

/// Pass the upstream response through unchanged. The returned value borrows
/// the caller's parsed arena — cleanup is a no-op.
pub fn transformResponsesResponse(
    upstream_response: Responses.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    _ = original_req;
    _ = allocator;
    return upstream_response;
}

/// No-op: all memory belongs to the client response's parsed arena.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
    _ = inbound_response;
    _ = allocator;
}

/// Stream state for the pass-through: captures usage from the terminal
/// `response.completed` / `response.incomplete` events so the pipeline can
/// record tokens.
pub const ResponsesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        _ = self; // no owned memory (usage capture only)
    }
};

/// The subset of stream event payloads the pass-through inspects.
const NativeStreamEvent = struct {
    type: []const u8 = "",
    response: ?struct { usage: Responses.Usage = .{} } = null,
};

/// Pass each SSE line through verbatim, re-terminated with a blank line,
/// capturing usage from terminal events. Lines are forwarded unfiltered —
/// including `event:` and blank lines — so the client sees exactly the
/// upstream byte stream.
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (std.mem.startsWith(u8, line, "data: ")) {
        const json_part = line["data: ".len..];
        if (std.json.parseFromSlice(
            NativeStreamEvent,
            allocator,
            json_part,
            .{ .ignore_unknown_fields = true },
        )) |parsed| {
            defer parsed.deinit();
            const event = parsed.value;
            if (std.mem.eql(u8, event.type, "response.completed") or
                std.mem.eql(u8, event.type, "response.incomplete"))
            {
                if (event.response) |r| {
                    state.input_tokens = r.usage.input_tokens;
                    state.output_tokens = r.usage.output_tokens;
                }
            }
        } else |_| {}
    }
    const bytes = std.fmt.allocPrint(allocator, "{s}\n\n", .{line}) catch
        return .{ .skip = {} };
    return .{ .output = bytes };
}

/// Nothing to flush — pass-through events are emitted as they arrive.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    _ = state;
    _ = allocator;
    return null;
}
