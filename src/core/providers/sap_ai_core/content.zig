// SPDX-License-Identifier: Apache-2.0
//! Mapping helpers for the sap_ai_core provider.
//! Internal — only for transformer.zig.
//! Stateless value-to-value transforms and ownership helpers.

const std = @import("std");
const Chat = @import("../openai/chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Sap = @import("types.zig");

// ============================================================================
// Models filter
// ============================================================================

/// A SAP model is usable only when it has a latest non-deprecated version
/// and supports the "orchestration" scenario.
pub fn isOrchestrationCapable(sap_model: Sap.SapModel) bool {
    var has_latest = false;
    for (sap_model.versions) |version| {
        if (version.isLatest and !version.deprecated) has_latest = true;
    }
    if (!has_latest) return false;
    for (sap_model.allowedScenarios) |scenario| {
        if (std.mem.eql(u8, scenario.scenarioId, "orchestration")) return true;
    }
    return false;
}

// ============================================================================
// Request envelope helpers
// ============================================================================

/// Sampling fields forwarded to SAP model params.
pub const SapParams = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
};

/// Build the `model.params` object from sampling fields.
/// Returns null when all fields are null (object omitted on the wire).
/// The returned value owns its map — freed by `freeParams`.
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

// ============================================================================
// Response deep-copy (SAP envelopes own their inner chat objects)
// ============================================================================

/// Deep-copy a chat response message (all strings freshly allocated).
pub fn dupeResponseMessage(
    allocator: std.mem.Allocator,
    msg: Chat.ResponseMessage,
) !Chat.ResponseMessage {
    const duped_content: ?[]const u8 = if (msg.content) |c| try allocator.dupe(u8, c) else null;
    errdefer if (duped_content) |c| allocator.free(c);

    const duped_tool_calls: ?[]const Chat.ToolCall = if (msg.tool_calls) |tcs| blk: {
        const duped = try allocator.alloc(Chat.ToolCall, tcs.len);
        var filled: usize = 0;
        errdefer {
            for (duped[0..filled]) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.type);
                allocator.free(tc.function.name);
                allocator.free(tc.function.arguments);
            }
            allocator.free(duped);
        }
        for (tcs, 0..) |tc, i| {
            const entry_id = try allocator.dupe(u8, tc.id);
            errdefer allocator.free(entry_id);
            const entry_type = try allocator.dupe(u8, tc.type);
            errdefer allocator.free(entry_type);
            const entry_name = try allocator.dupe(u8, tc.function.name);
            errdefer allocator.free(entry_name);
            const entry_args = try allocator.dupe(u8, tc.function.arguments);
            duped[i] = .{
                .id = entry_id,
                .type = entry_type,
                .function = .{ .name = entry_name, .arguments = entry_args },
            };
            filled += 1;
        }
        break :blk duped;
    } else null;

    return .{
        .role = msg.role,
        .content = duped_content,
        .tool_calls = duped_tool_calls,
    };
}

/// Deep-copy a chat response choice.
pub fn dupeResponseChoice(
    allocator: std.mem.Allocator,
    choice: Chat.ResponseChoice,
) !Chat.ResponseChoice {
    const msg = try dupeResponseMessage(allocator, choice.message);
    errdefer freeResponseMessage(allocator, msg);
    return .{
        .index = choice.index,
        .message = msg,
        .finish_reason = try allocator.dupe(u8, choice.finish_reason),
        .logprobs = null,
    };
}

/// Free a deep-copied chat response message.
pub fn freeResponseMessage(allocator: std.mem.Allocator, msg: Chat.ResponseMessage) void {
    if (msg.content) |c| allocator.free(c);
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.type);
            allocator.free(tc.function.name);
            allocator.free(tc.function.arguments);
        }
        allocator.free(tcs);
    }
}

// ============================================================================
// Stop-reason mapping
// ============================================================================

/// Map a chat finish_reason to the Messages-wire stop_reason vocabulary.
pub fn transformStopReasonToMessages(finish_reason: []const u8) []const u8 {
    if (std.mem.eql(u8, finish_reason, "stop")) return "end_turn";
    if (std.mem.eql(u8, finish_reason, "length")) return "max_tokens";
    if (std.mem.eql(u8, finish_reason, "tool_calls")) return "tool_use";
    return "end_turn";
}

// ============================================================================
// Messages face helpers (Anthropic wire ↔ chat payload)
// ============================================================================

/// Leaky-parse tool-call arguments into an owned JSON tree for a tool_use block.
/// Unparseable arguments become an empty object.
pub fn parseToolArguments(
    arguments: []const u8,
    allocator: std.mem.Allocator,
) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch
        .{ .object = .{} };
}

/// Free a leaky-parsed JSON tree (keys + string leaves owned).
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

/// Free a messages-flow response content-block slice.
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
            .thinking, .redacted_thinking,
            .server_tool_use, .tool_result,
            .web_search_tool_result, .web_fetch_tool_result,
            .code_execution_tool_result, .bash_code_execution_tool_result,
            .text_editor_code_execution_tool_result, .tool_search_tool_result,
            .fallback => {},
        }
    }
}

/// Free a messages-flow request message: duped text content (except system,
/// which borrows) and tool-call argument strings.
pub fn freeMessageOwnedText(msg: Chat.Message, allocator: std.mem.Allocator) void {
    if (msg.content) |c| switch (c) {
        .text => |text| if (msg.role != .system) allocator.free(text),
        .parts => {},
    };
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| allocator.free(tc.function.arguments);
        allocator.free(tcs);
    }
}

/// Map a SAP numeric error code to an OpenAI error type string.
pub fn sapErrorType(err: Sap.ErrorDetails) []const u8 {
    return if (err.code) |c|
        if (c >= 400 and c < 500) "invalid_request_error" else "server_error"
    else
        "server_error";
}

/// Map a SAP numeric error code to an OpenAI error code string.
pub fn sapErrorCode(err: Sap.ErrorDetails) ?[]const u8 {
    return if (err.code) |c| switch (c) {
        400 => "bad_request",
        401 => "invalid_api_key",
        403 => "forbidden",
        404 => "not_found",
        429 => "rate_limit_exceeded",
        500 => "server_error",
        503 => "service_unavailable",
        else => "unknown_error",
    } else null;
}
