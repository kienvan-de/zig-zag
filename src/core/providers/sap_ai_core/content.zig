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

//! Mapping internals for the sap_ai_core provider.
//!
//! `pub` here means **internal to the sap_ai_core provider** — support
//! functions for `transformer.zig`, not a public API.
//!
//! Per P6: every helper lives here; `transformer.zig` holds only the four
//! flow sections' main functions and stream states. Helpers are stateless —
//! stream state stays in `transformer.zig`, so this module never imports it
//! (no cycle).
//!
//! The SAP AI Core wire is an orchestration envelope: requests wrap chat
//! messages in `config.modules.prompt_templating`, responses wrap a chat
//! response as `final_result`. Most mapping here is envelope building and
//! ownership transfer of the inner chat objects.

const std = @import("std");

const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // chat schema (envelope payload)
const Responses = @import("../openai/responses_types.zig"); // inbound responses schema
const Sap = @import("types.zig"); // SAP AI Core wire types

// ============================================================================
// Request envelope
// ============================================================================

/// Sampling params extracted from any inbound request, mapped onto the SAP
/// `model.params` object.
pub const SapParams = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
};

/// Build the `model.params` object from the given fields. Returns null when
/// no field is set (the object is omitted on the wire). The returned value
/// owns its map — freed by `freeParams`.
pub fn buildParams(
    sap_params: SapParams,
    allocator: std.mem.Allocator,
) !?std.json.Value {
    var params_obj: std.json.ObjectMap = .{};
    errdefer params_obj.deinit(allocator);

    if (sap_params.temperature) |v| try params_obj.put(allocator, "temperature", .{ .float = v });
    if (sap_params.max_tokens) |v| try params_obj.put(allocator, "max_tokens", .{ .integer = @intCast(v) });
    if (sap_params.top_p) |v| try params_obj.put(allocator, "top_p", .{ .float = v });

    if (params_obj.count() == 0) return null;
    return .{ .object = params_obj };
}

/// Free a params value built by `buildParams` (keys are static literals —
/// only the map storage is freed).
pub fn freeParams(params: std.json.Value, allocator: std.mem.Allocator) void {
    if (params == .object) {
        var obj = params.object;
        obj.deinit(allocator);
    }
}

/// Map chat finish_reason to the Messages-wire stop_reason vocabulary.
pub fn transformStopReasonToMessages(finish_reason: []const u8) []const u8 {
    if (std.mem.eql(u8, finish_reason, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish_reason, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish_reason, "tool_calls")) return "tool_use";
    return "end_turn";
}

// ============================================================================
// Response deep-copy (SAP envelopes own their inner chat objects; the
// transformed result must outlive the client response's parse arena)
// ============================================================================

/// Deep-copy a chat response message (all strings freshly allocated).
pub fn dupeResponseMessage(
    allocator: std.mem.Allocator,
    msg: Chat.ResponseMessage,
) !Chat.ResponseMessage {
    return .{
        .role = msg.role,
        .content = if (msg.content) |c| try allocator.dupe(u8, c) else null,
        .tool_calls = if (msg.tool_calls) |tcs| blk: {
            const duped = try allocator.alloc(Chat.ToolCall, tcs.len);
            errdefer allocator.free(duped);
            for (tcs, 0..) |tc, i| {
                duped[i] = switch (tc) {
                    .function => |f| .{ .function = .{
                        .id = try allocator.dupe(u8, f.id),
                        .type = try allocator.dupe(u8, f.type),
                        .function = .{
                            .name = try allocator.dupe(u8, f.function.name),
                            .arguments = try allocator.dupe(u8, f.function.arguments),
                        },
                    } },
                    .custom => |c| .{ .custom = .{
                        .id = try allocator.dupe(u8, c.id),
                        .type = try allocator.dupe(u8, c.type),
                        .custom = c.custom,
                    } },
                };
            }
            break :blk duped;
        } else null,
        .function_call = if (msg.function_call) |fc| .{
            .name = try allocator.dupe(u8, fc.name),
            .arguments = try allocator.dupe(u8, fc.arguments),
        } else null,
    };
}

/// Deep-copy a chat response choice.
pub fn dupeResponseChoice(
    allocator: std.mem.Allocator,
    choice: Chat.ResponseChoice,
) !Chat.ResponseChoice {
    return .{
        .index = choice.index,
        .message = try dupeResponseMessage(allocator, choice.message),
        .finish_reason = try allocator.dupe(u8, choice.finish_reason),
        .logprobs = choice.logprobs, // json.Value managed separately
    };
}

/// Free a deep-copied chat response message.
pub fn freeResponseMessage(allocator: std.mem.Allocator, msg: Chat.ResponseMessage) void {
    if (msg.content) |c| allocator.free(c);
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            switch (tc) {
                .function => |f| {
                    allocator.free(f.id);
                    allocator.free(f.type);
                    allocator.free(f.function.name);
                    allocator.free(f.function.arguments);
                },
                .custom => |c| {
                    allocator.free(c.id);
                    allocator.free(c.type);
                },
            }
        }
        allocator.free(tcs);
    }
    if (msg.function_call) |fc| {
        allocator.free(fc.name);
        allocator.free(fc.arguments);
    }
}

// ============================================================================
// Error mapping (SAP numeric codes → OpenAI error shape)
// ============================================================================

/// Map a SAP numeric status to the OpenAI string code + error type.
/// (Static literals — no ownership.)
pub fn mapErrorCode(code: ?i64) struct { code: ?[]const u8, type: []const u8 } {
    const openai_code: ?[]const u8 = if (code) |c| switch (c) {
        400 => "bad_request",
        401 => "invalid_api_key",
        403 => "forbidden",
        404 => "not_found",
        429 => "rate_limit_exceeded",
        500 => "server_error",
        503 => "service_unavailable",
        else => "unknown_error",
    } else null;

    const error_type: []const u8 = if (code) |c|
        if (c >= 400 and c < 500) "invalid_request_error" else "server_error"
    else
        "server_error";

    return .{ .code = openai_code, .type = error_type };
}

/// Parse a raw SSE payload as a SAP error and render it to chat-format
/// `data: {json}\n\n` bytes (P4). Returns null when the payload is not an
/// error. The message string is duped before the parse is freed (bug #3 class).
pub fn formatSapErrorLine(
    json_part: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        Sap.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const mapped = mapErrorCode(parsed.value.@"error".code);
    const message = allocator.dupe(
        u8,
        parsed.value.@"error".message orelse "Unknown error from SAP AI Core",
    ) catch return null;
    defer allocator.free(message);

    const error_response = Chat.ErrorResponse{ .@"error" = .{
        .message = message,
        .type = mapped.type,
        .param = null,
        .code = mapped.code,
    } };

    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(error_response, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Chat streaming support (stateless)
// ============================================================================

/// Everything a chat chunk carries besides its delta.
pub const ChatChunkContext = struct {
    id: []const u8,
    created: i64,
    original_model: []const u8,
};

/// Serialize one `chat.completion.chunk` as ready `data: {json}\n\n` bytes.
pub fn buildChatChunk(
    ctx: ChatChunkContext,
    delta: Chat.Delta,
    finish_reason: ?[]const u8,
    usage: ?Chat.Usage,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const choices = [_]Chat.StreamChoice{.{
        .index = 0,
        .delta = delta,
        .finish_reason = finish_reason,
    }};

    const chunk = Chat.StreamChunk{
        .id = if (ctx.id.len > 0) ctx.id else "chatcmpl-sap",
        .object = "chat.completion.chunk",
        .created = ctx.created,
        .model = ctx.original_model,
        .choices = &choices,
        .usage = usage,
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(chunk, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Messages flow support (Responses-wire-style synth protocol, [DONE]-keyed)
// ============================================================================

/// Opening frames of the synthesized Messages protocol (message_start +
/// content_block_start). Owned bytes.
pub fn messagesOpen(
    original_model: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator,
        \\event: message_start
        \\data: {{"type":"message_start","message":{{"id":"msg_proxy","type":"message","role":"assistant","content":[],"model":"{s}","stop_reason":null,"stop_sequence":null,"usage":{{"input_tokens":0,"output_tokens":0}}}}}}
        \\
        \\event: content_block_start
        \\data: {{"type":"content_block_start","index":0,"content_block":{{"type":"text","text":""}}}}
        \\
        \\
    , .{original_model}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Closing frames (content_block_stop + message_delta + message_stop).
pub fn messagesClose(
    stop_reason: []const u8,
    output_tokens: u32,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator,
        \\event: content_block_stop
        \\data: {{"type":"content_block_stop","index":0}}
        \\
        \\event: message_delta
        \\data: {{"type":"message_delta","delta":{{"stop_reason":"{s}","stop_sequence":null}},"usage":{{"output_tokens":{d}}}}}
        \\
        \\event: message_stop
        \\data: {{"type":"message_stop"}}
        \\
        \\
    , .{ stop_reason, output_tokens }) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Messages face helpers (Anthropic wire ↔ chat payload)
// ============================================================================

/// Parse tool-call `arguments` into an owned JSON tree (leaky with
/// `allocator` — freed by `freeMessageOwnedBlocks`). Unparseable arguments
/// become an empty object.
pub fn parseToolArguments(
    arguments: []const u8,
    allocator: std.mem.Allocator,
) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch
        .{ .object = .{} };
}

/// Free a leaky-parsed JSON tree (keys AND allocated string leaves owned).
pub fn freeParsedJsonValue(value: std.json.Value, allocator: std.mem.Allocator) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeParsedJsonValue(entry.value_ptr.*, allocator);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        .array => |arr| {
            for (arr.items) |item| freeParsedJsonValue(item, allocator);
            arr.deinit();
        },
        .string => |str| allocator.free(str),
        .number_string => |str| allocator.free(str),
        else => {},
    }
}

/// Free a messages-flow response's content blocks (duped strings + leaky
/// trees). Bug #17 fix pattern.
pub fn freeMessageOwnedBlocks(
    blocks: []const Messages.ContentBlock,
    allocator: std.mem.Allocator,
) void {
    for (blocks) |block| {
        switch (block) {
            .text => |tb| allocator.free(tb.text),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                freeParsedJsonValue(tu.input, allocator);
            },
            .thinking, .redacted_thinking => {},
        }
    }
}

/// Free a messages-flow request's message: duped text (except system, which
/// borrows) and tool-call argument strings.
pub fn freeMessageOwnedText(msg: Chat.Message, allocator: std.mem.Allocator) void {
    if (msg.content) |c| {
        switch (c) {
            .text => |text| {
                if (msg.role != .system) allocator.free(text);
            },
            .parts => {},
        }
    }
    if (msg.tool_calls) |tool_calls| {
        for (tool_calls) |tc| {
            switch (tc) {
                .function => |f| allocator.free(f.function.arguments),
                .custom => {},
            }
        }
        allocator.free(tool_calls);
    }
}
