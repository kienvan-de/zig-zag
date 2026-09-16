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

pub const MCPToolFilter = struct {
    tool_names: []const []const u8 = &.{},
    read_only: ?bool = null,
};

/// Tool definition for the Responses API — flat format for "function" type,
/// plus pass-through for built-in tools (web_search_preview, file_search, etc.)
pub const Tool = union(enum) {
    function: struct {
        type: []const u8 = "function",
        function: common.ToolFunction,
    },
    web_search_preview: struct {
        type: []const u8 = "web_search_preview",
        search_context_size: ?[]const u8 = null,
        user_location: ?struct {
            type: []const u8 = "approximate",
            country: ?[]const u8 = null,
            city: ?[]const u8 = null,
            region: ?[]const u8 = null,
            timezone: ?[]const u8 = null,
        } = null,
    },
    file_search: struct {
        type: []const u8 = "file_search",
        vector_store_ids: []const []const u8 = &.{},
        max_num_results: ?u32 = null,
        filters: ?std.json.Value = null,
        ranking_options: ?struct {
            ranker: ?[]const u8 = null,
            score_threshold: ?f32 = null,
        } = null,
    },
    code_interpreter_tool: struct {
        type: []const u8 = "code_interpreter",
        container: ?struct {
            type: []const u8 = "",
        } = null,
    },
    mcp_tool: struct {
        type: []const u8 = "mcp",
        server_label: []const u8 = "",
        server_url: []const u8 = "",
        allowed_tools: ?MCPToolFilter = null,
        headers: ?std.json.Value = null,
        require_approval: ?[]const u8 = null,
        connector_id: ?[]const u8 = null,
        tunnel_id: ?[]const u8 = null,
        authorization: ?[]const u8 = null,
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
            // Flat Responses API format: {"type":"function","name":...,"description":...,"parameters":...}
            const name_val = obj.get("name") orelse return error.MissingField;
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
        } else if (std.mem.eql(u8, type_val.string, "web_search_preview")) {
            return .{ .web_search_preview = try std.json.innerParseFromValue(
                @TypeOf(@as(Tool, .{ .web_search_preview = .{} }).web_search_preview),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "file_search")) {
            return .{ .file_search = try std.json.innerParseFromValue(
                @TypeOf(@as(Tool, .{ .file_search = .{} }).file_search),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "code_interpreter")) {
            return .{ .code_interpreter_tool = try std.json.innerParseFromValue(
                @TypeOf(@as(Tool, .{ .code_interpreter_tool = .{} }).code_interpreter_tool),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "mcp")) {
            const server_label = if (obj.get("server_label")) |v| (if (v == .string) v.string else "") else "";
            const server_url = if (obj.get("server_url")) |v| (if (v == .string) v.string else "") else "";
            const allowed_tools: ?MCPToolFilter = if (obj.get("allowed_tools")) |at| blk: {
                if (at != .object) break :blk null;
                const tool_names: []const []const u8 = if (at.object.get("tool_names")) |tn| blk2: {
                    if (tn != .array) break :blk2 &.{};
                    const names = try allocator.alloc([]const u8, tn.array.items.len);
                    for (tn.array.items, 0..) |item, i| names[i] = if (item == .string) item.string else "";
                    break :blk2 names;
                } else &.{};
                const read_only: ?bool = if (at.object.get("read_only")) |ro| (if (ro == .bool) ro.bool else null) else null;
                break :blk MCPToolFilter{ .tool_names = tool_names, .read_only = read_only };
            } else null;
            const headers = obj.get("headers");
            const require_approval = if (obj.get("require_approval")) |v| (if (v == .string) v.string else null) else null;
            const connector_id = if (obj.get("connector_id")) |v| (if (v == .string) v.string else null) else null;
            const tunnel_id = if (obj.get("tunnel_id")) |v| (if (v == .string) v.string else null) else null;
            const authorization = if (obj.get("authorization")) |v| (if (v == .string) v.string else null) else null;
            return .{ .mcp_tool = .{
                .server_label = server_label,
                .server_url = server_url,
                .allowed_tools = allowed_tools,
                .headers = headers,
                .require_approval = require_approval,
                .connector_id = connector_id,
                .tunnel_id = tunnel_id,
                .authorization = authorization,
            } };
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
            inline .web_search_preview, .file_search, .code_interpreter_tool, .mcp_tool => |v| try jw.write(v),
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
    verbosity: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,

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
        if (obj.get("verbosity")) |v| { result.verbosity = if (v == .string) v.string else null; }
        if (obj.get("reasoning_effort")) |v| { result.reasoning_effort = if (v == .string) v.string else null; }

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
        if (self.verbosity) |v| { try jw.objectField("verbosity"); try jw.write(v); }
        if (self.reasoning_effort) |v| { try jw.objectField("reasoning_effort"); try jw.write(v); }
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
    annotations: ?[]const OutputAnnotation = null,
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

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .object) return .{ .other = source };
        const obj = source.object;
        const type_val = obj.get("type") orelse return .{ .other = source };
        if (type_val != .string) return .{ .other = source };

        if (std.mem.eql(u8, type_val.string, "output_text")) {
            const text = if (obj.get("text")) |t| (if (t == .string) t.string else "") else "";
            const ann_val = obj.get("annotations");
            const annotations: ?[]const OutputAnnotation = if (ann_val) |av| blk: {
                if (av != .array) break :blk null;
                const anns = try allocator.alloc(OutputAnnotation, av.array.items.len);
                for (av.array.items, 0..) |item, i| {
                    anns[i] = try OutputAnnotation.jsonParseFromValue(allocator, item, .{});
                }
                break :blk anns;
            } else null;
            return .{ .output_text = .{
                .type = type_val.string,
                .text = text,
                .annotations = annotations,
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
        content: []const std.json.Value = &.{},
    },
    web_search_call: struct {
        type: []const u8 = "web_search_call",
        id: []const u8 = "",
        status: []const u8 = "",
        action: ?struct {
            type: []const u8 = "",
            query: []const u8 = "",
        } = null,
    },
    file_search_call: struct {
        type: []const u8 = "file_search_call",
        id: []const u8 = "",
        status: []const u8 = "",
        queries: []const []const u8 = &.{},
        results: []const std.json.Value = &.{},
    },
    code_interpreter_call: struct {
        type: []const u8 = "code_interpreter_call",
        id: []const u8 = "",
        status: []const u8 = "",
        code: []const u8 = "",
        results: []const std.json.Value = &.{},
    },
    mcp_list_tools_item: struct {
        type: []const u8 = "mcp_list_tools",
        id: []const u8 = "",
        server_label: []const u8 = "",
        status: []const u8 = "",
        tools: []const std.json.Value = &.{},
        @"error": ?[]const u8 = null,
    },
    mcp_call_item: struct {
        type: []const u8 = "mcp_call",
        id: []const u8 = "",
        server_label: []const u8 = "",
        name: []const u8 = "",
        arguments: []const u8 = "",
        status: []const u8 = "",
        output: ?[]const u8 = null,
        @"error": ?std.json.Value = null,
        approval_request_id: ?[]const u8 = null,
    },
    image_generation_call: struct {
        type: []const u8 = "image_generation_call",
        id: []const u8 = "",
        status: []const u8 = "",
        result: ?[]const u8 = null,
        size: ?[]const u8 = null,
        quality: ?[]const u8 = null,
        action: ?std.json.Value = null,
        background: ?[]const u8 = null,
        output_format: ?[]const u8 = null,
        revised_prompt: ?[]const u8 = null,
    },
    local_shell_call: struct {
        type: []const u8 = "local_shell_call",
        id: []const u8 = "",
        call_id: []const u8 = "",
        status: []const u8 = "",
        action: ?struct {
            type: []const u8 = "",
            command: []const []const u8 = &.{},
            env: ?std.json.Value = null,
            timeout_ms: ?u32 = null,
            working_directory: ?[]const u8 = null,
            user: ?[]const u8 = null,
        } = null,
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
            const reasoning_content: []const std.json.Value = if (obj.get("content")) |cv| blk: {
                if (cv != .array) break :blk &.{};
                const items = try allocator.dupe(std.json.Value, cv.array.items);
                break :blk items;
            } else &.{};
            return .{ .reasoning = .{
                .id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "",
                .type = type_val.string,
                .summary = obj.get("summary"),
                .encrypted_content = obj.get("encrypted_content"),
                .status = if (obj.get("status")) |v| (if (v == .string) v.string else null) else null,
                .content = reasoning_content,
            } };
        } else if (std.mem.eql(u8, type_val.string, "web_search_call")) {
            return .{ .web_search_call = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .web_search_call = .{} }).web_search_call),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "file_search_call")) {
            return .{ .file_search_call = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .file_search_call = .{} }).file_search_call),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "code_interpreter_call")) {
            return .{ .code_interpreter_call = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .code_interpreter_call = .{} }).code_interpreter_call),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "mcp_list_tools")) {
            return .{ .mcp_list_tools_item = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .mcp_list_tools_item = .{} }).mcp_list_tools_item),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "mcp_call")) {
            return .{ .mcp_call_item = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .mcp_call_item = .{} }).mcp_call_item),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "image_generation_call")) {
            return .{ .image_generation_call = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .image_generation_call = .{} }).image_generation_call),
                allocator, source, options,
            ) };
        } else if (std.mem.eql(u8, type_val.string, "local_shell_call")) {
            return .{ .local_shell_call = try std.json.innerParseFromValue(
                @TypeOf(@as(OutputItem, .{ .local_shell_call = .{} }).local_shell_call),
                allocator, source, options,
            ) };
        } else {
            return .{ .other = source };
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .message => |v| try v.jsonStringify(jw),
            .function_call => |v| try jw.write(v),
            .reasoning => |v| {
                try jw.beginObject();
                try jw.objectField("id"); try jw.write(v.id);
                try jw.objectField("type"); try jw.write(v.type);
                if (v.summary) |s| { try jw.objectField("summary"); try jw.write(s); }
                if (v.encrypted_content) |e| { try jw.objectField("encrypted_content"); try jw.write(e); }
                if (v.status) |s| { try jw.objectField("status"); try jw.write(s); }
                try jw.objectField("content"); try jw.write(v.content);
                try jw.endObject();
            },
            inline .web_search_call, .file_search_call, .code_interpreter_call,
            .mcp_list_tools_item, .mcp_call_item, .image_generation_call,
            .local_shell_call => |v| try jw.write(v),
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
    input_tokens_details: ?common.PromptTokensDetails = null,
    output_tokens_details: ?common.CompletionTokensDetails = null,

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
    tools: ?[]const Tool = null,
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
    moderation: ?ModerationOutput = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    prompt_cache_diagnostics: ?PromptCacheDiagnostics = null,
    prompt: ?std.json.Value = null,
    text: ?std.json.Value = null,
    user: ?[]const u8 = null,

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
        if (self.user) |v| { try jw.objectField("user"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Annotation types
// ============================================================================

pub const ModerationCategories = struct {
    harassment: bool = false,
    @"harassment/threatening": bool = false,
    hate: bool = false,
    @"hate/threatening": bool = false,
    illicit: bool = false,
    @"illicit/violent": bool = false,
    @"self-harm": bool = false,
    @"self-harm/instructions": bool = false,
    @"self-harm/intent": bool = false,
    sexual: bool = false,
    @"sexual/minors": bool = false,
    violence: bool = false,
    @"violence/graphic": bool = false,
};

pub const ModerationResult = struct {
    type: []const u8 = "moderation_result",
    model: []const u8 = "",
    flagged: bool = false,
    categories: ?ModerationCategories = null,
    category_scores: ?std.json.Value = null,
    category_applied_input_types: ?std.json.Value = null,
};

pub const ModerationOutput = struct {
    input: ?ModerationResult = null,
    output: ?ModerationResult = null,
};

pub const PromptCacheDiagnostics = union(enum) {
    cache_miss: struct {
        type: []const u8 = "cache_miss",
        reason: []const u8 = "",
        cache_missed_tokens: u32 = 0,
        comparison_reusable_tokens: u32 = 0,
    },
    cache_hit: struct {
        type: []const u8 = "cache_hit",
    },
    comparison_response_not_found: struct {
        type: []const u8 = "comparison_response_not_found",
    },
    unavailable: struct {
        type: []const u8 = "unavailable",
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !PromptCacheDiagnostics {
        if (source != .object) return error.UnexpectedToken;
        const type_v = source.object.get("type") orelse return error.MissingField;
        if (type_v != .string) return error.UnexpectedToken;
        const t = type_v.string;
        if (std.mem.eql(u8, t, "cache_miss")) return .{ .cache_miss = try std.json.innerParseFromValue(@TypeOf(@as(PromptCacheDiagnostics, undefined).cache_miss), allocator, source, options) };
        if (std.mem.eql(u8, t, "cache_hit")) return .{ .cache_hit = .{} };
        if (std.mem.eql(u8, t, "comparison_response_not_found")) return .{ .comparison_response_not_found = .{} };
        if (std.mem.eql(u8, t, "unavailable")) return .{ .unavailable = .{} };
        return error.UnknownField;
    }
};

pub const UrlCitationAnnotation = struct {
    type: []const u8 = "url_citation",
    url: []const u8 = "",
    title: []const u8 = "",
    start_index: u32 = 0,
    end_index: u32 = 0,
};

pub const FileCitationAnnotation = struct {
    type: []const u8 = "file_citation",
    file_id: []const u8 = "",
    filename: []const u8 = "",
    index: u32 = 0,
};

pub const FilePathAnnotation = struct {
    type: []const u8 = "file_path",
    file_id: []const u8 = "",
    index: u32 = 0,
};

pub const ContainerFileCitationAnnotation = struct {
    type: []const u8 = "container_file_citation",
    container_id: []const u8 = "",
    file_id: []const u8 = "",
    start_index: u32 = 0,
    end_index: u32 = 0,
    filename: []const u8 = "",
};

pub const OutputAnnotation = union(enum) {
    url_citation: UrlCitationAnnotation,
    file_citation: FileCitationAnnotation,
    file_path: FilePathAnnotation,
    container_file_citation: ContainerFileCitationAnnotation,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !OutputAnnotation {
        if (source != .object) return error.UnexpectedToken;
        const type_v = source.object.get("type") orelse return error.MissingField;
        if (type_v != .string) return error.UnexpectedToken;
        const t = type_v.string;
        if (std.mem.eql(u8, t, "url_citation")) return .{ .url_citation = try std.json.innerParseFromValue(UrlCitationAnnotation, allocator, source, options) };
        if (std.mem.eql(u8, t, "file_citation")) return .{ .file_citation = try std.json.innerParseFromValue(FileCitationAnnotation, allocator, source, options) };
        if (std.mem.eql(u8, t, "file_path")) return .{ .file_path = try std.json.innerParseFromValue(FilePathAnnotation, allocator, source, options) };
        if (std.mem.eql(u8, t, "container_file_citation")) return .{ .container_file_citation = try std.json.innerParseFromValue(ContainerFileCitationAnnotation, allocator, source, options) };
        return error.UnknownField;
    }
};

// ============================================================================
// Streaming — SSE event wrapper + payload types
// ============================================================================

/// Typed SSE event for the Responses streaming API.
/// Every variant includes `sequence_number` (required by the official schema).
/// Each payload struct also carries `type` so std.json.stringify emits it.
pub const StreamEvent = union(enum) {
    // --- response lifecycle ---
    response_created: struct {
        type: []const u8 = "response.created",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },
    response_in_progress: struct {
        type: []const u8 = "response.in_progress",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },
    response_completed: struct {
        type: []const u8 = "response.completed",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },
    response_failed: struct {
        type: []const u8 = "response.failed",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },
    response_incomplete: struct {
        type: []const u8 = "response.incomplete",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },

    // --- output item ---
    output_item_added: struct {
        type: []const u8 = "response.output_item.added",
        sequence_number: u32,
        output_index: u32 = 0,
        item: OutputItem,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item"); try self.item.jsonStringify(jw);
            try jw.endObject();
        }
    },
    output_item_done: struct {
        type: []const u8 = "response.output_item.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item: OutputItem,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item"); try self.item.jsonStringify(jw);
            try jw.endObject();
        }
    },

    // --- content part ---
    content_part_added: struct {
        type: []const u8 = "response.content_part.added",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        part: OutputContent,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("part"); try self.part.jsonStringify(jw);
            try jw.endObject();
        }
    },
    content_part_done: struct {
        type: []const u8 = "response.content_part.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        part: OutputContent,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("part"); try self.part.jsonStringify(jw);
            try jw.endObject();
        }
    },

    // --- text streaming ---
    output_text_delta: struct {
        type: []const u8 = "response.output_text.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        delta: []const u8 = "",
        logprobs: ?[]const common.LogprobEntry = null,
    },
    output_text_done: struct {
        type: []const u8 = "response.output_text.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        text: []const u8 = "",
        logprobs: ?[]const common.LogprobEntry = null,
    },

    // --- function call streaming ---
    function_call_arguments_delta: struct {
        type: []const u8 = "response.function_call_arguments.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        call_id: ?[]const u8 = null,
        delta: []const u8 = "",
    },
    function_call_arguments_done: struct {
        type: []const u8 = "response.function_call_arguments.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        call_id: ?[]const u8 = null,
        arguments: []const u8 = "",
    },

    // --- error ---
    stream_error: struct {
        type: []const u8 = "error",
        sequence_number: u32,
        code: ?[]const u8 = null,
        message: []const u8 = "",
        param: ?[]const u8 = null,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            if (self.code) |v| { try jw.objectField("code"); try jw.write(v); }
            try jw.objectField("message"); try jw.write(self.message);
            if (self.param) |v| { try jw.objectField("param"); try jw.write(v); }
            try jw.endObject();
        }
    },

    // --- response queued ---
    response_queued: struct {
        type: []const u8 = "response.queued",
        sequence_number: u32,
        response: Response,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("response"); try self.response.jsonStringify(jw);
            try jw.endObject();
        }
    },

    // --- annotation ---
    output_text_annotation_added: struct {
        type: []const u8 = "response.output_text.annotation.added",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        annotation_index: u32 = 0,
        annotation: std.json.Value,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("annotation_index"); try jw.write(self.annotation_index);
            try jw.objectField("annotation"); try jw.write(self.annotation);
            try jw.endObject();
        }
    },

    // --- refusal streaming ---
    refusal_delta: struct {
        type: []const u8 = "response.refusal.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    refusal_done: struct {
        type: []const u8 = "response.refusal.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        refusal: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("refusal"); try jw.write(self.refusal);
            try jw.endObject();
        }
    },

    // --- reasoning text streaming ---
    reasoning_text_delta: struct {
        type: []const u8 = "response.reasoning_text.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    reasoning_text_done: struct {
        type: []const u8 = "response.reasoning_text.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        content_index: u32 = 0,
        text: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("content_index"); try jw.write(self.content_index);
            try jw.objectField("text"); try jw.write(self.text);
            try jw.endObject();
        }
    },

    // --- reasoning summary streaming ---
    reasoning_summary_part_added: struct {
        type: []const u8 = "response.reasoning_summary_part.added",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        summary_index: u32 = 0,
        part: std.json.Value,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("summary_index"); try jw.write(self.summary_index);
            try jw.objectField("part"); try jw.write(self.part);
            try jw.endObject();
        }
    },
    reasoning_summary_part_done: struct {
        type: []const u8 = "response.reasoning_summary_part.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        summary_index: u32 = 0,
        part: std.json.Value,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("summary_index"); try jw.write(self.summary_index);
            try jw.objectField("part"); try jw.write(self.part);
            try jw.endObject();
        }
    },
    reasoning_summary_text_delta: struct {
        type: []const u8 = "response.reasoning_summary_text.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        summary_index: u32 = 0,
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("summary_index"); try jw.write(self.summary_index);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    reasoning_summary_text_done: struct {
        type: []const u8 = "response.reasoning_summary_text.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        summary_index: u32 = 0,
        text: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("summary_index"); try jw.write(self.summary_index);
            try jw.objectField("text"); try jw.write(self.text);
            try jw.endObject();
        }
    },

    // --- web search call ---
    web_search_call_in_progress: struct {
        type: []const u8 = "response.web_search_call.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    web_search_call_searching: struct {
        type: []const u8 = "response.web_search_call.searching",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    web_search_call_completed: struct {
        type: []const u8 = "response.web_search_call.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- file search call ---
    file_search_call_in_progress: struct {
        type: []const u8 = "response.file_search_call.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    file_search_call_searching: struct {
        type: []const u8 = "response.file_search_call.searching",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    file_search_call_completed: struct {
        type: []const u8 = "response.file_search_call.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- code interpreter call ---
    code_interpreter_call_in_progress: struct {
        type: []const u8 = "response.code_interpreter_call.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    code_interpreter_call_code_delta: struct {
        type: []const u8 = "response.code_interpreter_call_code.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    code_interpreter_call_code_done: struct {
        type: []const u8 = "response.code_interpreter_call_code.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        code: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("code"); try jw.write(self.code);
            try jw.endObject();
        }
    },
    code_interpreter_call_interpreting: struct {
        type: []const u8 = "response.code_interpreter_call.interpreting",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    code_interpreter_call_completed: struct {
        type: []const u8 = "response.code_interpreter_call.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- MCP list tools ---
    mcp_list_tools_in_progress: struct {
        type: []const u8 = "response.mcp_list_tools.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    mcp_list_tools_completed: struct {
        type: []const u8 = "response.mcp_list_tools.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    mcp_list_tools_failed: struct {
        type: []const u8 = "response.mcp_list_tools.failed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- MCP call arguments ---
    mcp_call_arguments_delta: struct {
        type: []const u8 = "response.mcp_call_arguments.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    mcp_call_arguments_done: struct {
        type: []const u8 = "response.mcp_call_arguments.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        arguments: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("arguments"); try jw.write(self.arguments);
            try jw.endObject();
        }
    },

    // --- MCP call lifecycle ---
    mcp_call_in_progress: struct {
        type: []const u8 = "response.mcp_call.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    mcp_call_completed: struct {
        type: []const u8 = "response.mcp_call.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    mcp_call_failed: struct {
        type: []const u8 = "response.mcp_call.failed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- image generation call ---
    image_generation_call_in_progress: struct {
        type: []const u8 = "response.image_generation_call.in_progress",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    image_generation_call_generating: struct {
        type: []const u8 = "response.image_generation_call.generating",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },
    image_generation_call_partial_image: struct {
        type: []const u8 = "response.image_generation_call.partial_image",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        partial_image_index: u32 = 0,
        partial_image_b64: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("partial_image_index"); try jw.write(self.partial_image_index);
            try jw.objectField("partial_image_b64"); try jw.write(self.partial_image_b64);
            try jw.endObject();
        }
    },
    image_generation_call_completed: struct {
        type: []const u8 = "response.image_generation_call.completed",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.endObject();
        }
    },

    // --- audio streaming ---
    audio_delta: struct {
        type: []const u8 = "response.audio.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        response_id: []const u8 = "",
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("response_id"); try jw.write(self.response_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    audio_done: struct {
        type: []const u8 = "response.audio.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        response_id: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("response_id"); try jw.write(self.response_id);
            try jw.endObject();
        }
    },
    audio_transcript_delta: struct {
        type: []const u8 = "response.audio.transcript.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    audio_transcript_done: struct {
        type: []const u8 = "response.audio.transcript.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        transcript: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("transcript"); try jw.write(self.transcript);
            try jw.endObject();
        }
    },


    // --- shell call ---
    shell_call_command_added: struct {
        type: []const u8 = "response.shell_call_command.added",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        command_index: u32 = 0,
        command: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("command_index"); try jw.write(self.command_index);
            try jw.objectField("command"); try jw.write(self.command);
            try jw.endObject();
        }
    },
    shell_call_command_delta: struct {
        type: []const u8 = "response.shell_call_command.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        command_index: u32 = 0,
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("command_index"); try jw.write(self.command_index);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    shell_call_command_done: struct {
        type: []const u8 = "response.shell_call_command.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        command_index: u32 = 0,
        command: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("command_index"); try jw.write(self.command_index);
            try jw.objectField("command"); try jw.write(self.command);
            try jw.endObject();
        }
    },
    shell_call_output_delta: struct {
        type: []const u8 = "response.shell_call_output_content.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        delta: std.json.Value,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    shell_call_output_done: struct {
        type: []const u8 = "response.shell_call_output_content.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        output: []const std.json.Value = &.{},
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("output"); try jw.write(self.output);
            try jw.endObject();
        }
    },

    // --- custom tool call ---
    custom_tool_call_input_delta: struct {
        type: []const u8 = "response.custom_tool_call_input.delta",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        delta: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("delta"); try jw.write(self.delta);
            try jw.endObject();
        }
    },
    custom_tool_call_input_done: struct {
        type: []const u8 = "response.custom_tool_call_input.done",
        sequence_number: u32,
        output_index: u32 = 0,
        item_id: []const u8 = "",
        input: []const u8 = "",
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.objectField("output_index"); try jw.write(self.output_index);
            try jw.objectField("item_id"); try jw.write(self.item_id);
            try jw.objectField("input"); try jw.write(self.input);
            try jw.endObject();
        }
    },

    // --- response compaction ---
    response_compaction_compacting: struct {
        type: []const u8 = "response.compaction.compacting",
        sequence_number: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type"); try jw.write(self.type);
            try jw.objectField("sequence_number"); try jw.write(self.sequence_number);
            try jw.endObject();
        }
    },

    // --- pass-through (native Responses upstream bytes, e.g. copilot) ---
    raw_bytes: []const u8,

    /// Serialize this event. For named variants, emits standard SSE JSON.
    /// For raw_bytes, writes the bytes verbatim as a JSON string value.
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .raw_bytes => |b| try jw.write(b),
            inline else => |v| try jw.write(v),
        }
    }
};
