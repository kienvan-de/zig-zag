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
const constraints = @import("../constraints.zig");
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
            // Synthesized thinking blocks own their `thinking` text (signature is
            // an empty string literal — not freed).
            .thinking => |tb| allocator.free(tb.thinking),
            .redacted_thinking,
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
            .parts => |parts| {
                // Multimodal down-convert (Messages→Chat) owns each part's string:
                // text part → joined text; image_url part → data URI / url.
                for (parts) |part| switch (part) {
                    .text => |t| allocator.free(t.text),
                    .image_url => |iu| allocator.free(iu.image_url.url),
                    // input_audio/file are not produced by the down-convert; if
                    // present they were not allocated here — nothing to free.
                    .input_audio, .file => {},
                };
                allocator.free(parts);
            },
        }
    }
    if (msg.tool_calls) |tool_calls| {
        for (tool_calls) |tc| {
            allocator.free(tc.function.name);
            allocator.free(tc.function.arguments);
        }
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

// ============================================================================
// Tool-name constraint helpers (normalize on request, reverse on response)
// ============================================================================
//
// OpenAI-family backends (SAP AI Core et al.) cap tool-name length/charset at
// CHAT_MAX_LEN. These helpers normalize outgoing tool names and reverse the
// mapping on the response, plus split assistant turns that exceed the
// per-message tool_calls cap. They own their allocations; the transformer's
// cleanup* wrappers call the matching free* helper. Kept here (not in the
// transformer) so chat_transformer.zig stays a thin dispatch/serialization layer.

/// True when any tool name in the request (definitions or prior-turn tool_calls)
/// exceeds CHAT_MAX_LEN or uses an invalid charset.
pub fn chatRequestNeedsToolNameNormalization(request: Chat.Request) bool {
    if (request.tools) |ts| for (ts) |t| {
        if (constraints.toolNameNeedsNormalize(t.function.name, constraints.CHAT_MAX_LEN)) return true;
    };
    for (request.messages) |m| if (m.tool_calls) |tcs| for (tcs) |tc| {
        if (constraints.toolNameNeedsNormalize(tc.function.name, constraints.CHAT_MAX_LEN)) return true;
    };
    return false;
}

/// Allocate a tools slice with normalized function names (owned). Freed by
/// freeNormalizedTools.
pub fn dupeNormalizedTools(tools: ?[]const Chat.Tool, allocator: std.mem.Allocator) !?[]const Chat.Tool {
    const src = tools orelse return null;
    const out = try allocator.alloc(Chat.Tool, src.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |t| allocator.free(t.function.name);
        allocator.free(out);
    }
    for (src, 0..) |t, i| {
        out[i] = t;
        out[i].function.name = try constraints.normalizeToolName(allocator, t.function.name, constraints.CHAT_MAX_LEN);
        built += 1;
    }
    return out;
}

/// Allocate a messages slice whose tool_calls have normalized names (owned).
/// Freed by freeNormalizedMessages.
pub fn dupeNormalizedMessages(messages: []const Chat.Message, allocator: std.mem.Allocator) ![]const Chat.Message {
    const out = try allocator.alloc(Chat.Message, messages.len);
    var built_msgs: usize = 0;
    errdefer {
        for (out[0..built_msgs]) |m| if (m.tool_calls) |tcs| {
            for (tcs) |tc| allocator.free(tc.function.name);
            allocator.free(tcs);
        };
        allocator.free(out);
    }
    for (messages, 0..) |m, i| {
        out[i] = m;
        if (m.tool_calls) |tcs| {
            const new_tcs = try allocator.alloc(Chat.ToolCall, tcs.len);
            var built: usize = 0;
            errdefer {
                for (new_tcs[0..built]) |tc| allocator.free(tc.function.name);
                allocator.free(new_tcs);
            }
            for (tcs, 0..) |tc, j| {
                new_tcs[j] = tc;
                new_tcs[j].function.name = try constraints.normalizeToolName(allocator, tc.function.name, constraints.CHAT_MAX_LEN);
                built += 1;
            }
            out[i].tool_calls = new_tcs;
        }
        built_msgs += 1;
    }
    return out;
}

fn freeNormalizedTools(tools: ?[]const Chat.Tool, allocator: std.mem.Allocator) void {
    const ts = tools orelse return;
    for (ts) |t| allocator.free(t.function.name);
    allocator.free(ts);
}

/// Free the normalized tools + messages allocated for a request by
/// dupeNormalizedTools / dupeNormalizedMessages.
pub fn freeNormalizedChatRequest(request: Chat.Request, allocator: std.mem.Allocator) void {
    freeNormalizedTools(request.tools, allocator);
    for (request.messages) |m| if (m.tool_calls) |tcs| {
        for (tcs) |tc| allocator.free(tc.function.name);
        allocator.free(tcs);
    };
    allocator.free(request.messages);
}

/// Reverse tool-name normalization on a chat response: rewrite tool_call names
/// back to the caller's originals (recovered from `original_req`). Returns the
/// input choices unchanged (aliased) when there is nothing to reverse; otherwise
/// returns a new owned slice to be freed by freeReversedChatResponseChoices.
/// `owned` is set true when a new slice was allocated.
pub fn reverseChatToolNames(
    choices: []const Chat.ResponseChoice,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
    owned: *bool,
) ![]const Chat.ResponseChoice {
    owned.* = false;
    const req_tools = original_req.tools orelse return choices;
    var originals = try allocator.alloc([]const u8, req_tools.len);
    defer allocator.free(originals);
    var any_normalized = false;
    for (req_tools, 0..) |t, i| {
        originals[i] = t.function.name;
        if (constraints.toolNameNeedsNormalize(t.function.name, constraints.CHAT_MAX_LEN)) any_normalized = true;
    }
    if (!any_normalized) return choices;

    var has_tool_calls = false;
    for (choices) |c| if (c.message.tool_calls != null) { has_tool_calls = true; break; };
    if (!has_tool_calls) return choices;

    const out = try allocator.alloc(Chat.ResponseChoice, choices.len);
    var built_choices: usize = 0;
    errdefer {
        for (out[0..built_choices]) |c| if (c.message.tool_calls) |tcs| {
            for (tcs) |tc| allocator.free(tc.function.name);
            allocator.free(tcs);
        };
        allocator.free(out);
    }
    for (choices, 0..) |c, i| {
        out[i] = c;
        if (c.message.tool_calls) |tcs| {
            const new_tcs = try allocator.alloc(Chat.ToolCall, tcs.len);
            var built: usize = 0;
            errdefer {
                for (new_tcs[0..built]) |tc| allocator.free(tc.function.name);
                allocator.free(new_tcs);
            }
            for (tcs, 0..) |tc, j| {
                new_tcs[j] = tc;
                const orig = constraints.recoverToolName(allocator, tc.function.name, originals, constraints.CHAT_MAX_LEN);
                new_tcs[j].function.name = try allocator.dupe(u8, orig);
                built += 1;
            }
            out[i].message.tool_calls = new_tcs;
        }
        built_choices += 1;
    }
    owned.* = true;
    return out;
}

/// Free the reversed choices slice allocated by reverseChatToolNames.
pub fn freeReversedChatResponseChoices(choices: []const Chat.ResponseChoice, allocator: std.mem.Allocator) void {
    for (choices) |c| if (c.message.tool_calls) |tcs| {
        for (tcs) |tc| allocator.free(tc.function.name);
        allocator.free(tcs);
    };
    allocator.free(choices);
}

/// Split any assistant message whose `tool_calls` exceed
/// `constraints.CHAT_MAX_TOOL_CALLS_PER_MESSAGE` into multiple assistant
/// messages, interleaving each chunk with the `tool` result messages that answer
/// it. Preserves ordering and the assistant→tool adjacency Chat requires.
///
/// Takes ownership of `input`. Returns `input` unchanged when nothing needs
/// splitting; otherwise returns a new owned slice and frees `input`'s backing
/// array. Message payloads alias into the result unchanged; each assistant
/// chunk's tool_calls slice is a freshly-allocated array whose ToolCall elements
/// alias the originals (name/arguments not re-duped). Each ToolCall's strings
/// remain owned by exactly one message, so freeMessageOwnedText frees them once.
pub fn splitOversizedToolCallTurns(
    input: []Chat.Message,
    allocator: std.mem.Allocator,
) ![]Chat.Message {
    const cap = constraints.CHAT_MAX_TOOL_CALLS_PER_MESSAGE;

    var needs = false;
    for (input) |m| {
        if (m.tool_calls) |tcs| if (tcs.len > cap) { needs = true; break; };
    }
    if (!needs) return input;

    var out: std.ArrayList(Chat.Message) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const msg = input[i];
        const tcs = msg.tool_calls orelse {
            try out.append(allocator, msg);
            continue;
        };
        if (tcs.len <= cap) {
            try out.append(allocator, msg);
            continue;
        }

        // Contiguous run of `tool` result messages answering this assistant.
        var results_end = i + 1;
        while (results_end < input.len and input[results_end].role == .tool) results_end += 1;
        const results = input[i + 1 .. results_end];

        var placed = try allocator.alloc(bool, results.len);
        defer allocator.free(placed);
        @memset(placed, false);

        // Emit chunks: assistant(chunk) then the tool results answering it.
        var offset: usize = 0;
        var first = true;
        while (offset < tcs.len) {
            const end = @min(offset + cap, tcs.len);
            const chunk = try allocator.alloc(Chat.ToolCall, end - offset);
            @memcpy(chunk, tcs[offset..end]);
            try out.append(allocator, .{
                .role = msg.role,
                .content = if (first) msg.content else null,
                .tool_calls = chunk,
            });
            first = false;
            for (results, 0..) |res, ri| {
                if (placed[ri]) continue;
                const rid = res.tool_call_id orelse continue;
                for (chunk) |tc| {
                    if (std.mem.eql(u8, tc.id, rid)) {
                        try out.append(allocator, res);
                        placed[ri] = true;
                        break;
                    }
                }
            }
            offset = end;
        }
        // Orphan / non-matching results kept in original order (never dropped).
        for (results, 0..) |res, ri| {
            if (!placed[ri]) try out.append(allocator, res);
        }

        allocator.free(tcs); // element strings live on via the chunks
        i = results_end - 1;
    }

    allocator.free(input);
    return out.toOwnedSlice(allocator);
}
