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

// ============================================================================
// Stop-reason mapping
// ============================================================================

// ============================================================================
// Messages face helpers (Anthropic wire ↔ chat payload)
// ============================================================================

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

/// Free the empty-string content replacements made by `normalizeNonNullContent`.
///
/// Only for callers that hold a borrowed (not chat-owned) message list and
/// therefore need to free the replacements themselves. When the list was
/// allocated by `chat_transformer`, its own cleanup frees every `.text` content
/// and this must NOT be called (it would double free).
pub fn freeNormalizedContent(msg: Chat.Message, allocator: std.mem.Allocator) void {
    if (msg.content) |c| switch (c) {
        .text => |text| if (text.len == 0) allocator.free(text),
        .parts => {},
    };
}

/// Replace null message content with an empty string, mutating the slice in place.
///
/// SAP AI Core's orchestration schema rejects `content: null` — it requires an
/// empty string instead. `chat_transformer` produces nullable `content` per the
/// chat-completions contract (e.g. a message that is only a tool call), so every
/// message crossing into the SAP envelope is normalized here, in place, on the
/// very slice `chat_transformer` allocated. That keeps a single owner: the
/// delegated `Chat.Request`, freed by `chat_transformer.cleanupMessagesRequest`.
///
/// Each replacement is an owned empty string allocated with the same allocator,
/// so `chat_content.freeMessageOwnedText` (which frees every `.text` content)
/// frees it exactly once alongside the rest — no separate bookkeeping needed.
pub fn normalizeNonNullContent(
    messages: []Chat.Message,
    allocator: std.mem.Allocator,
) !void {
    for (messages) |*msg| {
        if (msg.content == null) {
            msg.content = .{ .text = try allocator.dupe(u8, "") };
        }
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
