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

//! Mapping helpers for the google_ai_studio provider — internal to this provider.
//! Stateless value-to-value transforms shared across the four flow functions in transformer.zig.

const std = @import("std");

const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Chat = @import("../openai/chat_types.zig"); // inbound chat schema
const Responses = @import("../openai/responses_types.zig"); // Responses API schema
const common = @import("../openai/types.zig"); // shared primitives
const Google = @import("types.zig"); // Gemini wire types

// ============================================================================
// Tool mapping
// ============================================================================

/// Map OpenAI tool_choice (JSON value) to the Gemini ToolConfig.
/// "none" → NONE, "required" → ANY, named function → ANY (Gemini has no named mode),
/// "auto" / unknown → AUTO.
pub fn transformToolChoice(tool_choice: std.json.Value) ?Google.ToolConfig {
    switch (tool_choice) {
        .string => |s| {
            if (std.mem.eql(u8, s, "none")) return .{ .function_calling_config = .{ .mode = "NONE" } };
            if (std.mem.eql(u8, s, "required")) return .{ .function_calling_config = .{ .mode = "ANY" } };
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        .object => |obj| {
            if (obj.get("type")) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "function"))
                    return .{ .function_calling_config = .{ .mode = "ANY" } };
            }
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        else => return null,
    }
}

/// Map Responses tool_choice (JSON value) to Gemini ToolConfig.
/// "none" → NONE, "required" → ANY, {"type":"function","name":"..."} → ANY,
/// "auto" / unknown / null → null (omit toolConfig).
pub fn transformResponsesToolChoice(tool_choice: ?std.json.Value) ?Google.ToolConfig {
    const tc = tool_choice orelse return null;
    return transformToolChoice(tc);
}

/// Map a slice of ToolFunction to a single GeminiTool wrapping all declarations.
/// Parameters schema is converted via mapToGeminiSchema.
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

    const gemini_tools = try allocator.alloc(Google.GeminiTool, 1);
    errdefer allocator.free(gemini_tools);
    gemini_tools[0] = .{ .function_declarations = try declarations.toOwnedSlice(allocator) };
    return gemini_tools;
}

/// Free a tools slice produced by transformTools.
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

// ============================================================================
// Schema mapping (OpenAI JSON Schema → GeminiSchema)
// ============================================================================

/// Map an arbitrary JSON Schema value to a typed GeminiSchema.
/// Whitelist approach — only fields Gemini's Schema proto supports are emitted.
///   - lowercase type names → Gemini uppercase enum
///   - anyOf with {"type":"null"} → sets nullable:true, strips the null variant
///   - bare {} inside anyOf → dropped
///   - unsupported keys ($ref, $defs, title, default, additionalProperties) → dropped
pub fn mapToGeminiSchema(value: std.json.Value, allocator: std.mem.Allocator) error{OutOfMemory}!Google.GeminiSchema {
    if (value != .object) return .{};
    const obj = value.object;

    var schema = Google.GeminiSchema{};

    if (obj.get("type")) |tv| {
        if (tv == .string) {
            schema.type = mapSchemaType(tv.string);
            if (std.mem.eql(u8, tv.string, "null")) schema.nullable = true;
        }
    }
    if (obj.get("description")) |v| {
        if (v == .string) schema.description = v.string;
    }
    if (obj.get("format")) |v| {
        if (v == .string and isGeminiFormat(v.string)) schema.format = v.string;
    }
    if (obj.get("pattern")) |v| {
        if (v == .string) schema.pattern = v.string;
    }
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
    if (obj.get("items")) |v| {
        const child = try allocator.create(Google.GeminiSchema);
        errdefer allocator.destroy(child);
        child.* = try mapToGeminiSchema(v, allocator);
        schema.items = child;
    }
    if (obj.get("anyOf")) |v| {
        if (v == .array) {
            var variants: std.ArrayList(Google.GeminiSchema) = .empty;
            errdefer {
                for (variants.items) |s| freeGeminiSchema(s, allocator);
                variants.deinit(allocator);
            }
            for (v.array.items) |item| {
                if (item != .object) continue;
                if (item.object.count() == 0) continue;
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
    if (obj.get("minimum")) |v| schema.minimum = jsonToF64(v);
    if (obj.get("maximum")) |v| schema.maximum = jsonToF64(v);
    if (obj.get("minItems")) |v| schema.min_items = jsonToU64(v);
    if (obj.get("maxItems")) |v| schema.max_items = jsonToU64(v);

    return schema;
}

/// Free a GeminiSchema produced by mapToGeminiSchema.
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
    return t;
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

// ============================================================================
// Chat request: Chat.Message[] → Google.Content[]
// ============================================================================

/// Result of buildContents: the contents slice and an owned system text string.
pub const BuiltContents = struct {
    contents: []Google.Content,
    system_text: ?[]const u8,
};

/// Convert Chat messages to Gemini contents.
///   system/developer → joined into system_text (caller maps to systemInstruction)
///   user             → "user" turn with text/image parts
///   assistant        → "model" turn with text parts + function_call parts
///   tool             → "user" turn with function_response parts
///
/// Consecutive same-role user/model turns are merged (Gemini requires alternating).
/// Image content parts: data: URI → inline_data, https:// URL → file_data.
pub fn buildContents(
    messages: []const Chat.Message,
    allocator: std.mem.Allocator,
) !BuiltContents {
    var system_parts: std.ArrayList([]const u8) = .empty;
    defer system_parts.deinit(allocator);

    var contents: std.ArrayList(Google.Content) = .empty;
    errdefer {
        for (contents.items) |c| {
            for (c.parts) |part| freeResponseOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        contents.deinit(allocator);
    }

    for (messages) |msg| {
        switch (msg.role) {
            .system, .developer => {
                if (msg.content) |c| switch (c) {
                    .text => |t| try system_parts.append(allocator, t),
                    .parts => |ps| for (ps) |p| {
                        if (p == .text) try system_parts.append(allocator, p.text.text);
                    },
                };
            },
            .user => {
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer parts.deinit(allocator);

                if (msg.content) |c| switch (c) {
                    .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                    .parts => |ps| for (ps) |p| switch (p) {
                        .text => |tp| try parts.append(allocator, .{ .text = .{ .text = tp.text } }),
                        .image_url => |ip| try appendImagePart(&parts, ip.image_url.url, allocator),
                        .input_audio, .file => {}, // no Gemini equivalent
                    },
                };

                if (parts.items.len == 0)
                    try parts.append(allocator, .{ .text = .{ .text = "" } });

                try mergeOrAppend(&contents, "user", try parts.toOwnedSlice(allocator), allocator);
            },
            .assistant => {
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer {
                    for (parts.items) |p| freeResponseOwnedArgs(p, allocator);
                    parts.deinit(allocator);
                }

                if (msg.content) |c| switch (c) {
                    .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                    .parts => |ps| for (ps) |p| {
                        if (p == .text) try parts.append(allocator, .{ .text = .{ .text = p.text.text } });
                    },
                };

                if (msg.tool_calls) |tcs| for (tcs) |tc| {
                    const args_val = std.json.parseFromSliceLeaky(
                        std.json.Value, allocator, tc.function.arguments, .{},
                    ) catch .null;
                    try parts.append(allocator, .{ .function_call = .{
                        .name = tc.function.name,
                        .args = args_val,
                    } });
                };

                if (parts.items.len == 0)
                    try parts.append(allocator, .{ .text = .{ .text = "" } });

                try mergeOrAppend(&contents, "model", try parts.toOwnedSlice(allocator), allocator);
            },
            .tool => {
                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer parts.deinit(allocator);

                const func_name = msg.tool_call_id orelse "unknown_function";
                const content_text: []const u8 = if (msg.content) |c| switch (c) {
                    .text => |t| t,
                    .parts => |ps| if (ps.len > 0 and ps[0] == .text) ps[0].text.text else "",
                } else "";

                var resp_obj: std.json.ObjectMap = .{};
                errdefer resp_obj.deinit(allocator);
                try resp_obj.put(allocator, "output", .{ .string = content_text });

                try parts.append(allocator, .{ .function_response = .{
                    .name = func_name,
                    .response = .{ .object = resp_obj },
                } });

                try mergeOrAppend(&contents, "user", try parts.toOwnedSlice(allocator), allocator);
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

// ============================================================================
// Messages request: Messages.Message[] → Google.Content[]
// ============================================================================

/// Convert Anthropic Messages turns to Gemini contents.
///   user      → "user" turn
///   assistant → "model" turn
/// Consecutive same-role turns are merged.
/// tool_use blocks → function_call parts (args borrowed from inbound parse).
/// tool_result blocks → function_response parts (hand-built {"output":…} map owned).
/// thinking/redacted_thinking → skipped.
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
            .system => continue, // system handled separately via system_instruction
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
                        // args borrows the inbound parse's tree.
                        try parts.append(allocator, .{ .function_call = .{
                            .name = tu.name,
                            .args = tu.input,
                        } });
                    },
                    .tool_result => |tr| {
                        const output_text: []const u8 = if (tr.content) |c| switch (c) {
                            .text => |t| t,
                            .blocks => |blks| if (blks.len > 0) blks[0].text else "",
                        } else "";
                        var resp_obj: std.json.ObjectMap = .{};
                        errdefer resp_obj.deinit(allocator);
                        try resp_obj.put(allocator, "output", .{ .string = output_text });
                        try parts.append(allocator, .{ .function_response = .{
                            .name = tr.tool_use_id,
                            .response = .{ .object = resp_obj },
                        } });
                    },
                    else => {}, // thinking/redacted_thinking/server_tool_use/etc: no equivalent
                }
            },
        }

        if (parts.items.len == 0)
            try parts.append(allocator, .{ .text = .{ .text = "" } });

        try mergeOrAppend(&contents, role, try parts.toOwnedSlice(allocator), allocator);
    }

    if (contents.items.len == 0) {
        const fallback = try allocator.alloc(Google.Part, 1);
        fallback[0] = .{ .text = .{ .text = "" } };
        try contents.append(allocator, .{ .role = "user", .parts = fallback });
    }

    return contents.toOwnedSlice(allocator);
}

// ============================================================================
// Responses request: Responses.Request.input → Google.Content[]
// ============================================================================

/// Convert Responses input to Gemini contents.
///   input.text                 → single user turn
///   input.items[].message      → user/model turn with text + image parts
///   input.items[].function_call → model turn with function_call part
///   input.items[].function_call_output → user turn with function_response part
///   input.items[].reasoning    → dropped (no Gemini equivalent)
///
/// Consecutive same-role turns are merged.
pub fn buildContentsFromResponsesInput(
    input: Responses.InputParam,
    allocator: std.mem.Allocator,
) ![]Google.Content {
    var contents: std.ArrayList(Google.Content) = .empty;
    errdefer {
        for (contents.items) |c| {
            for (c.parts) |part| freeResponseOwnedArgs(part, allocator);
            allocator.free(c.parts);
        }
        contents.deinit(allocator);
    }

    switch (input) {
        .text => |t| {
            const parts = try allocator.alloc(Google.Part, 1);
            parts[0] = .{ .text = .{ .text = t } };
            try contents.append(allocator, .{ .role = "user", .parts = parts });
        },
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const item_type_val = obj.get("type") orelse continue;
            if (item_type_val != .string) continue;
            const item_type = item_type_val.string;

            if (std.mem.eql(u8, item_type, "message")) {
                const role_val = obj.get("role") orelse continue;
                if (role_val != .string) continue;
                const role_str = role_val.string;

                // system/developer messages: no per-turn equivalent in Gemini.
                if (std.mem.eql(u8, role_str, "system") or
                    std.mem.eql(u8, role_str, "developer")) continue;

                const role: []const u8 = if (std.mem.eql(u8, role_str, "assistant")) "model" else "user";

                var parts: std.ArrayList(Google.Part) = .empty;
                errdefer parts.deinit(allocator);

                const content_val = obj.get("content") orelse continue;
                switch (content_val) {
                    .string => |s| {
                        if (s.len > 0) try parts.append(allocator, .{ .text = .{ .text = s } });
                    },
                    .array => |arr| for (arr.items) |part| {
                        if (part != .object) continue;
                        const ptype = part.object.get("type") orelse continue;
                        if (ptype != .string) continue;

                        if (std.mem.eql(u8, ptype.string, "input_text") or
                            std.mem.eql(u8, ptype.string, "text") or
                            std.mem.eql(u8, ptype.string, "output_text"))
                        {
                            const tv = part.object.get("text") orelse continue;
                            if (tv == .string and tv.string.len > 0)
                                try parts.append(allocator, .{ .text = .{ .text = tv.string } });
                        } else if (std.mem.eql(u8, ptype.string, "input_image") or
                            std.mem.eql(u8, ptype.string, "image_url"))
                        {
                            const url_val = part.object.get("image_url") orelse continue;
                            const url: []const u8 = switch (url_val) {
                                .string => |s| s,
                                .object => |o| blk: {
                                    const uv = o.get("url") orelse break :blk "";
                                    break :blk if (uv == .string) uv.string else "";
                                },
                                else => continue,
                            };
                            if (url.len > 0) try appendImagePart(&parts, url, allocator);
                        }
                        // input_file, refusal → no Gemini equivalent.
                    },
                    else => continue,
                }

                if (parts.items.len == 0) continue;
                try mergeOrAppend(&contents, role, try parts.toOwnedSlice(allocator), allocator);

            } else if (std.mem.eql(u8, item_type, "function_call")) {
                const name_val = obj.get("name") orelse continue;
                if (name_val != .string) continue;
                const args_val = obj.get("arguments") orelse std.json.Value{ .string = "{}" };
                const args_str: []const u8 = if (args_val == .string) args_val.string else "{}";

                const args: std.json.Value = std.json.parseFromSliceLeaky(
                    std.json.Value, allocator, args_str, .{},
                ) catch .null;

                var parts = try allocator.alloc(Google.Part, 1);
                parts[0] = .{ .function_call = .{ .name = name_val.string, .args = args } };
                try mergeOrAppend(&contents, "model", parts, allocator);

            } else if (std.mem.eql(u8, item_type, "function_call_output")) {
                const call_id_val = obj.get("call_id") orelse continue;
                if (call_id_val != .string) continue;

                const output_str: []const u8 = blk: {
                    const ov = obj.get("output") orelse break :blk "";
                    break :blk if (ov == .string) ov.string else "";
                };

                var resp_obj: std.json.ObjectMap = .{};
                errdefer resp_obj.deinit(allocator);
                try resp_obj.put(allocator, "output", .{ .string = output_str });

                var parts = try allocator.alloc(Google.Part, 1);
                parts[0] = .{ .function_response = .{
                    .name = call_id_val.string,
                    .response = .{ .object = resp_obj },
                } };
                try mergeOrAppend(&contents, "user", parts, allocator);
            }
            // reasoning: no Gemini input equivalent — dropped.
        },
    }

    if (contents.items.len == 0) return error.EmptyMessages;

    // Gemini requires user-first conversation.
    if (!std.mem.eql(u8, contents.items[0].role, "user")) {
        const synthetic = try allocator.alloc(Google.Part, 1);
        synthetic[0] = .{ .text = .{ .text = "[Conversation start]" } };
        try contents.insert(allocator, 0, .{ .role = "user", .parts = synthetic });
    }

    return contents.toOwnedSlice(allocator);
}

// ============================================================================
// System instruction mapping
// ============================================================================

/// Build a Gemini SystemInstruction from an Anthropic SystemParam.
///   .text  → one text Part
///   .blocks → one text Part per block, joined; parts slice is owned
pub fn buildSystemInstruction(
    sys: Messages.SystemParam,
    allocator: std.mem.Allocator,
) !Google.SystemInstruction {
    switch (sys) {
        .text => |t| {
            const parts = try allocator.alloc(Google.Part, 1);
            parts[0] = .{ .text = .{ .text = t } };
            return .{ .parts = parts };
        },
        .blocks => |blks| {
            const parts = try allocator.alloc(Google.Part, blks.len);
            for (blks, 0..) |blk, i| {
                parts[i] = .{ .text = .{ .text = blk.text } };
            }
            return .{ .parts = parts };
        },
    }
}

/// Build a Gemini SystemInstruction from a plain string (Chat/Responses flow).
/// The text is borrowed — only the parts slice is allocated.
pub fn buildSystemInstructionFromString(
    text: []const u8,
    allocator: std.mem.Allocator,
) !Google.SystemInstruction {
    const parts = try allocator.alloc(Google.Part, 1);
    parts[0] = .{ .text = .{ .text = text } };
    return .{ .parts = parts };
}

// ============================================================================
// Response mapping: Gemini wire → inbound schemas
// ============================================================================

/// Map Gemini finishReason to the Chat-schema finish_reason.
pub fn transformStopReason(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "stop";
    if (std.mem.eql(u8, r, "STOP")) return "stop";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "length";
    if (std.mem.eql(u8, r, "SAFETY")) return "content_filter";
    if (std.mem.eql(u8, r, "RECITATION")) return "content_filter";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_calls";
    return "stop";
}

/// Map Gemini finishReason to the Anthropic Messages stop_reason vocabulary.
pub fn transformStopReasonToMessages(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "end_turn";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "max_tokens";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_use";
    return "end_turn";
}

/// Join text parts of the first candidate into one string. Freshly allocated.
pub fn extractTextFromBlocks(
    response: Google.Response,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (response.candidates.len == 0) return allocator.dupe(u8, "");

    var parts_text: std.ArrayList([]const u8) = .empty;
    defer parts_text.deinit(allocator);

    for (response.candidates[0].content.parts) |part| {
        switch (part) {
            .text => |tp| if (tp.text.len > 0) try parts_text.append(allocator, tp.text),
            else => {},
        }
    }

    if (parts_text.items.len == 0) return allocator.dupe(u8, "");
    return std.mem.join(allocator, "", parts_text.items);
}

/// Extract function_call parts of the first candidate as Chat tool calls.
/// Gemini provides no call ids — synthetic `call_{name}` is used.
/// id and arguments are freshly allocated; free with freeToolCallList.
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

/// Free a tool-call list produced by extractToolCalls.
pub fn freeToolCallList(tool_calls: []const Chat.ToolCall, allocator: std.mem.Allocator) void {
    for (tool_calls) |tc| {
        allocator.free(tc.id);
        allocator.free(tc.function.arguments);
    }
    allocator.free(tool_calls);
}

// ============================================================================
// Chat streaming support
// ============================================================================

/// Everything a chat chunk needs besides its delta.
pub const ChatChunkContext = struct {
    id: []const u8,
    created: i64,
    original_model: []const u8,
};

/// Serialize one `chat.completion.chunk` as a ready `data: {json}\n\n` line.
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

// ============================================================================
// Responses SSE helper
// ============================================================================

/// Write a single Responses SSE event: `event: {type}\ndata: {json}\n\n`.
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

// ============================================================================
// Cleanup helpers
// ============================================================================

/// Free a `std.json.Value` tree produced by parseFromSliceLeaky.
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

/// Free request-owned memory from chat-flow parts:
///   function_call → leaky-parsed args tree
///   function_response → hand-built ObjectMap storage
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

/// Free request-owned memory from messages-flow parts:
///   function_call → args BORROW the inbound parse, not freed here
///   function_response → hand-built ObjectMap storage
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

/// Free request-owned memory from responses-flow parts:
///   function_call → leaky-parsed args tree (same as chat flow)
///   function_response → hand-built ObjectMap storage
pub fn freeResponsesOwnedArgs(part: Google.Part, allocator: std.mem.Allocator) void {
    freeResponseOwnedArgs(part, allocator);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Append an image URL as a Gemini Part.
/// data: URI → inline_data (base64); https:// or other URL → file_data.
fn appendImagePart(
    parts: *std.ArrayList(Google.Part),
    url: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (std.mem.startsWith(u8, url, "data:")) {
        // data:<media_type>;base64,<data>
        const comma_idx = std.mem.indexOfScalar(u8, url, ',') orelse return;
        const semicolon_idx = std.mem.indexOfScalar(u8, url[5..], ';') orelse return;
        const media_type = url[5 .. 5 + semicolon_idx];
        const data = url[comma_idx + 1 ..];
        try parts.append(allocator, .{ .inline_data = .{ .mime_type = media_type, .data = data } });
    } else {
        // URL-based image: use file_data with an empty mime_type (Gemini infers it).
        try parts.append(allocator, .{ .file_data = .{ .mime_type = "", .file_uri = url } });
    }
}

/// Merge `new_parts` into the last content turn if same role, otherwise append.
/// Takes ownership of `new_parts`.
fn mergeOrAppend(
    contents: *std.ArrayList(Google.Content),
    role: []const u8,
    new_parts: []Google.Part,
    allocator: std.mem.Allocator,
) !void {
    if (contents.items.len > 0) {
        const last = &contents.items[contents.items.len - 1];
        if (std.mem.eql(u8, last.role, role)) {
            // Extend the existing turn's parts slice.
            const merged = try allocator.alloc(Google.Part, last.parts.len + new_parts.len);
            @memcpy(merged[0..last.parts.len], last.parts);
            @memcpy(merged[last.parts.len..], new_parts);
            allocator.free(last.parts);
            allocator.free(new_parts);
            last.parts = merged;
            return;
        }
    }
    try contents.append(allocator, .{ .role = role, .parts = new_parts });
}
