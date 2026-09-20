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

//! Google AI Studio (Gemini) wire-format transformer — four flows.
//!
//! Flows: Models, Chat, Messages, Responses.
//! Gemini SSE sends full Response objects per chunk (no incremental event types).
//! The Messages flow synthesizes Anthropic SSE protocol from Gemini chunks.
//! The Responses flow synthesizes OpenAI Responses SSE from Gemini chunks.

const std = @import("std");

const Chat = @import("../openai/chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Responses = @import("../openai/responses_types.zig");
const common = @import("../openai/types.zig");
const Google = @import("types.zig");
const content = @import("content.zig");
const chat_content = @import("../openai/chat_content.zig");
const log = @import("../../log.zig");
const time = @import("../../time.zig");

/// The Responses flow synthesizes its own terminal events; the pipeline appends the `[DONE]` sentinel afterwards.
pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the Gemini models listing to inbound `Model` entries, prefixing ids
/// with the provider name. Only models supporting `generateContent` are listed;
/// the `models/` name prefix is stripped.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Google.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var models = std.ArrayList(common.Model).empty;
    errdefer models.deinit(allocator);

    for (response.value.models) |m| {
        var supports_generate = false;
        for (m.supported_generation_methods) |method| {
            if (std.mem.eql(u8, method, "generateContent")) {
                supports_generate = true;
                break;
            }
        }
        if (!supports_generate) continue;

        const bare_name = if (std.mem.startsWith(u8, m.name, "models/"))
            m.name["models/".len..]
        else
            m.name;
        if (bare_name.len == 0) continue;

        try models.append(allocator, .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, bare_name }),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, "google"),
        });
    }

    return models.toOwnedSlice(allocator);
}

// ============================================================================
// Flow: /v1/chat/completions — inbound chat schema → Gemini wire
// ============================================================================

/// Stream state for the chat flow.
pub const ChatStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
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

/// Inbound chat request → Gemini request, pinned to `model`.
///
/// Field mapping (Chat.Request → Google.RequestPayload):
///   messages (system/dev)         → system_instruction (extracted via buildContents)
///   messages (user/assistant/tool) → contents (buildContents; same-role turns merged)
///   max_tokens | max_completion_tokens → generation_config.max_output_tokens (clamped to 65536)
///   temperature                   → generation_config.temperature
///   top_p                         → generation_config.top_p
///   stop[]                        → generation_config.stop_sequences
///   n                             → generation_config.candidate_count
///   seed                          → generation_config.seed
///   presence_penalty              → generation_config.presence_penalty
///   frequency_penalty             → generation_config.frequency_penalty
///   logprobs                      → generation_config.response_logprobs
///   top_logprobs                  → generation_config.logprobs
///   response_format (json_object/json_schema) → generation_config.response_mime_type="application/json"
///   tools[].function              → tools (transformTools via GeminiTool)
///   tool_choice                   → tool_config (transformToolChoice)
///   service_tier                  → service_tier
///   store                         → store
///   (no mapping) stream, stream_options, parallel_tool_calls, logit_bias,
///                user, reasoning_effort, modalities, audio, metadata,
///                prediction, web_search_options, moderation, verbosity
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const built = try content.buildContents(request.messages, allocator);
    errdefer {
        for (built.contents) |c| {
            for (c.parts) |part| content.freeResponseOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        allocator.free(built.contents);
        if (built.system_text) |sys| allocator.free(sys);
    }

    var system_instruction: ?Google.SystemInstruction = null;
    if (built.system_text) |sys| {
        system_instruction = try content.buildSystemInstructionFromString(sys, allocator);
    }
    errdefer if (system_instruction) |si| allocator.free(si.parts);

    const tools: ?[]Google.GeminiTool = if (request.tools) |chat_tools| blk: {
        var fns: std.ArrayList(common.ToolFunction) = .empty;
        defer fns.deinit(allocator);
        for (chat_tools) |t| try fns.append(allocator, t.function);
        break :blk if (fns.items.len > 0) try content.transformTools(fns.items, allocator) else null;
    } else null;
    errdefer if (tools) |ts| content.cleanupTools(ts, allocator);

    const tool_config: ?Google.ToolConfig = if (request.tool_choice) |tc|
        content.transformToolChoice(tc)
    else
        null;

    const raw_max = request.max_tokens orelse request.max_completion_tokens;
    const max_tokens: ?u32 = if (raw_max) |m| @min(m, 65536) else null;

    const response_mime_type: ?[]const u8 = if (request.response_format) |rf|
        if (std.mem.eql(u8, rf.type, "json_object") or std.mem.eql(u8, rf.type, "json_schema"))
            "application/json"
        else
            null
    else
        null;

    return .{
        .model = model,
        .payload = .{
            .contents = built.contents,
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .service_tier = request.service_tier,
            .store = request.store,
            .generation_config = .{
                .temperature = request.temperature,
                .top_p = request.top_p,
                .max_output_tokens = max_tokens,
                .stop_sequences = request.stop,
                .candidate_count = request.n,
                .seed = if (request.seed) |s| @intCast(s) else null,
                .presence_penalty = request.presence_penalty,
                .frequency_penalty = request.frequency_penalty,
                .response_logprobs = request.logprobs,
                .logprobs = if (request.top_logprobs) |lp| @intCast(lp) else null,
                .response_mime_type = response_mime_type,
            },
        },
    };
}

/// Free what `transformChatRequest` allocated.
pub fn cleanupChatRequest(
    request: Google.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.payload.contents) |c| {
        for (c.parts) |part| content.freeResponseOwnedArgs(part, allocator);
        allocator.free(c.parts);
    }
    allocator.free(request.payload.contents);

    if (request.payload.system_instruction) |si| {
        // The single part's text is the joined system_text owned by this request.
        if (si.parts.len > 0 and si.parts[0] == .text) allocator.free(si.parts[0].text.text);
        allocator.free(si.parts);
    }

    if (request.payload.tools) |ts| content.cleanupTools(ts, allocator);
}

/// Gemini response → inbound chat response.
///
/// Field mapping (Google.Response → Chat.Response):
///   synthesized "chatcmpl-{ts}"      → id
///   "chat.completion"                → object
///   time.timestamp()                 → created
///   original_req.model               → model (provider-prefixed)
///   candidates[0].content text parts → choices[0].message.content (joined)
///   candidates[0].content fn parts   → choices[0].message.tool_calls
///   candidates[0].finish_reason      → choices[0].finish_reason (transformStopReason)
///   usage_metadata.prompt_token_count      → usage.prompt_tokens
///   usage_metadata.candidates_token_count  → usage.completion_tokens
///   usage_metadata.total_token_count       → usage.total_tokens
///   usage_metadata.cached_content_token_count → usage.prompt_tokens_details.cached_tokens
///   usage_metadata.service_tier           → service_tier
///   (not mapped) candidates[1..], safety_ratings, citation_metadata,
///                grounding_metadata, logprobs_result, prompt_feedback,
///                model_version, response_id, model_status,
///                thoughts_token_count (no Chat.Response equivalent),
///                tool_use_prompt_token_count (no Chat.Response equivalent)
pub fn transformChatResponse(
    upstream_response: Google.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    const message_text = try content.extractTextFromBlocks(upstream_response, allocator);
    // extractTextFromBlocks always allocates; free the empty string if there is no text.
    const message_text_opt: ?[]const u8 = if (message_text.len > 0) message_text else blk: {
        allocator.free(message_text);
        break :blk null;
    };
    errdefer if (message_text_opt) |t| allocator.free(t);

    const tool_calls = try content.extractToolCalls(upstream_response, allocator);
    errdefer if (tool_calls) |calls| content.freeToolCallList(calls, allocator);

    const finish_reason: []const u8 = if (upstream_response.candidates.len > 0)
        content.transformStopReason(upstream_response.candidates[0].finish_reason)
    else
        "stop";

    const choices = try allocator.alloc(Chat.ResponseChoice, 1);
    errdefer allocator.free(choices);
    choices[0] = .{
        .index = 0,
        .message = .{
            .role = .assistant,
            .content = message_text_opt,
            .tool_calls = tool_calls,
        },
        .finish_reason = finish_reason,
        .logprobs = null,
    };

    const cached = upstream_response.usage_metadata.cached_content_token_count;

    return .{
        .id = try std.fmt.allocPrint(allocator, "chatcmpl-{d}", .{time.timestamp()}),
        .object = "chat.completion",
        .created = time.timestamp(),
        .model = try allocator.dupe(u8, original_req.model),
        .choices = choices,
        .usage = .{
            .prompt_tokens = upstream_response.usage_metadata.prompt_token_count,
            .completion_tokens = upstream_response.usage_metadata.candidates_token_count,
            .total_tokens = upstream_response.usage_metadata.total_token_count,
            .prompt_tokens_details = if (cached > 0) .{
                .cached_tokens = cached,
            } else null,
        },
        .system_fingerprint = null,
        .service_tier = upstream_response.usage_metadata.service_tier,
    };
}

/// Free what `transformChatResponse` allocated.
pub fn cleanupChatResponse(
    inbound_response: Chat.Response,
    allocator: std.mem.Allocator,
) void {
    if (inbound_response.choices.len > 0) {
        const message = inbound_response.choices[0].message;
        if (message.content) |c| allocator.free(c);
        if (message.tool_calls) |calls| content.freeToolCallList(calls, allocator);
    }
    allocator.free(inbound_response.choices);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// One Gemini SSE line → Chat.StreamChunk slice (caller serializes).
///
/// Gemini sends complete Response objects per chunk. One chunk → one StreamChunk
/// carrying text delta and/or tool_call deltas.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) Chat.ChatStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.Response,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        if (content.tryParseGeminiError(json_part, allocator)) |err| return .{ .@"error" = err };
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    if (parsed.value.candidates.len == 0) return .{ .skip = {} };
    const candidate = parsed.value.candidates[0];

    if (parsed.value.usage_metadata.total_token_count > 0) {
        state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
        state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
        state.cache_read_tokens = parsed.value.usage_metadata.cached_content_token_count;
    }

    const is_final = candidate.finish_reason != null and candidate.finish_reason.?.len > 0;
    if (is_final) state.finish_reason = content.transformStopReason(candidate.finish_reason);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    for (candidate.content.parts) |part| {
        switch (part) {
            .text => |tp| text_buf.appendSlice(allocator, tp.text) catch return .{ .skip = {} },
            else => {},
        }
    }

    var tool_call_buf: std.ArrayList(Chat.DeltaToolCall) = .empty;
    defer tool_call_buf.deinit(allocator);
    var arg_bufs = std.ArrayList(std.ArrayList(u8)).empty;
    defer {
        for (arg_bufs.items) |*b| b.deinit(allocator);
        arg_bufs.deinit(allocator);
    }
    var fc_index: u32 = 0;
    for (candidate.content.parts) |part| {
        switch (part) {
            .function_call => |fc| {
                var arg_buf: std.ArrayList(u8) = .empty;
                arg_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})}) catch return .{ .skip = {} };
                const owned_name = allocator.dupe(u8, fc.name) catch return .{ .skip = {} };
                tool_call_buf.append(allocator, .{
                    .index = fc_index,
                    .id = owned_name,
                    .type = "function",
                    .function = .{ .name = owned_name, .arguments = arg_buf.items },
                }) catch return .{ .skip = {} };
                arg_bufs.append(allocator, arg_buf) catch return .{ .skip = {} };
                fc_index += 1;
            },
            else => {},
        }
    }

    const stream_cached = parsed.value.usage_metadata.cached_content_token_count;
    const usage: ?Chat.Usage = if (is_final and parsed.value.usage_metadata.total_token_count > 0) .{
        .prompt_tokens = parsed.value.usage_metadata.prompt_token_count,
        .completion_tokens = parsed.value.usage_metadata.candidates_token_count,
        .total_tokens = parsed.value.usage_metadata.total_token_count,
        .prompt_tokens_details = if (stream_cached > 0) .{ .cached_tokens = stream_cached } else null,
    } else null;

    const choices = allocator.alloc(Chat.StreamChoice, 1) catch return .{ .skip = {} };
    choices[0] = .{
        .index = 0,
        .delta = .{
            .content = if (text_buf.items.len > 0) allocator.dupe(u8, text_buf.items) catch return .{ .skip = {} } else null,
            .tool_calls = if (tool_call_buf.items.len > 0) tool_call_buf.toOwnedSlice(allocator) catch return .{ .skip = {} } else null,
        },
        .finish_reason = if (is_final) state.finish_reason else null,
    };

    const chunks = allocator.alloc(Chat.StreamChunk, 1) catch return .{ .skip = {} };
    chunks[0] = .{
        .id = state.response_id,
        .object = "chat.completion.chunk",
        .created = state.created,
        .model = state.original_model,
        .choices = choices,
        .usage = usage,
    };
    return .{ .events = chunks };
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → Gemini wire
// ============================================================================

/// Stream state for the messages flow. The Gemini wire has no Anthropic SSE
/// protocol framing, so this transformer synthesizes it: message_start +
/// content_block_start on the first chunk, text deltas per chunk, and the
/// closing triple on the terminal chunk.
pub const MessagesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    /// Whether the synthetic message_start + content_block_start were emitted.
    sent_start: bool = false,
    /// Index of the next content block to open (text is always 0; tool_use starts at 1+).
    next_block_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            .response_id = "msg_google", // static literal; Gemini wire has no ids
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        _ = self;
    }
};

/// Inbound messages request → Gemini request, pinned to `model`.
///
/// Field mapping (Messages.Request → Google.RequestPayload):
///   messages (user/assistant)     → contents (buildContentsFromMessages; same-role merged)
///   system (.text | .blocks)      → system_instruction (buildSystemInstruction)
///   max_tokens (clamped ≤65536)   → generation_config.max_output_tokens
///   temperature                   → generation_config.temperature
///   top_p                         → generation_config.top_p
///   top_k                         → generation_config.top_k
///   stop_sequences                → generation_config.stop_sequences
///   tools (Messages.Tool[])       → tools (name/description/input_schema mapped)
///   tool_choice                   → tool_config
///   service_tier                  → service_tier
///   (not mapped) stream, metadata (no Gemini equivalent), thinking, betas, output_config,
///                container, inference_geo, cache_control, fallbacks
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const contents = try content.buildContentsFromMessages(request.messages, allocator);
    errdefer {
        for (contents) |c| {
            for (c.parts) |part| content.freeMessagesOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        allocator.free(contents);
    }

    var system_instruction: ?Google.SystemInstruction = null;
    if (request.system) |sys| {
        system_instruction = try content.buildSystemInstruction(sys, allocator);
    }
    errdefer if (system_instruction) |si| allocator.free(si.parts);

    // Map Messages.Tool[] to Gemini tools.
    const tools: ?[]Google.GeminiTool = if (request.tools) |msg_tools| blk: {
        var fns: std.ArrayList(common.ToolFunction) = .empty;
        defer fns.deinit(allocator);
        for (msg_tools) |t| {
            try fns.append(allocator, .{
                .name = t.name orelse continue,
                .description = t.description,
                .parameters = t.input_schema,
            });
        }
        break :blk if (fns.items.len > 0) try content.transformTools(fns.items, allocator) else null;
    } else null;
    errdefer if (tools) |ts| content.cleanupTools(ts, allocator);

    const tool_config: ?Google.ToolConfig = if (request.tool_choice) |tc| switch (tc) {
        .auto => .{ .function_calling_config = .{ .mode = "AUTO" } },
        .any => .{ .function_calling_config = .{ .mode = "ANY" } },
        .none => .{ .function_calling_config = .{ .mode = "NONE" } },
        .tool => |t| .{ .function_calling_config = .{
            .mode = "ANY",
            .allowed_function_names = if (t.name.len > 0) &.{t.name} else null,
        } },
    } else null;

    return .{
        .model = model,
        .payload = .{
            .contents = contents,
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .service_tier = request.service_tier,
            .generation_config = .{
                .temperature = request.temperature,
                .top_p = request.top_p,
                .top_k = request.top_k,
                .max_output_tokens = @min(request.max_tokens, 65536),
                .stop_sequences = request.stop_sequences,
            },
        },
    };
}

/// Free what `transformMessagesRequest` allocated.
pub fn cleanupMessagesRequest(
    request: Google.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.payload.contents) |c| {
        for (c.parts) |part| content.freeMessagesOwnedArgs(part, allocator);
        allocator.free(c.parts);
    }
    allocator.free(request.payload.contents);

    if (request.payload.system_instruction) |si| {
        // Parts slice is owned; individual part texts borrow from the inbound parse.
        allocator.free(si.parts);
    }

    if (request.payload.tools) |ts| content.cleanupTools(ts, allocator);
}

/// Gemini response → inbound messages response (Anthropic Messages wire).
///
/// Field mapping (Google.Response → Messages.Response):
///   synthesized "msg_{ts}"                      → id
///   "message"                                   → type
///   "assistant"                                 → role
///   candidates[0] text parts                    → content[].text blocks
///   candidates[0] function_call parts           → content[].tool_use blocks (name used as id)
///   candidates[0].finish_reason                 → stop_reason (transformStopReasonToMessages)
///   usage_metadata.prompt_token_count           → usage.input_tokens
///   usage_metadata.candidates_token_count       → usage.output_tokens
///   usage_metadata.cached_content_token_count   → usage.cache_read_input_tokens
///   "google_ai_studio/gemini"                   → model (no upstream model field)
///   (not mapped) candidates[1..], safety_ratings, citation_metadata,
///                grounding_metadata, logprobs_result, prompt_feedback,
///                model_version, response_id, model_status, stop_sequence,
///                thoughts_token_count (no Messages.Response equivalent),
///                tool_use_prompt_token_count (no Messages.Response equivalent)
pub fn transformMessagesResponse(
    upstream_response: Google.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {

    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer {
        for (content_blocks.items) |block| switch (block) {
            .text => |t| allocator.free(t.text),
            .tool_use => |tu| {
                allocator.free(tu.id);
                content.freeParsedJsonValue(tu.input, allocator);
            },
            else => {},
        };
        content_blocks.deinit(allocator);
    }

    if (upstream_response.candidates.len > 0) {
        for (upstream_response.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    const owned_text = try allocator.dupe(u8, tp.text);
                    errdefer allocator.free(owned_text);
                    try content_blocks.append(allocator, .{ .text = .{
                        .type = "text",
                        .text = owned_text,
                    } });
                },
                .function_call => |fc| {
                    // Gemini has no tool-call ids — name used as id.
                    const owned_name = try allocator.dupe(u8, fc.name);
                    errdefer allocator.free(owned_name);
                    // Deep-copy fc.args: serialize then re-parse onto allocator so the
                    // returned response does not borrow from the upstream parse arena.
                    var args_buf: std.ArrayList(u8) = .empty;
                    defer args_buf.deinit(allocator);
                    try args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})});
                    const owned_args = std.json.parseFromSliceLeaky(
                        std.json.Value, allocator, args_buf.items, .{},
                    ) catch std.json.Value{ .object = .{} };
                    errdefer content.freeParsedJsonValue(owned_args, allocator);
                    try content_blocks.append(allocator, .{ .tool_use = .{
                        .type = "tool_use",
                        .id = owned_name,
                        .name = owned_name,
                        .input = owned_args,
                    } });
                },
                else => {},
            }
        }
    }

    if (content_blocks.items.len == 0) {
        const owned_text = try allocator.dupe(u8, "");
        errdefer allocator.free(owned_text);
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = owned_text } });
    }

    const stop_reason: []const u8 = if (upstream_response.candidates.len > 0)
        content.transformStopReasonToMessages(upstream_response.candidates[0].finish_reason)
    else
        "end_turn";

    const cached = upstream_response.usage_metadata.cached_content_token_count;

    return .{
        .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{time.timestamp()}),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, original_req.model),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = .{
            .input_tokens = upstream_response.usage_metadata.prompt_token_count - cached,
            .output_tokens = upstream_response.usage_metadata.candidates_token_count,
            .cache_read_input_tokens = if (cached > 0) cached else null,
        },
    };
}

/// Free what `transformMessagesResponse` allocated.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    for (inbound_response.content) |block| {
        switch (block) {
            .text => |t| allocator.free(t.text),
            .tool_use => |tu| {
                allocator.free(tu.id); // id and name point to the same allocation
                content.freeParsedJsonValue(tu.input, allocator);
            },
            else => {},
        }
    }
    allocator.free(inbound_response.content);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// One Gemini SSE line → slice of Messages.SseEvent (caller serializes).
///
/// Synthesizes the Anthropic SSE protocol from Gemini chunks:
///   first chunk  → message_start + content_block_start(text) + ping
///   text parts   → content_block_delta (text_delta)
///   fn_call parts → content_block_start(tool_use) + content_block_delta(input_json_delta) + content_block_stop
///   terminal     → content_block_stop(text) + message_delta + message_stop
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) Messages.MessagesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.Response,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        if (content.tryParseGeminiError(json_part, allocator)) |err| {
            const ev = allocator.alloc(Messages.SseEvent, 1) catch {
                chat_content.freeError(err, allocator);
                return .{ .skip = {} };
            };
            ev[0] = .{ .error_event = .{
                .type = "error",
                .@"error" = .{ .type = err.@"error".type, .message = err.@"error".message },
            }};
            return .{ .events = ev };
        }
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);

    if (!state.sent_start) {
        state.sent_start = true;
        events.append(allocator, .{ .message_start = .{
            .type = "message_start",
            .message = .{
                .id = state.response_id,
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
        state.next_block_index = 1;
        events.append(allocator, .{ .ping = .{} }) catch return .{ .skip = {} };
    }

    if (parsed.value.candidates.len > 0) {
        const candidate = parsed.value.candidates[0];

        for (candidate.content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len == 0) continue;
                    const owned_text = allocator.dupe(u8, tp.text) catch continue;
                    events.append(allocator, .{ .content_block_delta = .{
                        .type = "content_block_delta",
                        .index = 0,
                        .delta = .{ .type = "text_delta", .text = owned_text },
                    }}) catch {
                        allocator.free(owned_text);
                        continue;
                    };
                },
                .function_call => |fc| {
                    var args_buf: std.ArrayList(u8) = .empty;
                    args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})}) catch continue;
                    const owned_args = args_buf.toOwnedSlice(allocator) catch continue;
                    const owned_name = allocator.dupe(u8, fc.name) catch {
                        allocator.free(owned_args);
                        continue;
                    };

                    const block_idx = state.next_block_index;
                    state.next_block_index += 1;

                    events.append(allocator, .{ .content_block_start = .{
                        .type = "content_block_start",
                        .index = block_idx,
                        .content_block = .{ .type = "tool_use", .id = owned_name, .name = owned_name },
                    }}) catch continue;
                    events.append(allocator, .{ .content_block_delta = .{
                        .type = "content_block_delta",
                        .index = block_idx,
                        .delta = .{ .type = "input_json_delta", .partial_json = owned_args },
                    }}) catch continue;
                    events.append(allocator, .{ .content_block_stop = .{
                        .type = "content_block_stop",
                        .index = block_idx,
                    }}) catch continue;
                },
                else => {},
            }
        }

        if (candidate.finish_reason) |reason| {
            if (reason.len > 0) {
                state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
                state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
                state.cache_read_tokens = parsed.value.usage_metadata.cached_content_token_count;
                state.input_tokens -= state.cache_read_tokens;
                const stop_reason = content.transformStopReasonToMessages(candidate.finish_reason);
                state.finish_reason = stop_reason;

                events.append(allocator, .{ .content_block_stop = .{
                    .type = "content_block_stop",
                    .index = 0,
                }}) catch return .{ .skip = {} };
                events.append(allocator, .{ .message_delta = .{
                    .type = "message_delta",
                    .delta = .{ .stop_reason = stop_reason, .stop_sequence = null },
                    .usage = .{
                        .output_tokens = state.output_tokens,
                        .cache_read_input_tokens = if (state.cache_read_tokens > 0) state.cache_read_tokens else null,
                    },
                }}) catch return .{ .skip = {} };
                events.append(allocator, .{ .message_stop = .{
                    .type = "message_stop",
                }}) catch return .{ .skip = {} };
            }
        }
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — inbound responses schema → Gemini wire
// ============================================================================

/// Stream state for the responses flow.
pub const ResponsesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    /// Whether the synthetic output_item.added + content_part.added were emitted.
    sent_start: bool = false,
    sequence_number: u32 = 0,
    /// Accumulates text across chunks for output_text.done.
    text_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            .response_id = "resp_google", // static literal; Gemini wire has no response ids
        };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
        self.text_buf.deinit(self.allocator);
    }
};

/// Inbound responses request → Gemini request, pinned to `model`.
///
/// Field mapping (Responses.Request → Google.RequestPayload):
///   input (text)                  → contents [{role:"user", parts:[text]}]
///   input (items[].message)       → contents (same-role turns merged)
///   input (items[].function_call) → model turn with function_call part
///   input (items[].function_call_output) → user turn with function_response part
///   input (items[].reasoning)     → dropped (no Gemini equivalent)
///   instructions                  → system_instruction
///   max_output_tokens (≤65536)    → generation_config.max_output_tokens
///   temperature                   → generation_config.temperature
///   top_p                         → generation_config.top_p
///   tools[].function              → tools (transformTools)
///   tool_choice                   → tool_config (transformResponsesToolChoice)
///   reasoning.budget_tokens       → generation_config.thinking_config.thinking_budget; effort dropped (no equivalent)
///   (no mapping for parallel_tool_calls — Gemini has no equivalent concept)
///   service_tier                  → service_tier
///   store                         → store
///   (no stop field in Responses.Request)
///   (not mapped) previous_response_id, stream, stream_options, text,
///                include, truncation, background, max_tool_calls, conversation,
///                context_management, metadata, top_logprobs, moderation,
///                safety_identifier, prompt_cache_key, prompt_cache_options,
///                user, prompt, verbosity, reasoning_effort
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const contents = try content.buildContentsFromResponsesInput(request.input, allocator);
    errdefer {
        for (contents) |c| {
            for (c.parts) |part| content.freeResponsesOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        allocator.free(contents);
    }

    var system_instruction: ?Google.SystemInstruction = null;
    if (request.instructions) |instr| {
        system_instruction = try content.buildSystemInstructionFromString(instr, allocator);
    }
    errdefer if (system_instruction) |si| allocator.free(si.parts);

    var fns: std.ArrayList(common.ToolFunction) = .empty;
    defer fns.deinit(allocator);
    if (request.tools) |resp_tools| {
        for (resp_tools) |t| switch (t) {
            .function => |f| try fns.append(allocator, f.function),
            .web_search_preview, .file_search, .code_interpreter_tool, .mcp_tool, .other => {},
        };
    }
    const tools: ?[]Google.GeminiTool = if (fns.items.len > 0)
        try content.transformTools(fns.items, allocator)
    else
        null;
    errdefer if (tools) |ts| content.cleanupTools(ts, allocator);

    const tool_config = content.transformResponsesToolChoice(request.tool_choice);
    // parallel_tool_calls: Gemini has no equivalent concept — not mapped.

    const raw_max = request.max_output_tokens;

    return .{
        .model = model,
        .payload = .{
            .contents = contents,
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .service_tier = request.service_tier,
            .store = request.store,
            .generation_config = .{
                .temperature = request.temperature,
                .top_p = request.top_p,
                .max_output_tokens = if (raw_max) |m| @min(m, 65536) else null,
                .thinking_config = if (request.reasoning) |r| blk: {
                    // Partial mapping: budget_tokens is directly equivalent.
                    // effort ("low"/"medium"/"high") has no Gemini equivalent — dropped.
                    const budget: ?u32 = if (r == .object) b: {
                        const bt = r.object.get("budget_tokens") orelse break :b null;
                        break :b if (bt == .integer) @intCast(bt.integer) else null;
                    } else null;
                    break :blk Google.ThinkingConfig{ .thinking_budget = budget };
                } else null,
            },
        },
    };
}

/// Free what `transformResponsesRequest` allocated.
pub fn cleanupResponsesRequest(
    request: Google.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.payload.contents) |c| {
        for (c.parts) |part| content.freeResponsesOwnedArgs(part, allocator);
        allocator.free(c.parts);
    }
    allocator.free(request.payload.contents);
    if (request.payload.system_instruction) |si| allocator.free(si.parts);
    if (request.payload.tools) |ts| content.cleanupTools(ts, allocator);
}

/// Gemini response → inbound responses response.
///
/// Field mapping (Google.Response → Responses.Response):
///   synthesized "resp_{ts}"              → id
///   "response"                           → object
///   time.timestamp()                     → created_at, completed_at
///   original_req.model                   → model (duped)
///   candidates[0].finish_reason=="MAX_TOKENS" → status="incomplete" + incomplete_details
///   otherwise                            → status="completed"
///   candidates[0] text parts             → output[0].message.content[output_text] (duped)
///   candidates[0] function_call parts    → output[N].function_call (id/name/arguments duped)
///   concat of text parts                 → output_text (convenience field, duped)
///   usage_metadata.prompt_token_count    → usage.input_tokens
///   usage_metadata.candidates_token_count → usage.output_tokens
///   usage_metadata.total_token_count     → usage.total_tokens
///   original_req.temperature             → temperature
///   original_req.top_p                   → top_p
///   original_req.top_logprobs            → top_logprobs
///   original_req.parallel_tool_calls     → parallel_tool_calls (default true)
///   original_req.store                   → store
///   original_req.max_output_tokens       → max_output_tokens
///   original_req.metadata                → metadata
///   original_req.instructions            → instructions
///   original_req.tool_choice             → tool_choice
///   original_req.tools                   → tools
///   original_req.background              → background
///   original_req.max_tool_calls          → max_tool_calls
///   original_req.conversation            → conversation
///   original_req.previous_response_id    → previous_response_id
///   original_req.truncation              → truncation
///   original_req.user                    → user
///   usage_metadata.service_tier          → service_tier
///   (not mapped) candidates[1..], safety_ratings, citation_metadata,
///                grounding_metadata, logprobs_result, prompt_feedback,
///                model_version, response_id, model_status
///   (target null) error, reasoning, moderation, safety_identifier, prompt_cache_key,
///                 prompt_cache_options, prompt_cache_diagnostics, prompt, text
///                 (no upstream Gemini source for these fields)
pub fn transformResponsesResponse(
    upstream_response: Google.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer output_items.deinit(allocator);

    var msg_content_parts: std.ArrayList(Responses.OutputContent) = .empty;
    errdefer msg_content_parts.deinit(allocator);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);

    if (upstream_response.candidates.len > 0) {
        for (upstream_response.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len > 0) {
                        try msg_content_parts.append(allocator, .{ .output_text = .{
                            .type = "output_text",
                            .text = try allocator.dupe(u8, tp.text),
                        } });
                        try text_buf.appendSlice(allocator, tp.text);
                    }
                },
                .function_call => |fc| {
                    var args_buf: std.ArrayList(u8) = .empty;
                    defer args_buf.deinit(allocator);
                    try args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})});
                    try output_items.append(allocator, .{ .function_call = .{
                        .id = try std.fmt.allocPrint(allocator, "call_{s}", .{fc.name}),
                        .type = "function_call",
                        .name = try allocator.dupe(u8, fc.name),
                        .arguments = try args_buf.toOwnedSlice(allocator),
                        .call_id = null,
                        .status = "completed",
                    } });
                },
                else => {},
            }
        }
    }

    const content_slice = try msg_content_parts.toOwnedSlice(allocator);
    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{time.timestamp()}),
        .type = "message",
        .role = "assistant",
        .content = content_slice,
        .status = "completed",
    } });

    const output_text: ?[]const u8 = if (text_buf.items.len > 0)
        try text_buf.toOwnedSlice(allocator)
    else
        null;
    errdefer if (output_text) |s| allocator.free(s);

    // finishReason → status + incomplete_details.
    var status: []const u8 = "completed";
    var incomplete_details: ?std.json.Value = null;
    if (upstream_response.candidates.len > 0) {
        if (upstream_response.candidates[0].finish_reason) |reason| {
            if (std.mem.eql(u8, reason, "MAX_TOKENS")) {
                status = "incomplete";
                var obj: std.json.ObjectMap = .{};
                const key = try allocator.dupe(u8, "reason");
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, "max_output_tokens");
                errdefer allocator.free(value);
                try obj.put(allocator, key, .{ .string = value });
                incomplete_details = .{ .object = obj };
            } else if (std.mem.eql(u8, reason, "SAFETY") or std.mem.eql(u8, reason, "RECITATION")) {
                status = "incomplete";
                var obj: std.json.ObjectMap = .{};
                const key = try allocator.dupe(u8, "reason");
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, "content_filter");
                errdefer allocator.free(value);
                try obj.put(allocator, key, .{ .string = value });
                incomplete_details = .{ .object = obj };
            }
        }
    }

    const now: f64 = @floatFromInt(time.timestamp());

    return .{
        .id = try std.fmt.allocPrint(allocator, "resp_{d}", .{time.timestamp()}),
        .object = "response",
        .created_at = now,
        .completed_at = now,
        .model = try allocator.dupe(u8, original_req.model),
        .status = status,
        .output = try output_items.toOwnedSlice(allocator),
        .output_text = output_text,
        .usage = .{
            .input_tokens = upstream_response.usage_metadata.prompt_token_count,
            .output_tokens = upstream_response.usage_metadata.candidates_token_count,
            .total_tokens = upstream_response.usage_metadata.total_token_count,
            .input_tokens_details = if (upstream_response.usage_metadata.cached_content_token_count > 0) .{
                .cached_tokens = upstream_response.usage_metadata.cached_content_token_count,
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
        .service_tier = upstream_response.usage_metadata.service_tier,
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
    if (inbound_response.incomplete_details) |details| content.freeParsedJsonValue(details, allocator);
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

/// One Gemini SSE line → slice of Responses.StreamEvent (caller serializes).
///
/// Event mapping:
///   first chunk → output_item_added (message) + content_part_added (output_text)
///   text parts  → output_text_delta
///   fn parts    → output_item_added (function_call) + function_call_arguments_delta
///                 + function_call_arguments_done + output_item_done (function_call)
///   terminal    → output_text_done + content_part_done
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) Responses.ResponsesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.Response,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        if (content.tryParseGeminiError(json_part, allocator)) |err| {
            const ev = allocator.alloc(Responses.StreamEvent, 1) catch {
                chat_content.freeError(err, allocator);
                return .{ .skip = {} };
            };
            ev[0] = .{ .stream_error = .{
                .sequence_number = state.sequence_number,
                .code = err.@"error".code,
                .message = err.@"error".message,
            }};
            return .{ .events = ev };
        }
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    var events: std.ArrayList(Responses.StreamEvent) = .empty;
    defer events.deinit(allocator);

    if (!state.sent_start) {
        state.sent_start = true;
        events.append(allocator, .{ .output_item_added = .{
            .sequence_number = state.sequence_number,
            .output_index = 0,
            .item = .{ .message = .{
                .id = state.response_id,
                .type = "message",
                .role = "assistant",
                .content = &.{},
                .status = "in_progress",
            }},
        }}) catch return .{ .skip = {} };
        state.sequence_number += 1;
        events.append(allocator, .{ .content_part_added = .{
            .sequence_number = state.sequence_number,
            .output_index = 0,
            .item_id = state.response_id,
            .content_index = 0,
            .part = .{ .output_text = .{ .type = "output_text", .text = "" } },
        }}) catch return .{ .skip = {} };
        state.sequence_number += 1;
    }

    if (parsed.value.candidates.len > 0) {
        const candidate = parsed.value.candidates[0];

        for (candidate.content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len == 0) continue;
                    state.text_buf.appendSlice(allocator, tp.text) catch continue;
                    const owned_text = allocator.dupe(u8, tp.text) catch continue;
                    events.append(allocator, .{ .output_text_delta = .{
                        .sequence_number = state.sequence_number,
                        .output_index = 0,
                        .item_id = state.response_id,
                        .content_index = 0,
                        .delta = owned_text,
                    }}) catch {
                        allocator.free(owned_text);
                        continue;
                    };
                    state.sequence_number += 1;
                },
                .function_call => |fc| {
                    var args_buf: std.ArrayList(u8) = .empty;
                    args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})}) catch continue;
                    const owned_args = args_buf.toOwnedSlice(allocator) catch continue;
                    const owned_name = allocator.dupe(u8, fc.name) catch {
                        allocator.free(owned_args);
                        continue;
                    };

                    events.append(allocator, .{ .output_item_added = .{
                        .sequence_number = state.sequence_number,
                        .output_index = 1,
                        .item = .{ .function_call = .{
                            .id = owned_name,
                            .type = "function_call",
                            .name = owned_name,
                            .arguments = "",
                            .status = "in_progress",
                        }},
                    }}) catch continue;
                    state.sequence_number += 1;
                    events.append(allocator, .{ .function_call_arguments_delta = .{
                        .sequence_number = state.sequence_number,
                        .output_index = 1,
                        .item_id = state.response_id,
                        .call_id = owned_name,
                        .delta = owned_args,
                    }}) catch continue;
                    state.sequence_number += 1;
                    events.append(allocator, .{ .function_call_arguments_done = .{
                        .sequence_number = state.sequence_number,
                        .output_index = 1,
                        .item_id = state.response_id,
                        .call_id = owned_name,
                        .arguments = owned_args,
                    }}) catch continue;
                    state.sequence_number += 1;
                    events.append(allocator, .{ .output_item_done = .{
                        .sequence_number = state.sequence_number,
                        .output_index = 1,
                        .item = .{ .function_call = .{
                            .id = owned_name,
                            .type = "function_call",
                            .name = owned_name,
                            .arguments = owned_args,
                            .call_id = null,
                            .status = "completed",
                        }},
                    }}) catch continue;
                    state.sequence_number += 1;
                },
                else => {},
            }
        }

        if (candidate.finish_reason) |reason| {
            if (reason.len > 0) {
                state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
                state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
                state.cache_read_tokens = parsed.value.usage_metadata.cached_content_token_count;
                const finish = content.transformStopReason(candidate.finish_reason);
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, finish) catch null;

                events.append(allocator, .{ .output_text_done = .{
                    .sequence_number = state.sequence_number,
                    .output_index = 0,
                    .item_id = state.response_id,
                    .content_index = 0,
                    .text = state.text_buf.items,
                }}) catch return .{ .skip = {} };
                state.sequence_number += 1;
                events.append(allocator, .{ .content_part_done = .{
                    .sequence_number = state.sequence_number,
                    .output_index = 0,
                    .item_id = state.response_id,
                    .content_index = 0,
                    .part = .{ .output_text = .{ .type = "output_text", .text = state.text_buf.items } },
                }}) catch return .{ .skip = {} };
                state.sequence_number += 1;
            }
        }
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

/// Emit the terminal Responses events after the upstream stream ends.
/// Returns null when there is nothing to flush.
/// Caller serializes and frees the returned slice.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    const reason = state.finish_reason orelse return null;
    const is_incomplete = std.mem.eql(u8, reason, "length") or
        std.mem.eql(u8, reason, "content_filter");
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
            .input_tokens_details = if (state.cache_read_tokens > 0) .{
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
