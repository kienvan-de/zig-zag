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

//! Mapping internals for the openai provider's responses transformer.
//!
//! `pub` here means **internal to the openai provider** — support functions
//! for `responses_transformer.zig`, not a public API.
//!
//! Per P6: every helper lives here; `responses_transformer.zig` holds only
//! the four flow sections' main functions and stream states. Helpers are
//! stateless — stream state stays in `responses_transformer.zig`, so this
//! module never imports it (no cycle).
//!
//! The upstream speaks the Responses API wire; the three inbound faces
//! (chat / messages / responses) are bridged onto it.

const std = @import("std");

const Chat = @import("chat_types.zig"); // chat schema
const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Responses = @import("responses_types.zig"); // Responses API wire types

// ============================================================================
// Request bridging helpers
// ============================================================================

/// Serialize a chat message into a JSON object value for a Responses request's
/// `input[]` items (chat face). The returned tree is leaky-allocated with
/// `allocator` — freed by `freeInputItem`.
pub fn chatMessageToInputItem(message: Chat.Message, allocator: std.mem.Allocator) !std.json.Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(message, .{ .emit_null_optional_fields = false })});

    // BUG #23 fix: the old code used arena parseFromSlice, copied .value into
    // the items list, then freed the arena at loop end -> dangling trees.
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, buf.items, .{ .allocate = .alloc_always });
}

/// Free an input item tree produced by `chatMessageToInputItem`.
pub fn freeInputItem(value: std.json.Value, allocator: std.mem.Allocator) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeInputItem(entry.value_ptr.*, allocator);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        .array => |arr| {
            for (arr.items) |item| freeInputItem(item, allocator);
            arr.deinit();
        },
        .string => |str| allocator.free(str),
        .number_string => |str| allocator.free(str),
        else => {},
    }
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

/// Serialize one `chat.completion.chunk` as ready `data: {json}\n\n` bytes
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
        .id = if (ctx.id.len > 0) ctx.id else "resp_unknown",
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

/// Free a messages-flow response's content blocks: the owned tool_use id/name
/// and the leaky-parsed argument trees. Text block strings are dupes too.
/// (Bug #17 fix pattern: the old code leaked the parse arena and left the
/// copied value dangling after scope exit.)
pub fn freeMessageOwnedBlocks(blocks: []const Messages.ContentBlock, allocator: std.mem.Allocator) void {
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

/// Parse tool-call `arguments` into an owned JSON tree for a tool_use block
/// (messages flow response). Leaky parse with `allocator` — freed by
/// `freeMessageOwnedBlocks`. Unparseable arguments become an empty object.
pub fn parseToolArguments(
    arguments: []const u8,
    allocator: std.mem.Allocator,
) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch
        .{ .object = .{} };
}

/// Free a chat tool-call list as built by the chat-face response transform:
/// each function variant owns id, name, and arguments.
pub fn freeChatToolCallList(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tc| {
        switch (tc) {
            .function => |f| {
                allocator.free(f.id);
                allocator.free(f.function.name);
                allocator.free(f.function.arguments);
            },
            .custom => {},
        }
    }
    allocator.free(tool_calls);
}

/// Render a `response.failed` payload as chat-format error bytes (P4), or
/// null when the payload has no usable message. The message string is
/// borrowed from `json_part` and formatted immediately.
pub fn formatFailedEvent(json_part: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const ErrPayload = struct {
        @"error": ?struct {
            message: ?[]const u8 = null,
        } = null,
    };
    var message: []const u8 = "Upstream response failed";

    if (std.json.parseFromSlice(ErrPayload, allocator, json_part, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    })) |parsed| {
        defer parsed.deinit();
        if (parsed.value.@"error") |err_val| {
            if (err_val.message) |m| message = m;
        }
    } else |_| {}

    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator, "data: {{\"error\":{{\"message\":{f},\"type\":\"server_error\",\"code\":null,\"param\":null}}}}\n\n", .{
        std.json.fmt(message, .{}),
    }) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Messages flow support (Responses wire → Messages wire)
// ============================================================================

/// Opening frames of the synthesized Messages protocol (message_start +
/// content_block_start), used lazily on the first text delta and by the
/// closer when the stream never opened. Owned bytes.
pub fn messagesOpen(
    original_model: []const u8,
    input_tokens: u32,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator,
        \\event: message_start
        \\data: {{"type":"message_start","message":{{"id":"msg_proxy","type":"message","role":"assistant","content":[],"model":"{s}","stop_reason":null,"stop_sequence":null,"usage":{{"input_tokens":{d},"output_tokens":0}}}}}}
        \\
        \\event: content_block_start
        \\data: {{"type":"content_block_start","index":0,"content_block":{{"type":"text","text":""}}}}
        \\
        \\
    , .{ original_model, input_tokens }) catch return null;
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
