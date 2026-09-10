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

//! Anthropic wire-format transformer — one file, four flows.
//!
//! ## Principles
//!
//! - **P1** One transformer per upstream wire format: this file converts between
//!   the inbound API schemas and the Anthropic wire, and nothing else.
//! - **P2** Four flows, named after the *inbound* schema: `Models`, `Chat`,
//!   `Messages`, `Responses`. Each request/response/stream flow exposes exactly
//!   `transform{Flow}Request`, `cleanup{Flow}Request`, `transform{Flow}Response`,
//!   `cleanup{Flow}Response`, `transform{Flow}StreamLine`. `Models` is
//!   response-only. `Responses` additionally owns `flushResponsesStream`.
//! - **P3** Three owned stream states (`ChatStreamState`, `MessagesStreamState`,
//!   `ResponsesStreamState`), each with the uniform core
//!   `allocator, original_model, response_id, finish_reason, input_tokens, output_tokens`
//!   plus flow-specific fields. Usage is read from these fields at end of stream —
//!   never scraped from individual chunks by pipelines.
//! - **P4** One streaming result type, `StreamLineResult`. `output` carries
//!   formatted SSE bytes ready to write (caller frees); errors are rendered
//!   *inside* this transformer into the flow's own wire format.
//! - **P5** No re-exports, no aliases: every `pub` symbol here is defined here.
//! - **P6** Main surface only: mapping/streaming support code lives in `content.zig`.
//! - **P7** Flow prefixes only in names (`Chat`/`Messages`/`Responses`/`Models`) —
//!   including import aliases, so a reader sees the same vocabulary everywhere.
//!   `Anthropic` names the wire format and appears only in prose.
//! - **P8** Parameter order is fixed: request `(request, model, allocator)`,
//!   response `(upstream_response, original_req, allocator)` — every response
//!   carries the original inbound request so flow-specific echo fields
//!   (e.g. Responses temperature/store) and the requested model are available;
//!   stream `(line, *state, allocator)`, cleanup `(value, allocator)`.
//!   Exception: `transformModelsResponse` keeps its pre-existing order.
//! - **P11** Self-contained: depends on shared *type definitions* and its own
//!   `content.zig` only — never on another provider's transformer/converter.
//!   Conversion duplicated across providers is accepted; isolation over DRY.

const std = @import("std");

const Messages = @import("types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // inbound chat schema (shapes only)
const Responses = @import("../openai/responses_types.zig"); // inbound responses schema (shapes only)
const common = @import("../openai/types.zig"); // shared primitives (ToolFunction)
const content = @import("content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract (shared by all flows)
// ============================================================================

/// Result of feeding one upstream SSE line through a flow's stream transform.
/// `output` is ready-to-write SSE bytes owned by the caller's allocator.
pub const StreamLineResult = union(enum) {
    output: []const u8,
    skip: void,
};

/// The responses flow synthesizes its own terminal events; the pipeline appends
/// the `[DONE]` sentinel afterwards.
/// TODO(review): this is file-level today but only the Responses flow needs it —
/// decide between per-flow flags or leaving it here.
pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================
// Response-only: GET, no request body, no streaming (P2).

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

/// Stream state for the chat flow: Anthropic events are stateful, so context
/// (open tool call, whether a role has been emitted) must survive across lines.
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

/// Inbound chat request → Anthropic request, pinned to `model`.
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    return .{
        .model = model,
        .messages = try content.normalizeMessages(request.messages, allocator),
        .system = try content.extractSystemPrompt(request.messages, allocator),
        .max_tokens = request.max_tokens orelse request.max_completion_tokens orelse 4096,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stream = request.stream,
        .stop_sequences = request.stop,
        .tools = if (request.tools) |chat_tools| blk: {
            var fns: std.ArrayList(common.ToolFunction) = .empty;
            defer fns.deinit(allocator);
            for (chat_tools) |t| switch (t) {
                .function => |f| try fns.append(allocator, f.function),
                .custom => {},
            };
            break :blk if (fns.items.len > 0) try content.transformTools(fns.items, allocator) else null;
        } else null,
        .tool_choice = if (request.tool_choice) |tool_choice| content.transformToolChoice(tool_choice) else null,
        .metadata = if (request.user) |user| .{ .user_id = user } else null,
    };
}

/// Free what `transformChatRequest` allocated: the system prompt, every turn's
/// content blocks (including the parsed `tool_use.input` trees), the message
/// slice, and the tool slice. Everything else borrows from the parsed inbound
/// request and is freed with it.
pub fn cleanupChatRequest(
    request: Messages.Request,
    allocator: std.mem.Allocator,
) void {
    if (request.system) |system_prompt| allocator.free(system_prompt);
    for (request.messages) |msg| {
        if (msg.content == .blocks) content.freeMessageBlocks(msg.content.blocks, allocator);
    }
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
}

/// Free a slice of inbound tool calls produced by this flow (each `function`
/// variant owns its serialized `arguments` string).
/// Anthropic response → inbound chat response.
pub fn transformChatResponse(
    upstream_response: Messages.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    // The upstream echoes the concrete model id it served. `original_req` is
    // kept for P8 response-signature uniformity (and future echo fields).
    _ = original_req;

    var message_text: ?[]const u8 = try content.extractTextFromBlocks(upstream_response.content, allocator);
    errdefer if (message_text) |t| allocator.free(t);

    // An empty text body is reported as `null` content, so the empty join is
    // dropped rather than carried as a zero-length string.
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
            .function_call = null,
        },
        .finish_reason = content.transformStopReason(upstream_response.stop_reason),
        .logprobs = null,
    };

    return .{
        // Duplicated: the caller keeps this after the upstream parse is freed.
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "chat.completion",
        .created = time.timestamp(),
        .model = try std.fmt.allocPrint(allocator, "anthropic/{s}", .{upstream_response.model}),
        .choices = choices,
        .usage = .{
            .prompt_tokens = upstream_response.usage.input_tokens,
            .completion_tokens = upstream_response.usage.output_tokens,
            .total_tokens = upstream_response.usage.input_tokens + upstream_response.usage.output_tokens,
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
        if (message.content) |text| allocator.free(text);
        if (message.tool_calls) |calls| content.freeToolCalls(calls, allocator);
    }
    allocator.free(inbound_response.choices);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
}

/// Serialize a chat `StreamChunk` into a `data: {json}\n\n` SSE line.
/// The chunk borrows from `state` and the caller's parsed event, so it is
/// consumed here immediately — no parse round-trip.
/// One Anthropic SSE line → zero or one chat-format SSE chunk, as ready bytes.
/// Parses the event, mutates `state`, and delegates byte formatting to
/// `content.buildChatChunk` (P6: all helpers in content.zig). Upstream `error`
/// events render into chat-format error bytes inline (P4).
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    // Cheap type probe first; a failure here may instead be an error payload.
    const type_info = std.json.parseFromSlice(
        struct { type: []const u8 },
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const bytes = content.formatChatErrorLine(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    };
    defer type_info.deinit();

    const event_type = type_info.value.type;

    if (std.mem.eql(u8, event_type, "error")) {
        const bytes = content.formatChatErrorLine(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        const parsed = std.json.parseFromSlice(
            Messages.MessageStart,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            log.debug("[anthropic] message_start parse failed: {}", .{err});
            return .{ .skip = {} };
        };
        defer parsed.deinit();

        // Id is owned by the state (the parsed event dies on return). Guarded so
        // a duplicate message_start can't leak the previous dupe.
        if (state.response_id.len == 0 and parsed.value.message.id.len > 0) {
            state.response_id = allocator.dupe(u8, parsed.value.message.id) catch return .{ .skip = {} };
        }
        state.input_tokens = parsed.value.message.usage.input_tokens;

        const bytes = content.buildChatChunk(.{
            .id = state.response_id,
            .created = state.created,
            .original_model = state.original_model,
        }, .{ .role = .assistant }, null, null, allocator) orelse return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const parsed = std.json.parseFromSlice(
            Messages.ContentBlockStart,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            log.debug("[anthropic] content_block_start parse failed: {}", .{err});
            return .{ .skip = {} };
        };
        defer parsed.deinit();

        // A `tool_use` block opens with id + name; text blocks wait for deltas.
        const block = parsed.value.content_block;
        if (!std.mem.eql(u8, block.type, "tool_use")) return .{ .skip = {} };

        const tool_calls = [_]Chat.DeltaToolCall{.{
            .index = parsed.value.index,
            .id = block.id,
            .type = "function",
            .function = .{ .name = block.name, .arguments = "" },
        }};
        const bytes = content.buildChatChunk(.{
            .id = state.response_id,
            .created = state.created,
            .original_model = state.original_model,
        }, .{ .tool_calls = &tool_calls }, null, null, allocator) orelse return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const parsed = std.json.parseFromSlice(
            Messages.ContentBlockDelta,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            log.debug("[anthropic] content_block_delta parse failed: {}", .{err});
            return .{ .skip = {} };
        };
        defer parsed.deinit();

        // Text or partial tool-call arguments; thinking deltas are skipped.
        const delta = parsed.value.delta;
        if (std.mem.eql(u8, delta.type, "text_delta")) {
            const text = delta.text orelse return .{ .skip = {} };
            const bytes = content.buildChatChunk(.{
                .id = state.response_id,
                .created = state.created,
                .original_model = state.original_model,
            }, .{ .content = text }, null, null, allocator) orelse return .{ .skip = {} };
            return .{ .output = bytes };
        }
        if (std.mem.eql(u8, delta.type, "input_json_delta")) {
            const partial = delta.partial_json orelse return .{ .skip = {} };
            const tool_calls = [_]Chat.DeltaToolCall{.{
                .index = parsed.value.index,
                .function = .{ .arguments = partial },
            }};
            const bytes = content.buildChatChunk(.{
                .id = state.response_id,
                .created = state.created,
                .original_model = state.original_model,
            }, .{ .tool_calls = &tool_calls }, null, null, allocator) orelse return .{ .skip = {} };
            return .{ .output = bytes };
        }
        return .{ .skip = {} };
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const parsed = std.json.parseFromSlice(
            Messages.MessageDelta,
            allocator,
            json_part,
            .{ .allocate = .alloc_always },
        ) catch |err| {
            log.debug("[anthropic] message_delta parse failed: {}", .{err});
            return .{ .skip = {} };
        };
        defer parsed.deinit();

        state.output_tokens = parsed.value.usage.output_tokens;
        const finish_reason = content.transformStopReason(parsed.value.delta.stop_reason);
        state.finish_reason = finish_reason;

        const usage = common.Usage{
            .prompt_tokens = state.input_tokens,
            .completion_tokens = state.output_tokens,
            .total_tokens = state.input_tokens + state.output_tokens,
        };
        const bytes = content.buildChatChunk(.{
            .id = state.response_id,
            .created = state.created,
            .original_model = state.original_model,
        }, .{}, finish_reason, usage, allocator) orelse return .{ .skip = {} };
        return .{ .output = bytes };
    }

    // message_stop, content_block_stop, ping, … — nothing to emit.
    return .{ .skip = {} };
}

// ============================================================================
// Flow: /v1/messages — inbound messages schema → Anthropic wire (pass-through)
// ============================================================================

/// Stream state for the messages pass-through flow: lines are forwarded verbatim,
/// the state exists only to carry usage out for metrics (P3).
pub const MessagesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        _ = self;
    }
};

/// Pass-through: keep the inbound Anthropic request, pin `model`.
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    _ = allocator;
    // Copy-and-override: the shallow copy borrows the inbound parse's slices,
    // and any field added to the wire type later rides along automatically —
    // which is exactly what a pass-through wants. The pipeline frees the
    // inbound parse; no ownership transfers here.
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
    _ = original_req;
    _ = allocator;
    return upstream_response;
}

/// Pass-through cleanup — nothing was allocated.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    _ = inbound_response;
    _ = allocator;
}

/// Forward one Anthropic SSE line verbatim, re-attaching the `event:` line the
/// SSE iterator strips, and accumulate usage into `state`. The forwarded line
/// is untouched — parsing here is only for metrics (P3/P4).
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) {
        // Non-data line (shouldn't happen with SSEIterator, but handle gracefully).
        const raw = std.fmt.allocPrint(allocator, "{s}\n", .{line}) catch return .{ .skip = {} };
        return .{ .output = raw };
    }
    const json_part = line["data: ".len..];

    // Probe the event type once; dispatch usage extraction on it (the old code
    // re-parsed every line three times).
    const type_probe = std.json.parseFromSlice(
        struct { type: []const u8 = "" },
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .output = std.fmt.allocPrint(allocator, "{s}\n\n", .{line}) catch return .{ .skip = {} } };
    defer type_probe.deinit();
    const event_type = type_probe.value.type;

    // Usage accumulation only — never mutate the forwarded line.
    if (std.mem.eql(u8, event_type, "message_start")) {
        if (std.json.parseFromSlice(Messages.MessageStart, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            state.input_tokens = parsed.value.message.usage.input_tokens;
        } else |_| {}
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        if (std.json.parseFromSlice(Messages.MessageDelta, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            state.output_tokens = parsed.value.usage.output_tokens;
        } else |_| {}
    }

    // Reconstruct proper SSE framing: "event: <type>\ndata: <json>\n\n".
    if (event_type.len > 0) {
        const framed = std.fmt.allocPrint(allocator, "event: {s}\n{s}\n\n", .{ event_type, line }) catch return .{ .skip = {} };
        return .{ .output = framed };
    }
    // No usable type field — emit the data line with proper SSE termination.
    const terminated = std.fmt.allocPrint(allocator, "{s}\n\n", .{line}) catch return .{ .skip = {} };
    return .{ .output = terminated };
}

// ============================================================================
// Flow: /v1/responses — inbound responses schema → Anthropic wire
// ============================================================================
// Conversion is written locally against the Anthropic Messages wire (P11): no
// delegation to another provider's transformer. `content.zig` is not used here —
// this flow shares no parsing with the chat/messages flows.

/// Stream state for the responses flow: accumulates the Anthropic message id,
/// terminal reason and usage so `flushResponsesStream` can synthesize the
/// closing Responses events.
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
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.response_id = "";
        self.finish_reason = null;
    }
};

/// Inbound responses request → Anthropic request (input items/messages →
/// messages, instructions → system, reasoning effort → thinking, betas,
/// service_tier, max_output_tokens → max_tokens), pinned to `model`.
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Messages.Request {
    var messages = std.ArrayList(Messages.Message).empty;
    errdefer messages.deinit(allocator);

    switch (request.input) {
        .text => |t| {
            try messages.append(allocator, .{ .role = .user, .content = .{ .text = t } });
        },
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const role_val = obj.get("role") orelse continue;
            if (role_val != .string) continue;
            const role: Messages.Role = if (std.mem.eql(u8, role_val.string, "assistant"))
                .assistant
            else
                .user;

            const content_val = obj.get("content") orelse continue;
            const text: []const u8 = switch (content_val) {
                .string => |s| s,
                .array => |arr| blk: {
                    // First non-empty text part wins; non-text parts (images,
                    // item references) have no Anthropic equivalent here.
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

            try messages.append(allocator, .{ .role = role, .content = .{ .text = text } });
        },
    }

    if (messages.items.len == 0) return error.EmptyMessages;

    // Tool definitions: function tools map through content.transformTools;
    // custom tools (no Anthropic equivalent) are skipped (P11 note in content.zig).
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

    return .{
        .model = model,
        .messages = try messages.toOwnedSlice(allocator),
        // Anthropic requires a positive max_tokens; mirror the old default.
        .max_tokens = request.max_output_tokens orelse 4096,
        .system = request.instructions,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stream = request.stream,
        .tools = tools,
        .tool_choice = content.responsesToolChoice(request.tool_choice),
        .thinking = request.thinking,
        .betas = request.betas,
        .service_tier = request.service_tier,
    };
}

pub fn cleanupResponsesRequest(
    request: Messages.Request,
    allocator: std.mem.Allocator,
) void {
    allocator.free(request.messages);
    if (request.tools) |tools| allocator.free(tools);
}

/// Anthropic response → inbound responses response (content blocks → output
/// items, stop_reason → status, usage passthrough) plus the request-echo
/// fields the Responses schema carries (temperature, top_p, …) which have no
/// upstream equivalent and are copied from `original_req`.
pub fn transformResponsesResponse(
    upstream_response: Messages.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    var output_items = std.ArrayList(Responses.OutputItem).empty;
    errdefer output_items.deinit(allocator);

    var parts = std.ArrayList(Responses.OutputContent).empty;
    errdefer parts.deinit(allocator);

    for (upstream_response.content) |block| {
        switch (block) {
            .text => |t| {
                if (t.text.len > 0) try parts.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, t.text),
                } });
            },
            .tool_use => |tu| {
                // Arguments: serialize the parsed input tree back to a JSON string.
                var args = std.ArrayList(u8).empty;
                defer args.deinit(allocator);
                try args.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});

                try output_items.append(allocator, .{ .function_call = .{
                    .id = try allocator.dupe(u8, tu.id),
                    .type = "function_call",
                    .name = try allocator.dupe(u8, tu.name),
                    .arguments = try args.toOwnedSlice(allocator),
                    .status = "completed",
                } });
            },
            .thinking, .redacted_thinking,
            .server_tool_use, .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result => {}, // no Responses equivalent
        }
    }

    const content_slice = try parts.toOwnedSlice(allocator);
    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .type = "message",
        .role = "assistant",
        .content = content_slice,
        .status = "completed",
    } });

    // stop_reason → status + incomplete_details
    var status: []const u8 = "completed";
    var incomplete_details: ?std.json.Value = null;
    if (upstream_response.stop_reason) |sr| {
        if (std.mem.eql(u8, sr, "max_tokens")) {
            status = "incomplete";
            // Build with owned strings: cleanupResponsesResponse frees the tree
            // via freeJsonValue, which frees keys and string values.
            var obj = std.json.ObjectMap.empty;
            const key = try allocator.dupe(u8, "reason");
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, "max_output_tokens");
            errdefer allocator.free(value);
            try obj.put(allocator, key, .{ .string = value });
            incomplete_details = .{ .object = obj };
        }
    }

    return .{
        .id = try allocator.dupe(u8, upstream_response.id),
        .object = "response",
        .created_at = 0,
        .model = try allocator.dupe(u8, original_req.model),
        .status = status,
        .output = try output_items.toOwnedSlice(allocator),
        .usage = .{
            .input_tokens = upstream_response.usage.input_tokens,
            .output_tokens = upstream_response.usage.output_tokens,
            .total_tokens = upstream_response.usage.input_tokens + upstream_response.usage.output_tokens,
        },
        .incomplete_details = incomplete_details,
        // Request-echo fields (no upstream equivalent — part of the Responses contract).
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
    };
}

/// Free what `transformResponsesResponse` allocated: id/model strings and the
/// output tree. Echo fields (metadata, temperature, …) borrow from
/// `original_req` and are freed with its parse.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    // `incomplete_details` is built here (ObjectMap) — free the value tree.
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
            .reasoning => {},
            .other => {},
        }
    }
    allocator.free(inbound_response.output);
}

/// One Anthropic SSE line → Responses SSE events as ready bytes; accumulates
/// id / usage / terminal reason into `state`.
///
/// Event mapping:
///   - `message_start`            → capture id + input usage, emit nothing
///   - `content_block_start`      → `response.output_item.added` + `response.content_part.added`
///   - `content_block_delta`      → text_delta → `response.output_text.delta`;
///                                  input_json_delta → `response.function_call_arguments.delta`
///   - `content_block_stop`       → `response.output_text.done` (text blocks only)
///   - `message_delta`            → capture output usage + terminal reason, emit nothing
///   - `message_stop`, `ping`, …  → skipped
///   - `error`                    → rendered inline as `response.failed` (P4)
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
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
        const bytes = content.formatResponsesError(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        const MsgStart = struct {
            message: struct {
                id: []const u8 = "",
                usage: struct { input_tokens: u32 = 0 } = .{},
            } = .{},
        };
        if (std.json.parseFromSlice(MsgStart, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            if (state.response_id.len == 0 and parsed.value.message.id.len > 0) {
                state.response_id = state.allocator.dupe(u8, parsed.value.message.id) catch "";
            }
            state.input_tokens = parsed.value.message.usage.input_tokens;
        } else |_| {}
        return .{ .skip = {} };
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const BlockStart = struct {
            content_block: struct {
                type: []const u8 = "",
            } = .{},
        };
        const parsed = std.json.parseFromSlice(BlockStart, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return .{ .skip = {} };
        defer parsed.deinit();
        const is_text = std.mem.eql(u8, parsed.value.content_block.type, "text");
        const bytes = content.responsesOutputItemAdded(state.response_id, is_text, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const Delta = struct {
            delta: struct {
                type: []const u8 = "",
                text: []const u8 = "",
                partial_json: []const u8 = "",
            } = .{},
        };
        const parsed = std.json.parseFromSlice(Delta, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return .{ .skip = {} };
        defer parsed.deinit();
        const delta = parsed.value.delta;

        if (std.mem.eql(u8, delta.type, "text_delta")) {
            if (delta.text.len == 0) return .{ .skip = {} };
            const bytes = content.allocFmt(
                allocator,
                "event: response.output_text.delta\ndata: {{\"type\":\"response.output_text.delta\",\"item_id\":\"{s}\",\"output_index\":0,\"content_index\":0,\"delta\":{f}}}\n\n",
                .{ state.response_id, std.json.fmt(delta.text, .{}) },
            ) orelse return .{ .skip = {} };
            return .{ .output = bytes };
        }
        if (std.mem.eql(u8, delta.type, "input_json_delta")) {
            if (delta.partial_json.len == 0) return .{ .skip = {} };
            const bytes = content.allocFmt(
                allocator,
                "event: response.function_call_arguments.delta\ndata: {{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"{s}\",\"output_index\":0,\"delta\":{f}}}\n\n",
                .{ state.response_id, std.json.fmt(delta.partial_json, .{}) },
            ) orelse return .{ .skip = {} };
            return .{ .output = bytes };
        }
        return .{ .skip = {} }; // thinking/signature deltas
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        const bytes = content.responsesOutputTextDone(state.response_id, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const MsgDelta = struct {
            delta: struct { stop_reason: []const u8 = "" } = .{},
            usage: struct { output_tokens: u32 = 0 } = .{},
        };
        if (std.json.parseFromSlice(MsgDelta, allocator, json_part, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            state.output_tokens = parsed.value.usage.output_tokens;
            const reason = parsed.value.delta.stop_reason;
            if (reason.len > 0) {
                // Own the reason: it borrows from `parsed`, which dies below.
                // message_delta arrives at most once upstream, but guard anyway
                // so a repeat can't leak the previous dupe.
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, reason) catch null;
            }
        } else |_| {}
        return .{ .skip = {} };
    }

    return .{ .skip = {} }; // message_stop, ping, unknown
}

/// Emit the terminal Responses events after the upstream stream ends
/// (`response.output_item.done` + `response.completed`, or `response.incomplete`
/// when the reason is `max_tokens`) with the usage accumulated in `state`.
/// Returns `null` when there is nothing to flush.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "max_tokens")) "incomplete" else "completed";
    const input_tok = state.input_tokens;
    const output_tok = state.output_tokens;

    return content.allocFmt(
        allocator,
        \\event: response.output_item.done
        \\data: {{"type":"response.output_item.done","item":{{"id":"{s}","type":"message","role":"assistant","status":"{s}"}}}}
        \\
        \\event: response.completed
        \\data: {{"type":"response.completed","response":{{"id":"{s}","object":"response","model":"{s}","status":"{s}","usage":{{"input_tokens":{d},"output_tokens":{d},"total_tokens":{d}}}}}}}
        \\
        \\
    ,
        .{ state.response_id, status, state.response_id, state.original_model, status, input_tok, output_tok, input_tok + output_tok },
    );
}
