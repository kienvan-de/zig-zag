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

//! Mapping helpers for the openai provider's chat transformer.
//! Internal to the openai provider — only for chat_transformer.zig.
//! Stateless value-to-value transforms and ownership helpers.
//! No serialization — the transformer returns typed structs; callers serialize.

const std = @import("std");
const common = @import("types.zig");
const Messages = @import("../anthropic/types.zig");
const Chat = @import("chat_types.zig");
const log = @import("../../log.zig");

// ============================================================================
// Error helpers (chat stream)
// ============================================================================

/// Parse a raw SSE payload as an OpenAI ErrorResponse.
/// All strings are freshly duped — caller owns via freeError.
/// Returns null when the payload is not a recognisable error.
pub fn tryParseError(json_part: []const u8, allocator: std.mem.Allocator) ?common.ErrorResponse {
    const parsed = std.json.parseFromSlice(
        common.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const src = parsed.value.@"error";
    const msg = allocator.dupe(u8, src.message) catch return null;
    errdefer allocator.free(msg);
    const typ = allocator.dupe(u8, src.type) catch return null;
    errdefer allocator.free(typ);
    const param: ?[]const u8 = if (src.param) |p| allocator.dupe(u8, p) catch null else null;
    const code: ?[]const u8 = if (src.code) |c| allocator.dupe(u8, c) catch null else null;
    return .{ .@"error" = .{ .message = msg, .type = typ, .param = param, .code = code } };
}

/// Free an ErrorResponse returned by tryParseError.
pub fn freeError(err: common.ErrorResponse, allocator: std.mem.Allocator) void {
    allocator.free(err.@"error".message);
    allocator.free(err.@"error".type);
    if (err.@"error".param) |v| allocator.free(v);
    if (err.@"error".code) |v| allocator.free(v);
}

// ============================================================================
// Messages flow — stop-reason mapping
// ============================================================================

/// Map a chat finish_reason to the Anthropic Messages stop_reason vocabulary.
pub fn transformStopReasonToMessages(finish_reason: []const u8) []const u8 {
    if (std.mem.eql(u8, finish_reason, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish_reason, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish_reason, "tool_calls")) return "tool_use";
    return "end_turn";
}

// ============================================================================
// Messages flow — tool argument parsing
// ============================================================================

/// Leaky-parse tool-call arguments JSON into a std.json.Value.
/// On failure returns an empty object.
pub fn parseToolArguments(arguments: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch
        .{ .object = .{} };
}

// ============================================================================
// Messages flow — owned-block lifecycle
// ============================================================================

/// Recursively free a leaky-parsed JSON tree (keys + string leaves owned).
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
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        else => {},
    }
}

/// Free a Messages-flow response content-block slice.
/// .text: duped text string. .tool_use: duped id/name + leaky input tree.
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
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }
}

// ============================================================================
// Messages flow — request lifecycle
// ============================================================================

/// Free a tool_choice object built by the messages-flow request transform
/// (the .tool case): frees the two nested ObjectMaps' entry storage.
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
        else => {},
    }
}

/// Free a messages-flow request message built by the reverse transform:
/// all text content is duped (including system messages), tool-call argument strings + slice.
pub fn freeMessageOwnedText(msg: Chat.Message, allocator: std.mem.Allocator) void {
    if (msg.content) |c| {
        switch (c) {
            .text => |text| allocator.free(text),
            .parts => {},
        }
    }
    if (msg.tool_calls) |tool_calls| {
        for (tool_calls) |tc| allocator.free(tc.function.arguments);
        allocator.free(tool_calls);
    }
}

// ============================================================================
// SSE serialization
// ============================================================================

/// Write a single `chat.completion.chunk` as `data: {json}\n\n` to `buf`.
pub fn writeChatSSE(
    chunk: Chat.StreamChunk,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    try buf.print(allocator, "data: {f}\n\n", .{std.json.fmt(chunk, .{})});
}
