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

//! Mapping internals for the openai provider's chat transformer.
//!
//! `pub` here means **internal to the openai provider** — these are support
//! functions for `chat_transformer.zig`, not a public API. Nothing outside
//! `src/core/providers/openai/` should import this module.
//!
//! Per P6: every helper lives here; `chat_transformer.zig` holds only the four
//! flow sections' main functions and stream states. Helpers are stateless —
//! stream state stays in `chat_transformer.zig`, so this module never imports
//! it (no cycle); main functions pass the needed fields explicitly.
//!
//! The openai provider is largely a pass-through (proxy and upstream both
//! speak OpenAI format), so most "mapping" here is ownership bookkeeping:
//! which fields are owned by the transformed value and freed on cleanup, and
//! which borrow from the inbound parse.

const std = @import("std");
const common = @import("types.zig"); // shared primitives

const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Chat = @import("chat_types.zig"); // chat schema (proxy + upstream wire)
const log = @import("../../log.zig");

// ============================================================================
// Error parsing (chat stream)
// ============================================================================

/// Try to parse a raw SSE payload as an OpenAI error response. All strings in
/// the result are freshly allocated — free with `freeError`. Returns null when
/// the payload is not an error.
pub fn tryParseError(json_part: []const u8, allocator: std.mem.Allocator) ?common.ErrorResponse {
    const parsed = std.json.parseFromSlice(
        common.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    // Own the strings: the parse dies below (bug #3 class — never return
    // slices into a Parsed that is freed).
    return .{ .@"error" = .{
        .message = allocator.dupe(u8, parsed.value.@"error".message) catch return null,
        .type = allocator.dupe(u8, parsed.value.@"error".type) catch return null,
        .param = blk: {
            const p = parsed.value.@"error".param orelse break :blk null;
            break :blk allocator.dupe(u8, p) catch return null;
        },
        .code = blk: {
            const c = parsed.value.@"error".code orelse break :blk null;
            break :blk allocator.dupe(u8, c) catch return null;
        },
    } };
}

/// Free an error response returned by `tryParseError`.
pub fn freeError(error_response: common.ErrorResponse, allocator: std.mem.Allocator) void {
    allocator.free(error_response.@"error".message);
    allocator.free(error_response.@"error".type);
    if (error_response.@"error".param) |v| allocator.free(v);
    if (error_response.@"error".code) |v| allocator.free(v);
}

/// Render a chat error into `data: {json}\n\n` bytes (caller frees), or null
/// on allocation failure.
pub fn formatChatError(
    error_response: common.ErrorResponse,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(error_response, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Parse a raw SSE payload as an error and render it to chat-format bytes
/// (P4). Returns null when the payload is not an error.
pub fn formatChatErrorLine(
    json_part: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const error_response = tryParseError(json_part, allocator) orelse return null;
    defer freeError(error_response, allocator);
    log.warn("[openai] [chat-stream] upstream error: {s}", .{error_response.@"error".message});
    return formatChatError(error_response, allocator);
}

// ============================================================================
// Chat streaming support (stateless)
// ============================================================================

/// Everything a chat chunk carries besides its delta.
pub const ChatChunkContext = struct {
    id: []const u8,
    created: i64,
    original_model: []const u8,
    system_fingerprint: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
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
        .id = if (ctx.id.len > 0) ctx.id else "chatcmpl-unknown",
        .object = "chat.completion.chunk",
        .created = ctx.created,
        .model = ctx.original_model,
        .choices = &choices,
        .usage = usage,
        .system_fingerprint = ctx.system_fingerprint,
        .service_tier = ctx.service_tier,
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(chunk, .{})}) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Messages flow support (Anthropic wire → chat wire)
// ============================================================================

/// Map chat finish_reason to the Messages-wire stop_reason vocabulary.
pub fn transformStopReasonToMessages(finish_reason: []const u8) []const u8 {
    if (std.mem.eql(u8, finish_reason, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish_reason, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish_reason, "tool_calls")) return "tool_use";
    return "end_turn";
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

/// Free a messages-flow response's content blocks: the owned tool_use id/name
/// and the leaky-parsed argument trees. Text block strings are dupes too.
/// (Bug #17 fix: the old code leaked the parse arena and left the copied value
/// dangling after scope exit.)
pub fn freeMessageOwnedBlocks(blocks: []const Messages.ContentBlock, allocator: std.mem.Allocator) void {
    for (blocks) |block| {
        switch (block) {
            .text => |tb| allocator.free(tb.text),
            .tool_use => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                freeParsedJsonValue(tu.input, allocator);
            },
            .thinking, .redacted_thinking,
            .server_tool_use, .tool_result, .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result => {},
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

// ============================================================================
// Messages flow streaming support (stateless)
// ============================================================================

/// Opening frames of the synthesized Messages protocol: `message_start`
/// (with the served model) and `content_block_start`. Concatenated bytes are
/// owned by the caller. Returns null on allocation failure.
pub fn messagesOpen(
    original_model: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(allocator,
        \\event: message_start
        \\data: {{"type":"message_start","message":{{"id":"msg_proxy","type":"message","role":"assistant","content":[],"model":"{s}","stop_reason":null,"stop_sequence":null,"usage":{{"input_tokens":0,"output_tokens":0}}}}}}
        \\
        \\event: content_block_start
        \\data: {{"type":"content_block_start","index":0,"content_block":{{"type":"text","text":""}}}}
        \\
        \\
    , .{original_model}) catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

/// Closing frames of the synthesized Messages protocol: `content_block_stop`,
/// `message_delta` (terminal reason + output tokens), `message_stop`.
pub fn messagesClose(
    stop_reason: []const u8,
    output_tokens: u32,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(allocator,
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
    return out.toOwnedSlice(allocator) catch null;
}

/// Free a tool_choice object built by the messages-flow request transform
/// (the `.tool` case): the two nested ObjectMaps' entry storage. Keys and
/// values are static literals — NOT freed here.
pub fn freeBuiltToolChoice(tool_choice: std.json.Value, allocator: std.mem.Allocator) void {
    switch (tool_choice) {
        .object => |obj| {
            if (obj.get("function")) |fv| {
                if (fv == .object) {
                    var inner = fv.object;
                    inner.deinit(allocator);
                }
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        else => {}, // string modes are static literals
    }
}

/// Free a messages-flow request's message as built by the reverse transform:
/// duped text (except system messages, which borrow the inbound system string)
/// and tool-call argument strings. The slice itself is freed by the caller.
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
            allocator.free(tc.function.arguments);
        }
        allocator.free(tool_calls);
    }
}
