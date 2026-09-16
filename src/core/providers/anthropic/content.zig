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

//! Mapping helpers for the Anthropic provider — internal to this provider.
//! Stateless value-to-value transforms shared across the four flow functions in transformer.zig.

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
    content_val: MessageContent,
    allocator: std.mem.Allocator,
) ![]Messages.ContentBlockParam {
    var blocks = std.ArrayList(Messages.ContentBlockParam).empty;
    errdefer blocks.deinit(allocator);

    switch (content_val) {
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
                    .input_audio, .file => {
                        // No Anthropic equivalent for audio/file content parts.
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

    return try blocks.toOwnedSlice(allocator);
}

/// Re-shape an inbound tool/function result into one Anthropic `tool_result` block.
pub fn transformToolResult(
    tool_call_id: []const u8,
    content_val: ?MessageContent,
    allocator: std.mem.Allocator,
) !Messages.ContentBlockParam {
    _ = allocator;

    const text: ?[]const u8 = if (content_val) |c| switch (c) {
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
        .content = if (text) |t| .{ .text = t } else null,
        .is_error = null,
    } };
}

/// Map inbound tool definitions (Chat.Tool[]) to Anthropic tool definitions.
/// A missing `parameters` becomes an empty input schema (Anthropic requires it).
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

/// Map Responses.Tool[] to Anthropic tool definitions.
/// Only `.function` tools map; built-in tool types are skipped (no Anthropic equivalent).
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
            .web_search_preview, .file_search, .code_interpreter_tool, .mcp_tool, .other => {},
        }
    }

    return try mapped.toOwnedSlice(allocator);
}

/// Map inbound `tool_choice` (Chat raw JSON) to Anthropic `ToolChoice`.
/// `"none"` returns `null` — Anthropic has no "decline tools" choice.
/// Allocates nothing; returns borrowed/static values.
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

/// Map Responses-API `tool_choice` (JSON value) to Anthropic `ToolChoice`.
/// Shapes: "none" | "auto" | "required" | {"type":"function","name":"..."}
pub fn responsesToolChoice(tool_choice: ?std.json.Value) ?Messages.ToolChoice {
    const value = tool_choice orelse return null;
    switch (value) {
        .string => |mode| {
            if (std.mem.eql(u8, mode, "none")) return .{ .none = .{ .type = "none" } };
            if (std.mem.eql(u8, mode, "required")) return .{ .any = .{ .type = "any" } };
            return .{ .auto = .{ .type = "auto" } };
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

/// Normalize an inbound message list into Anthropic turns: drop system/developer
/// (caller extracts them first), fold `tool`/`function` roles into `user`
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

    var pending = std.ArrayList(Messages.ContentBlockParam).empty;
    defer pending.deinit(allocator);
    var pending_role: ?Messages.Role = null;

    for (messages) |msg| {
        if (msg.role == .system or msg.role == .developer) continue;

        const role: Messages.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system, .developer => unreachable,
            .tool => .user,
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
            if (msg.tool_calls) |tool_calls| {
                const tool_use_blocks = try transformToolCalls(tool_calls, allocator);
                defer allocator.free(tool_use_blocks);
                try blocks.appendSlice(allocator, tool_use_blocks);
            }
        }

        if (blocks.items.len == 0) continue;

        if (pending_role) |open_role| {
            if (open_role == role) {
                try pending.appendSlice(allocator, blocks.items);
                continue;
            }
            if (pending.items.len > 0) {
                try normalized.append(allocator, .{
                    .role = open_role,
                    .content = .{ .blocks = try pending.toOwnedSlice(allocator) },
                });
            }
        }

        try pending.appendSlice(allocator, blocks.items);
        pending_role = role;
    }

    if (pending_role) |open_role| {
        if (pending.items.len > 0) {
            try normalized.append(allocator, .{
                .role = open_role,
                .content = .{ .blocks = try pending.toOwnedSlice(allocator) },
            });
        }
    }

    if (normalized.items.len == 0) return error.EmptyMessages;

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
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
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

/// Map an Anthropic `stop_reason` to an inbound Chat finish reason.
/// Unknown or absent reasons degrade to `"stop"`. Allocates nothing.
pub fn transformStopReason(stop_reason: ?[]const u8) []const u8 {
    const reason = stop_reason orelse return "stop";
    if (std.mem.eql(u8, reason, "max_tokens")) return "length";
    if (std.mem.eql(u8, reason, "tool_use")) return "tool_calls";
    // "end_turn", "stop_sequence", "pause_turn" and anything else
    return "stop";
}

/// Join Anthropic text blocks into one string. Non-text blocks are skipped.
/// Returns an empty (allocated) string when there is no text.
/// Freshly allocated — caller owns it.
pub fn extractTextFromBlocks(
    blocks: []const Messages.ContentBlock,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    for (blocks) |block| {
        switch (block) {
            .text => |t| if (t.text.len > 0) try parts.append(allocator, t.text),
            .tool_use, .server_tool_use, .thinking, .redacted_thinking,
            .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }

    if (parts.items.len == 0) return try allocator.dupe(u8, "");
    return try std.mem.join(allocator, "", parts.items);
}

/// Collect Anthropic `tool_use` blocks into inbound Chat tool calls, serializing
/// each block's `input` object into the `arguments` JSON string.
/// Returns `null` when the response has no tool calls.
/// Freshly allocated — caller owns the slice and each `arguments` string.
pub fn extractToolCalls(
    blocks: []const Messages.ContentBlock,
    allocator: std.mem.Allocator,
) !?[]Chat.ToolCall {
    var tool_calls = std.ArrayList(Chat.ToolCall).empty;
    errdefer {
        for (tool_calls.items) |tc| allocator.free(tc.function.arguments);
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
            .text, .server_tool_use, .thinking, .redacted_thinking,
            .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }

    if (tool_calls.items.len == 0) return null;
    return try tool_calls.toOwnedSlice(allocator);
}

/// Map an Anthropic error payload to the common error shape.
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

/// Best-effort parse of a raw JSON payload as an Anthropic error, mapped to
/// the common error shape. Returns `null` when the payload is not an error.
///
/// Ownership: `message` and `code` are freshly duplicated and become the
/// caller's property. `type` is a static literal — never free it.
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
            .type = mapped.@"error".type,
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

/// Everything a chat chunk carries besides its delta.
pub const ChatChunkContext = struct {
    id: []const u8,
    created: i64,
    original_model: []const u8,
};

/// Serialize one `chat.completion.chunk` as a ready `data: {json}\n\n` line.
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

/// Render a chat-schema error into `data: {json}\n\n` bytes.
pub fn formatChatError(
    error_response: common.ErrorResponse,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf = std.ArrayList(u8).empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(error_response, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Parse a raw SSE payload as an Anthropic error and render it to chat-format
/// `data: {json}\n\n` bytes. Returns null when the payload is not an error.
pub fn formatChatErrorLine(
    json_part: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const error_response = tryParseError(json_part, allocator) orelse return null;
    defer freeError(error_response, allocator);
    log.warn("[anthropic] [chat-stream] upstream error: {s}", .{error_response.@"error".message});
    return formatChatError(error_response, allocator);
}

/// Free a `tool_calls` slice as built by `extractToolCalls`.
pub fn freeToolCalls(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tool_call| {
        allocator.free(tool_call.function.arguments);
    }
    allocator.free(tool_calls);
}

// ============================================================================
// Responses flow SSE helpers (stateless)
// ============================================================================

/// Write a single SSE event to `buf` using the Responses stream format:
///   event: {type}\ndata: {json}\n\n
/// The `StreamEvent.jsonStringify` writes only the JSON payload; the SSE
/// framing (`event:` line) is added here.
pub fn writeResponsesSSE(
    event: Responses.StreamEvent,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    // Derive the `event:` type string from the event tag name (which matches
    // the `type` field value). Use std.json.fmt to serialize the payload.
    const type_str: []const u8 = switch (event) {
        .response_created => "response.created",
        .response_in_progress => "response.in_progress",
        .response_completed => "response.completed",
        .response_failed => "response.failed",
        .response_incomplete => "response.incomplete",
        .output_item_added => "response.output_item.added",
        .output_item_done => "response.output_item.done",
        .content_part_added => "response.content_part.added",
        .content_part_done => "response.content_part.done",
        .output_text_delta => "response.output_text.delta",
        .output_text_done => "response.output_text.done",
        .function_call_arguments_delta => "response.function_call_arguments.delta",
        .function_call_arguments_done => "response.function_call_arguments.done",
        .stream_error => "error",
        .response_queued => "response.queued",
        .output_text_annotation_added => "response.output_text.annotation.added",
        .refusal_delta => "response.refusal.delta",
        .refusal_done => "response.refusal.done",
        .reasoning_text_delta => "response.reasoning_text.delta",
        .reasoning_text_done => "response.reasoning_text.done",
        .reasoning_summary_part_added => "response.reasoning_summary_part.added",
        .reasoning_summary_part_done => "response.reasoning_summary_part.done",
        .reasoning_summary_text_delta => "response.reasoning_summary_text.delta",
        .reasoning_summary_text_done => "response.reasoning_summary_text.done",
        .web_search_call_in_progress => "response.web_search_call.in_progress",
        .web_search_call_searching => "response.web_search_call.searching",
        .web_search_call_completed => "response.web_search_call.completed",
        .file_search_call_in_progress => "response.file_search_call.in_progress",
        .file_search_call_searching => "response.file_search_call.searching",
        .file_search_call_completed => "response.file_search_call.completed",
        .code_interpreter_call_in_progress => "response.code_interpreter_call.in_progress",
        .code_interpreter_call_code_delta => "response.code_interpreter_call_code.delta",
        .code_interpreter_call_code_done => "response.code_interpreter_call_code.done",
        .code_interpreter_call_interpreting => "response.code_interpreter_call.interpreting",
        .code_interpreter_call_completed => "response.code_interpreter_call.completed",
        .mcp_list_tools_in_progress => "response.mcp_list_tools.in_progress",
        .mcp_list_tools_completed => "response.mcp_list_tools.completed",
        .mcp_list_tools_failed => "response.mcp_list_tools.failed",
        .mcp_call_arguments_delta => "response.mcp_call_arguments.delta",
        .mcp_call_arguments_done => "response.mcp_call_arguments.done",
        .mcp_call_in_progress => "response.mcp_call.in_progress",
        .mcp_call_completed => "response.mcp_call.completed",
        .mcp_call_failed => "response.mcp_call.failed",
        .image_generation_call_in_progress => "response.image_generation_call.in_progress",
        .image_generation_call_generating => "response.image_generation_call.generating",
        .image_generation_call_partial_image => "response.image_generation_call.partial_image",
        .image_generation_call_completed => "response.image_generation_call.completed",
        .audio_delta => "response.audio.delta",
        .audio_done => "response.audio.done",
        .audio_transcript_delta => "response.audio.transcript.delta",
        .audio_transcript_done => "response.audio.transcript.done",
        .shell_call_command_added => "response.shell_call_command.added",
        .shell_call_command_delta => "response.shell_call_command.delta",
        .shell_call_command_done => "response.shell_call_command.done",
        .shell_call_output_delta => "response.shell_call_output_content.delta",
        .shell_call_output_done => "response.shell_call_output_content.done",
        .custom_tool_call_input_delta => "response.custom_tool_call_input.delta",
        .custom_tool_call_input_done => "response.custom_tool_call_input.done",
        .response_compaction_compacting => "response.compaction.compacting",
        .raw_bytes => "",
    };

    if (event == .raw_bytes) {
        try buf.appendSlice(allocator, event.raw_bytes);
        return;
    }

    try buf.print(allocator, "event: {s}\ndata: {f}\n\n", .{ type_str, std.json.fmt(event, .{}) });
}
