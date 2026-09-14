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

//! Transformer for the google_ai_studio (Gemini) provider.
//!
//! Four flows, named after the *inbound* schema (P2). Each request/response
//! flow exposes exactly five functions; the Responses flow adds a flush.
//! Every `pub` symbol here is defined here (P5). Conversion is written
//! locally against the Gemini wire (P11) — no other provider's transformer
//! is imported.

const std = @import("std");

const Chat = @import("../openai/chat_types.zig"); // inbound chat schema (shapes only)
const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Responses = @import("../openai/responses_types.zig"); // inbound responses schema (shapes only)
const common = @import("../openai/types.zig"); // shared primitives (ToolFunction)
const Google = @import("types.zig"); // Gemini wire types
const content = @import("content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

/// Re-export from anthropic/types.zig so callers can use `Transformer.StreamLineResult`.
pub const StreamLineResult = Messages.StreamLineResult;

/// Chat and Messages pipelines append their own `[DONE]` sentinel; the
/// Responses pipeline does not (native Responses upstreams end silently).
pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the Gemini models listing to inbound `Model` entries, prefixing ids
/// with the provider name. Only models supporting `generateContent` are
/// listed; the `models/` name prefix is stripped.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Google.ModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var models = std.ArrayList(common.Model).empty;
    errdefer models.deinit(allocator);

    for (response.value.models) |m| {
        // Filter: only models that support generateContent.
        var supports_generate = false;
        for (m.supported_generation_methods) |method| {
            if (std.mem.eql(u8, method, "generateContent")) {
                supports_generate = true;
                break;
            }
        }
        if (!supports_generate) continue;

        // Strip the "models/" prefix to get the bare model id.
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

/// Stream state for the chat flow. Gemini chunks are self-contained Responses,
/// so little survives across lines; the core fields carry id/model/usage out.
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

/// Inbound chat request → Gemini request, pinned to `model`. Gemini caps
/// output at 65536 tokens — `max_tokens`/`max_completion_tokens` are clamped.
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const built = try content.buildContents(request.messages, allocator);
    errdefer allocator.free(built.contents);
    errdefer if (built.system_text) |sys| allocator.free(sys);

    var system_instruction: ?Google.SystemInstruction = null;
    if (built.system_text) |sys| {
        const si_parts = try allocator.alloc(Google.Part, 1);
        si_parts[0] = .{ .text = .{ .text = sys } };
        system_instruction = .{ .parts = si_parts };
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

    const raw_max_tokens = request.max_tokens orelse request.max_completion_tokens;
    // Gemini models have a max output of 65536 tokens — clamp to avoid 400s.
    const max_tokens: ?u32 = if (raw_max_tokens) |m| @min(m, 65536) else null;

    const response_mime_type: ?[]const u8 = if (request.response_format) |rf|
        if (std.mem.eql(u8, rf.type, "json_object") or std.mem.eql(u8, rf.type, "json_schema"))
            "application/json"
        else
            null
    else
        null;

    const generation_config = Google.GenerationConfig{
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
    };

    log.debug("[google] transformChatRequest: model={s} contents={d} tools={?} max_tokens={?}", .{
        model,
        built.contents.len,
        if (tools) |t| t.len else null,
        max_tokens,
    });

    return .{
        .model = model,
        .payload = .{
            .contents = built.contents,
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .generation_config = generation_config,
        },
    };
}

/// Free what `transformChatRequest` allocated: contents (+ owned function_call
/// argument trees), system instruction, tools (+ sanitized schemas). Borrowed
/// fields (names, text, stop sequences) are not freed here.
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

    if (request.payload.tools) |tools| content.cleanupTools(tools, allocator);
}

/// Gemini response → inbound chat response. The Gemini wire carries no model
/// field and no id: the model is echoed from the original request (provider-
/// prefixed) and the id is synthesized (`chatcmpl-<timestamp>`).
pub fn transformChatResponse(
    upstream_response: Google.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    const message_text = try content.extractTextFromBlocks(upstream_response, allocator);
    errdefer allocator.free(message_text);

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
            .content = if (message_text.len > 0) message_text else null,
            .tool_calls = tool_calls,
        },
        .finish_reason = finish_reason,
        .logprobs = null,
    };

    return .{
        .id = try std.fmt.allocPrint(allocator, "chatcmpl-{d}", .{time.timestamp()}),
        .object = "chat.completion",
        .created = time.timestamp(),
        .model = try std.fmt.allocPrint(allocator, "google_ai_studio/{s}", .{original_req.model}),
        .choices = choices,
        .usage = .{
            .prompt_tokens = upstream_response.usage_metadata.prompt_token_count,
            .completion_tokens = upstream_response.usage_metadata.candidates_token_count,
            .total_tokens = upstream_response.usage_metadata.total_token_count,
        },
        .system_fingerprint = null,
        .service_tier = null,
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
        if (message.tool_calls) |tool_calls| content.freeToolCallList(tool_calls, allocator);
    }
    allocator.free(inbound_response.choices);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// One Gemini SSE line (a full Response) → zero or one chat-format SSE chunk
/// as ready bytes (P4: no serialize→parse round-trip). The Gemini wire has no
/// ids, so the chunk id is static per stream; usage is emitted only on the
/// terminal chunk (the one carrying a finish_reason and a total count).
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        log.debug("[google] stream chunk parse failed: {}", .{err});
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    if (parsed.value.candidates.len == 0) {
        // Usage-only trailing chunk? Gemini sends usage on the final candidate
        // chunk; without a candidate there is nothing to forward.
        return .{ .skip = {} };
    }
    const candidate = parsed.value.candidates[0];

    // Collect text parts (the typical case: exactly one text part per chunk).
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    for (candidate.content.parts) |part| {
        switch (part) {
            .text => |tp| text_buf.appendSlice(allocator, tp.text) catch return .{ .skip = {} },
            else => {},
        }
    }

    const is_final = candidate.finish_reason != null and candidate.finish_reason.?.len > 0;

    // Usage tracking: Gemini repeats counts on every chunk; the authoritative
    // totals arrive with the terminal chunk.
    if (parsed.value.usage_metadata.total_token_count > 0) {
        state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
        state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
    }

    const usage: ?Chat.Usage = if (is_final and parsed.value.usage_metadata.total_token_count > 0)
        .{
            .prompt_tokens = parsed.value.usage_metadata.prompt_token_count,
            .completion_tokens = parsed.value.usage_metadata.candidates_token_count,
            .total_tokens = parsed.value.usage_metadata.total_token_count,
        }
    else
        null;

    if (is_final) {
        state.finish_reason = content.transformStopReason(candidate.finish_reason);
    }

    const delta = Chat.Delta{
        .content = if (text_buf.items.len > 0) text_buf.items else null,
    };

    const bytes = content.buildChatChunk(.{
        .id = state.response_id,
        .created = state.created,
        .original_model = state.original_model,
    }, delta, if (is_final) state.finish_reason else null, usage, allocator) orelse
        return .{ .skip = {} };
    return .{ .output = bytes };
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → Gemini wire
// ============================================================================

/// Stream state for the messages flow: the Gemini wire has no message_start /
/// message_stop framing, so the transformer synthesizes the Anthropic SSE
/// protocol (message_start + content_block_start once, then deltas, then the
/// stop triple on the terminal chunk).
pub const MessagesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    // --- messages-flow specifics ---
    /// Whether the synthetic message_start + content_block_start were emitted.
    sent_start: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            // Static literal (Gemini wire has no ids): never freed — deinit is
            // a no-op for the id here, unlike the other states which own dupes.
            .response_id = "msg_google",
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        _ = self;
    }
};

/// Inbound messages request → Gemini request, pinned to `model`. Gemini caps
/// output at 65536 tokens. Tools/tool_choice are not mapped (the old pass-
/// through also dropped them — Anthropic-format tool declarations have no
/// verified Gemini mapping yet).
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const contents = try content.buildContentsFromMessages(request.messages, allocator);
    errdefer allocator.free(contents);

    var system_instruction: ?Google.SystemInstruction = null;
    if (request.system) |sys| {
        const si_parts = try allocator.alloc(Google.Part, 1);
        si_parts[0] = .{ .text = .{ .text = sys } };
        system_instruction = .{ .parts = si_parts };
    }
    errdefer if (system_instruction) |si| allocator.free(si.parts);

    return .{
        .model = model,
        .payload = .{
            .contents = contents,
            .system_instruction = system_instruction,
            .tools = null,
            .tool_config = null,
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
        // The single part's text borrows from the inbound system string, so
        // only the parts slice is owned here (unlike the chat flow, which owns
        // the joined text).
        allocator.free(si.parts);
    }
}

/// Gemini response → inbound messages response (Anthropic Messages wire out).
/// The Gemini wire carries no id or model: the id is synthesized (`msg_<ts>`)
/// and the model string uses the historical literal.
pub fn transformMessagesResponse(
    upstream_response: Google.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    _ = original_req;

    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer content_blocks.deinit(allocator);

    if (upstream_response.candidates.len > 0) {
        for (upstream_response.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| try content_blocks.append(allocator, .{ .text = .{
                    .type = "text",
                    .text = tp.text,
                } }),
                .function_call => |fc| {
                    // Gemini has no tool-call ids — the name stands in for the id.
                    try content_blocks.append(allocator, .{ .tool_use = .{
                        .type = "tool_use",
                        .id = fc.name,
                        .name = fc.name,
                        .input = fc.args,
                    } });
                },
                else => {},
            }
        }
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = "" } });
    }

    const stop_reason: []const u8 = if (upstream_response.candidates.len > 0)
        content.transformStopReasonToMessages(upstream_response.candidates[0].finish_reason)
    else
        "end_turn";

    return .{
        .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{time.timestamp()}),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, "google_ai_studio/gemini"),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = .{
            .input_tokens = upstream_response.usage_metadata.prompt_token_count,
            .output_tokens = upstream_response.usage_metadata.candidates_token_count,
        },
    };
}

/// Free what `transformMessagesResponse` allocated: the content-block slice
/// (block fields borrow from the upstream response) plus id and model strings.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.content);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// One Gemini SSE line → Anthropic-format SSE events as ready bytes,
/// synthesizing the message protocol: the first chunk emits `message_start` +
/// `content_block_start` (+ `ping`), text parts emit `content_block_delta`
/// events, and the chunk carrying a finish_reason emits the closing
/// `content_block_stop` + `message_delta` + `message_stop` triple. Usage is
/// accumulated into `state` from the terminal chunk.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Synthetic protocol opening, once per stream.
    if (!state.sent_start) {
        state.sent_start = true;
        const msg_start = Messages.MessageStart{
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
        };
        out.print(allocator, "event: message_start\ndata: {f}\n\n", .{std.json.fmt(msg_start, .{})}) catch return .{ .skip = {} };
        const cb_start = Messages.ContentBlockStart{
            .type = "content_block_start",
            .index = 0,
            .content_block = .{ .type = "text", .text = "" },
        };
        out.print(allocator, "event: content_block_start\ndata: {f}\n\n", .{std.json.fmt(cb_start, .{ .emit_null_optional_fields = false })}) catch return .{ .skip = {} };
        const ping = Messages.Ping{};
        out.print(allocator, "event: ping\ndata: {f}\n\n", .{std.json.fmt(ping, .{})}) catch return .{ .skip = {} };
    }

    if (parsed.value.candidates.len > 0) {
        const candidate = parsed.value.candidates[0];

        // Text deltas.
        for (candidate.content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len == 0) continue;
                    const delta_ev = Messages.ContentBlockDelta{
                        .type = "content_block_delta",
                        .index = 0,
                        .delta = .{ .type = "text_delta", .text = tp.text },
                    };
                    out.print(
                        allocator,
                        "event: content_block_delta\ndata: {f}\n\n",
                        .{std.json.fmt(delta_ev, .{})},
                    ) catch continue;
                },
                else => {},
            }
        }

        // Terminal chunk: closing triple + usage accumulation.
        if (candidate.finish_reason) |reason| {
            if (reason.len > 0) {
                state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
                state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
                const stop_reason = content.transformStopReasonToMessages(candidate.finish_reason);
                state.finish_reason = stop_reason;

                const cb_stop = Messages.ContentBlockStop{ .type = "content_block_stop", .index = 0 };
                out.print(allocator, "event: content_block_stop\ndata: {f}\n\n", .{std.json.fmt(cb_stop, .{})}) catch return .{ .skip = {} };
                const msg_delta = Messages.MessageDelta{
                    .type = "message_delta",
                    .delta = .{ .stop_reason = stop_reason, .stop_sequence = null },
                    .usage = .{ .output_tokens = state.output_tokens },
                };
                out.print(allocator, "event: message_delta\ndata: {f}\n\n", .{std.json.fmt(msg_delta, .{})}) catch return .{ .skip = {} };
                const msg_stop = Messages.MessageStop{ .type = "message_stop" };
                out.print(allocator, "event: message_stop\ndata: {f}\n\n", .{std.json.fmt(msg_stop, .{})}) catch return .{ .skip = {} };
            }
        }
    }

    if (out.items.len == 0) return .{ .skip = {} };
    return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — inbound responses schema → Gemini wire
// ============================================================================
// Conversion is written locally against the Gemini wire (P11): the old
// implementation bridged through the Anthropic path plus the openai
// responses_transformer, which duplicated provider logic and lost events.

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

    // --- responses-flow specifics ---
    /// Whether the synthetic output_item.added + content_part.added were emitted.
    sent_start: bool = false,
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
    }
};

/// Inbound responses request → Gemini request, pinned to `model`. Input text
/// / message items become contents, `instructions` → systemInstruction,
/// `max_output_tokens` clamped to the Gemini 65536 ceiling. Tools and
/// tool_choice are not mapped (no verified Gemini mapping yet — matching the
/// messages flow's stance).
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    var contents: std.ArrayList(Google.Content) = .empty;
    errdefer {
        for (contents.items) |c| allocator.free(c.parts);
        contents.deinit(allocator);
    }

    switch (request.input) {
        .text => |text| {
            const parts = try allocator.alloc(Google.Part, 1);
            parts[0] = .{ .text = .{ .text = text } };
            try contents.append(allocator, .{ .role = "user", .parts = parts });
        },
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const role_val = obj.get("role") orelse continue;
            if (role_val != .string) continue;
            const role: []const u8 = if (std.mem.eql(u8, role_val.string, "assistant"))
                "model"
            else
                "user";

            const content_val = obj.get("content") orelse continue;
            const text: []const u8 = switch (content_val) {
                .string => |s| s,
                .array => |arr| blk: {
                    // First non-empty text part wins; images/references skipped.
                    for (arr.items) |part| {
                        if (part != .object) continue;
                        const tv = part.object.get("text") orelse continue;
                        if (tv == .string and tv.string.len > 0) break :blk tv.string;
                    }
                    break :blk "";
                },
                else => continue,
            };
            if (text.len == 0) continue;

            const parts = try allocator.alloc(Google.Part, 1);
            parts[0] = .{ .text = .{ .text = text } };
            try contents.append(allocator, .{ .role = role, .parts = parts });
        },
    }

    if (contents.items.len == 0) return error.EmptyMessages;

    var system_instruction: ?Google.SystemInstruction = null;
    if (request.instructions) |sys| {
        const si_parts = try allocator.alloc(Google.Part, 1);
        si_parts[0] = .{ .text = .{ .text = sys } };
        system_instruction = .{ .parts = si_parts };
    }
    errdefer if (system_instruction) |si| allocator.free(si.parts);

    var fns: std.ArrayList(common.ToolFunction) = .empty;
    defer fns.deinit(allocator);
    if (request.tools) |resp_tools| {
        for (resp_tools) |t| switch (t) {
            .function => |f| try fns.append(allocator, f.function),
            .other => {},
        };
    }
    const tools: ?[]Google.GeminiTool = if (fns.items.len > 0)
        try content.transformTools(fns.items, allocator)
    else
        null;
    errdefer if (tools) |ts| content.cleanupTools(ts, allocator);

    const tool_config: ?Google.ToolConfig = if (request.tool_choice) |tc|
        content.transformToolChoice(tc)
    else
        null;

    const raw_max_tokens = request.max_output_tokens;
    return .{
        .model = model,
        .payload = .{
            .contents = try contents.toOwnedSlice(allocator),
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .generation_config = .{
                .temperature = request.temperature,
                .top_p = request.top_p,
                .max_output_tokens = if (raw_max_tokens) |m| @min(m, 65536) else null,
                .stop_sequences = request.stop,
            },
        },
    };
}

/// Free what `transformResponsesRequest` allocated: the contents slice and
/// each part slice (text borrows the inbound parse; system parts slice owned).
pub fn cleanupResponsesRequest(
    request: Google.Request,
    allocator: std.mem.Allocator,
) void {
    for (request.payload.contents) |c| allocator.free(c.parts);
    allocator.free(request.payload.contents);
    if (request.payload.system_instruction) |si| allocator.free(si.parts);
    if (request.payload.tools) |ts| content.cleanupTools(ts, allocator);
}

/// Gemini response → inbound responses response. The Gemini wire carries no
/// id: one is synthesized. Output items follow the Responses shape (message
/// item first). Echo fields are copied from `original_req` per the Responses
/// contract (no upstream equivalent).
pub fn transformResponsesResponse(
    upstream_response: Google.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer output_items.deinit(allocator);

    var parts: std.ArrayList(Responses.OutputContent) = .empty;
    errdefer parts.deinit(allocator);

    if (upstream_response.candidates.len > 0) {
        for (upstream_response.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len > 0) try parts.append(allocator, .{ .output_text = .{
                        .type = "output_text",
                        .text = try allocator.dupe(u8, tp.text),
                    } });
                },
                .function_call => |fc| {
                    // Arguments: re-serialize the parsed args tree to a string.
                    var args_buf: std.ArrayList(u8) = .empty;
                    defer args_buf.deinit(allocator);
                    try args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})});

                    try output_items.append(allocator, .{
                        .function_call = .{
                            .id = try std.fmt.allocPrint(allocator, "call_{s}", .{fc.name}),
                            .type = "function_call",
                            // Owned: cleanupResponsesResponse frees name.
                            .name = try allocator.dupe(u8, fc.name),
                            .arguments = try args_buf.toOwnedSlice(allocator),
                            .status = "completed",
                        },
                    });
                },
                else => {},
            }
        }
    }

    const content_slice = try parts.toOwnedSlice(allocator);
    errdefer {
        for (content_slice) |c| switch (c) {
            .output_text => |txt| allocator.free(txt.text),
            else => {},
        };
        allocator.free(content_slice);
    }
    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{time.timestamp()}),
        .type = "message",
        .role = "assistant",
        .content = content_slice,
        .status = "completed",
    } });

    // finishReason → status + incomplete_details
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
            }
        }
    }

    return .{
        .id = try std.fmt.allocPrint(allocator, "resp_{d}", .{time.timestamp()}),
        .object = "response",
        .created_at = 0,
        .model = try allocator.dupe(u8, original_req.model),
        .status = status,
        .output = try output_items.toOwnedSlice(allocator),
        .usage = .{
            .input_tokens = upstream_response.usage_metadata.prompt_token_count,
            .output_tokens = upstream_response.usage_metadata.candidates_token_count,
            .total_tokens = upstream_response.usage_metadata.total_token_count,
        },
        .incomplete_details = incomplete_details,
        // Request-echo fields (no upstream equivalent — Responses contract).
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
    };
}

/// Free what `transformResponsesResponse` allocated: id/model strings, the
/// output tree (message item + text parts + function calls), and the
/// incomplete_details map. Echo fields borrow from `original_req`.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    if (inbound_response.incomplete_details) |details| content.freeParsedJsonValue(details, allocator);
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

/// One Gemini SSE line → Responses SSE events as ready bytes. The first
/// chunk emits `response.output_item.added` + `response.content_part.added`;
/// text parts emit `response.output_text.delta`; the terminal chunk emits
/// `response.output_text.done`. Usage / terminal reason accumulate into
/// `state` for `flushResponsesStream`. Upstream errors surface as
/// `response.failed` (P4).
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Google.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Opening events, once per stream (the id is static — no wire ids).
    if (!state.sent_start) {
        state.sent_start = true;
        const bytes = Responses.outputItemAddedSSE(state.response_id, true, state.sequence_number, allocator) orelse
            return .{ .skip = {} };
        state.sequence_number += 2;
        out.appendSlice(allocator, bytes) catch {
            allocator.free(bytes);
            return .{ .skip = {} };
        };
        allocator.free(bytes);
    }

    if (parsed.value.candidates.len > 0) {
        const candidate = parsed.value.candidates[0];

        for (candidate.content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len == 0) continue;
                    var ev_buf: std.ArrayList(u8) = .empty;
                    const ev = Responses.StreamEvent{ .output_text_delta = .{
                        .sequence_number = state.sequence_number,
                        .item_id = state.response_id,
                        .delta = tp.text,
                    }};
                    ev.writeSSE(&ev_buf, allocator) catch { ev_buf.deinit(allocator); continue; };
                    state.sequence_number += 1;
                    out.appendSlice(allocator, ev_buf.items) catch { ev_buf.deinit(allocator); continue; };
                    ev_buf.deinit(allocator);
                },
                else => {},
            }
        }

        if (candidate.finish_reason) |reason| {
            if (reason.len > 0) {
                state.input_tokens = parsed.value.usage_metadata.prompt_token_count;
                state.output_tokens = parsed.value.usage_metadata.candidates_token_count;
                state.finish_reason = content.transformStopReason(candidate.finish_reason);

                var done_ev_buf: std.ArrayList(u8) = .empty;
                const done_ev = Responses.StreamEvent{ .output_text_done = .{
                    .sequence_number = state.sequence_number,
                    .item_id = state.response_id,
                }};
                done_ev.writeSSE(&done_ev_buf, allocator) catch {
                    done_ev_buf.deinit(allocator);
                    return .{ .skip = {} };
                };
                state.sequence_number += 1;
                out.appendSlice(allocator, done_ev_buf.items) catch { done_ev_buf.deinit(allocator); return .{ .skip = {} }; };
                done_ev_buf.deinit(allocator);
            }
        }
    }

    if (out.items.len == 0) return .{ .skip = {} };
    return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

/// Emit the terminal Responses events after the upstream stream ends
/// (`response.output_item.done` + `response.completed`, or
/// `response.incomplete` for a length-capped finish) with the usage
/// accumulated in `state`. Returns `null` when there is nothing to flush.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "length")) "incomplete" else "completed";
    const input_tok = state.input_tokens;
    const output_tok = state.output_tokens;

    var buf = std.ArrayList(u8).empty;

    const item_done = Responses.StreamEvent{ .output_item_done = .{
        .sequence_number = state.sequence_number,
        .item = .{ .message = .{
            .id = state.response_id,
            .type = "message",
            .role = "assistant",
            .content = &.{},
            .status = status,
        }},
    }};
    item_done.writeSSE(&buf, allocator) catch return null;
    state.sequence_number += 1;

    const completed_ev = if (std.mem.eql(u8, status, "incomplete"))
        Responses.StreamEvent{ .response_incomplete = .{
            .sequence_number = state.sequence_number,
            .response = .{
                .id = state.response_id,
                .model = state.original_model,
                .status = status,
                .output = &.{},
                .usage = .{
                    .input_tokens = input_tok,
                    .output_tokens = output_tok,
                    .total_tokens = input_tok + output_tok,
                },
            },
        }}
    else
        Responses.StreamEvent{ .response_completed = .{
            .sequence_number = state.sequence_number,
            .response = .{
                .id = state.response_id,
                .model = state.original_model,
                .status = status,
                .output = &.{},
                .usage = .{
                    .input_tokens = input_tok,
                    .output_tokens = output_tok,
                    .total_tokens = input_tok + output_tok,
                },
            },
        }};
    completed_ev.writeSSE(&buf, allocator) catch { buf.deinit(allocator); return null; };
    return buf.toOwnedSlice(allocator) catch null;
}
