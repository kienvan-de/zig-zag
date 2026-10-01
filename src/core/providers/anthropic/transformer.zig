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

//! Anthropic wire-format transformer — four flows.
//!
//! Flows (named after the inbound schema): Models, Chat, Messages, Responses.
//! Each flow exposes transform/cleanup functions for request, response, and stream.
//! Stream states carry usage; SSE bytes are caller-freed.
//! Mapping helpers live in content.zig.

const std = @import("std");

const Messages = @import("types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // inbound chat schema (shapes only)
const Responses = @import("../openai/responses_types.zig"); // inbound responses schema (shapes only)
const common = @import("../openai/types.zig"); // shared primitives (ToolFunction)
const content = @import("content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");
const utils = @import("../../utils.zig");

/// One streaming line result. `output` carries formatted SSE bytes (caller frees). `skip` means nothing to emit.
pub const StreamLineResult = union(enum) {
    output: []const u8,
    skip: void,
};

/// The responses flow synthesizes its own terminal events; the pipeline appends the `[DONE]` sentinel afterwards.
pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Convert an Anthropic error response to OpenAI error format (for /v1/chat/completions and /v1/responses).
/// Delegates to content.transformErrorResponse. Borrows strings — allocates nothing.
pub fn transformToOpenAIError(err: Messages.ErrorResponse) common.ErrorResponse {
    return content.transformErrorResponse(err);
}

/// Convert an Anthropic error response to Anthropic error format (for /v1/messages).
/// Pass-through — already in the right format.
pub fn transformToMessagesError(err: Messages.ErrorResponse) Messages.ErrorResponse {
    return err;
}

/// Map the Anthropic models listing to inbound `Model` entries, prefixing ids
/// with the provider name.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Messages.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    const data = response.value.data;

    var models = try allocator.alloc(common.Model, data.len);
    errdefer allocator.free(models);

    for (data, 0..) |entry, i| {
        models[i] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, entry.id }),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, provider_name),
        };
    }

    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — inbound chat schema → Anthropic wire
// ============================================================================

/// Stream state for the chat flow.
pub const ChatStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
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

/// Inbound chat request → Anthropic request, pinned to `model`.
///
/// Field mapping (Chat.Request → Messages.Request):
///   model                           → model (overridden by `model` param)
///   messages                        → messages (normalizeMessages: drop system/dev, fold tool results)
///   system/developer messages       → system (extractSystemPrompt)
///   max_tokens | max_completion_tokens → max_tokens (first non-null; 4096 only if both omitted)
///   temperature                     → temperature
///   top_p                           → top_p
///   stream                          → stream
///   stop[]                          → stop_sequences[]
///   tools[].function                → tools[] (transformTools via ToolFunction)
///   tool_choice                     → tool_choice (transformToolChoice)
///   user                            → metadata.user_id
///   parallel_tool_calls             → tool_choice.disable_parallel_tool_use (inverted; explicit for both true and false)
///   (no mapping) n, presence_penalty, frequency_penalty, response_format,
///                logit_bias, logprobs, top_logprobs, seed, reasoning_effort,
///                modalities, audio, store, metadata, prediction, service_tier,
///                web_search_options, moderation, verbosity, stream_options
///   (upstream ignored) type, role, model — always "message"/"assistant"/served model
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    var tools: ?[]Messages.Tool = null;
    if (request.tools) |chat_tools| {
        var fns: std.ArrayList(common.ToolFunction) = .empty;
        defer fns.deinit(allocator);
        for (chat_tools) |t| try fns.append(allocator, t.function);
        if (fns.items.len > 0) {
            tools = try content.transformTools(fns.items, allocator);
        }
    }

    var tool_choice_val = if (request.tool_choice) |tc| content.transformToolChoice(tc) else null;

    // parallel_tool_calls → disable_parallel_tool_use (inverted).
    // false → disable=true; true → disable=false (explicit).
    if (request.parallel_tool_calls) |ptc| {
        const disable = !ptc;
        tool_choice_val = switch (tool_choice_val orelse Messages.ToolChoice{ .auto = .{} }) {
            .auto => |tc| Messages.ToolChoice{ .auto = .{ .type = tc.type, .disable_parallel_tool_use = disable } },
            .any => |tc| Messages.ToolChoice{ .any = .{ .type = tc.type, .disable_parallel_tool_use = disable } },
            .tool => |tc| Messages.ToolChoice{ .tool = .{ .type = tc.type, .name = tc.name, .disable_parallel_tool_use = disable } },
            .none => tool_choice_val,
        };
    }

    return .{
        .model = model,
        .messages = try content.normalizeMessages(request.messages, allocator),
        .system = if (try content.extractSystemPrompt(request.messages, allocator)) |s| .{ .text = s } else null,
        .max_tokens = request.max_tokens orelse request.max_completion_tokens orelse 4096,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stream = request.stream,
        .stop_sequences = request.stop,
        .tools = tools,
        .tool_choice = tool_choice_val,
        .metadata = if (request.user) |user| .{ .user_id = user } else null,
        .service_tier = request.service_tier,
    };
}

/// Free what `transformChatRequest` allocated.
pub fn cleanupChatRequest(
    request: Messages.Request,
    allocator: std.mem.Allocator,
) void {
    if (request.system) |sys| switch (sys) {
        .text => |s| allocator.free(s),
        .blocks => |blks| allocator.free(blks),
    };
    for (request.messages) |msg| {
        if (msg.content == .blocks) content.freeMessageBlocks(msg.content.blocks, allocator);
    }
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
}

/// Anthropic response → inbound chat response.
///
/// Field mapping (Messages.Response → Chat.Response):
///   id                          → id (duped)
///   "chat.completion"           → object
///   now                         → created
///   original_req.model          → model (duped)
///   content[text blocks]        → choices[0].message.content (joined)
///   content[tool_use blocks]    → choices[0].message.tool_calls
///   stop_reason                 → choices[0].finish_reason (transformStopReason)
///   usage.input_tokens          → usage.prompt_tokens
///   usage.output_tokens         → usage.completion_tokens
///   input+output                → usage.total_tokens
///   usage.cache_creation_input_tokens → usage.prompt_tokens_details.cache_write_tokens
///   usage.cache_read_input_tokens     → usage.prompt_tokens_details.cached_tokens
///   upstream_response.usage.service_tier → service_tier
///   (not mapped) output_tokens_details, server_tool_use, cache_creation,
///                stop_sequence, container, stop_details, metadata, moderation
///   (upstream ignored) type, role, model — always "message"/"assistant"/served model
///   (target null) system_fingerprint, refusal, annotations, audio, logprobs,
///                 completion_tokens_details (no Anthropic source)
pub fn transformChatResponse(
    upstream_response: Messages.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    var message_text: ?[]const u8 = try content.extractTextFromBlocks(upstream_response.content, allocator);
    errdefer if (message_text) |t| allocator.free(t);

    if (message_text) |t| {
        if (t.len == 0) {
            allocator.free(t);
            message_text = null;
        }
    }

    const tool_calls = try content.extractToolCalls(upstream_response.content, allocator);
    errdefer if (tool_calls) |calls| content.freeToolCalls(calls, allocator);

    const choices = try allocator.alloc(Chat.ResponseChoice, 1);
    errdefer allocator.free(choices);
    choices[0] = .{
        .index = 0,
        .message = .{
            .role = .assistant,
            .content = message_text,
            .tool_calls = tool_calls,
        },
        .finish_reason = content.transformStopReason(upstream_response.stop_reason),
        .logprobs = null,
    };

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "chat.completion",
        .created = time.timestamp(),
        .model = try allocator.dupe(u8, original_req.model),
        .choices = choices,
        .usage = .{
            .prompt_tokens = upstream_response.usage.input_tokens +
                (upstream_response.usage.cache_creation_input_tokens orelse 0) +
                (upstream_response.usage.cache_read_input_tokens orelse 0),
            .completion_tokens = upstream_response.usage.output_tokens,
            .total_tokens = upstream_response.usage.input_tokens + upstream_response.usage.output_tokens,
            .prompt_tokens_details = if (upstream_response.usage.cache_creation_input_tokens != null or
                upstream_response.usage.cache_read_input_tokens != null) .{
                .cache_write_tokens = upstream_response.usage.cache_creation_input_tokens orelse 0,
                .cached_tokens = upstream_response.usage.cache_read_input_tokens orelse 0,
            } else null,
        },
        .system_fingerprint = null,
        .service_tier = upstream_response.usage.service_tier,
    };
}

/// Free what `transformChatResponse` allocated.
pub fn cleanupChatResponse(
    inbound_response: Chat.Response,
    allocator: std.mem.Allocator,
) void {
    if (inbound_response.choices.len > 0) {
        const message = inbound_response.choices[0].message;
        if (message.content) |text| allocator.free(text);
        if (message.tool_calls) |calls| content.freeToolCalls(calls, allocator);
    }
    allocator.free(inbound_response.choices);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// One Anthropic SSE line → Chat.StreamChunk (caller serializes to bytes).
///
/// Event mapping (Anthropic → Chat.StreamChunk):
///   message_start          → chunk with role:assistant delta (captures id + input_tokens)
///   content_block_start    → chunk with tool_use open delta (if tool_use block)
///   content_block_delta    → text_delta → chunk with content delta
///                            input_json_delta → chunk with tool_call arguments delta
///   message_delta          → chunk with finish_reason + usage (captures output_tokens)
///   content_block_stop,
///   message_stop, ping, …  → skip
///   error                  → skip (caller checks for error event separately)
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) Chat.ChatStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const type_info = std.json.parseFromSlice(
        struct { type: []const u8 },
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer type_info.deinit();
    const event_type = type_info.value.type;

    if (std.mem.eql(u8, event_type, "message_start")) {
        const parsed = std.json.parseFromSlice(
            Messages.MessageStart,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch return .{ .skip = {} };
        defer parsed.deinit();

        if (state.response_id.len == 0 and parsed.value.message.id.len > 0) {
            state.response_id = allocator.dupe(u8, parsed.value.message.id) catch return .{ .skip = {} };
        }
        state.cache_write_tokens = parsed.value.message.usage.cache_creation_input_tokens orelse 0;
        state.cache_read_tokens = parsed.value.message.usage.cache_read_input_tokens orelse 0;
        state.input_tokens = parsed.value.message.usage.input_tokens + state.cache_write_tokens + state.cache_read_tokens;

        const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
        choices[0] = .{ .index = 0, .delta = .{ .role = .assistant }, .finish_reason = null };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
        chunks[0] = .{
            .id = if (state.response_id.len > 0) state.response_id else "chatcmpl-unknown",
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const parsed = std.json.parseFromSlice(
            Messages.ContentBlockStart,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch return .{ .skip = {} };
        defer parsed.deinit();

        const block = parsed.value.content_block;
        if (!std.mem.eql(u8, block.type, "tool_use")) return .{ .skip = {} };

        const tool_calls = allocator.alloc(Chat.DeltaToolCall, 1) catch return .{ .skip = {} };
        tool_calls[0] = .{
            .index = parsed.value.index,
            .id = if (block.id) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
            .type = "function",
            .function = .{ .name = if (block.name) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null, .arguments = "" },
        };
        const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
        choices[0] = .{ .index = 0, .delta = .{ .tool_calls = tool_calls }, .finish_reason = null };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
        chunks[0] = .{
            .id = if (state.response_id.len > 0) state.response_id else "chatcmpl-unknown",
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const parsed = std.json.parseFromSlice(
            Messages.ContentBlockDelta,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch return .{ .skip = {} };
        defer parsed.deinit();

        const delta = parsed.value.delta;

        if (std.mem.eql(u8, delta.type, "text_delta")) {
            const text = delta.text orelse return .{ .skip = {} };
            const owned_text = allocator.dupe(u8, text) catch return .{ .skip = {} };
            const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
            choices[0] = .{ .index = 0, .delta = .{ .content = owned_text }, .finish_reason = null };
            const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
            chunks[0] = .{
                .id = if (state.response_id.len > 0) state.response_id else "chatcmpl-unknown",
                .object = "chat.completion.chunk",
                .created = state.created,
                .model = state.original_model,
                .choices = choices,
            };
            return .{ .events = chunks };
        }

        if (std.mem.eql(u8, delta.type, "input_json_delta")) {
            const partial = delta.partial_json orelse return .{ .skip = {} };
            const owned_partial = allocator.dupe(u8, partial) catch return .{ .skip = {} };
            const tool_calls = allocator.alloc(Chat.DeltaToolCall, 1) catch return .{ .skip = {} };
            tool_calls[0] = .{
                .index = parsed.value.index,
                .function = .{ .arguments = owned_partial },
            };
            const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
            choices[0] = .{ .index = 0, .delta = .{ .tool_calls = tool_calls }, .finish_reason = null };
            const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
            chunks[0] = .{
                .id = if (state.response_id.len > 0) state.response_id else "chatcmpl-unknown",
                .object = "chat.completion.chunk",
                .created = state.created,
                .model = state.original_model,
                .choices = choices,
            };
            return .{ .events = chunks };
        }

        return .{ .skip = {} }; // thinking/signature deltas
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const parsed = std.json.parseFromSlice(
            Messages.MessageDelta,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch return .{ .skip = {} };
        defer parsed.deinit();

        state.output_tokens = parsed.value.usage.output_tokens;
        if (parsed.value.usage.cache_creation_input_tokens) |v| state.cache_write_tokens = v;
        if (parsed.value.usage.cache_read_input_tokens) |v| state.cache_read_tokens = v;
        if (parsed.value.usage.input_tokens) |v| state.input_tokens = v + state.cache_write_tokens + state.cache_read_tokens;
        const finish_reason = content.transformStopReason(parsed.value.delta.stop_reason);
        state.finish_reason = finish_reason;

        const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
        choices[0] = .{ .index = 0, .delta = .{}, .finish_reason = finish_reason };
        const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
        chunks[0] = .{
            .id = if (state.response_id.len > 0) state.response_id else "chatcmpl-unknown",
            .object = "chat.completion.chunk",
            .created = state.created,
            .model = state.original_model,
            .choices = choices,
            .usage = .{
                .prompt_tokens = state.input_tokens,
                .completion_tokens = state.output_tokens,
                .total_tokens = state.input_tokens + state.output_tokens,
                .prompt_tokens_details = if (state.cache_write_tokens > 0 or state.cache_read_tokens > 0) .{
                    .cache_write_tokens = state.cache_write_tokens,
                    .cached_tokens = state.cache_read_tokens,
                } else null,
            },
        };
        return .{ .events = chunks };
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const parsed = std.json.parseFromSlice(
            Messages.SseErrorEvent,
            allocator,
            json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch return .{ .skip = {} };
        defer parsed.deinit();
        const mapped = content.transformErrorResponse(.{ .@"error" = parsed.value.@"error" });
        const msg = allocator.dupe(u8, mapped.@"error".message) catch return .{ .skip = {} };
        const typ = allocator.dupe(u8, mapped.@"error".type) catch { allocator.free(msg); return .{ .skip = {} }; };
        return .{ .@"error" = .{ .@"error" = .{ .message = msg, .type = typ, .param = null, .code = null } } };
    }

    return .{ .skip = {} }; // content_block_stop, message_stop, ping, …
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → Anthropic wire (pass-through)
// ============================================================================

/// Stream state for the messages pass-through flow.
pub const MessagesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    /// Whether a `message_stop` was seen from the (real Anthropic) upstream.
    /// The pass-through forwards events verbatim; if the upstream drops the
    /// connection without a message_stop, the post-loop finalize synthesizes a
    /// minimal terminal so the client never sees a stream without a stop reason.
    saw_stop: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
    }
};

/// Pass-through: keep the inbound Anthropic request, pin `model`.
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    _ = allocator;
    var pinned = request;
    pinned.model = model;
    return pinned;
}

/// Pass-through cleanup — no allocations are made.
pub fn cleanupMessagesRequest(
    request: Messages.Request,
    allocator: std.mem.Allocator,
) void {
    _ = request;
    _ = allocator;
}

/// Pass-through: return the upstream Anthropic response as-is. The upstream
/// already echoes the served model, so `original_req` is unused here.
pub fn transformMessagesResponse(
    upstream_response: Messages.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    var response = upstream_response;
    response.id = if (upstream_response.id.len > 0)
        try allocator.dupe(u8, upstream_response.id)
    else
        try utils.generateMessagesResponseId(allocator);
    errdefer allocator.free(response.id);
    response.model = try allocator.dupe(u8, original_req.model);
    return response;
}

/// Free the id and model strings allocated by transformMessagesResponse.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// Forward one Anthropic SSE line as a typed Messages.SseEvent (caller serializes).
/// Accumulates usage into state.
/// All string fields in the returned events are duped — caller frees the slice with `allocator.free`.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) Messages.MessagesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const type_probe = std.json.parseFromSlice(
        struct { type: []const u8 = "" },
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer type_probe.deinit();
    const event_type = type_probe.value.type;

    const ev: Messages.SseEvent = blk: {
        if (std.mem.eql(u8, event_type, "message_start")) {
            const parsed = std.json.parseFromSlice(Messages.MessageStart, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            state.cache_write_tokens = v.message.usage.cache_creation_input_tokens orelse 0;
            state.cache_read_tokens = v.message.usage.cache_read_input_tokens orelse 0;
            state.input_tokens = v.message.usage.input_tokens;
            if (state.response_id.len == 0) {
                state.response_id = if (v.message.id.len > 0)
                    allocator.dupe(u8, v.message.id) catch return .{ .skip = {} }
                else
                    utils.generateMessagesResponseId(allocator) catch return .{ .skip = {} };
            }
            break :blk .{ .message_start = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .message = .{
                    .id = state.response_id,
                    .type = allocator.dupe(u8, v.message.type) catch return .{ .skip = {} },
                    .role = allocator.dupe(u8, v.message.role) catch return .{ .skip = {} },
                    .model = allocator.dupe(u8, state.original_model) catch return .{ .skip = {} },
                    .stop_reason = if (v.message.stop_reason) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .stop_sequence = if (v.message.stop_sequence) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .usage = v.message.usage,
                },
            }};
        }
        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const parsed = std.json.parseFromSlice(Messages.ContentBlockStart, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            const cb = v.content_block;
            break :blk .{ .content_block_start = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .index = v.index,
                .content_block = .{
                    .type = allocator.dupe(u8, cb.type) catch return .{ .skip = {} },
                    .text = if (cb.text) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .id = if (cb.id) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .name = if (cb.name) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .thinking = if (cb.thinking) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .signature = if (cb.signature) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .data = if (cb.data) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .tool_use_id = if (cb.tool_use_id) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                },
            }};
        }
        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const parsed = std.json.parseFromSlice(Messages.ContentBlockDelta, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            const d = v.delta;
            break :blk .{ .content_block_delta = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .index = v.index,
                .delta = .{
                    .type = allocator.dupe(u8, d.type) catch return .{ .skip = {} },
                    .text = if (d.text) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .partial_json = if (d.partial_json) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .thinking = if (d.thinking) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .signature = if (d.signature) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                },
            }};
        }
        if (std.mem.eql(u8, event_type, "content_block_stop")) {
            const parsed = std.json.parseFromSlice(Messages.ContentBlockStop, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            break :blk .{ .content_block_stop = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .index = v.index,
            }};
        }
        if (std.mem.eql(u8, event_type, "message_delta")) {
            const parsed = std.json.parseFromSlice(Messages.MessageDelta, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            state.output_tokens = v.usage.output_tokens;
            if (v.usage.cache_creation_input_tokens) |vv| state.cache_write_tokens = vv;
            if (v.usage.cache_read_input_tokens) |vv| state.cache_read_tokens = vv;
            break :blk .{ .message_delta = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .delta = .{
                    .stop_reason = if (v.delta.stop_reason) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                    .stop_sequence = if (v.delta.stop_sequence) |s| allocator.dupe(u8, s) catch return .{ .skip = {} } else null,
                },
                .usage = v.usage,
            }};
        }
        if (std.mem.eql(u8, event_type, "message_stop")) {
            const parsed = std.json.parseFromSlice(Messages.MessageStop, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            state.saw_stop = true;
            break :blk .{ .message_stop = .{
                .type = allocator.dupe(u8, parsed.value.type) catch return .{ .skip = {} },
            }};
        }
        if (std.mem.eql(u8, event_type, "ping")) {
            break :blk .{ .ping = .{} };
        }
        if (std.mem.eql(u8, event_type, "error")) {
            const parsed = std.json.parseFromSlice(Messages.SseErrorEvent, allocator, json_part,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
            defer parsed.deinit();
            const v = parsed.value;
            break :blk .{ .error_event = .{
                .type = allocator.dupe(u8, v.type) catch return .{ .skip = {} },
                .@"error" = .{
                    .type = allocator.dupe(u8, v.@"error".type) catch return .{ .skip = {} },
                    .message = allocator.dupe(u8, v.@"error".message) catch return .{ .skip = {} },
                },
            }};
        }
        return .{ .skip = {} };
    };

    const events = allocator.alloc(Messages.SseEvent, 1) catch return .{ .skip = {} };
    events[0] = ev;
    return .{ .events = events };
}

/// Terminal flush for the pass-through when the upstream closed WITHOUT sending
/// `message_stop` (dropped connection / empty stream). Returns an owned event
/// slice (caller frees) with a minimal message_delta + message_stop, or null if
/// a message_stop was already forwarded. Note: the pass-through does not track
/// open block indices, so this does not emit a content_block_stop — a bare
/// message termination is still far better for the client than a hanging stream.
pub fn finalizeMessagesStream(
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) ?[]Messages.SseEvent {
    if (state.saw_stop) return null;
    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);
    events.append(allocator, .{ .message_delta = .{
        .type = "message_delta",
        .delta = .{ .stop_reason = "end_turn", .stop_sequence = null },
        .usage = .{ .output_tokens = state.output_tokens },
    }}) catch return null;
    events.append(allocator, .{ .message_stop = .{ .type = "message_stop" } }) catch return null;
    state.saw_stop = true;
    return events.toOwnedSlice(allocator) catch null;
}

/// Stream state for the responses flow.
pub const ResponsesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    sequence_number: u32 = 0,
    /// Type of the currently-open content block: "text" or "tool_use".
    open_block_type: []const u8 = "text",
    /// Accumulates text_delta fragments for output_text.done.
    text_buf: std.ArrayList(u8) = .empty,
    /// Accumulates input_json_delta fragments for function_call_arguments.done.
    arguments_buf: std.ArrayList(u8) = .empty,
    /// id of the current tool_use block (from content_block_start).
    tool_use_id: []const u8 = "",
    /// name of the current tool_use block (from content_block_start).
    tool_use_name: []const u8 = "",
    /// output_index of the currently-open block (from ContentBlockStart.index).
    output_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        if (self.finish_reason) |reason| self.allocator.free(reason);
        if (self.tool_use_id.len > 0) self.allocator.free(self.tool_use_id);
        if (self.tool_use_name.len > 0) self.allocator.free(self.tool_use_name);
        self.response_id = "";
        self.finish_reason = null;
        self.tool_use_id = "";
        self.tool_use_name = "";
        self.text_buf.deinit(self.allocator);
        self.arguments_buf.deinit(self.allocator);
    }
};

/// Inbound responses request → Anthropic request.
///
/// Field mapping (Responses.Request → Messages.Request):
///   model                           → model (overridden by `model` param)
///   input (text)                    → messages[{role:user,content:[{type:text,text:…}]}]
///   input (items[])                 → messages[] (turn-grouping §2B):
///     item.type=="message"          → role from field (system/developer skipped)
///     item.type=="function_call"    → assistant tool_use block
///     item.type=="function_call_output" → user tool_result block
///     item.type=="reasoning"        → dropped (no Anthropic input equivalent)
///   instructions                    → system
///   max_output_tokens               → max_tokens (default 4096)
///   temperature                     → temperature
///   top_p                           → top_p
///   stream                          → stream
///   (no stop field in Responses.Request — stop_sequences not set)
///   tools[].function                → tools[] (transformResponsesTools)
///   tool_choice                     → tool_choice (responsesToolChoice)
///   parallel_tool_calls             → tool_choice.disable_parallel_tool_use (inverted; explicit for both true and false)
///   service_tier                    → service_tier
///   user                            → metadata.user_id
///   reasoning.budget_tokens         → thinking.budget_tokens (type="enabled"); effort dropped
///   (not mapped) previous_response_id, text, store, include,
///                truncation, background, max_tool_calls, conversation,
///                context_management, metadata, top_logprobs, moderation,
///                safety_identifier, prompt_cache_key, prompt_cache_options,
///                prompt, verbosity, reasoning_effort, stream_options
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    var pending_blocks = std.ArrayList(Messages.ContentBlockParam).empty;
    errdefer {
        for (pending_blocks.items) |block| {
            if (block == .tool_use) content.freeJsonValue(allocator, block.tool_use.input);
        }
        pending_blocks.deinit(allocator);
    }
    var pending_role: ?Messages.Role = null;

    var messages = std.ArrayList(Messages.Message).empty;
    errdefer {
        for (messages.items) |msg| {
            if (msg.content == .blocks) content.freeMessageBlocks(msg.content.blocks, allocator);
        }
        messages.deinit(allocator);
    }

    const flushTurn = struct {
        fn call(
            msgs: *std.ArrayList(Messages.Message),
            blocks: *std.ArrayList(Messages.ContentBlockParam),
            role: Messages.Role,
            alloc: std.mem.Allocator,
        ) !void {
            if (blocks.items.len == 0) return;
            const owned = try blocks.toOwnedSlice(alloc);
            try msgs.append(alloc, .{ .role = role, .content = .{ .blocks = owned } });
        }
    }.call;

    switch (request.input) {
        .text => |t| {
            var blocks = std.ArrayList(Messages.ContentBlockParam).empty;
            defer blocks.deinit(allocator);
            try blocks.append(allocator, .{ .text = .{ .type = "text", .text = t } });
            try messages.append(allocator, .{
                .role = .user,
                .content = .{ .blocks = try blocks.toOwnedSlice(allocator) },
            });
        },
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const item_type_val = obj.get("type") orelse continue;
            if (item_type_val != .string) continue;
            const item_type = item_type_val.string;

            if (std.mem.eql(u8, item_type, "message")) {
                const role_val = obj.get("role") orelse continue;
                if (role_val != .string) continue;
                const role_str = role_val.string;

                // system/developer messages are not carried into Anthropic turns.
                if (std.mem.eql(u8, role_str, "system") or
                    std.mem.eql(u8, role_str, "developer")) continue;

                const role: Messages.Role = if (std.mem.eql(u8, role_str, "assistant"))
                    .assistant
                else
                    .user;

                if (pending_role) |open_role| {
                    if (open_role != role) {
                        try flushTurn(&messages, &pending_blocks, open_role, allocator);
                        pending_role = null;
                    }
                }
                pending_role = role;

                const content_val = obj.get("content") orelse continue;
                switch (content_val) {
                    .string => |s| {
                        if (s.len > 0)
                            try pending_blocks.append(allocator, .{ .text = .{ .type = "text", .text = s } });
                    },
                    .array => |arr| for (arr.items) |part| {
                        if (part != .object) continue;
                        const ptype = (part.object.get("type") orelse continue);
                        if (ptype != .string) continue;

                        if (std.mem.eql(u8, ptype.string, "input_text") or
                            std.mem.eql(u8, ptype.string, "text") or
                            std.mem.eql(u8, ptype.string, "output_text"))
                        {
                            const tv = part.object.get("text") orelse continue;
                            if (tv == .string and tv.string.len > 0)
                                try pending_blocks.append(allocator, .{ .text = .{ .type = "text", .text = tv.string } });
                        } else if (std.mem.eql(u8, ptype.string, "input_image") or
                            std.mem.eql(u8, ptype.string, "image_url"))
                        {
                            const url_val = part.object.get("image_url") orelse continue;
                            const url: []const u8 = switch (url_val) {
                                .string => |s| s,
                                .object => |o| blk: {
                                    const uv = o.get("url") orelse break :blk "";
                                    break :blk if (uv == .string) uv.string else "";
                                },
                                else => continue,
                            };
                            if (url.len == 0) continue;
                            try pending_blocks.append(allocator, .{ .image = .{
                                .type = "image",
                                .source = .{ .url = .{ .type = "url", .url = url } },
                            } });
                        }
                        // input_file, refusal, other → no lossless Anthropic target.
                    },
                    else => continue,
                }
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                const name_val = obj.get("name") orelse continue;
                if (name_val != .string) continue;
                const args_val = obj.get("arguments") orelse std.json.Value{ .string = "{}" };
                const args_str: []const u8 = if (args_val == .string) args_val.string else "{}";

                // call_id preferred as tool_use id; fall back to id.
                const id_val = obj.get("call_id") orelse obj.get("id") orelse continue;
                if (id_val != .string) continue;

                var input: std.json.Value = .{ .object = std.json.ObjectMap{} };
                if (std.json.parseFromSliceLeaky(std.json.Value, allocator, args_str, .{})) |parsed| {
                    input = parsed;
                } else |_| {}

                const role: Messages.Role = .assistant;
                if (pending_role) |open_role| {
                    if (open_role != role) {
                        try flushTurn(&messages, &pending_blocks, open_role, allocator);
                        pending_role = null;
                    }
                }
                pending_role = role;
                try pending_blocks.append(allocator, .{ .tool_use = .{
                    .type = "tool_use",
                    .id = id_val.string,
                    .name = name_val.string,
                    .input = input,
                } });
            } else if (std.mem.eql(u8, item_type, "function_call_output")) {
                const call_id_val = obj.get("call_id") orelse continue;
                if (call_id_val != .string) continue;

                const output_str: ?[]const u8 = blk: {
                    const ov = obj.get("output") orelse break :blk null;
                    break :blk if (ov == .string) ov.string else null;
                };

                const is_error: ?bool = if (obj.get("error")) |ev| blk: {
                    break :blk if (ev == .bool) ev.bool else null;
                } else null;

                const role: Messages.Role = .user;
                if (pending_role) |open_role| {
                    if (open_role != role) {
                        try flushTurn(&messages, &pending_blocks, open_role, allocator);
                        pending_role = null;
                    }
                }
                pending_role = role;
                try pending_blocks.append(allocator, .{ .tool_result = .{
                    .type = "tool_result",
                    .tool_use_id = call_id_val.string,
                    .content = if (output_str) |s| .{ .text = s } else null,
                    .is_error = is_error,
                } });
            }
            // reasoning items: dropped.
        },
    }

    if (pending_role) |role| try flushTurn(&messages, &pending_blocks, role, allocator);

    if (messages.items.len == 0) return error.EmptyMessages;

    // Ensure user-first.
    if (messages.items[0].role != .user) {
        const synthetic = try allocator.alloc(Messages.ContentBlockParam, 1);
        synthetic[0] = .{ .text = .{ .type = "text", .text = "[Conversation start]" } };
        try messages.insert(allocator, 0, .{
            .role = .user,
            .content = .{ .blocks = synthetic },
        });
    }

    var tools: ?[]Messages.Tool = null;
    if (request.tools) |req_tools| blk: {
        tools = content.transformResponsesTools(req_tools, allocator) catch |err| {
            if (err == error.OutOfMemory) return err;
            break :blk;
        };
        if (tools != null and tools.?.len == 0) {
            allocator.free(tools.?);
            tools = null;
        }
    }

    const tool_choice_val = content.responsesToolChoice(request.tool_choice);
    const tool_choice_with_parallel: ?Messages.ToolChoice = if (request.parallel_tool_calls) |ptc| blk: {
        const disable = !ptc;
        break :blk switch (tool_choice_val orelse Messages.ToolChoice{ .auto = .{} }) {
            .auto => |tc| Messages.ToolChoice{ .auto = .{ .type = tc.type, .disable_parallel_tool_use = disable } },
            .any => |tc| Messages.ToolChoice{ .any = .{ .type = tc.type, .disable_parallel_tool_use = disable } },
            .tool => |tc| Messages.ToolChoice{ .tool = .{ .type = tc.type, .name = tc.name, .disable_parallel_tool_use = disable } },
            .none => tool_choice_val,
        };
    } else tool_choice_val;

    return .{
        .model = model,
        .messages = try messages.toOwnedSlice(allocator),
        .max_tokens = request.max_output_tokens orelse 4096,
        .system = if (request.instructions) |instr| .{ .text = instr } else null,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stream = request.stream,
        .tools = tools,
        .tool_choice = tool_choice_with_parallel,
        .stop_sequences = null,
        .metadata = if (request.user) |user| .{ .user_id = user } else null,
        .thinking = if (request.reasoning) |r| blk: {
            // Partial mapping: budget_tokens is directly equivalent.
            // effort ("low"/"medium"/"high") has no Anthropic equivalent — dropped.
            // type forced to "enabled" when reasoning is present.
            const budget: ?u32 = if (r == .object) b: {
                const bt = r.object.get("budget_tokens") orelse break :b null;
                break :b if (bt == .integer) @intCast(bt.integer) else null;
            } else null;
            break :blk Messages.ThinkingConfig{ .type = "enabled", .budget_tokens = budget };
        } else null,
        .betas = null,
        .service_tier = request.service_tier,
    };
}

pub fn cleanupResponsesRequest(
    request: Messages.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.messages) |msg| {
        if (msg.content == .blocks) content.freeMessageBlocks(msg.content.blocks, allocator);
    }
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
}

/// Anthropic response → inbound responses response.
///
/// Field mapping (Messages.Response → Responses.Response):
///   id                          → id (duped), output[0].message.id (duped)
///   "response"                  → object
///   time.timestamp()            → created_at, completed_at
///   original_req.model          → model (duped)
///   stop_reason                 → status ("completed" / "incomplete") + incomplete_details
///     end_turn / tool_use / stop_sequence / pause_turn → "completed"
///     max_tokens → "incomplete" + {reason:"max_output_tokens"}
///     refusal    → "incomplete" + {reason:"content_filter"}
///     model_context_window_exceeded → "incomplete" + {reason:"max_context_length"}
///   content[text blocks]        → output[0].message.content[{type:output_text,text:…}] (duped)
///   content[tool_use blocks]    → output[N].function_call (id/name/arguments duped)
///   usage.input_tokens          → usage.input_tokens
///   usage.output_tokens         → usage.output_tokens
///   input+output                → usage.total_tokens
///   original_req.temperature    → temperature
///   original_req.top_p          → top_p
///   original_req.top_logprobs   → top_logprobs
///   original_req.parallel_tool_calls → parallel_tool_calls (default true)
///   original_req.store          → store
///   original_req.max_output_tokens → max_output_tokens
///   original_req.metadata       → metadata
///   original_req.instructions   → instructions
///   original_req.tool_choice    → tool_choice
///   original_req.tools          → tools (direct echo, borrows from request)
///   original_req.background      → background
///   original_req.max_tool_calls  → max_tool_calls
///   original_req.conversation    → conversation
///   original_req.previous_response_id → previous_response_id
///   original_req.truncation     → truncation
///   original_req.user           → user
///   upstream_response.usage.service_tier → service_tier
///   concat of output_text parts → output_text (convenience field)
///   (not mapped) upstream model/type/role, stop_sequence, container, stop_details,
///                cache stats, output_tokens_details, server_tool_use
///   (upstream ignored) type, role, model — always "message"/"assistant"/served model
///   (target null) error, reasoning, prompt_cache_diagnostics, prompt, text,
///                 background, max_tool_calls, conversation, safety_identifier,
///                 prompt_cache_key, prompt_cache_options, moderation (no source)
pub fn transformResponsesResponse(
    upstream_response: Messages.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items = std.ArrayList(Responses.OutputItem).empty;
    errdefer output_items.deinit(allocator);

    var msg_content_parts = std.ArrayList(Responses.OutputContent).empty;
    errdefer msg_content_parts.deinit(allocator);

    for (upstream_response.content) |block| {
        switch (block) {
            .text => |t| {
                if (t.text.len > 0) try msg_content_parts.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, t.text),
                } });
            },
            .tool_use => |tu| {
                var args = std.ArrayList(u8).empty;
                defer args.deinit(allocator);
                try args.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});

                try output_items.append(allocator, .{ .function_call = .{
                    .id = try allocator.dupe(u8, tu.id),
                    .type = "function_call",
                    .name = try allocator.dupe(u8, tu.name),
                    .arguments = try args.toOwnedSlice(allocator),
                    .call_id = null,
                    .status = "completed",
                } });
            },
            .server_tool_use, .thinking, .redacted_thinking,
            .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }

    const content_slice = try msg_content_parts.toOwnedSlice(allocator);
    // Insert message item at index 0 so message comes before any function_call items.
    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .type = "message",
        .role = "assistant",
        .content = content_slice,
        .status = "completed",
    } });

    // stop_reason → status + incomplete_details.
    var status: []const u8 = "completed";
    var incomplete_details: ?std.json.Value = null;
    if (upstream_response.stop_reason) |sr| {
        const is_incomplete = std.mem.eql(u8, sr, "max_tokens") or
            std.mem.eql(u8, sr, "refusal") or
            std.mem.eql(u8, sr, "model_context_window_exceeded");
        if (is_incomplete) {
            status = "incomplete";
            const reason_str: []const u8 = if (std.mem.eql(u8, sr, "max_tokens"))
                "max_output_tokens"
            else if (std.mem.eql(u8, sr, "model_context_window_exceeded"))
                "max_context_length"
            else
                "content_filter";

            var obj = std.json.ObjectMap.empty;
            const key = try allocator.dupe(u8, "reason");
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, reason_str);
            errdefer allocator.free(value);
            try obj.put(allocator, key, .{ .string = value });
            incomplete_details = .{ .object = obj };
        }
    }

    // Concatenate all output_text parts for the convenience output_text field.
    var output_text_buf = std.ArrayList(u8).empty;
    defer output_text_buf.deinit(allocator);
    for (upstream_response.content) |block| {
        switch (block) {
            .text => |t| if (t.text.len > 0) try output_text_buf.appendSlice(allocator, t.text),
            // Only text contributes to the output_text convenience field; other
            // block kinds are surfaced as their own output items elsewhere.
            .tool_use, .server_tool_use, .thinking, .redacted_thinking, .tool_result,
            .web_search_tool_result, .web_fetch_tool_result, .code_execution_tool_result,
            .bash_code_execution_tool_result, .text_editor_code_execution_tool_result,
            .tool_search_tool_result, .fallback => {},
        }
    }
    const output_text: ?[]const u8 = if (output_text_buf.items.len > 0)
        try output_text_buf.toOwnedSlice(allocator)
    else
        null;
    errdefer if (output_text) |s| allocator.free(s);

    const now: f64 = @floatFromInt(time.timestamp());

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "response",
        .created_at = now,
        .completed_at = now,
        .model = try allocator.dupe(u8, original_req.model),
        .status = status,
        .output = try output_items.toOwnedSlice(allocator),
        .output_text = output_text,
        .usage = .{
            .input_tokens = upstream_response.usage.input_tokens +
                (upstream_response.usage.cache_creation_input_tokens orelse 0) +
                (upstream_response.usage.cache_read_input_tokens orelse 0),
            .output_tokens = upstream_response.usage.output_tokens,
            .total_tokens = upstream_response.usage.input_tokens + upstream_response.usage.output_tokens,
            .input_tokens_details = if (upstream_response.usage.cache_creation_input_tokens != null or
                upstream_response.usage.cache_read_input_tokens != null) .{
                .cache_write_tokens = upstream_response.usage.cache_creation_input_tokens orelse 0,
                .cached_tokens = upstream_response.usage.cache_read_input_tokens orelse 0,
            } else null,
        },
        .incomplete_details = incomplete_details,
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .top_logprobs = original_req.top_logprobs,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
        .instructions = if (original_req.instructions) |s| .{ .string = s } else null,
        .tool_choice = original_req.tool_choice,
        .tools = original_req.tools,
        .background = original_req.background,
        .max_tool_calls = original_req.max_tool_calls,
        .conversation = original_req.conversation,
        .previous_response_id = original_req.previous_response_id,
        .truncation = original_req.truncation,
        .user = original_req.user,
        .service_tier = upstream_response.usage.service_tier,
    };
}

/// Free what `transformResponsesResponse` allocated.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    if (inbound_response.output_text) |s| allocator.free(s);
    if (inbound_response.incomplete_details) |details| content.freeJsonValue(allocator, details);
    for (inbound_response.output) |item| {
        switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |t| allocator.free(t.text),
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

/// One Anthropic SSE line → typed Responses.StreamEvent (caller serializes).
///
/// Event mapping (Anthropic → Responses.StreamEvent):
///   message_start        → captures id + input_tokens; skip
///   content_block_start  → output_item_added + content_part_added (text)
///                          output_item_added (tool_use → function_call)
///   content_block_delta  → text_delta → output_text_delta
///                          input_json_delta → function_call_arguments_delta
///   content_block_stop   → text: output_text_done + content_part_done
///                          tool_use: function_call_arguments_done + output_item_done
///   message_delta        → captures output_tokens + finish_reason; skip
///   message_stop, ping   → skip
///   error                → stream_error event
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) Responses.ResponsesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const type_probe = std.json.parseFromSlice(
        struct { type: []const u8 = "" },
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer type_probe.deinit();
    const event_type = type_probe.value.type;

    if (std.mem.eql(u8, event_type, "error")) {
        var err_message: []const u8 = "Upstream error";
        var err_code: ?[]const u8 = null;
        if (std.json.parseFromSlice(Messages.SseErrorEvent, allocator, json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed|
        {
            defer parsed.deinit();
            err_message = allocator.dupe(u8, parsed.value.@"error".message) catch err_message;
            err_code = if (parsed.value.@"error".type.len > 0)
                allocator.dupe(u8, parsed.value.@"error".type) catch null
            else
                null;
        } else |_| {}
        const events = allocator.alloc(Responses.StreamEvent, 1) catch return .{ .skip = {} };
        events[0] = .{ .stream_error = .{
            .sequence_number = state.sequence_number,
            .code = err_code,
            .message = err_message,
        }};
        return .{ .events = events };
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        if (std.json.parseFromSlice(Messages.MessageStart, allocator, json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed|
        {
            defer parsed.deinit();
            if (state.response_id.len == 0 and parsed.value.message.id.len > 0) {
                state.response_id = state.allocator.dupe(u8, parsed.value.message.id) catch "";
            }
            state.cache_write_tokens = parsed.value.message.usage.cache_creation_input_tokens orelse 0;
            state.cache_read_tokens = parsed.value.message.usage.cache_read_input_tokens orelse 0;
            state.input_tokens = parsed.value.message.usage.input_tokens + state.cache_write_tokens + state.cache_read_tokens;
        } else |_| {}
        return .{ .skip = {} };
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const parsed = std.json.parseFromSlice(Messages.ContentBlockStart, allocator, json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
        defer parsed.deinit();

        const block = parsed.value.content_block;
        const is_text = std.mem.eql(u8, block.type, "text");
        state.open_block_type = if (is_text) "text" else "tool_use";
        state.output_index = parsed.value.index;
        state.text_buf.clearRetainingCapacity();
        state.arguments_buf.clearRetainingCapacity();
        if (state.tool_use_id.len > 0) state.allocator.free(state.tool_use_id);
        if (state.tool_use_name.len > 0) state.allocator.free(state.tool_use_name);
        state.tool_use_id = if (block.id) |s| state.allocator.dupe(u8, s) catch "" else "";
        state.tool_use_name = if (block.name) |s| state.allocator.dupe(u8, s) catch "" else "";

        if (is_text) {
            // Two events: output_item_added + content_part_added.
            const events = allocator.alloc(Responses.StreamEvent, 2) catch return .{ .skip = {} };
            events[0] = .{ .output_item_added = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item = .{ .message = .{
                    .id = state.response_id,
                    .type = "message",
                    .role = "assistant",
                    .content = &.{},
                    .status = "in_progress",
                }},
            }};
            events[1] = .{ .content_part_added = .{
                .sequence_number = state.sequence_number + 1,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .content_index = 0,
                .part = .{ .output_text = .{ .type = "output_text", .text = "" } },
            }};
            return .{ .events = events };
        } else {
            const events = allocator.alloc(Responses.StreamEvent, 1) catch return .{ .skip = {} };
            events[0] = .{ .output_item_added = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item = .{ .function_call = .{
                    .id = state.tool_use_id,
                    .type = "function_call",
                    .name = state.tool_use_name,
                    .arguments = "",
                    .status = "in_progress",
                }},
            }};
            return .{ .events = events };
        }
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const parsed = std.json.parseFromSlice(Messages.ContentBlockDelta, allocator, json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return .{ .skip = {} };
        defer parsed.deinit();
        const delta = parsed.value.delta;

        if (std.mem.eql(u8, delta.type, "text_delta")) {
            const text = delta.text orelse return .{ .skip = {} };
            if (text.len == 0) return .{ .skip = {} };
            state.text_buf.appendSlice(allocator, text) catch return .{ .skip = {} };
            const owned_text = allocator.dupe(u8, text) catch return .{ .skip = {} };
            const events = allocator.alloc(Responses.StreamEvent, 1) catch return .{ .skip = {} };
            events[0] = .{ .output_text_delta = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .content_index = 0,
                .delta = owned_text,
            }};
            return .{ .events = events };
        }

        if (std.mem.eql(u8, delta.type, "input_json_delta")) {
            const partial = delta.partial_json orelse return .{ .skip = {} };
            if (partial.len == 0) return .{ .skip = {} };
            state.arguments_buf.appendSlice(allocator, partial) catch return .{ .skip = {} };
            const owned_partial = allocator.dupe(u8, partial) catch return .{ .skip = {} };
            const events = allocator.alloc(Responses.StreamEvent, 1) catch return .{ .skip = {} };
            events[0] = .{ .function_call_arguments_delta = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .call_id = if (state.tool_use_id.len > 0) state.tool_use_id else null,
                .delta = owned_partial,
            }};
            return .{ .events = events };
        }

        return .{ .skip = {} }; // thinking/signature deltas
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        if (std.mem.eql(u8, state.open_block_type, "tool_use")) {
            // Two events: function_call_arguments_done + output_item_done.
            const events = allocator.alloc(Responses.StreamEvent, 2) catch return .{ .skip = {} };
            events[0] = .{ .function_call_arguments_done = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .call_id = if (state.tool_use_id.len > 0) state.tool_use_id else null,
                .arguments = state.arguments_buf.items,
            }};
            events[1] = .{ .output_item_done = .{
                .sequence_number = state.sequence_number + 1,
                .output_index = state.output_index,
                .item = .{ .function_call = .{
                    .id = state.tool_use_id,
                    .type = "function_call",
                    .name = state.tool_use_name,
                    .arguments = state.arguments_buf.items,
                    .call_id = null,
                    .status = "completed",
                }},
            }};
            return .{ .events = events };
        } else {
            // Two events: output_text_done + content_part_done.
            const events = allocator.alloc(Responses.StreamEvent, 2) catch return .{ .skip = {} };
            events[0] = .{ .output_text_done = .{
                .sequence_number = state.sequence_number,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .content_index = 0,
                .text = state.text_buf.items,
            }};
            events[1] = .{ .content_part_done = .{
                .sequence_number = state.sequence_number + 1,
                .output_index = state.output_index,
                .item_id = state.response_id,
                .content_index = 0,
                .part = .{ .output_text = .{ .type = "output_text", .text = state.text_buf.items } },
            }};
            return .{ .events = events };
        }
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        if (std.json.parseFromSlice(Messages.MessageDelta, allocator, json_part,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed|
        {
            defer parsed.deinit();
            state.output_tokens = parsed.value.usage.output_tokens;
            if (parsed.value.usage.cache_creation_input_tokens) |v| state.cache_write_tokens = v;
            if (parsed.value.usage.cache_read_input_tokens) |v| state.cache_read_tokens = v;
            if (parsed.value.usage.input_tokens) |v| state.input_tokens = v + state.cache_write_tokens + state.cache_read_tokens;
            if (parsed.value.delta.stop_reason) |reason| {
                if (reason.len > 0) {
                    if (state.finish_reason) |prev| allocator.free(prev);
                    state.finish_reason = allocator.dupe(u8, reason) catch null;
                }
            }
        } else |_| {}
        return .{ .skip = {} };
    }

    return .{ .skip = {} }; // message_stop, ping, unknown
}

/// Emit the terminal Responses events after the upstream stream ends.
/// Returns null when there is nothing to flush (no finish_reason captured).
/// Returns a slice of typed events: output_item_done + response_completed/incomplete.
/// Caller serializes and frees.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    const reason = state.finish_reason orelse return null;
    const is_incomplete = std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "refusal") or
        std.mem.eql(u8, reason, "model_context_window_exceeded");
    const status: []const u8 = if (is_incomplete) "incomplete" else "completed";

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
            .input_tokens_details = if (state.cache_write_tokens > 0 or state.cache_read_tokens > 0) .{
                .cache_write_tokens = state.cache_write_tokens,
                .cached_tokens = state.cache_read_tokens,
            } else null,
        },
        .parallel_tool_calls = true,
    };

    events[1] = if (is_incomplete)
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
