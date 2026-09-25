// SPDX-License-Identifier: Apache-2.0
//! Transformer for the openai provider's native Responses API face.
//! The upstream speaks the Responses API wire. Each inbound flow (chat,
//! messages, responses) is bridged onto it.
//!
//! Four flows, named after the *inbound* schema. Every pub symbol is defined
//! here. Conversion helpers live in responses_content.zig only.
//! Stream functions return typed event slices — callers own serialization.

const std = @import("std");

const Chat = @import("chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Responses = @import("responses_types.zig");
const common = @import("types.zig");
const content = @import("responses_content.zig");
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

pub const appendsDoneMarker = false;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Convert an OpenAI error response to OpenAI error format (for /v1/chat/completions and /v1/responses).
/// Pass-through — already in the right format.
pub fn transformToOpenAIError(err: common.ErrorResponse) common.ErrorResponse {
    return err;
}

/// Convert an OpenAI error response to Anthropic error format (for /v1/messages).
pub fn transformToMessagesError(err: common.ErrorResponse) Messages.ErrorResponse {
    return .{ .@"error" = .{
        .type = err.@"error".type,
        .message = err.@"error".message,
    } };
}

/// Map the upstream models listing to inbound Model entries, prefixing ids
/// with the provider name.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(common.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var models = try allocator.alloc(common.Model, response.value.data.len);
    var filled: usize = 0;
    errdefer {
        for (models[0..filled]) |m| {
            allocator.free(m.id);
            allocator.free(m.owned_by);
        }
        allocator.free(models);
    }
    for (response.value.data, 0..) |m, i| {
        models[i] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, m.id }),
            .object = "model",
            .created = m.created,
            .owned_by = try allocator.dupe(u8, m.owned_by),
        };
        filled += 1;
    }
    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — Chat wire in, Responses wire out
// ============================================================================

pub const ChatStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
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

/// Chat wire request → Responses wire request, pinned to model.
///
/// Chat.Request fields mapped:
///   model (pinned), system/developer messages → instructions (joined "\n\n"),
///   remaining messages → input[] (serialized via chatMessageToInputItem),
///   stream, tools (.function → Responses.Tool.function; built-in types skipped),
///   tool_choice, parallel_tool_calls, temperature, top_p, top_logprobs,
///   store, metadata, user, service_tier,
///   max_completion_tokens / max_tokens → max_output_tokens,
///   response_format → text.format,
///   reasoning_effort → reasoning.effort.
/// Skipped: stream_options (injected by upstream, not passed through), n,
///   presence_penalty, frequency_penalty, stop, logit_bias, logprobs, seed,
///   modalities, audio, prediction, web_search_options, moderation, verbosity
///   (chat-only or no Responses.Request equivalent).
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
    errdefer switch (input) {
        .items => |items| {
            for (items) |item| content.freeInputItem(item, allocator);
            allocator.free(items);
        },
        .text => {},
    };

    const tools: ?[]const Responses.Tool = if (request.tools) |chat_tools| blk: {
        const rt = try allocator.alloc(Responses.Tool, chat_tools.len);
        for (chat_tools, 0..) |t, i| rt[i] = .{ .function = .{ .function = t.function } };
        break :blk rt;
    } else null;
    errdefer if (tools) |ts| allocator.free(ts);

    return .{
        .model = model,
        .input = input,
        .instructions = instructions,
        .stream = request.stream,
        .tools = tools,
        .tool_choice = request.tool_choice,
        .parallel_tool_calls = request.parallel_tool_calls,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_logprobs = request.top_logprobs,
        .store = request.store,
        .metadata = request.metadata,
        .user = request.user,
        .service_tier = request.service_tier,
        .max_output_tokens = request.max_completion_tokens orelse request.max_tokens,
        .text = if (request.response_format) |rf| .{ .format = rf } else null,
        .reasoning = if (request.reasoning_effort) |re| blk: {
            var obj: std.json.ObjectMap = .{};
            errdefer obj.deinit(allocator);
            try obj.put(allocator, "effort", .{ .string = re });
            break :blk std.json.Value{ .object = obj };
        } else null,
        .stream_options = null,
        .previous_response_id = null,
        .reasoning_effort = null,
        .include = null,
        .truncation = null,
        .background = null,
        .max_tool_calls = null,
        .conversation = null,
        .context_management = null,
        .moderation = null,
        .safety_identifier = null,
        .prompt_cache_key = null,
        .prompt_cache_options = null,
        .prompt = null,
        .verbosity = null,
    };
}

/// Free what transformChatRequest allocated.
pub fn cleanupChatRequest(request: Responses.Request, allocator: std.mem.Allocator) void {
    if (request.instructions) |s| allocator.free(s);
    switch (request.input) {
        .items => |items| {
            for (items) |item| content.freeInputItem(item, allocator);
            allocator.free(items);
        },
        .text => {},
    }
    if (request.tools) |ts| allocator.free(ts);
    if (request.reasoning) |r| {
        var obj = r.object;
        obj.deinit(allocator);
    }
}

/// Responses wire response → inbound chat response.
///
/// Responses.Response fields mapped:
///   output[].message.content[output_text].text → joined message text (duped)
///   output[].function_call → tool_calls (id/name/arguments duped)
///   status="incomplete" → finish_reason="length"
///   function_call present → finish_reason="tool_calls"; otherwise "stop"
///   id → id (duped), created_at → created, model (duped from original_req)
///   usage.input_tokens → prompt_tokens, usage.output_tokens → completion_tokens
///   service_tier passed through
/// Skipped: object, completed_at, output_text, incomplete_details, error,
///   output[].reasoning/web_search_call/etc., temperature, top_p, top_logprobs,
///   moderation, metadata, instructions, tool_choice, tools, store, background,
///   max_output_tokens, max_tool_calls, parallel_tool_calls, truncation,
///   previous_response_id, conversation, safety_identifier, prompt_cache_key,
///   prompt_cache_options, prompt_cache_diagnostics, prompt, text, user
///   (no Chat.Response equivalent).
pub fn transformChatResponse(
    upstream_response: Responses.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var tool_calls: std.ArrayList(Chat.ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.function.name);
            allocator.free(tc.function.arguments);
        }
        tool_calls.deinit(allocator);
    }

    var reasoning_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (reasoning_parts.items) |p| allocator.free(p);
        reasoning_parts.deinit(allocator);
    }

    for (upstream_response.output) |item| {
        switch (item) {
            .message => |m| for (m.content) |c| switch (c) {
                .output_text => |t| try text_parts.append(allocator, t.text),
                // refusal/other have no Chat message-content equivalent.
                .refusal, .other => log.debug("[chat] dropping Responses output content {s}: no Chat equivalent", .{@tagName(c)}),
            },
            .function_call => |f| try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, f.id),
                .type = "function",
                .function = .{
                    .name = try allocator.dupe(u8, f.name),
                    .arguments = try allocator.dupe(u8, f.arguments),
                },
            }),
            // Reasoning → Chat `reasoning` field (joined across items).
            .reasoning => |r| if (try content.extractReasoningText(r, allocator)) |txt| {
                try reasoning_parts.append(allocator, txt);
            },
            // No Chat equivalent — dropped, logged.
            .web_search_call, .file_search_call, .code_interpreter_call,
            .mcp_list_tools_item, .mcp_call_item, .image_generation_call,
            .local_shell_call, .other => log.debug("[chat] dropping Responses output item {s}: no Chat equivalent", .{@tagName(item)}),
        }
    }

    const message_text: ?[]const u8 = if (text_parts.items.len > 0)
        try std.mem.join(allocator, "", text_parts.items)
    else
        null;
    errdefer if (message_text) |t| allocator.free(t);

    const reasoning_text: ?[]const u8 = if (reasoning_parts.items.len > 0)
        try std.mem.join(allocator, "", reasoning_parts.items)
    else
        null;
    errdefer if (reasoning_text) |t| allocator.free(t);

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
            .reasoning = reasoning_text,
            .tool_calls = tc_slice,
        },
        .finish_reason = try allocator.dupe(u8, finish_reason),
        .logprobs = null,
    };

    const owned_id = try allocator.dupe(u8, upstream_response.id);
    errdefer allocator.free(owned_id);
    const owned_model = try allocator.dupe(u8, original_req.model);

    return .{
        .id = owned_id,
        .object = "chat.completion",
        .created = @intFromFloat(upstream_response.created_at),
        .model = owned_model,
        .choices = choices,
        .usage = if (upstream_response.usage) |u| .{
            .prompt_tokens = u.input_tokens,
            .completion_tokens = u.output_tokens,
            .total_tokens = u.total_tokens,
            .prompt_tokens_details = if (u.input_tokens_details) |d|
                if (d.cached_tokens > 0 or d.cache_write_tokens > 0) .{
                    .cached_tokens = d.cached_tokens,
                    .cache_write_tokens = d.cache_write_tokens,
                } else null
            else null,
        } else null,
        .service_tier = upstream_response.service_tier,
    };
}

/// Free what transformChatResponse allocated.
pub fn cleanupChatResponse(inbound_response: Chat.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    for (inbound_response.choices) |choice| {
        if (choice.message.content) |c| allocator.free(c);
        if (choice.message.reasoning) |r| allocator.free(r);
        if (choice.message.tool_calls) |tcs| content.freeChatToolCallList(tcs, allocator);
        allocator.free(choice.finish_reason);
    }
    allocator.free(inbound_response.choices);
}

/// One Responses SSE line → Chat.ChatStreamLineResult (typed StreamChunk slice).
///
/// Responses events handled (parsed as std.json.Value, type field dispatched):
///   response.output_text.delta → text delta StreamChunk
///   response.function_call_arguments.delta → tool_calls delta StreamChunk
///   response.completed → final StreamChunk (finish_reason="stop", usage)
///   response.incomplete → final StreamChunk (finish_reason="length", usage)
///   All other events → skip
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) Chat.ChatStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .skip = {} };
    const obj = parsed.value.object;

    const event_type = if (obj.get("type")) |t| (if (t == .string) t.string else return .{ .skip = {} }) else return .{ .skip = {} };

    // Capture item_id into state on first sight (owns the dupe).
    if (state.response_id.len == 0) {
        if (obj.get("item_id")) |id_v| {
            if (id_v == .string and id_v.string.len > 0) {
                if (state.allocator.dupe(u8, id_v.string)) |duped| {
                                state.response_id = duped;
                            } else |_| {}
            }
        }
    }

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        const delta_v = obj.get("delta") orelse return .{ .skip = {} };
        if (delta_v != .string or delta_v.string.len == 0) return .{ .skip = {} };
        const owned = allocator.dupe(u8, delta_v.string) catch return .{ .skip = {} };
        const choices = allocator.alloc(Chat.StreamChoice, 1) catch {
            allocator.free(owned);
            return .{ .skip = {} };
        };
        choices[0] = .{ .index = 0, .delta = .{ .content = owned }, .finish_reason = null };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch {
            allocator.free(owned);
            allocator.free(choices);
            return .{ .skip = {} };
        };
        chunks[0] = .{
            .id = state.response_id,
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_text.delta") or
        std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta"))
    {
        // Reasoning delta → Chat delta carrying `reasoning` (not `content`).
        const delta_v = obj.get("delta") orelse return .{ .skip = {} };
        if (delta_v != .string or delta_v.string.len == 0) return .{ .skip = {} };
        const owned = allocator.dupe(u8, delta_v.string) catch return .{ .skip = {} };
        const choices = allocator.alloc(Chat.StreamChoice, 1) catch {
            allocator.free(owned);
            return .{ .skip = {} };
        };
        choices[0] = .{ .index = 0, .delta = .{ .reasoning = owned }, .finish_reason = null };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch {
            allocator.free(owned);
            allocator.free(choices);
            return .{ .skip = {} };
        };
        chunks[0] = .{
            .id = state.response_id,
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta_v = obj.get("delta") orelse return .{ .skip = {} };
        if (delta_v != .string or delta_v.string.len == 0) return .{ .skip = {} };
        const owned_args = allocator.dupe(u8, delta_v.string) catch return .{ .skip = {} };
        const tcs = allocator.alloc(Chat.DeltaToolCall, 1) catch {
            allocator.free(owned_args);
            return .{ .skip = {} };
        };
        tcs[0] = .{ .index = 0, .function = .{ .arguments = owned_args } };
        const choices = allocator.alloc(Chat.StreamChoice, 1) catch {
            allocator.free(owned_args);
            allocator.free(tcs);
            return .{ .skip = {} };
        };
        choices[0] = .{ .index = 0, .delta = .{ .tool_calls = tcs }, .finish_reason = null };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch {
            allocator.free(owned_args);
            allocator.free(tcs);
            allocator.free(choices);
            return .{ .skip = {} };
        };
        chunks[0] = .{
            .id = state.response_id,
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        if (obj.get("response")) |resp_v| {
            if (resp_v == .object) {
                if (resp_v.object.get("usage")) |usage_v| {
                    if (usage_v == .object) {
                        if (usage_v.object.get("input_tokens")) |it| {
                            if (it == .integer) state.input_tokens = @intCast(it.integer);
                        }
                        if (usage_v.object.get("output_tokens")) |ot| {
                            if (ot == .integer) state.output_tokens = @intCast(ot.integer);
                        }
                        if (usage_v.object.get("input_tokens_details")) |dtl| {
                            if (dtl == .object) {
                                if (dtl.object.get("cached_tokens")) |ct| {
                                    if (ct == .integer) state.cache_read_tokens = @intCast(ct.integer);
                                }
                                if (dtl.object.get("cache_write_tokens")) |cwt| {
                                    if (cwt == .integer) state.cache_write_tokens = @intCast(cwt.integer);
                                }
                            }
                        }
                    }
                }
            }
        }
        const finish_reason: []const u8 = if (std.mem.eql(u8, event_type, "response.incomplete"))
            "length"
        else
            "stop";
        const owned_reason = allocator.dupe(u8, finish_reason) catch return .{ .skip = {} };
        const choices = allocator.alloc(Chat.StreamChoice, 1) catch {
            allocator.free(owned_reason);
            return .{ .skip = {} };
        };
        choices[0] = .{ .index = 0, .delta = .{}, .finish_reason = owned_reason };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch {
            allocator.free(owned_reason);
            allocator.free(choices);
            return .{ .skip = {} };
        };
        chunks[0] = .{
            .id = state.response_id,
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
            .usage = .{
                .prompt_tokens = state.input_tokens,
                .completion_tokens = state.output_tokens,
                .total_tokens = state.input_tokens + state.output_tokens,
                .prompt_tokens_details = if (state.cache_read_tokens > 0 or state.cache_write_tokens > 0) .{
                    .cached_tokens = state.cache_read_tokens,
                    .cache_write_tokens = state.cache_write_tokens,
                } else null,
            },
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const msg_v = obj.get("message") orelse return .{ .skip = {} };
        if (msg_v != .string) return .{ .skip = {} };
        const msg = allocator.dupe(u8, msg_v.string) catch return .{ .skip = {} };
        const typ = allocator.dupe(u8, "server_error") catch { allocator.free(msg); return .{ .skip = {} }; };
        const code: ?[]const u8 = if (obj.get("code")) |c| if (c == .string) allocator.dupe(u8, c.string) catch null else null else null;
        return .{ .@"error" = .{ .@"error" = .{ .message = msg, .type = typ, .param = null, .code = code } } };
    }

    return .{ .skip = {} };
}

// ============================================================================
// Flow: /v1/messages — Messages wire in, Responses wire out
// ============================================================================

pub const MessagesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    // finish_reason holds a string literal ("max_tokens" or "end_turn"), never duped.
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    sent_open: bool = false,
    // Reasoning-block bookkeeping. When reasoning deltas arrive (before text),
    // a `thinking` block is opened at index 0 and the text block moves to the
    // next index. With no reasoning, text stays at index 0 (unchanged behavior).
    open_block: enum { none, thinking, text } = .none,
    thinking_index: u32 = 0,
    text_index: u32 = 0,
    next_index: u32 = 0,
    /// terminal (message_delta + message_stop) emitted yet? Guards the post-loop
    /// finalize against double-emitting when response.completed already fired.
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        _ = self; // finish_reason is a literal — no heap strings to free.
    }
};

/// Inbound messages request → Responses wire request, pinned to model.
///
/// Messages.Request fields mapped:
///   model (pinned), system → instructions (text: duped; blocks: joined+duped),
///   messages (user/assistant, text content first match) → input[],
///   stream, temperature, top_p, max_tokens → max_output_tokens, service_tier.
/// Skipped: stop_sequences (Responses.Request has no stop field), tools,
///   tool_choice, top_k, thinking, betas, metadata, output_config,
///   cache_control, fallbacks, container, inference_geo
///   (no Responses.Request equivalent).
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

    for (request.messages) |msg| {
        const role_str: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .system => continue,
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
        try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role_str) });
        try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, text) });
        try input_items.append(allocator, .{ .object = obj });
    }

    const instructions: ?[]const u8 = if (request.system) |sys| switch (sys) {
        .text => |t| try allocator.dupe(u8, t),
        .blocks => |blocks| blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            for (blocks) |b| try parts.append(allocator, b.text);
            break :blk if (parts.items.len > 0) try std.mem.join(allocator, "\n\n", parts.items) else null;
        },
    } else null;
    errdefer if (instructions) |s| allocator.free(s);

    return .{
        .model = model,
        .input = .{ .items = try input_items.toOwnedSlice(allocator) },
        .instructions = instructions,
        .stream = request.stream,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .max_output_tokens = request.max_tokens,
        .service_tier = request.service_tier,
        .stream_options = null,
        .tools = null,
        .tool_choice = null,
        .parallel_tool_calls = null,
        .reasoning = null,
        .reasoning_effort = null,
        .text = null,
        .store = null,
        .include = null,
        .truncation = null,
        .background = null,
        .max_tool_calls = null,
        .conversation = null,
        .context_management = null,
        .metadata = null,
        .top_logprobs = null,
        .moderation = null,
        .safety_identifier = null,
        .prompt_cache_key = null,
        .prompt_cache_options = null,
        .user = null,
        .prompt = null,
        .verbosity = null,
        .previous_response_id = null,
    };
}

/// Free what transformMessagesRequest allocated: instructions (duped), input
/// item trees (keys+content duped), and the items slice.
pub fn cleanupMessagesRequest(request: Responses.Request, allocator: std.mem.Allocator) void {
    if (request.instructions) |s| allocator.free(s);
    switch (request.input) {
        .items => |items| {
            for (items) |item| content.freeInputItem(item, allocator);
            allocator.free(items);
        },
        .text => {},
    }
}

/// Responses wire response → inbound messages response.
///
/// Responses.Response fields mapped:
///   output[].message.content[output_text].text → content[].text (duped)
///   output[].function_call → content[].tool_use (id/name duped, input leaky-parsed)
///   status="incomplete" → stop_reason="max_tokens"
///   status="failed" → stop_reason="refusal"; otherwise "end_turn"
///   id → id (duped), original_req.model → model (duped)
///   usage.input_tokens/output_tokens passed through
/// Skipped: object, completed_at, output_text, incomplete_details, error,
///   output[].reasoning/web_search_call/etc., temperature, top_p, top_logprobs,
///   moderation, metadata, reasoning, tools, tool_choice, instructions,
///   store, background, service_tier, max_output_tokens, max_tool_calls,
///   parallel_tool_calls, truncation, previous_response_id, conversation,
///   safety_identifier, prompt_cache_key, prompt_cache_options,
///   prompt_cache_diagnostics, prompt, text, user, container, stop_details
///   (no Messages.Response equivalent).
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
            .message => |m| for (m.content) |c| switch (c) {
                .output_text => |t| {
                    if (t.text.len > 0) try content_blocks.append(allocator, .{ .text = .{
                        .type = "text",
                        .text = try allocator.dupe(u8, t.text),
                    } });
                },
                // No Messages content-block equivalent.
                .refusal, .other => log.debug("[messages] dropping Responses output content {s}: no Messages equivalent", .{@tagName(c)}),
            },
            .function_call => |f| try content_blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = try allocator.dupe(u8, f.id),
                .name = try allocator.dupe(u8, f.name),
                .input = try content.parseToolArguments(f.arguments, allocator),
            } }),
            // Reasoning → thinking block (empty signature; synthesized). Responses
            // emits reasoning items before message items, so order places it first.
            .reasoning => |r| if (try content.extractReasoningText(r, allocator)) |txt| {
                errdefer allocator.free(txt);
                try content_blocks.append(allocator, .{ .thinking = .{
                    .type = "thinking",
                    .thinking = txt,
                    .signature = "",
                } });
            },
            // No Messages equivalent — dropped, logged.
            .web_search_call, .file_search_call, .code_interpreter_call,
            .mcp_list_tools_item, .mcp_call_item, .image_generation_call,
            .local_shell_call, .other => log.debug("[messages] dropping Responses output item {s}: no Messages equivalent", .{@tagName(item)}),
        }
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = try allocator.dupe(u8, "") } });
    }

    const stop_reason: ?[]const u8 = if (std.mem.eql(u8, upstream_response.status, "incomplete"))
        "max_tokens"
    else if (std.mem.eql(u8, upstream_response.status, "failed"))
        "refusal"
    else
        "end_turn";

    const owned_id = try allocator.dupe(u8, upstream_response.id);
    errdefer allocator.free(owned_id);
    const owned_content = try content_blocks.toOwnedSlice(allocator);
    errdefer {
        content.freeMessageOwnedBlocks(owned_content, allocator);
        allocator.free(owned_content);
    }
    const owned_model = try allocator.dupe(u8, original_req.model);

    return .{
        .id = owned_id,
        .type = "message",
        .role = "assistant",
        .content = owned_content,
        .model = owned_model,
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = if (upstream_response.usage) |u| blk: {
            const cached = if (u.input_tokens_details) |d| d.cached_tokens else 0;
            const written = if (u.input_tokens_details) |d| d.cache_write_tokens else 0;
            break :blk .{
                .input_tokens = u.input_tokens - cached - written,
                .output_tokens = u.output_tokens,
                .cache_read_input_tokens = if (cached > 0) cached else null,
                .cache_creation_input_tokens = if (written > 0) written else null,
            };
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

/// One Responses SSE line → Messages.MessagesStreamLineResult (typed SseEvent slice).
///
/// Synthesizes Anthropic SSE protocol from Responses events:
///   first text delta → message_start + content_block_start + content_block_delta
///   subsequent text deltas → content_block_delta
///   response.completed / response.incomplete → content_block_stop + message_delta + message_stop
///   A stream that ends without any delta still closes as a minimal message.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) Messages.MessagesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .skip = {} };
    const obj = parsed.value.object;

    const event_type = if (obj.get("type")) |t| (if (t == .string) t.string else return .{ .skip = {} }) else return .{ .skip = {} };

    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);

    if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        if (obj.get("response")) |resp_v| {
            if (resp_v == .object) {
                if (resp_v.object.get("usage")) |usage_v| {
                    if (usage_v == .object) {
                        if (usage_v.object.get("input_tokens")) |it| {
                            if (it == .integer) state.input_tokens = @intCast(it.integer);
                        }
                        if (usage_v.object.get("output_tokens")) |ot| {
                            if (ot == .integer) state.output_tokens = @intCast(ot.integer);
                        }
                        if (usage_v.object.get("input_tokens_details")) |dtl| {
                            if (dtl == .object) {
                                if (dtl.object.get("cached_tokens")) |ct| {
                                    if (ct == .integer) state.cache_read_tokens = @intCast(ct.integer);
                                }
                                if (dtl.object.get("cache_write_tokens")) |cwt| {
                                    if (cwt == .integer) state.cache_write_tokens = @intCast(cwt.integer);
                                }
                            }
                        }
                        state.input_tokens -= state.cache_read_tokens + state.cache_write_tokens;
                    }
                }
            }
        }
        if (std.mem.eql(u8, event_type, "response.incomplete")) {
            state.finish_reason = "max_tokens";
        }

        finishMessagesStream(state, &events, allocator);
        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_text.delta") or
        std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta"))
    {
        const delta_v = obj.get("delta") orelse return .{ .skip = {} };
        if (delta_v != .string or delta_v.string.len == 0) return .{ .skip = {} };

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
                    .usage = .{ .input_tokens = state.input_tokens, .output_tokens = 0 },
                },
            }}) catch return .{ .skip = {} };
            state.sent_open = true;
        }
        // Open the thinking block on first reasoning delta (index 0).
        if (state.open_block != .thinking) {
            state.thinking_index = state.next_index;
            state.next_index += 1;
            state.open_block = .thinking;
            events.append(allocator, .{ .content_block_start = .{
                .type = "content_block_start",
                .index = state.thinking_index,
                .content_block = .{ .type = "thinking", .thinking = "" },
            }}) catch return .{ .skip = {} };
        }

        const owned = allocator.dupe(u8, delta_v.string) catch return .{ .skip = {} };
        events.append(allocator, .{ .content_block_delta = .{
            .type = "content_block_delta",
            .index = state.thinking_index,
            .delta = .{ .type = "thinking_delta", .thinking = owned },
        }}) catch {
            allocator.free(owned);
            return .{ .skip = {} };
        };
        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        const delta_v = obj.get("delta") orelse return .{ .skip = {} };
        if (delta_v != .string or delta_v.string.len == 0) return .{ .skip = {} };

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
                    .usage = .{ .input_tokens = state.input_tokens, .output_tokens = 0 },
                },
            }}) catch return .{ .skip = {} };
            state.sent_open = true;
        }
        // Close a preceding thinking block, then open the text block (once).
        if (state.open_block == .thinking) {
            events.append(allocator, .{ .content_block_stop = .{
                .type = "content_block_stop", .index = state.thinking_index,
            }}) catch return .{ .skip = {} };
            state.open_block = .none;
        }
        if (state.open_block != .text) {
            state.text_index = state.next_index;
            state.next_index += 1;
            state.open_block = .text;
            events.append(allocator, .{ .content_block_start = .{
                .type = "content_block_start",
                .index = state.text_index,
                .content_block = .{ .type = "text", .text = "" },
            }}) catch return .{ .skip = {} };
        }

        // Dupe — delta_v.string borrows from parsed which dies after this function returns.
        const owned_text = allocator.dupe(u8, delta_v.string) catch return .{ .skip = {} };
        events.append(allocator, .{ .content_block_delta = .{
            .type = "content_block_delta",
            .index = state.text_index,
            .delta = .{ .type = "text_delta", .text = owned_text },
        }}) catch {
            allocator.free(owned_text);
            return .{ .skip = {} };
        };

        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const msg_v = obj.get("message") orelse return .{ .skip = {} };
        if (msg_v != .string) return .{ .skip = {} };
        const msg = allocator.dupe(u8, msg_v.string) catch return .{ .skip = {} };
        const ev = allocator.alloc(Messages.SseEvent, 1) catch { allocator.free(msg); return .{ .skip = {} }; };
        ev[0] = .{ .error_event = .{
            .type = "error",
            .@"error" = .{ .type = "server_error", .message = msg },
        }};
        return .{ .events = ev };
    }

    return .{ .skip = {} };
}

/// Emit the terminal (lazy message_start if needed, close open block,
/// message_delta + message_stop). Idempotent via `state.finished` so the
/// pipeline's post-loop finalize does not double-emit when response.completed
/// already fired.
fn finishMessagesStream(
    state: *MessagesStreamState,
    events: *std.ArrayList(Messages.SseEvent),
    allocator: std.mem.Allocator,
) void {
    if (state.finished) return;
    state.finished = true;

    // Lazy open: a stream that produced no deltas still closes correctly.
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
                .usage = .{ .input_tokens = state.input_tokens, .output_tokens = 0 },
            },
        }}) catch return;
        events.append(allocator, .{ .content_block_start = .{
            .type = "content_block_start",
            .index = 0,
            .content_block = .{ .type = "text", .text = "" },
        }}) catch return;
        state.sent_open = true;
        state.open_block = .text;
        state.text_index = 0;
    }

    const stop_reason = state.finish_reason orelse "end_turn";
    const close_index: u32 = switch (state.open_block) {
        .none, .text => state.text_index,
        .thinking => state.thinking_index,
    };
    events.append(allocator, .{ .content_block_stop = .{
        .type = "content_block_stop", .index = close_index,
    }}) catch return;
    state.open_block = .none;
    events.append(allocator, .{ .message_delta = .{
        .type = "message_delta",
        .delta = .{ .stop_reason = stop_reason, .stop_sequence = null },
        .usage = .{
            .output_tokens = state.output_tokens,
            .cache_read_input_tokens = if (state.cache_read_tokens > 0) state.cache_read_tokens else null,
            .cache_creation_input_tokens = if (state.cache_write_tokens > 0) state.cache_write_tokens else null,
        },
    }}) catch return;
    events.append(allocator, .{ .message_stop = .{ .type = "message_stop" } }) catch return;
}

/// Terminal flush when the stream ends without a response.completed event
/// (upstream closed / empty stream). Returns an owned event slice (caller frees),
/// or null if the terminal was already emitted.
pub fn finalizeMessagesStream(
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) ?[]Messages.SseEvent {
    if (state.finished) return null;
    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);
    finishMessagesStream(state, &events, allocator);
    if (events.items.len == 0) return null;
    return events.toOwnedSlice(allocator) catch null;
}
// ============================================================================

pub const ResponsesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        _ = self; // pass-through owns no heap strings.
    }
};

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

/// No-op: the request is owned by the caller.
pub fn cleanupResponsesRequest(request: Responses.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
}

/// Pass the upstream response through, rewriting model to the inbound model name.
pub fn transformResponsesResponse(
    upstream_response: Responses.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var resp = upstream_response;
    resp.model = try allocator.dupe(u8, original_req.model);
    return resp;
}

/// Free the model string allocated by transformResponsesResponse.
pub fn cleanupResponsesResponse(inbound_response: Responses.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.model);
}

/// One Responses SSE line → Responses.ResponsesStreamLineResult (typed StreamEvent slice).
///
/// Forwards events as raw_bytes, rewriting the model field in response.*
/// lifecycle events to echo state.original_model.
/// Usage from response.completed / response.incomplete is captured into state.
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) Responses.ResponsesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return content.passThrough(allocator, line);
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return content.passThrough(allocator, line);
    defer parsed.deinit();

    if (parsed.value != .object) return content.passThrough(allocator, line);
    const obj = parsed.value.object;

    const event_type = if (obj.get("type")) |t| (if (t == .string) t.string else return content.passThrough(allocator, line)) else return content.passThrough(allocator, line);

    // Capture usage from terminal lifecycle events.
    if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        if (obj.get("response")) |resp_v| {
            if (resp_v == .object) {
                if (resp_v.object.get("usage")) |usage_v| {
                    if (usage_v == .object) {
                        if (usage_v.object.get("input_tokens")) |it| {
                            if (it == .integer) state.input_tokens = @intCast(it.integer);
                        }
                        if (usage_v.object.get("output_tokens")) |ot| {
                            if (ot == .integer) state.output_tokens = @intCast(ot.integer);
                        }
                        if (usage_v.object.get("input_tokens_details")) |dtl| {
                            if (dtl == .object) {
                                if (dtl.object.get("cached_tokens")) |ct| {
                                    if (ct == .integer) state.cache_read_tokens = @intCast(ct.integer);
                                }
                                if (dtl.object.get("cache_write_tokens")) |cwt| {
                                    if (cwt == .integer) state.cache_write_tokens = @intCast(cwt.integer);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Rewrite model in lifecycle events that carry a response object.
    if (obj.get("response")) |resp_v| {
        if (resp_v == .object) {
            const upstream_model = if (resp_v.object.get("model")) |m|
                (if (m == .string) m.string else "")
            else
                "";
            if (upstream_model.len > 0 and !std.mem.eql(u8, upstream_model, state.original_model)) {
                // Mutate model in-place on the already-parsed value and re-serialize.
                if (parsed.value.object.getPtr("response")) |rp| {
                    if (rp.* == .object) {
                        rp.object.put(allocator, "model", .{ .string = state.original_model }) catch
                            return content.passThrough(allocator, line);
                        var buf: std.ArrayList(u8) = .empty;
                        buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(parsed.value, .{})}) catch {
                            buf.deinit(allocator);
                            return content.passThrough(allocator, line);
                        };
                        const owned = buf.toOwnedSlice(allocator) catch {
                            buf.deinit(allocator);
                            return content.passThrough(allocator, line);
                        };
                        return content.wrapRawBytes(owned, allocator);
                    }
                }
            }
        }
    }

    return content.passThrough(allocator, line);
}

/// Nothing to flush — pass-through events are emitted as they arrive.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    _ = state;
    _ = allocator;
    return null;
}
