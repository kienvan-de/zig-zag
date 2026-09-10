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

//! Mapping internals for the anthropic provider.
//!
//! `pub` here means **internal to the anthropic provider** — these are support
//! functions for `transformer.zig`, not a public API. Nothing outside
//! `src/core/providers/anthropic/` should import this module.
//!
//! Per P6: every helper lives here; `transformer.zig` holds only the four flow
//! sections' main functions and stream states. Helpers are stateless — stream
//! state stays in `transformer.zig`, so this module never imports it (no
//! cycle); main functions pass the needed fields explicitly.
//!
//! Scope (P6/P11): pure value-to-value mapping helpers shared by the flow
//! sections of `transformer.zig`. Deliberately **stateless** — no function here
//! takes a stream state, because the states are owned by `transformer.zig`
//! (P3) and importing them back here would create an import cycle. Stream-event
//! handlers therefore live with their flow section.

const std = @import("std");

const Messages = @import("types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // inbound chat schema (shapes only)
const Responses = @import("../openai/responses_types.zig"); // Responses API schema
const common = @import("../openai/types.zig"); // shared primitives (ToolFunction)
const log = @import("../../log.zig");

const MessageContent = Chat.MessageContent;

// ============================================================================
// Inbound chat schema → Anthropic wire (request side)
// ============================================================================

/// Collect `system` / `developer` messages into one Anthropic system prompt.
/// Returns `null` when the conversation has no system turn. The result is a
/// fresh allocation (`std.mem.join`) — the caller owns it.
pub fn extractSystemPrompt(
    messages: []const Chat.Message,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    for (messages) |msg| {
        if (msg.role != .system and msg.role != .developer) continue;

        const text: []const u8 = if (msg.content) |c| switch (c) {
            .text => |s| s,
            .parts => |content_parts| blk: {
                // Multi-part system content: each text part becomes its own entry.
                for (content_parts) |part| {
                    if (part == .text) try parts.append(allocator, part.text.text);
                }
                break :blk "";
            },
        } else "";

        if (text.len > 0) try parts.append(allocator, text);
    }

    if (parts.items.len == 0) return null;
    return try std.mem.join(allocator, "\n\n", parts.items);
}

/// Re-shape one inbound chat content value into Anthropic content blocks.
/// The returned slice is freshly allocated — the caller owns it.
pub fn transformContent(
    content: MessageContent,
    allocator: std.mem.Allocator,
) ![]Messages.ContentBlockParam {
    var blocks = std.ArrayList(Messages.ContentBlockParam).empty;
    errdefer blocks.deinit(allocator);

    switch (content) {
        .text => |text| try blocks.append(allocator, .{ .text = .{ .type = "text", .text = text } }),
        .parts => |parts| {
            for (parts) |part| {
                switch (part) {
                    .text => |text_part| try blocks.append(allocator, .{
                        .text = .{ .type = "text", .text = text_part.text },
                    }),
                    .image_url => |image_part| {
                        const url = image_part.image_url.url;
                        if (std.mem.startsWith(u8, url, "data:")) {
                            // data:<media_type>;base64,<data>
                            const comma_idx = std.mem.indexOfScalar(u8, url, ',') orelse return error.UnsupportedContentType;
                            const semicolon_idx = std.mem.indexOfScalar(u8, url[5..], ';') orelse return error.UnsupportedContentType;
                            try blocks.append(allocator, .{ .image = .{
                                .type = "image",
                                .source = .{ .base64 = .{
                                    .type = "base64",
                                    .media_type = url[5 .. 5 + semicolon_idx],
                                    .data = url[comma_idx + 1 ..],
                                } },
                            } });
                        } else {
                            try blocks.append(allocator, .{ .image = .{
                                .type = "image",
                                .source = .{ .url = .{ .type = "url", .url = url } },
                            } });
                        }
                    },
                }
            }
        },
    }

    return try blocks.toOwnedSlice(allocator);
}

/// Re-shape inbound tool calls into Anthropic `tool_use` blocks. Arguments are
/// parsed into `std.json.Value`; unparseable arguments become an empty input
/// object rather than failing the whole request. Freshly allocated — caller owns it.
pub fn transformToolCalls(
    tool_calls: []const Chat.ToolCall,
    allocator: std.mem.Allocator,
) ![]Messages.ContentBlockParam {
    var blocks = std.ArrayList(Messages.ContentBlockParam).empty;
    errdefer blocks.deinit(allocator);

    for (tool_calls) |tool_call| {
        {
            // Arguments arrive as a JSON string; Anthropic wants an object.
            var input: std.json.Value = .{ .object = std.json.ObjectMap{} };
            if (std.json.parseFromSliceLeaky(std.json.Value, allocator, tool_call.function.arguments, .{})) |parsed| {
                input = parsed;
            } else |_| {}
            try blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = tool_call.id,
                .name = tool_call.function.name,
                .input = input,
            } });
        }
    }

    return try blocks.toOwnedSlice(allocator);
}

/// Re-shape an inbound tool/function result into one Anthropic `tool_result`
/// block. Borrows the content slice — allocates nothing.
pub fn transformToolResult(
    tool_call_id: []const u8,
    content: ?MessageContent,
    allocator: std.mem.Allocator,
) !Messages.ContentBlockParam {
    _ = allocator;

    const text: ?[]const u8 = if (content) |c| switch (c) {
        .text => |t| t,
        .parts => |parts| blk: {
            for (parts) |part| {
                if (part == .text) break :blk part.text.text;
            }
            break :blk null;
        },
    } else null;

    return .{ .tool_result = .{
        .type = "tool_result",
        .tool_use_id = tool_call_id,
        .content = text,
        .is_error = null,
    } };
}

/// Map inbound tool definitions to Anthropic tool definitions. A missing
/// `parameters` becomes an empty input schema (Anthropic requires the field).
/// Freshly allocated — caller owns it.
pub fn transformTools(
    tools: []const common.ToolFunction,
    allocator: std.mem.Allocator,
) ![]Messages.Tool {
    var mapped = std.ArrayList(Messages.Tool).empty;
    errdefer mapped.deinit(allocator);

    for (tools) |f| {
        try mapped.append(allocator, .{
            .name = f.name,
            .description = f.description,
            .input_schema = f.parameters orelse std.json.Value{ .object = std.json.ObjectMap{} },
        });
    }

    return try mapped.toOwnedSlice(allocator);
}

pub fn transformResponsesTools(
    tools: []const Responses.Tool,
    allocator: std.mem.Allocator,
) ![]Messages.Tool {
    var mapped = std.ArrayList(Messages.Tool).empty;
    errdefer mapped.deinit(allocator);

    for (tools) |tool| {
        switch (tool) {
            .function => |f| try mapped.append(allocator, .{
                .name = f.function.name,
                .description = f.function.description,
                .input_schema = f.function.parameters orelse std.json.Value{ .object = std.json.ObjectMap{} },
            }),
            .other => {}, // No Anthropic equivalent for custom/built-in tools.
        }
    }

    return try mapped.toOwnedSlice(allocator);
}

/// Map inbound `tool_choice` (raw JSON) to Anthropic `tool_choice`.
/// `"none"` returns `null` — Anthropic has no "decline tools" choice, so the
/// field is omitted instead. Allocates nothing; returns borrowed/static values.
pub fn transformToolChoice(
    tool_choice: std.json.Value,
) ?Messages.ToolChoice {
    switch (tool_choice) {
        .string => |mode| {
            if (std.mem.eql(u8, mode, "none")) return null;
            if (std.mem.eql(u8, mode, "required")) return .{ .any = .{ .type = "any" } };
            return .{ .auto = .{ .type = "auto" } }; // "auto" and unknown modes
        },
        .object => |obj| {
            // {"type":"function","function":{"name":"..."}}
            if (obj.get("function")) |func_val| {
                if (func_val == .object) {
                    if (func_val.object.get("name")) |name_val| {
                        if (name_val == .string) {
                            return .{ .tool = .{ .type = "tool", .name = name_val.string } };
                        }
                    }
                }
            }
            return .{ .auto = .{ .type = "auto" } };
        },
        else => return .{ .auto = .{ .type = "auto" } },
    }
}

/// Normalize an inbound message list into Anthropic turns: drop system/developer
/// (the caller extracts them first), fold `tool`/`function` roles into `user`
/// `tool_result` blocks, merge consecutive same-role turns, guarantee the
/// conversation opens with a user turn, and reject an empty result.
/// Freshly allocated — caller owns the slice and each message's blocks.
pub fn normalizeMessages(
    messages: []const Chat.Message,
    allocator: std.mem.Allocator,
) ![]Messages.Message {
    var normalized = std.ArrayList(Messages.Message).empty;
    errdefer {
        for (normalized.items) |msg| {
            if (msg.content == .blocks) freeMessageBlocks(msg.content.blocks, allocator);
        }
        normalized.deinit(allocator);
    }

    // Blocks of the turn currently being accumulated.
    var pending = std.ArrayList(Messages.ContentBlockParam).empty;
    defer pending.deinit(allocator);
    var pending_role: ?Messages.Role = null;

    for (messages) |msg| {
        // System turns are the caller's responsibility (extractSystemPrompt).
        if (msg.role == .system or msg.role == .developer) continue;

        const role: Messages.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system, .developer => unreachable, // filtered above
            .tool => .user, // tool responses ride the user turn
        };

        var blocks = std.ArrayList(Messages.ContentBlockParam).empty;
        defer blocks.deinit(allocator);

        if (msg.role == .tool) {
            try blocks.append(allocator, try transformToolResult(msg.tool_call_id orelse "", msg.content, allocator));
        } else {
            if (msg.content) |c| {
                const transformed = try transformContent(c, allocator);
                defer allocator.free(transformed);
                try blocks.appendSlice(allocator, transformed);
            }
            // Assistant messages may carry only tool calls (content null).
            if (msg.tool_calls) |tool_calls| {
                const tool_use_blocks = try transformToolCalls(tool_calls, allocator);
                defer allocator.free(tool_use_blocks);
                try blocks.appendSlice(allocator, tool_use_blocks);
            }
        }

        if (blocks.items.len == 0) continue;

        // Same role as the open turn → keep accumulating; otherwise flush it.
        if (pending_role) |open_role| {
            if (open_role == role) {
                try pending.appendSlice(allocator, blocks.items);
                continue;
            }
            if (pending.items.len > 0) {
                // toOwnedSlice leaves `pending` empty; the next turn starts fresh.
                try normalized.append(allocator, .{
                    .role = open_role,
                    .content = .{ .blocks = try pending.toOwnedSlice(allocator) },
                });
            }
        }

        try pending.appendSlice(allocator, blocks.items);
        pending_role = role;
    }

    // Flush the last open turn.
    if (pending_role) |open_role| {
        if (pending.items.len > 0) {
            try normalized.append(allocator, .{
                .role = open_role,
                .content = .{ .blocks = try pending.toOwnedSlice(allocator) },
            });
        }
    }

    if (normalized.items.len == 0) return error.EmptyMessages;

    // Anthropic requires a user-first conversation; an assistant-first one gets
    // a synthetic opener. Allocated (not a static literal) so the cleanup
    // function can free every message's blocks uniformly.
    if (normalized.items[0].role != .user) {
        const synthetic = try allocator.alloc(Messages.ContentBlockParam, 1);
        synthetic[0] = .{ .text = .{ .type = "text", .text = "[Conversation start]" } };
        try normalized.insert(allocator, 0, .{
            .role = .user,
            .content = .{ .blocks = synthetic },
        });
    }

    return try normalized.toOwnedSlice(allocator);
}

// ============================================================================
// Anthropic wire → inbound chat schema (response side)
// ============================================================================

/// Recursively free everything a parsed dynamic `std.json.Value` owns.
///
/// Zig 0.16's `std.json.Value` has no `deinit`, and `Parsed(Value).deinit()`
/// can't be used when the value is handed to the outgoing request (it would
/// dangle). Callers that embed a parsed value must free it through here.
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator); // frees the hash table's backing memory
        },
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var owned = arr;
            owned.deinit(); // Managed list — frees via its own stored allocator
        },
        .string, .number_string => |s| allocator.free(s),
        .null, .bool, .integer, .float => {},
    }
}

/// Free the blocks of one Anthropic message produced by this provider.
/// Only `tool_use.input` is owned (parsed here); every other block field
/// borrows from the inbound parsed request.
pub fn freeMessageBlocks(
    blocks: []const Messages.ContentBlockParam,
    allocator: std.mem.Allocator,
) void {
    for (blocks) |block| {
        if (block == .tool_use) freeJsonValue(allocator, block.tool_use.input);
    }
    allocator.free(blocks);
}

/// Map an Anthropic `stop_reason` to an inbound finish reason.
/// Unknown or absent reasons degrade to `"stop"`. Allocates nothing.
pub fn transformStopReason(stop_reason: ?[]const u8) []const u8 {
    const reason = stop_reason orelse return "stop";
    if (std.mem.eql(u8, reason, "max_tokens")) return "length";
    if (std.mem.eql(u8, reason, "tool_use")) return "tool_calls";
    // "end_turn", "stop_sequence" and anything else
    return "stop";
}

/// Join Anthropic text blocks into one string. `tool_use` and thinking blocks
/// are not text and are skipped. Returns an empty (allocated) string when there
/// is no text. Freshly allocated — caller owns it.
pub fn extractTextFromBlocks(
    blocks: []const Messages.ContentBlock,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    for (blocks) |block| {
        switch (block) {
            .text => |t| if (t.text.len > 0) try parts.append(allocator, t.text),
            .tool_use, .thinking, .redacted_thinking,
            .server_tool_use, .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result => {},
        }
    }

    if (parts.items.len == 0) return try allocator.dupe(u8, "");
    return try std.mem.join(allocator, "", parts.items);
}

/// Collect Anthropic `tool_use` blocks into inbound tool calls, serializing each
/// block's `input` object into the `arguments` JSON string.
/// Returns `null` when the response has no tool calls. Freshly allocated —
/// caller owns the slice and each `arguments` string.
pub fn extractToolCalls(
    blocks: []const Messages.ContentBlock,
    allocator: std.mem.Allocator,
) !?[]Chat.ToolCall {
    var tool_calls = std.ArrayList(Chat.ToolCall).empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.function.arguments);
        }
        tool_calls.deinit(allocator);
    }

    for (blocks) |block| {
        switch (block) {
            .tool_use => |tu| {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(allocator);
                try buf.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});
                try tool_calls.append(allocator, .{
                    .id = tu.id,
                    .type = "function",
                    .function = .{
                        .name = tu.name,
                        .arguments = try buf.toOwnedSlice(allocator),
                    },
                });
            },
            .text, .thinking, .redacted_thinking,
            .server_tool_use, .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result => {},
        }
    }

    if (tool_calls.items.len == 0) return null;
    return try tool_calls.toOwnedSlice(allocator);
}

/// Map an Anthropic error payload to the chat-schema error shape.
/// Anthropic's finer-grained types all collapse onto the two inbound ones:
/// everything client-side is `invalid_request_error`, everything provider-side
/// is `server_error`. The original Anthropic type is preserved in `code`.
/// Borrows the message; allocates nothing.
pub fn transformErrorResponse(
    error_response: Messages.ErrorResponse,
) common.ErrorResponse {
    const kind = error_response.@"error".type;
    const provider_side = std.mem.eql(u8, kind, "overloaded_error");

    return .{ .@"error" = .{
        .message = error_response.@"error".message,
        .type = if (provider_side) "server_error" else "invalid_request_error",
        .param = null,
        .code = kind,
    } };
}

/// Best-effort parse of a raw JSON payload as an Anthropic error, mapped to the
/// chat-schema error shape. Returns `null` when the payload is not an error.
///
/// Ownership: `message` and `code` are **freshly duplicated** and become the
/// caller's property (the parsed tree dies inside this function, so borrowing
/// from it would dangle). `type` is a static literal — never free it.
pub fn tryParseError(
    json_part: []const u8,
    allocator: std.mem.Allocator,
) ?common.ErrorResponse {
    const parsed = std.json.parseFromSlice(
        Messages.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const mapped = transformErrorResponse(parsed.value);

    const message = allocator.dupe(u8, mapped.@"error".message) catch return null;
    errdefer allocator.free(message);

    var code: ?[]const u8 = null;
    if (mapped.@"error".code) |c| {
        code = allocator.dupe(u8, c) catch null;
    }

    return .{
        .@"error" = .{
            .message = message,
            .type = mapped.@"error".type, // static literal, not owned
            .param = null,
            .code = code,
        },
    };
}

/// Free what `tryParseError` returned.
pub fn freeError(error_response: common.ErrorResponse, allocator: std.mem.Allocator) void {
    allocator.free(error_response.@"error".message);
    if (error_response.@"error".code) |code| allocator.free(code);
}

// ============================================================================
// Chat streaming support (stateless)
// ============================================================================
// Byte formatting for one chat chunk / one error line. Stateless by design:
// the stream state lives in `transformer.zig`, and the caller passes the few
// fields a chunk needs, so `content.zig` never imports `transformer.zig`
// (no cycle). Parsing and state mutation stay in the flow's main function.

/// Everything a chat chunk carries besides its delta.
pub const ChatChunkContext = struct {
    id: []const u8,
    created: i64,
    original_model: []const u8,
};

/// Serialize one `chat.completion.chunk` as a ready `data: {json}\n\n` line.
/// The chunk borrows from `ctx` and `delta`, so the caller writes the result
/// immediately.
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
        .id = if (ctx.id.len > 0) ctx.id else "msg_unknown",
        .object = "chat.completion.chunk",
        .created = ctx.created,
        .model = ctx.original_model,
        .choices = &choices,
        .usage = usage,
    };

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(chunk, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Render a chat-schema error into `data: {json}\n\n` bytes, or null on
/// allocation failure. The error's owned strings stay with the caller
/// (free with `freeError` afterwards).
pub fn formatChatError(
    error_response: common.ErrorResponse,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf = std.ArrayList(u8).empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(error_response, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Parse a raw SSE payload as an Anthropic error and render it to chat-format
/// `data: {json}\n\n` bytes (P4: errors are formatted inside the provider).
/// Returns null when the payload is not an error or allocation fails.
pub fn formatChatErrorLine(
    json_part: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const error_response = tryParseError(json_part, allocator) orelse return null;
    defer freeError(error_response, allocator);
    log.warn("[anthropic] [chat-stream] upstream error: {s}", .{error_response.@"error".message});
    return formatChatError(error_response, allocator);
}

/// Free a `tool_calls` slice as built by `extractToolCalls`: each function
/// variant owns its `arguments` string, and the slice itself is owned.
pub fn freeToolCalls(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tool_call| {
        allocator.free(tool_call.function.arguments);
    }
    allocator.free(tool_calls);
}

// ============================================================================
// Responses flow support (stateless)
// ============================================================================

/// Map a Responses-API `tool_choice` (JSON value) to the Anthropic wire shape.
/// Shapes: "none" | "auto" | "required" | {"type":"function","name":"..."} —
/// note the Responses API carries the name at the top level (no nested
/// `function` object like chat). Anything unmappable falls back to `auto`.
pub fn responsesToolChoice(tool_choice: ?std.json.Value) ?Messages.ToolChoice {
    const value = tool_choice orelse return null;
    switch (value) {
        .string => |mode| {
            if (std.mem.eql(u8, mode, "none")) return .{ .none = .{ .type = "none" } };
            if (std.mem.eql(u8, mode, "required")) return .{ .any = .{ .type = "any" } };
            return .{ .auto = .{ .type = "auto" } }; // "auto" and unknown
        },
        .object => |obj| {
            const type_val = obj.get("type") orelse return .{ .auto = .{ .type = "auto" } };
            if (type_val != .string) return .{ .auto = .{ .type = "auto" } };
            if (std.mem.eql(u8, type_val.string, "function")) {
                if (obj.get("name")) |name_val| {
                    if (name_val == .string) {
                        return .{ .tool = .{ .type = "tool", .name = name_val.string } };
                    }
                }
            }
            return .{ .auto = .{ .type = "auto" } };
        },
        else => return .{ .auto = .{ .type = "auto" } },
    }
}


