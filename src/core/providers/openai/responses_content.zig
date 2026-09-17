// SPDX-License-Identifier: Apache-2.0
//! Mapping helpers for the openai provider's responses transformer.
//! Internal — only for responses_transformer.zig.
//! Stateless value-to-value transforms and ownership helpers.

const std = @import("std");
const common = @import("types.zig");
const Chat = @import("chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Responses = @import("responses_types.zig");

// ============================================================================
// Request bridging helpers (chat face: Chat.Message → Responses input item)
// ============================================================================

/// Serialize a Chat.Message to a JSON object value for a Responses request
/// `input[]` array. The returned tree is leaky-allocated — freed by freeInputItem.
pub fn chatMessageToInputItem(message: Chat.Message, allocator: std.mem.Allocator) !std.json.Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(message, .{ .emit_null_optional_fields = false })});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, buf.items, .{ .allocate = .alloc_always });
}

/// Free an input item tree built by chatMessageToInputItem or by the messages
/// face (where keys are duped strings).
pub fn freeInputItem(value: std.json.Value, allocator: std.mem.Allocator) void {
    freeParsedJsonValue(value, allocator);
}

// ============================================================================
// Messages flow support
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
            .server_tool_use, .tool_result,
            .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }
}

/// Leaky-parse tool-call arguments JSON into an owned tree for a tool_use block.
/// Unparseable arguments become an empty object.
pub fn parseToolArguments(arguments: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch
        .{ .object = .{} };
}

/// Free a chat tool-call list (id, name, arguments are all duped strings).
pub fn freeChatToolCallList(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tc| {
        allocator.free(tc.id);
        allocator.free(tc.function.name);
        allocator.free(tc.function.arguments);
    }
    allocator.free(tool_calls);
}

// ============================================================================
// Responses pass-through helpers
// ============================================================================

/// Wrap a raw byte slice as a single-element ResponsesStreamLineResult.
pub fn wrapRawBytes(bytes: []const u8, allocator: std.mem.Allocator) Responses.ResponsesStreamLineResult {
    const evs = allocator.alloc(Responses.StreamEvent, 1) catch {
        allocator.free(bytes);
        return .{ .skip = {} };
    };
    evs[0] = .{ .raw_bytes = bytes };
    return .{ .events = evs };
}

/// Dupe `line` with a trailing `\n\n` and wrap as a pass-through event.
pub fn passThrough(allocator: std.mem.Allocator, line: []const u8) Responses.ResponsesStreamLineResult {
    const bytes = std.fmt.allocPrint(allocator, "{s}\n\n", .{line}) catch return .{ .skip = {} };
    return wrapRawBytes(bytes, allocator);
}
