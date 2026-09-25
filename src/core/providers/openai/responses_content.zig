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
            // Synthesized thinking blocks own their `thinking` text (signature is
            // an empty string literal — not freed).
            .thinking => |tb| allocator.free(tb.thinking),
            .redacted_thinking,
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

/// Extract the reasoning text from a Responses `reasoning` output item, joining
/// the `summary[].text` entries (and falling back to `content[].text`). Returns
/// a freshly-allocated string the caller owns, or null if there is no text.
/// Used to surface reasoning when down-converting Responses → Chat/Messages
/// instead of dropping the reasoning item.
pub fn extractReasoningText(
    item: Responses.OutputItemReasoning,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    // summary is a JSON array of {type:"summary_text", text:"..."} objects.
    if (item.summary) |s| if (s == .array) {
        for (s.array.items) |entry| {
            if (entry != .object) continue;
            if (entry.object.get("text")) |t| {
                if (t == .string and t.string.len > 0) try parts.append(allocator, t.string);
            }
        }
    };
    // content is a typed slice of reasoning content parts, each {text:"..."}.
    for (item.content) |entry| {
        if (entry != .object) continue;
        if (entry.object.get("text")) |t| {
            if (t == .string and t.string.len > 0) try parts.append(allocator, t.string);
        }
    }

    if (parts.items.len == 0) return null;
    return try std.mem.join(allocator, "", parts.items);
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

// ============================================================================
// SSE serialization
// ============================================================================

/// Write a single SSE event to `buf` using the Responses stream format:
///   event: {type}\ndata: {json}\n\n
pub fn writeResponsesSSE(
    event: Responses.StreamEvent,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
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
