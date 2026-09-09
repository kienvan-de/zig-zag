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

//! Mapping internals for the google_ai_studio provider.
//!
//! `pub` here means **internal to the google_ai_studio provider** — these are
//! support functions for `transformer.zig`, not a public API. Nothing outside
//! `src/core/providers/google_ai_studio/` should import this module.
//!
//! Per P6: every helper lives here; `transformer.zig` holds only the four flow
//! sections' main functions and stream states. Helpers are stateless — stream
//! state stays in `transformer.zig`, so this module never imports it (no
//! cycle); main functions pass the needed fields explicitly.

const std = @import("std");

const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // inbound chat schema (shapes only)
const common = @import("../openai/types.zig"); // shared primitives (ToolFunction)
const Google = @import("types.zig"); // Gemini wire types

// ============================================================================
// Request mapping: inbound schemas → Gemini wire
// ============================================================================

/// Map OpenAI tool_choice (JSON value) to the Gemini ToolConfig mode.
/// Shapes: "none" | "auto" | "required" | {"type":"function","function":{"name":…}}.
/// Gemini has no named-function mode — a named choice maps to ANY.
pub fn transformToolChoice(tool_choice: std.json.Value) ?Google.ToolConfig {
    switch (tool_choice) {
        .string => |s| {
            if (std.mem.eql(u8, s, "none")) {
                return .{ .function_calling_config = .{ .mode = "NONE" } };
            } else if (std.mem.eql(u8, s, "required")) {
                return .{ .function_calling_config = .{ .mode = "ANY" } };
            }
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        .object => |obj| {
            if (obj.get("type")) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "function")) {
                    return .{ .function_calling_config = .{ .mode = "ANY" } };
                }
            }
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        else => return null,
    }
}

/// Sanitize a JSON schema for Gemini: recursively drops keys Gemini rejects
/// in `FunctionDeclaration.parameters` ($schema/$ref/$defs, format, numeric
/// bounds, default/examples, title, additionalProperties). Allocates a fresh
/// tree (object keys are borrowed from the input; containers are new).
pub fn sanitizeSchema(value: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    switch (value) {
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .{};
            errdefer new_obj.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "$schema") or
                    std.mem.eql(u8, key, "$ref") or
                    std.mem.eql(u8, key, "$defs") or
                    std.mem.eql(u8, key, "format") or
                    std.mem.eql(u8, key, "minimum") or
                    std.mem.eql(u8, key, "maximum") or
                    std.mem.eql(u8, key, "exclusiveMinimum") or
                    std.mem.eql(u8, key, "exclusiveMaximum") or
                    std.mem.eql(u8, key, "default") or
                    std.mem.eql(u8, key, "examples") or
                    std.mem.eql(u8, key, "title") or
                    std.mem.eql(u8, key, "additionalProperties")) continue;
                const sanitized = try sanitizeSchema(entry.value_ptr.*, allocator);
                try new_obj.put(allocator, key, sanitized);
            }
            return .{ .object = new_obj };
        },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            errdefer new_arr.deinit();
            for (arr.items) |item| {
                try new_arr.append(try sanitizeSchema(item, allocator));
            }
            return .{ .array = new_arr };
        },
        else => return value,
    }
}

/// Free a tree produced by `sanitizeSchema`: its containers are freshly
/// allocated (string leaves are borrowed, so only recursing containers +
/// map index storage are freed here).
pub fn freeSanitizedSchema(value: std.json.Value, allocator: std.mem.Allocator) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| freeSanitizedSchema(entry.value_ptr.*, allocator);
            var owned = obj; // mutable handle copy
            owned.deinit(allocator);
        },
        .array => |arr| {
            for (arr.items) |item| freeSanitizedSchema(item, allocator);
            arr.deinit(); // Managed list frees via its stored allocator
        },
        else => {},
    }
}

/// Map OpenAI function tools to a single GeminiTool wrapping the declarations.
/// Custom tools are skipped (no Gemini equivalent). Always returns an allocated
/// slice (possibly empty, possibly with an empty declarations list). The
/// `parameters` schemas are sanitized (see `sanitizeSchema`).
/// Free a tools array produced by `transformTools`: the declarations slice,
/// each declaration's sanitized schema tree, and the wrapping slice.
pub fn cleanupTools(tools: []const Google.GeminiTool, allocator: std.mem.Allocator) void {
    for (tools) |tool| {
        if (tool.function_declarations) |fds| {
            for (fds) |fd| {
                if (fd.parameters) |p| freeSanitizedSchema(p, allocator);
            }
            allocator.free(fds);
        }
    }
    allocator.free(tools);
}

pub fn transformTools(
    tools: []const common.ToolFunction,
    allocator: std.mem.Allocator,
) ![]Google.GeminiTool {
    var declarations: std.ArrayList(Google.FunctionDeclaration) = .empty;
    errdefer declarations.deinit(allocator);

    for (tools) |f| {
        const params = if (f.parameters) |p|
            try sanitizeSchema(p, allocator)
        else
            null;
        errdefer if (params) |p| freeSanitizedSchema(p, allocator);
        try declarations.append(allocator, .{
            .name = f.name,
            .description = f.description,
            .parameters = params,
        });
    }

    // Gemini wraps all declarations in exactly one GeminiTool object.
    const gemini_tools = try allocator.alloc(Google.GeminiTool, 1);
    errdefer allocator.free(gemini_tools);
    gemini_tools[0] = .{ .function_declarations = try declarations.toOwnedSlice(allocator) };
    return gemini_tools;
}

pub const BuiltContents = struct {
    contents: []Google.Content,
    /// Joined system/developer message text; null when none. Freshly allocated.
    system_text: ?[]const u8,
};

/// Convert OpenAI chat messages to Gemini contents. System/developer messages
/// are joined into `system_text` (caller passes it as systemInstruction);
/// assistant tool_calls become function_call parts (arguments re-parsed into
/// an owned JSON tree); tool results become user turns with function_response
/// parts wrapping {"output": text}.
pub fn buildContents(
    messages: []const Chat.Message,
    allocator: std.mem.Allocator,
) !BuiltContents {
    var system_parts: std.ArrayList([]const u8) = .empty;
    defer system_parts.deinit(allocator);

    var contents: std.ArrayList(Google.Content) = .empty;
    errdefer contents.deinit(allocator);

    for (messages) |msg| {
        switch (msg.role) {
            .system, .developer => {
                if (msg.content) |c| {
                    switch (c) {
                        .text => |t| try system_parts.append(allocator, t),
                        .parts => |ps| for (ps) |p| {
                            if (p == .text) try system_parts.append(allocator, p.text.text);
                        },
                    }
                }
            },
            .user => {
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer parts.deinit(allocator);

                if (msg.content) |c| {
                    switch (c) {
                        .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                        .parts => |ps| for (ps) |p| {
                            switch (p) {
                                .text => |tp| try parts.append(allocator, .{ .text = .{ .text = tp.text } }),
                                else => {}, // audio/file/refusal: no Gemini equivalent
                            }
                        },
                    }
                }

                if (parts.items.len == 0) {
                    try parts.append(allocator, .{ .text = .{ .text = "" } });
                }
                try contents.append(allocator, .{ .role = "user", .parts = try parts.toOwnedSlice(allocator) });
            },
            .assistant => {
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer {
                    for (parts.items) |p| freeResponseOwnedArgs(p, allocator);
                    parts.deinit(allocator);
                }

                if (msg.content) |c| {
                    switch (c) {
                        .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                        .parts => |ps| for (ps) |p| {
                            if (p == .text) try parts.append(allocator, .{ .text = .{ .text = p.text.text } });
                        },
                    }
                }

                // Assistant tool_calls → function_call parts. The arguments JSON
                // string is re-parsed into an owned tree (leaky: frees manually).
                if (msg.tool_calls) |tool_calls| for (tool_calls) |tc| {
                    const args_val: std.json.Value = std.json.parseFromSliceLeaky(
                        std.json.Value,
                        allocator,
                        tc.function.arguments,
                        .{},
                    ) catch .null;
                    try parts.append(allocator, .{ .function_call = .{
                        .name = tc.function.name,
                        .args = args_val,
                    } });
                };

                if (parts.items.len == 0) {
                    try parts.append(allocator, .{ .text = .{ .text = "" } });
                }
                try contents.append(allocator, .{ .role = "model", .parts = try parts.toOwnedSlice(allocator) });
            },
            .tool => {
                // Tool results become user turns with function_response parts.
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer parts.deinit(allocator);

                const func_name = msg.tool_call_id orelse "unknown_function";
                const content_text: []const u8 = if (msg.content) |c| switch (c) {
                    .text => |t| t,
                    .parts => |ps| if (ps.len > 0 and ps[0] == .text) ps[0].text.text else "",
                } else "";

                // The map is owned by the part from here on — freed by
                // freeFunctionResponseArgs in cleanup (NOT by a defer: the
                // old code deinited before serialization = use-after-free).
                var resp_obj: std.json.ObjectMap = .{};
                errdefer resp_obj.deinit(allocator);
                try resp_obj.put(allocator, "output", .{ .string = content_text });

                try parts.append(allocator, .{ .function_response = .{
                    .name = func_name,
                    .response = .{ .object = resp_obj },
                } });

                try contents.append(allocator, .{ .role = "user", .parts = try parts.toOwnedSlice(allocator) });
            },
        }
    }

    const system_text: ?[]const u8 = if (system_parts.items.len > 0)
        try std.mem.join(allocator, "\n", system_parts.items)
    else
        null;

    return .{
        .contents = try contents.toOwnedSlice(allocator),
        .system_text = system_text,
    };
}

/// Convert Anthropic messages to Gemini contents (messages flow mapping):
/// user → "user", assistant → "model", tool_use → function_call (args tree is
/// borrowed — the inbound parse owns it), tool_result → function_response
/// wrapping a hand-built {"output": …} map owned by the request. Thinking and
/// other non-content blocks are skipped. Never returns zero contents (a
/// fallback empty user turn is appended) since Gemini requires contents.
pub fn buildContentsFromMessages(
    messages: []const Messages.Message,
    allocator: std.mem.Allocator,
) ![]Google.Content {
    var contents: std.ArrayList(Google.Content) = .empty;
    errdefer {
        for (contents.items) |c| {
            for (c.parts) |part| freeMessagesOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        contents.deinit(allocator);
    }

    for (messages) |msg| {
        const role: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "model",
        };

        var parts: std.ArrayList(Google.Part) = .empty;
        errdefer {
            for (parts.items) |part| freeMessagesOwnedArgs(part, allocator);
            parts.deinit(allocator);
        }

        switch (msg.content) {
            .text => |text| try parts.append(allocator, .{ .text = .{ .text = text } }),
            .blocks => |blocks| for (blocks) |block| {
                switch (block) {
                    .text => |tb| try parts.append(allocator, .{ .text = .{ .text = tb.text } }),
                    .tool_use => |tu| {
                        // args borrows the inbound parse's tree — do NOT free here.
                        try parts.append(allocator, .{ .function_call = .{
                            .name = tu.name,
                            .args = tu.input,
                        } });
                    },
                    .tool_result => |tr| {
                        // Hand-built map: literal key + borrowed value string;
                        // the map storage itself is owned by this request.
                        var resp_obj: std.json.ObjectMap = .{};
                        errdefer resp_obj.deinit(allocator);
                        try resp_obj.put(allocator, "output", .{ .string = tr.content orelse "" });
                        try parts.append(allocator, .{ .function_response = .{
                            .name = tr.tool_use_id,
                            .response = .{ .object = resp_obj },
                        } });
                    },
                    else => {}, // thinking / redacted_thinking: no Gemini equivalent
                }
            },
        }

        if (parts.items.len == 0) {
            try parts.append(allocator, .{ .text = .{ .text = "" } });
        }
        try contents.append(allocator, .{ .role = role, .parts = try parts.toOwnedSlice(allocator) });
    }

    if (contents.items.len == 0) {
        const fallback_parts = try allocator.alloc(Google.Part, 1);
        fallback_parts[0] = .{ .text = .{ .text = "" } };
        try contents.append(allocator, .{ .role = "user", .parts = fallback_parts });
    }

    return contents.toOwnedSlice(allocator);
}

// ============================================================================
// Response mapping: Gemini wire → inbound schemas
// ============================================================================

/// Map Gemini finishReason to the chat-schema finish_reason.
/// SAFETY and RECITATION both mean the model halted the content → content_filter.
pub fn transformStopReason(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "stop";
    if (std.mem.eql(u8, r, "STOP")) return "stop";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "length";
    if (std.mem.eql(u8, r, "SAFETY")) return "content_filter";
    if (std.mem.eql(u8, r, "RECITATION")) return "content_filter";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_calls";
    return "stop";
}

/// Map Gemini finishReason to the Messages-wire stop_reason vocabulary
/// (messages flow output).
pub fn transformStopReasonToMessages(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "end_turn";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "max_tokens";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_use";
    return "end_turn";
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
/// The chunk borrows from `ctx` and `delta`, so the caller writes the result
/// immediately. (Google-local twin of the anthropic helper — providers share
/// no transformer code per P11.)
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
        .id = if (ctx.id.len > 0) ctx.id else "chatcmpl-google",
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

/// Free a tool-call list as built by `extractToolCalls`: id and arguments
/// strings are owned; the slice itself is owned.
pub fn freeToolCallList(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tc| {
        allocator.free(tc.id);
        allocator.free(tc.function.arguments);
    }
    allocator.free(tool_calls);
}

/// Join text parts of the first candidate. Freshly allocated (possibly empty)
/// — caller owns it. function_call/function_response parts are skipped.
pub fn extractTextFromBlocks(
    response: Google.Response,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (response.candidates.len == 0) return allocator.dupe(u8, "");

    var parts_text: std.ArrayList([]const u8) = .empty;
    defer parts_text.deinit(allocator);

    for (response.candidates[0].content.parts) |part| {
        switch (part) {
            .text => |tp| {
                if (tp.text.len > 0) try parts_text.append(allocator, tp.text);
            },
            else => {},
        }
    }

    if (parts_text.items.len == 0) return allocator.dupe(u8, "");
    return std.mem.join(allocator, "", parts_text.items);
}

/// Extract function_call parts of the first candidate as chat tool calls.
/// Gemini provides no call ids — a synthetic `call_{name}` id is generated.
/// Arguments are re-serialized from the parsed `args` tree. Everything is
/// freshly allocated; free with the .function branches of the caller's cleanup.
pub fn extractToolCalls(
    response: Google.Response,
    allocator: std.mem.Allocator,
) !?[]Chat.ToolCall {
    if (response.candidates.len == 0) return null;

    var tool_calls: std.ArrayList(Chat.ToolCall) = .empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.function.arguments);
        }
        tool_calls.deinit(allocator);
    }

    for (response.candidates[0].content.parts) |part| {
        switch (part) {
            .function_call => |fc| {
                // Re-serialize the parsed args tree into the arguments string.
                var args_buf: std.ArrayList(u8) = .empty;
                defer args_buf.deinit(allocator);
                try args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})});

                try tool_calls.append(allocator, .{
                    .id = try std.fmt.allocPrint(allocator, "call_{s}", .{fc.name}),
                    .type = "function",
                    .function = .{
                        .name = fc.name,
                        .arguments = try args_buf.toOwnedSlice(allocator),
                    },
                });
            },
            else => {},
        }
    }

    if (tool_calls.items.len == 0) return null;
    return try tool_calls.toOwnedSlice(allocator);
}

/// Free the request-owned JSON of a chat-flow part: function_call args are a
/// leaky-parsed tree (keys AND string values Scanner-owned), function_response
/// is a hand-built map (literal key, borrowed value — deinit storage only).
pub fn freeResponseOwnedArgs(part: Google.Part, allocator: std.mem.Allocator) void {
    switch (part) {
        .function_call => |fc| freeParsedJsonValue(fc.args, allocator),
        .function_response => |fr| {
            if (fr.response == .object) {
                var owned = fr.response.object;
                owned.deinit(allocator);
            }
        },
        else => {},
    }
}

/// Free the request-owned memory of a messages-flow part: function_call args
/// BORROW the inbound Anthropic parse's tree (not freed here — its arena does),
/// while function_response maps are hand-built and owned.
pub fn freeMessagesOwnedArgs(part: Google.Part, allocator: std.mem.Allocator) void {
    switch (part) {
        .function_response => |fr| {
            if (fr.response == .object) {
                var owned = fr.response.object;
                owned.deinit(allocator);
            }
        },
        else => {},
    }
}

/// Free a `std.json.Value` tree produced by `parseFromSliceLeaky` with
/// `allocator` (roots of any type). Keys AND string values are Scanner-owned
/// allocations; `ObjectMap.deinit` only releases the entry storage.
pub fn freeParsedJsonValue(value: std.json.Value, allocator: std.mem.Allocator) void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*); // keys are owned strings
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
