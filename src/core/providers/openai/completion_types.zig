// SPDX-License-Identifier: Apache-2.0
//! OpenAI /v1/chat/completions types.
//!
//! Re-exports all common primitives from types.zig so callers only need to
//! import this file to access the full OpenAI chat/completions API surface.

const std = @import("std");

// Re-export all common primitives explicitly (usingnamespace removed in Zig 0.16)
const common = @import("types.zig");
pub const Model = common.Model;
pub const ModelsResponse = common.ModelsResponse;
pub const Role = common.Role;
pub const ContentPart = common.ContentPart;
pub const FunctionCall = common.FunctionCall;
pub const ToolCallFunction = common.ToolCallFunction;
pub const ToolCall = common.ToolCall;
pub const ToolFunction = common.ToolFunction;
pub const Tool = common.Tool;
pub const Function = common.Function;
pub const ResponseFormat = common.ResponseFormat;
pub const StreamOptions = common.StreamOptions;
pub const MessageContent = common.MessageContent;
pub const Usage = common.Usage;
pub const ErrorDetails = common.ErrorDetails;
pub const ErrorResponse = common.ErrorResponse;

// ============================================================================
// Streaming Tool Call (completions-specific delta fragments)
// ============================================================================

/// Streaming tool call function (partial, for delta chunks)
pub const DeltaToolCallFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.name) |n| {
            try jw.objectField("name");
            try jw.write(n);
        }
        if (self.arguments) |a| {
            try jw.objectField("arguments");
            try jw.write(a);
        }
        try jw.endObject();
    }
};

/// Streaming tool call (partial, for delta chunks)
/// In streaming, tool_calls come incrementally with index to identify which call
pub const DeltaToolCall = struct {
    index: u32,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?DeltaToolCallFunction = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("index");
        try jw.write(self.index);
        if (self.id) |i| {
            try jw.objectField("id");
            try jw.write(i);
        }
        if (self.type) |t| {
            try jw.objectField("type");
            try jw.write(t);
        }
        if (self.function) |f| {
            try jw.objectField("function");
            try f.jsonStringify(jw);
        }
        try jw.endObject();
    }
};

// ============================================================================
// Message (request-side)
// ============================================================================

/// Represents a message in the conversation
pub const Message = struct {
    role: common.Role,
    content: ?common.MessageContent = .{ .text = "" },
    name: ?[]const u8 = null,
    refusal: ?[]const u8 = null,
    audio: ?std.json.Value = null,
    tool_calls: ?[]const common.ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    function_call: ?common.FunctionCall = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("role");
        try jw.write(@tagName(self.role));

        try jw.objectField("content");
        if (self.content) |content| {
            switch (content) {
                .text => |t| try jw.write(t),
                .parts => |parts| {
                    try jw.beginArray();
                    for (parts) |part| {
                        try part.jsonStringify(jw);
                    }
                    try jw.endArray();
                },
            }
        } else {
            try jw.write("");
        }

        if (self.name) |n| { try jw.objectField("name"); try jw.write(n); }
        if (self.refusal) |r| { try jw.objectField("refusal"); try jw.write(r); }
        if (self.audio) |a| { try jw.objectField("audio"); try jw.write(a); }
        if (self.tool_calls) |tc| { try jw.objectField("tool_calls"); try jw.write(tc); }
        if (self.tool_call_id) |tid| { try jw.objectField("tool_call_id"); try jw.write(tid); }
        if (self.function_call) |fc| { try jw.objectField("function_call"); try jw.write(fc); }

        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const role_value = obj.get("role") orelse return error.MissingField;
        const role = try std.json.innerParseFromValue(common.Role, allocator, role_value, options);

        const content: ?common.MessageContent = if (obj.get("content")) |content_value| switch (content_value) {
            .string => |s| .{ .text = s },
            .array => |arr| blk: {
                const parts = try allocator.alloc(common.ContentPart, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    parts[i] = try common.ContentPart.jsonParseFromValue(allocator, item, options);
                }
                break :blk .{ .parts = parts };
            },
            .null => null,
            else => return error.UnexpectedToken,
        } else null;

        const name = if (obj.get("name")) |n| if (n == .string) n.string else null else null;
        const refusal = if (obj.get("refusal")) |r| if (r == .string) r.string else null else null;
        const audio = obj.get("audio");

        const tool_calls = if (obj.get("tool_calls")) |tc|
            if (tc == .array) blk: {
                const calls = try allocator.alloc(common.ToolCall, tc.array.items.len);
                for (tc.array.items, 0..) |item, i| {
                    calls[i] = try common.ToolCall.jsonParseFromValue(allocator, item, options);
                }
                break :blk calls;
            } else null
        else
            null;

        const tool_call_id = if (obj.get("tool_call_id")) |tid| if (tid == .string) tid.string else null else null;
        const function_call = if (obj.get("function_call")) |fc|
            if (fc == .object) try std.json.innerParseFromValue(common.FunctionCall, allocator, fc, options) else null
        else
            null;

        return .{
            .role = role,
            .content = content,
            .name = name,
            .refusal = refusal,
            .audio = audio,
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
            .function_call = function_call,
        };
    }
};

// ============================================================================
// Request
// ============================================================================

/// Request to OpenAI chat completions endpoint
pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    stream: ?bool = null,
    stream_options: ?common.StreamOptions = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    top_p: ?f32 = null,
    n: ?u32 = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    tools: ?[]const common.Tool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    functions: ?[]const common.Function = null,
    function_call: ?[]const u8 = null,
    response_format: ?common.ResponseFormat = null,
    stop: ?[]const []const u8 = null,
    logit_bias: ?std.json.Value = null,
    logprobs: ?bool = null,
    top_logprobs: ?u8 = null,
    user: ?[]const u8 = null,
    seed: ?i64 = null,
    reasoning_effort: ?[]const u8 = null,
    modalities: ?[]const []const u8 = null,
    audio: ?std.json.Value = null,
    store: ?bool = null,
    moderation: ?std.json.Value = null,
    web_search_options: ?std.json.Value = null,
    metadata: ?std.json.Value = null,
    prediction: ?std.json.Value = null,
    safety_identifier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?std.json.Value = null,
    prompt_cache_retention: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    verbosity: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("messages");
        try jw.beginArray();
        for (self.messages) |msg| { try msg.jsonStringify(jw); }
        try jw.endArray();
        if (self.stream) |v| { try jw.objectField("stream"); try jw.write(v); }
        if (self.stream_options) |v| { try jw.objectField("stream_options"); try jw.write(v); }
        if (self.temperature) |v| { try jw.objectField("temperature"); try jw.write(v); }
        if (self.max_tokens) |v| { try jw.objectField("max_tokens"); try jw.write(v); }
        if (self.max_completion_tokens) |v| { try jw.objectField("max_completion_tokens"); try jw.write(v); }
        if (self.top_p) |v| { try jw.objectField("top_p"); try jw.write(v); }
        if (self.n) |v| { try jw.objectField("n"); try jw.write(v); }
        if (self.presence_penalty) |v| { try jw.objectField("presence_penalty"); try jw.write(v); }
        if (self.frequency_penalty) |v| { try jw.objectField("frequency_penalty"); try jw.write(v); }
        if (self.tools) |v| { try jw.objectField("tools"); try jw.write(v); }
        if (self.tool_choice) |v| { try jw.objectField("tool_choice"); try jw.write(v); }
        if (self.parallel_tool_calls) |v| { try jw.objectField("parallel_tool_calls"); try jw.write(v); }
        if (self.functions) |v| { try jw.objectField("functions"); try jw.write(v); }
        if (self.function_call) |v| { try jw.objectField("function_call"); try jw.write(v); }
        if (self.response_format) |v| { try jw.objectField("response_format"); try jw.write(v); }
        if (self.stop) |v| { try jw.objectField("stop"); try jw.write(v); }
        if (self.logit_bias) |v| { try jw.objectField("logit_bias"); try jw.write(v); }
        if (self.logprobs) |v| { try jw.objectField("logprobs"); try jw.write(v); }
        if (self.top_logprobs) |v| { try jw.objectField("top_logprobs"); try jw.write(v); }
        if (self.user) |v| { try jw.objectField("user"); try jw.write(v); }
        if (self.seed) |v| { try jw.objectField("seed"); try jw.write(v); }
        if (self.reasoning_effort) |v| { try jw.objectField("reasoning_effort"); try jw.write(v); }
        if (self.modalities) |v| { try jw.objectField("modalities"); try jw.write(v); }
        if (self.audio) |v| { try jw.objectField("audio"); try jw.write(v); }
        if (self.store) |v| { try jw.objectField("store"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        if (self.web_search_options) |v| { try jw.objectField("web_search_options"); try jw.write(v); }
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.prediction) |v| { try jw.objectField("prediction"); try jw.write(v); }
        if (self.safety_identifier) |v| { try jw.objectField("safety_identifier"); try jw.write(v); }
        if (self.prompt_cache_key) |v| { try jw.objectField("prompt_cache_key"); try jw.write(v); }
        if (self.prompt_cache_options) |v| { try jw.objectField("prompt_cache_options"); try jw.write(v); }
        if (self.prompt_cache_retention) |v| { try jw.objectField("prompt_cache_retention"); try jw.write(v); }
        if (self.service_tier) |v| { try jw.objectField("service_tier"); try jw.write(v); }
        if (self.verbosity) |v| { try jw.objectField("verbosity"); try jw.write(v); }
        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const val = try std.json.Value.jsonParse(allocator, source, options);
        return try jsonParseFromValue(allocator, val, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const model = if (obj.get("model")) |v| switch (v) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        } else return error.MissingField;

        const messages_val = obj.get("messages") orelse return error.MissingField;
        if (messages_val != .array) return error.UnexpectedToken;
        const messages_arr = messages_val.array.items;
        const messages = try allocator.alloc(Message, messages_arr.len);
        for (messages_arr, 0..) |msg_val, i| {
            messages[i] = try Message.jsonParseFromValue(allocator, msg_val, .{});
        }

        var result = Request{ .model = model, .messages = messages };

        if (obj.get("stream")) |v| { result.stream = if (v == .bool) v.bool else null; }
        if (obj.get("stream_options")) |v| {
            if (v == .object) result.stream_options = try std.json.parseFromValueLeaky(common.StreamOptions, allocator, v, .{});
        }
        if (obj.get("temperature")) |v| { result.temperature = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("max_tokens")) |v| { result.max_tokens = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("max_completion_tokens")) |v| { result.max_completion_tokens = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("top_p")) |v| { result.top_p = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("n")) |v| { result.n = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("presence_penalty")) |v| { result.presence_penalty = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("frequency_penalty")) |v| { result.frequency_penalty = switch (v) { .integer => |i| @floatFromInt(i), .float => |f| @floatCast(f), else => null }; }
        if (obj.get("tools")) |v| {
            if (v == .array) {
                const tools = try allocator.alloc(common.Tool, v.array.items.len);
                for (v.array.items, 0..) |tv, i| tools[i] = try common.Tool.jsonParseFromValue(allocator, tv, .{});
                result.tools = tools;
            }
        }
        if (obj.get("tool_choice")) |v| { result.tool_choice = v; }
        if (obj.get("parallel_tool_calls")) |v| { result.parallel_tool_calls = if (v == .bool) v.bool else null; }
        if (obj.get("functions")) |v| {
            if (v == .array) {
                const funcs = try allocator.alloc(common.Function, v.array.items.len);
                for (v.array.items, 0..) |fv, i| funcs[i] = try std.json.parseFromValueLeaky(common.Function, allocator, fv, .{});
                result.functions = funcs;
            }
        }
        if (obj.get("function_call")) |v| { result.function_call = if (v == .string) v.string else null; }
        if (obj.get("response_format")) |v| {
            if (v == .object) {
                const rf_type = if (v.object.get("type")) |t| (if (t == .string) t.string else "text") else "text";
                result.response_format = .{ .type = rf_type, .json_schema = v.object.get("json_schema") };
            }
        }
        if (obj.get("stop")) |v| {
            switch (v) {
                .string => |s| { const stop = try allocator.alloc([]const u8, 1); stop[0] = s; result.stop = stop; },
                .array => |arr| {
                    const stop = try allocator.alloc([]const u8, arr.items.len);
                    for (arr.items, 0..) |sv, i| stop[i] = if (sv == .string) sv.string else return error.UnexpectedToken;
                    result.stop = stop;
                },
                else => {},
            }
        }
        if (obj.get("logit_bias")) |v| { result.logit_bias = v; }
        if (obj.get("logprobs")) |v| { result.logprobs = if (v == .bool) v.bool else null; }
        if (obj.get("top_logprobs")) |v| { result.top_logprobs = if (v == .integer) @intCast(v.integer) else null; }
        if (obj.get("user")) |v| { result.user = if (v == .string) v.string else null; }
        if (obj.get("seed")) |v| { result.seed = if (v == .integer) v.integer else null; }
        if (obj.get("reasoning_effort")) |v| { result.reasoning_effort = if (v == .string) v.string else null; }
        if (obj.get("modalities")) |v| {
            if (v == .array) {
                const m = try allocator.alloc([]const u8, v.array.items.len);
                for (v.array.items, 0..) |item, i| m[i] = if (item == .string) item.string else "text";
                result.modalities = m;
            }
        }
        if (obj.get("audio")) |v| { result.audio = v; }
        if (obj.get("store")) |v| { result.store = if (v == .bool) v.bool else null; }
        if (obj.get("moderation")) |v| { result.moderation = v; }
        if (obj.get("web_search_options")) |v| { result.web_search_options = v; }
        if (obj.get("metadata")) |v| { result.metadata = v; }
        if (obj.get("prediction")) |v| { result.prediction = v; }
        if (obj.get("safety_identifier")) |v| { result.safety_identifier = if (v == .string) v.string else null; }
        if (obj.get("prompt_cache_key")) |v| { result.prompt_cache_key = if (v == .string) v.string else null; }
        if (obj.get("prompt_cache_options")) |v| { result.prompt_cache_options = v; }
        if (obj.get("prompt_cache_retention")) |v| { result.prompt_cache_retention = if (v == .string) v.string else null; }
        if (obj.get("service_tier")) |v| { result.service_tier = if (v == .string) v.string else null; }
        if (obj.get("verbosity")) |v| { result.verbosity = if (v == .string) v.string else null; }

        return result;
    }
};

// ============================================================================
// Streaming Response (choices[].delta)
// ============================================================================

/// Delta content in streaming response
pub const Delta = struct {
    role: ?common.Role = null,
    content: ?[]const u8 = null,
    refusal: ?[]const u8 = null,
    tool_calls: ?[]const DeltaToolCall = null,
    function_call: ?common.FunctionCall = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.role) |r| { try jw.objectField("role"); try jw.write(@tagName(r)); }
        if (self.content) |c| { try jw.objectField("content"); try jw.write(c); }
        if (self.refusal) |r| { try jw.objectField("refusal"); try jw.write(r); }
        if (self.tool_calls) |tc| {
            try jw.objectField("tool_calls");
            try jw.beginArray();
            for (tc) |call| { try call.jsonStringify(jw); }
            try jw.endArray();
        }
        if (self.function_call) |fc| { try jw.objectField("function_call"); try jw.write(fc); }
        try jw.endObject();
    }
};

/// Choice in streaming chunk
pub const StreamChoice = struct {
    index: u32 = 0,
    delta: Delta = .{},
    finish_reason: ?[]const u8 = null,
    logprobs: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("index"); try jw.write(self.index);
        try jw.objectField("delta"); try self.delta.jsonStringify(jw);
        if (self.logprobs) |lp| { try jw.objectField("logprobs"); try jw.write(lp); }
        try jw.objectField("finish_reason"); try jw.write(self.finish_reason);
        try jw.endObject();
    }
};

/// Streaming chunk response (`object: "chat.completion.chunk"`)
pub const StreamChunk = struct {
    id: []const u8,
    object: []const u8 = "chat.completion.chunk",
    created: i64,
    model: []const u8,
    choices: []const StreamChoice,
    usage: ?common.Usage = null,
    system_fingerprint: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    obfuscation: ?[]const u8 = null,
    moderation: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id"); try jw.write(self.id);
        try jw.objectField("object"); try jw.write(self.object);
        try jw.objectField("created"); try jw.write(self.created);
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("choices");
        try jw.beginArray();
        for (self.choices) |choice| { try choice.jsonStringify(jw); }
        try jw.endArray();
        if (self.usage) |u| { try jw.objectField("usage"); try common.Usage.jsonStringify(u, jw); }
        if (self.system_fingerprint) |sf| { try jw.objectField("system_fingerprint"); try jw.write(sf); }
        if (self.service_tier) |st| { try jw.objectField("service_tier"); try jw.write(st); }
        if (self.obfuscation) |v| { try jw.objectField("obfuscation"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Non-streaming Response
// ============================================================================

/// Message in non-streaming response
pub const ResponseMessage = struct {
    role: common.Role,
    content: ?[]const u8,
    refusal: ?[]const u8 = null,
    tool_calls: ?[]const common.ToolCall = null,
    function_call: ?common.FunctionCall = null,
    annotations: ?std.json.Value = null,
    audio: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role"); try jw.write(@tagName(self.role));
        if (self.content) |c| { try jw.objectField("content"); try jw.write(c); }
        if (self.refusal) |r| { try jw.objectField("refusal"); try jw.write(r); }
        if (self.tool_calls) |tc| { try jw.objectField("tool_calls"); try jw.write(tc); }
        if (self.function_call) |fc| { try jw.objectField("function_call"); try jw.write(fc); }
        if (self.annotations) |a| { try jw.objectField("annotations"); try jw.write(a); }
        if (self.audio) |au| { try jw.objectField("audio"); try jw.write(au); }
        try jw.endObject();
    }
};

/// Choice in non-streaming response
pub const ResponseChoice = struct {
    index: u32,
    message: ResponseMessage,
    finish_reason: []const u8,
    logprobs: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("index"); try jw.write(self.index);
        try jw.objectField("message"); try self.message.jsonStringify(jw);
        if (self.logprobs) |lp| { try jw.objectField("logprobs"); try jw.write(lp); }
        try jw.objectField("finish_reason"); try jw.write(self.finish_reason);
        try jw.endObject();
    }
};

/// Non-streaming response (`object: "chat.completion"`)
pub const Response = struct {
    id: []const u8,
    object: []const u8 = "chat.completion",
    created: i64 = 0,
    model: []const u8,
    choices: []const ResponseChoice,
    usage: ?common.Usage = null,
    system_fingerprint: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    metadata: ?std.json.Value = null,
    moderation: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id"); try jw.write(self.id);
        try jw.objectField("object"); try jw.write(self.object);
        try jw.objectField("created"); try jw.write(self.created);
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("choices");
        try jw.beginArray();
        for (self.choices) |choice| { try choice.jsonStringify(jw); }
        try jw.endArray();
        if (self.usage) |u| { try jw.objectField("usage"); try common.Usage.jsonStringify(u, jw); }
        if (self.system_fingerprint) |sf| { try jw.objectField("system_fingerprint"); try jw.write(sf); }
        if (self.service_tier) |st| { try jw.objectField("service_tier"); try jw.write(st); }
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Stream line dispatch result
// ============================================================================

/// Result type for stream line transformation (shared across all completions transformers)
pub const StreamLineResult = union(enum) {
    chunk: std.json.Parsed(StreamChunk),
    @"error": common.ErrorResponse,
    skip: void,
};
