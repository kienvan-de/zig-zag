// SPDX-License-Identifier: Apache-2.0
//! OpenAI /v1/responses types.
//!
//! The Responses API is a stateful, multi-modal alternative to /v1/chat/completions.
//! Key differences: input[] instead of messages[], output[] instead of choices[],
//! input_tokens/output_tokens instead of prompt_tokens/completion_tokens,
//! built-in tools (web search, file search, computer use, code interpreter),
//! and optional server-side state management via previous_response_id.

const std = @import("std");
const common = @import("types.zig");

// ============================================================================
// Tool definitions
// ============================================================================

/// Tool definition for the Responses API — flat format for "function" type,
/// plus pass-through for built-in tools (web_search_preview, file_search, etc.)
pub const Tool = union(enum) {
    function: struct {
        type: []const u8 = "function",
        function: common.ToolFunction,
    },
    /// Pass-through for built-in and unknown tool types
    other: std.json.Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return .{ .other = source };
        const obj = source.object;
        const type_val = obj.get("type") orelse return .{ .other = source };
        if (type_val != .string) return .{ .other = source };

        if (std.mem.eql(u8, type_val.string, "function")) {
            // Flat format: {"type":"function","name":...,"description":...,"parameters":...}
            if (obj.get("name")) |name_val| {
                if (name_val != .string) return error.UnexpectedToken;
                const desc = if (obj.get("description")) |d| (if (d == .string) d.string else null) else null;
                const params = obj.get("parameters");
                const strict = if (obj.get("strict")) |s| (if (s == .bool) s.bool else null) else null;
                return .{ .function = .{ .function = .{
                    .name = name_val.string,
                    .description = desc,
                    .parameters = params,
                    .strict = strict,
                } } };
            }
            // Nested Chat Completions format fallback: {"type":"function","function":{...}}
            if (obj.get("function")) |func_val| {
                const func = try std.json.parseFromValueLeaky(common.ToolFunction, allocator, func_val, options);
                return .{ .function = .{ .function = func } };
            }
            return error.MissingField;
        } else {
            return .{ .other = source };
        }
    }

    /// Serialize in flat Responses API format.
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .function => |f| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write("function");
                try jw.objectField("name"); try jw.write(f.function.name);
                if (f.function.description) |d| { try jw.objectField("description"); try jw.write(d); }
                if (f.function.parameters) |p| { try jw.objectField("parameters"); try jw.write(p); }
                if (f.function.strict) |s| { try jw.objectField("strict"); try jw.write(s); }
                try jw.endObject();
            },
            .other => |v| try jw.write(v),
        }
    }
};

// ============================================================================
// Request
// ============================================================================

/// Text output configuration
pub const ResponseTextParam = struct {
    format: ?common.ResponseFormat = null,
    verbosity: ?[]const u8 = null,
};

/// Prompt template reference (id + version + variables)
pub const PromptParam = struct {
    id: []const u8,
    version: ?[]const u8 = null,
    variables: ?std.json.Value = null,
};

/// Input parameter — string or array of input items
pub const InputParam = union(enum) {
    text: []const u8,
    items: []const std.json.Value, // polymorphic: message | item_reference

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        switch (source) {
            .string => |s| return .{ .text = s },
            .array => |arr| {
                const items = try allocator.dupe(std.json.Value, arr.items);
                return .{ .items = items };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |t| try jw.write(t),
            .items => |items| {
                try jw.beginArray();
                for (items) |item| try jw.write(item);
                try jw.endArray();
            },
        }
    }
};

/// POST /v1/responses request body
pub const Request = struct {
    model: []const u8,
    input: InputParam,
    instructions: ?[]const u8 = null,
    previous_response_id: ?[]const u8 = null,
    stream: ?bool = null,
    stream_options: ?common.StreamOptions = null,
    tools: ?[]const Tool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    reasoning: ?std.json.Value = null,
    text: ?ResponseTextParam = null,
    store: ?bool = null,
    max_output_tokens: ?u32 = null,
    include: ?[]const []const u8 = null,
    truncation: ?[]const u8 = null,
    background: ?bool = null,
    max_tool_calls: ?u32 = null,
    conversation: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_logprobs: ?u8 = null,
    service_tier: ?[]const u8 = null,
    moderation: ?std.json.Value = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    user: ?[]const u8 = null,
    prompt: ?PromptParam = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const val = try std.json.Value.jsonParse(allocator, source, options);
        return try jsonParseFromValue(allocator, val, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const model = if (obj.get("model")) |v| switch (v) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        const input_val = obj.get("input") orelse return error.MissingField;
        const input = try InputParam.jsonParseFromValue(allocator, input_val, options);

        var result = Request{ .model = model, .input = input };

        if (obj.get("instructions")) |v| { result.instructions = if (v == .string) v.string else null; }
        if (obj.get("previous_response_id")) |v| { result.previous_response_id = if (v == .string) v.string else null; }
        if (obj.get("stream")) |v| { result.stream = if (v == .bool) v.bool else null; }
        if (obj.get("stream_options")) |v| {
            if (v == .object) result.stream_options = try std.json.parseFromValueLeaky(common.StreamOptions, allocator, v, .{});
        }
        if (obj.get("tools")) |v| {
            if (v == .array) {
                const tools = try allocator.alloc(Tool, v.array.items.len);
                for (v.array.items, 0..) |tv, i| tools[i] = try Tool.jsonParseFromValue(allocator, tv, options);
                result.tools = tools;
            }
        }
        if (obj.get("tool_choice")) |v| { result.tool_choice = v; }
        if (obj.get("parallel_tool_calls")) |v| { result.parallel_tool_calls = if (v == .bool) v.bool else null; }
        if (obj.get("reasoning")) |v| { result.reasoning = v; }
        if (obj.get("text")) |v| {
            if (v == .object) {
                const fmt = if (v.object.get("format")) |f| blk: {
                    if (f == .object) {
                        const ft = if (f.object.get("type")) |t| (if (t == .string) t.string else "text") else "text";
                        const name = if (f.object.get("name")) |n| (if (n == .string) n.string else null) else null;
                        const desc = if (f.object.get("description")) |d| (if (d == .string) d.string else null) else null;
                        const schema = f.object.get("schema");
                        const strict = if (f.object.get("strict")) |s| (if (s == .bool) s.bool else null) else null;
                        break :blk common.ResponseFormat{
                            .type = ft,
                            .json_schema = f.object.get("json_schema"),
                            .name = name,
                            .description = desc,
                            .schema = schema,
                            .strict = strict,
                        };
                    }
                    break :blk null;
                } else null;
                const verb = if (v.object.get("verbosity")) |vb| (if (vb == .string) vb.string else null) else null;
                result.text = .{ .format = fmt, .verbosity = verb };
            }
        }
        if (obj.get("store")) |v| { result.store = if (v == .bool) v.bool else null; }
        if (obj.get("max_output_tokens")) |v| { result.max_output_tokens = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("include")) |v| {
            if (v == .array) {
                const inc = try allocator.alloc([]const u8, v.array.items.len);
                for (v.array.items, 0..) |item, i| inc[i] = if (item == .string) item.string else "";
                result.include = inc;
            }
        }
        if (obj.get("truncation")) |v| { result.truncation = if (v == .string) v.string else null; }
        if (obj.get("background")) |v| { result.background = if (v == .bool) v.bool else null; }
        if (obj.get("max_tool_calls")) |v| { result.max_tool_calls = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("conversation")) |v| { result.conversation = v; }
        if (obj.get("context_management")) |v| { result.context_management = v; }
        if (obj.get("metadata")) |v| { result.metadata = v; }
        if (obj.get("temperature")) |v| { result.temperature = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("top_p")) |v| { result.top_p = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("top_logprobs")) |v| { result.top_logprobs = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("service_tier")) |v| { result.service_tier = if (v == .string) v.string else null; }
        if (obj.get("moderation")) |v| { result.moderation = v; }
        if (obj.get("safety_identifier")) |v| { result.safety_identifier = if (v == .string) v.string else null; }
        if (obj.get("prompt_cache_key")) |v| { result.prompt_cache_key = if (v == .string) v.string else null; }
        if (obj.get("prompt_cache_options")) |v| { result.prompt_cache_options = v; }
        if (obj.get("user")) |v| { result.user = if (v == .string) v.string else null; }
        if (obj.get("prompt")) |v| {
            if (v == .object) {
                const id = if (v.object.get("id")) |id_v| (if (id_v == .string) id_v.string else return error.MissingField) else return error.MissingField;
                const ver = if (v.object.get("version")) |ver_v| (if (ver_v == .string) ver_v.string else null) else null;
                result.prompt = .{ .id = id, .version = ver, .variables = v.object.get("variables") };
            }
        }

        return result;
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("input"); try self.input.jsonStringify(jw);
        if (self.instructions) |v| { try jw.objectField("instructions"); try jw.write(v); }
        if (self.previous_response_id) |v| { try jw.objectField("previous_response_id"); try jw.write(v); }
        if (self.stream) |v| { try jw.objectField("stream"); try jw.write(v); }
        if (self.stream_options) |v| { try jw.objectField("stream_options"); try jw.write(v); }
        if (self.tools) |v| { try jw.objectField("tools"); try jw.write(v); }
        if (self.tool_choice) |v| { try jw.objectField("tool_choice"); try jw.write(v); }
        if (self.parallel_tool_calls) |v| { try jw.objectField("parallel_tool_calls"); try jw.write(v); }
        if (self.reasoning) |v| { try jw.objectField("reasoning"); try jw.write(v); }
        if (self.text) |v| { try jw.objectField("text"); try jw.write(v); }
        if (self.store) |v| { try jw.objectField("store"); try jw.write(v); }
        if (self.max_output_tokens) |v| { try jw.objectField("max_output_tokens"); try jw.write(v); }
        if (self.include) |v| { try jw.objectField("include"); try jw.write(v); }
        if (self.truncation) |v| { try jw.objectField("truncation"); try jw.write(v); }
        if (self.background) |v| { try jw.objectField("background"); try jw.write(v); }
        if (self.max_tool_calls) |v| { try jw.objectField("max_tool_calls"); try jw.write(v); }
        if (self.conversation) |v| { try jw.objectField("conversation"); try jw.write(v); }
        if (self.context_management) |v| { try jw.objectField("context_management"); try jw.write(v); }
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.temperature) |v| { try jw.objectField("temperature"); try jw.write(v); }
        if (self.top_p) |v| { try jw.objectField("top_p"); try jw.write(v); }
        if (self.top_logprobs) |v| { try jw.objectField("top_logprobs"); try jw.write(v); }
        if (self.service_tier) |v| { try jw.objectField("service_tier"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        if (self.safety_identifier) |v| { try jw.objectField("safety_identifier"); try jw.write(v); }
        if (self.prompt_cache_key) |v| { try jw.objectField("prompt_cache_key"); try jw.write(v); }
        if (self.prompt_cache_options) |v| { try jw.objectField("prompt_cache_options"); try jw.write(v); }
        if (self.user) |v| { try jw.objectField("user"); try jw.write(v); }
        if (self.prompt) |v| { try jw.objectField("prompt"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Response — output items
// ============================================================================

/// Text content inside an OutputMessage
pub const OutputTextContent = struct {
    type: []const u8 = "output_text",
    text: []const u8,
    annotations: ?std.json.Value = null,
    logprobs: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type"); try jw.write(self.type);
        try jw.objectField("text"); try jw.write(self.text);
        if (self.annotations) |v| { try jw.objectField("annotations"); try jw.write(v); }
        if (self.logprobs) |v| { try jw.objectField("logprobs"); try jw.write(v); }
        try jw.endObject();
    }
};

/// Content inside an output message — text or refusal
pub const OutputContent = union(enum) {
    output_text: OutputTextContent,
    refusal: struct {
        type: []const u8 = "refusal",
        refusal: []const u8,
    },
    other: std.json.Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .object) return .{ .other = source };
        const obj = source.object;
        const type_val = obj.get("type") orelse return .{ .other = source };
        if (type_val != .string) return .{ .other = source };

        if (std.mem.eql(u8, type_val.string, "output_text")) {
            const text = if (obj.get("text")) |t| (if (t == .string) t.string else "") else "";
            return .{ .output_text = .{
                .type = type_val.string,
                .text = text,
                .annotations = obj.get("annotations"),
                .logprobs = obj.get("logprobs"),
            } };
        } else if (std.mem.eql(u8, type_val.string, "refusal")) {
            const refusal = if (obj.get("refusal")) |r| (if (r == .string) r.string else "") else "";
            return .{ .refusal = .{ .type = type_val.string, .refusal = refusal } };
        } else {
            return .{ .other = source };
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .output_text => |v| try v.jsonStringify(jw),
            .refusal => |v| try jw.write(v),
            .other => |v| try jw.write(v),
        }
    }
};

/// Assistant message in the output array
pub const OutputMessage = struct {
    id: []const u8 = "",
    type: []const u8 = "message",
    role: []const u8 = "assistant",
    content: []const OutputContent,
    status: ?[]const u8 = null,
    phase: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id"); try jw.write(self.id);
        try jw.objectField("type"); try jw.write(self.type);
        try jw.objectField("role"); try jw.write(self.role);
        try jw.objectField("content");
        try jw.beginArray();
        for (self.content) |c| try c.jsonStringify(jw);
        try jw.endArray();
        if (self.status) |v| { try jw.objectField("status"); try jw.write(v); }
        if (self.phase) |v| { try jw.objectField("phase"); try jw.write(v); }
        try jw.endObject();
    }
};

/// An item in the output array — polymorphic
pub const OutputItem = union(enum) {
    message: OutputMessage,
    function_call: struct {
        id: []const u8 = "",
        type: []const u8 = "function_call",
        name: []const u8 = "",
        arguments: []const u8 = "",
        call_id: ?[]const u8 = null,
        status: ?[]const u8 = null,
        @"async": ?bool = null,
        namespace: ?[]const u8 = null,
        caller: ?std.json.Value = null,
    },
    reasoning: struct {
        id: []const u8 = "",
        type: []const u8 = "reasoning",
        summary: ?std.json.Value = null,
        encrypted_content: ?std.json.Value = null,
        status: ?[]const u8 = null,
    },
    other: std.json.Value,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return .{ .other = source };
        const obj = source.object;
        const type_val = obj.get("type") orelse return .{ .other = source };
        if (type_val != .string) return .{ .other = source };

        if (std.mem.eql(u8, type_val.string, "message")) {
            const id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "";
            const role = if (obj.get("role")) |v| (if (v == .string) v.string else "assistant") else "assistant";
            const status = if (obj.get("status")) |v| (if (v == .string) v.string else null) else null;
            const phase = if (obj.get("phase")) |v| (if (v == .string) v.string else null) else null;
            const content_val = obj.get("content") orelse return .{ .other = source };
            const content = if (content_val == .array) blk: {
                const items = try allocator.alloc(OutputContent, content_val.array.items.len);
                for (content_val.array.items, 0..) |item, i| {
                    items[i] = try OutputContent.jsonParseFromValue(allocator, item, options);
                }
                break :blk items;
            } else try allocator.alloc(OutputContent, 0);
            return .{ .message = .{ .id = id, .type = type_val.string, .role = role, .content = content, .status = status, .phase = phase } };
        } else if (std.mem.eql(u8, type_val.string, "function_call")) {
            return .{ .function_call = .{
                .id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "",
                .type = type_val.string,
                .name = if (obj.get("name")) |v| (if (v == .string) v.string else "") else "",
                .arguments = if (obj.get("arguments")) |v| (if (v == .string) v.string else "") else "",
                .call_id = if (obj.get("call_id")) |v| (if (v == .string) v.string else null) else null,
                .status = if (obj.get("status")) |v| (if (v == .string) v.string else null) else null,
                .@"async" = if (obj.get("async")) |v| (if (v == .bool) v.bool else null) else null,
                .namespace = if (obj.get("namespace")) |v| (if (v == .string) v.string else null) else null,
                .caller = obj.get("caller"),
            } };
        } else if (std.mem.eql(u8, type_val.string, "reasoning")) {
            return .{ .reasoning = .{
                .id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "",
                .type = type_val.string,
                .summary = obj.get("summary"),
                .encrypted_content = obj.get("encrypted_content"),
                .status = if (obj.get("status")) |v| (if (v == .string) v.string else null) else null,
            } };
        } else {
            return .{ .other = source };
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .message => |v| try v.jsonStringify(jw),
            .function_call => |v| try jw.write(v),
            .reasoning => |v| try jw.write(v),
            .other => |v| try jw.write(v),
        }
    }
};

// ============================================================================
// Usage (responses API renames prompt→input, completion→output)
// ============================================================================

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    total_tokens: u32 = 0,
    input_tokens_details: ?std.json.Value = null,
    output_tokens_details: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("input_tokens"); try jw.write(self.input_tokens);
        try jw.objectField("output_tokens"); try jw.write(self.output_tokens);
        try jw.objectField("total_tokens"); try jw.write(self.total_tokens);
        if (self.input_tokens_details) |v| { try jw.objectField("input_tokens_details"); try jw.write(v); }
        if (self.output_tokens_details) |v| { try jw.objectField("output_tokens_details"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Response
// ============================================================================

/// POST /v1/responses response body (`object: "response"`)
pub const Response = struct {
    id: []const u8,
    object: []const u8 = "response",
    created_at: f64 = 0,
    completed_at: ?f64 = null,
    model: []const u8,
    status: []const u8 = "completed",
    output: []const OutputItem,
    output_text: ?[]const u8 = null,
    usage: ?Usage = null,
    incomplete_details: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    tools: ?std.json.Value = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_logprobs: ?u8 = null,
    store: ?bool = null,
    background: ?bool = null,
    max_output_tokens: ?u32 = null,
    max_tool_calls: ?u32 = null,
    truncation: ?[]const u8 = null,
    parallel_tool_calls: bool = true,
    previous_response_id: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    conversation: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    prompt_cache_diagnostics: ?std.json.Value = null,
    prompt: ?std.json.Value = null,
    text: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id"); try jw.write(self.id);
        try jw.objectField("object"); try jw.write(self.object);
        try jw.objectField("created_at"); try jw.write(self.created_at);
        if (self.completed_at) |v| { try jw.objectField("completed_at"); try jw.write(v); }
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("status"); try jw.write(self.status);
        try jw.objectField("output");
        try jw.beginArray();
        for (self.output) |item| try item.jsonStringify(jw);
        try jw.endArray();
        if (self.output_text) |v| { try jw.objectField("output_text"); try jw.write(v); }
        if (self.usage) |u| { try jw.objectField("usage"); try u.jsonStringify(jw); }
        try jw.objectField("parallel_tool_calls"); try jw.write(self.parallel_tool_calls);
        if (self.incomplete_details) |v| { try jw.objectField("incomplete_details"); try jw.write(v); }
        if (self.@"error") |v| { try jw.objectField("error"); try jw.write(v); }
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.reasoning) |v| { try jw.objectField("reasoning"); try jw.write(v); }
        if (self.instructions) |v| { try jw.objectField("instructions"); try jw.write(v); }
        if (self.tool_choice) |v| { try jw.objectField("tool_choice"); try jw.write(v); }
        if (self.tools) |v| { try jw.objectField("tools"); try jw.write(v); }
        if (self.temperature) |v| { try jw.objectField("temperature"); try jw.write(v); }
        if (self.top_p) |v| { try jw.objectField("top_p"); try jw.write(v); }
        if (self.top_logprobs) |v| { try jw.objectField("top_logprobs"); try jw.write(v); }
        if (self.store) |v| { try jw.objectField("store"); try jw.write(v); }
        if (self.background) |v| { try jw.objectField("background"); try jw.write(v); }
        if (self.max_output_tokens) |v| { try jw.objectField("max_output_tokens"); try jw.write(v); }
        if (self.max_tool_calls) |v| { try jw.objectField("max_tool_calls"); try jw.write(v); }
        if (self.truncation) |v| { try jw.objectField("truncation"); try jw.write(v); }
        if (self.previous_response_id) |v| { try jw.objectField("previous_response_id"); try jw.write(v); }
        if (self.service_tier) |v| { try jw.objectField("service_tier"); try jw.write(v); }
        if (self.conversation) |v| { try jw.objectField("conversation"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        if (self.safety_identifier) |v| { try jw.objectField("safety_identifier"); try jw.write(v); }
        if (self.prompt_cache_key) |v| { try jw.objectField("prompt_cache_key"); try jw.write(v); }
        if (self.prompt_cache_options) |v| { try jw.objectField("prompt_cache_options"); try jw.write(v); }
        if (self.prompt_cache_diagnostics) |v| { try jw.objectField("prompt_cache_diagnostics"); try jw.write(v); }
        if (self.prompt) |v| { try jw.objectField("prompt"); try jw.write(v); }
        if (self.text) |v| { try jw.objectField("text"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Streaming — SSE event wrapper + payload types
// ============================================================================

/// Outer SSE event envelope: {type, sequence_number, ...payload}
/// The payload fields vary by event type; callers dispatch on `type`.
pub const StreamEvent = union(enum) {
    /// response.created / response.in_progress / response.queued — initial response shell
    response_created: Response,
    /// response.output_text.delta — incremental text
    output_text_delta: struct {
        type: []const u8 = "response.output_text.delta",
        item_id: []const u8 = "",
        output_index: u32 = 0,
        content_index: u32 = 0,
        delta: []const u8 = "",
        logprobs: ?std.json.Value = null,
    },
    /// response.output_text.done — text content complete
    output_text_done: struct {
        type: []const u8 = "response.output_text.done",
        item_id: []const u8 = "",
        output_index: u32 = 0,
        content_index: u32 = 0,
        text: []const u8 = "",
        logprobs: ?std.json.Value = null,
    },
    /// response.completed — final response with all output
    response_completed: Response,
    /// response.failed / response.incomplete — terminal error/cutoff
    response_failed: Response,
    /// error event
    @"error": common.ErrorResponse,
    /// Any other event type — passed through opaquely
    other: std.json.Value,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .response_created => |v| try v.jsonStringify(jw),
            .output_text_delta => |v| try jw.write(v),
            .output_text_done => |v| try jw.write(v),
            .response_completed => |v| try v.jsonStringify(jw),
            .response_failed => |v| try v.jsonStringify(jw),
            .@"error" => |v| try v.jsonStringify(jw),
            .other => |v| try jw.write(v),
        }
    }
};

/// Result type for responses stream line transformation
pub const StreamLineResult = union(enum) {
    event: StreamEvent,
    @"error": common.ErrorResponse,
    skip: void,
};
