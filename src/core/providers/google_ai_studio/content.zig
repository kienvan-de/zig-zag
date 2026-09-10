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

/// Map an arbitrary JSON Schema value to a typed GeminiSchema.
/// Whitelist approach — only fields Gemini's Schema proto supports are emitted.
/// Handles common OpenAI→Gemini translation:
///   - lowercase type names → Gemini uppercase enum
///   - anyOf with {"type":"null"} entry → sets nullable:true, strips the null variant
///   - bare {} entries inside anyOf → dropped
///   - unsupported keys ($ref, $defs, title, default, additionalProperties, etc.) → dropped
pub fn mapToGeminiSchema(value: std.json.Value, allocator: std.mem.Allocator) error{OutOfMemory}!Google.GeminiSchema {
    if (value != .object) return .{};
    const obj = value.object;

    var schema = Google.GeminiSchema{};

    // type — map lowercase OpenAI names to Gemini uppercase enum
    if (obj.get("type")) |tv| {
        if (tv == .string) schema.type = mapSchemaType(tv.string);
    }

    // description
    if (obj.get("description")) |v| {
        if (v == .string) schema.description = v.string;
    }

    // nullable — detect {"type":"null"} inside anyOf or explicit type:null
    if (obj.get("type")) |tv| {
        if (tv == .string and std.mem.eql(u8, tv.string, "null")) schema.nullable = true;
    }

    // format — only pass through values Gemini understands
    if (obj.get("format")) |v| {
        if (v == .string and isGeminiFormat(v.string)) schema.format = v.string;
    }

    // pattern
    if (obj.get("pattern")) |v| {
        if (v == .string) schema.pattern = v.string;
    }

    // enum
    if (obj.get("enum")) |v| {
        if (v == .array) {
            var enums: std.ArrayList([]const u8) = .empty;
            errdefer enums.deinit(allocator);
            for (v.array.items) |item| {
                if (item == .string) try enums.append(allocator, item.string);
            }
            if (enums.items.len > 0)
                schema.@"enum" = try enums.toOwnedSlice(allocator)
            else
                enums.deinit(allocator);
        }
    }

    // properties — recurse
    if (obj.get("properties")) |v| {
        if (v == .object) {
            var props: std.ArrayList(Google.GeminiSchemaProperty) = .empty;
            errdefer {
                for (props.items) |p| freeGeminiSchema(p.schema, allocator);
                props.deinit(allocator);
            }
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const child = try mapToGeminiSchema(entry.value_ptr.*, allocator);
                try props.append(allocator, .{ .name = entry.key_ptr.*, .schema = child });
            }
            schema.properties = try props.toOwnedSlice(allocator);
        }
    }

    // required
    if (obj.get("required")) |v| {
        if (v == .array) {
            var req: std.ArrayList([]const u8) = .empty;
            errdefer req.deinit(allocator);
            for (v.array.items) |item| {
                if (item == .string) try req.append(allocator, item.string);
            }
            if (req.items.len > 0)
                schema.required = try req.toOwnedSlice(allocator)
            else
                req.deinit(allocator);
        }
    }

    // items — recurse
    if (obj.get("items")) |v| {
        const child = try allocator.create(Google.GeminiSchema);
        errdefer allocator.destroy(child);
        child.* = try mapToGeminiSchema(v, allocator);
        schema.items = child;
    }

    // anyOf — extract nullable signal, filter bare {} and null-type variants, recurse the rest
    if (obj.get("anyOf")) |v| {
        if (v == .array) {
            var variants: std.ArrayList(Google.GeminiSchema) = .empty;
            errdefer {
                for (variants.items) |s| freeGeminiSchema(s, allocator);
                variants.deinit(allocator);
            }
            for (v.array.items) |item| {
                if (item != .object) continue;
                // bare {} — drop
                if (item.object.count() == 0) continue;
                // {"type":"null"} — extract nullable:true, drop this variant
                if (item.object.get("type")) |tv| {
                    if (tv == .string and std.mem.eql(u8, tv.string, "null")) {
                        schema.nullable = true;
                        continue;
                    }
                }
                try variants.append(allocator, try mapToGeminiSchema(item, allocator));
            }
            if (variants.items.len > 0)
                schema.any_of = try variants.toOwnedSlice(allocator)
            else
                variants.deinit(allocator);
        }
    }

    // numeric bounds
    if (obj.get("minimum")) |v| schema.minimum = jsonToF64(v);
    if (obj.get("maximum")) |v| schema.maximum = jsonToF64(v);

    // array bounds
    if (obj.get("minItems")) |v| schema.min_items = jsonToU64(v);
    if (obj.get("maxItems")) |v| schema.max_items = jsonToU64(v);

    return schema;
}

/// Free a GeminiSchema produced by mapToGeminiSchema.
/// Only recursively-allocated containers are freed; string slices borrow from
/// the inbound JSON parse and are not freed here.
pub fn freeGeminiSchema(schema: Google.GeminiSchema, allocator: std.mem.Allocator) void {
    if (schema.@"enum") |vs| allocator.free(vs);
    if (schema.required) |vs| allocator.free(vs);
    if (schema.properties) |props| {
        for (props) |p| freeGeminiSchema(p.schema, allocator);
        allocator.free(props);
    }
    if (schema.items) |child| {
        freeGeminiSchema(child.*, allocator);
        allocator.destroy(child);
    }
    if (schema.any_of) |variants| {
        for (variants) |s| freeGeminiSchema(s, allocator);
        allocator.free(variants);
    }
}

fn mapSchemaType(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "string"))  return "STRING";
    if (std.mem.eql(u8, t, "number"))  return "NUMBER";
    if (std.mem.eql(u8, t, "integer")) return "INTEGER";
    if (std.mem.eql(u8, t, "boolean")) return "BOOLEAN";
    if (std.mem.eql(u8, t, "array"))   return "ARRAY";
    if (std.mem.eql(u8, t, "object"))  return "OBJECT";
    if (std.mem.eql(u8, t, "null"))    return "NULL";
    return t; // already uppercase or unknown — pass through
}

fn isGeminiFormat(f: []const u8) bool {
    const allowed = &[_][]const u8{ "int32", "int64", "float", "double", "byte", "date-time" };
    for (allowed) |a| if (std.mem.eql(u8, f, a)) return true;
    return false;
}

fn jsonToF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonToU64(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// Map OpenAI function tools to a single GeminiTool wrapping the declarations.
/// Custom tools are skipped (no Gemini equivalent). Always returns an allocated
/// slice (possibly empty, possibly with an empty declarations list). The
/// `parameters` schemas are mapped via mapToGeminiSchema.
/// Free a tools array produced by `transformTools`: the declarations slice,
/// each declaration's GeminiSchema, and the wrapping slice.
pub fn cleanupTools(tools: []const Google.GeminiTool, allocator: std.mem.Allocator) void {
    for (tools) |tool| {
        if (tool.function_declarations) |fds| {
            for (fds) |fd| {
                if (fd.parameters) |p| freeGeminiSchema(p, allocator);
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
        const params: ?Google.GeminiSchema = if (f.parameters) |p|
            try mapToGeminiSchema(p, allocator)
        else
            null;
        errdefer if (params) |p| freeGeminiSchema(p, allocator);
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
