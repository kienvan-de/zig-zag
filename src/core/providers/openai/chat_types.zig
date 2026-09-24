// SPDX-License-Identifier: Apache-2.0
//! OpenAI /v1/chat/completions types.

const std = @import("std");

const common = @import("types.zig");

// ============================================================================
// Chat-completions-only types (not shared with Responses API)
// ============================================================================

/// Role in a Chat Completions conversation.
/// The Responses API uses plain strings for roles in input items.
pub const Role = enum {
    system,
    user,
    assistant,
    developer,
    tool,

    pub fn jsonStringify(self: Role, out: anytype) !void {
        try out.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Role {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options) catch return error.UnknownField;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Role {
        _ = allocator;
        _ = options;
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(Role, source.string) orelse error.UnknownField;
    }
};

pub const ContentPartText = struct {
    type: []const u8 = "text",
    text: []const u8,
};
pub const ContentPartImageUrlInner = struct {
    url: []const u8,
    detail: ?[]const u8 = null,
};
pub const ContentPartImageUrl = struct {
    type: []const u8 = "image_url",
    image_url: ContentPartImageUrlInner,
};
pub const ContentPartInputAudioInner = struct {
    data: []const u8 = "",
    format: []const u8 = "", // "wav" | "mp3"
};
pub const ContentPartInputAudio = struct {
    type: []const u8 = "input_audio",
    input_audio: ContentPartInputAudioInner,
};
pub const ContentPartFileInner = struct {
    file_id: ?[]const u8 = null,
    file_data: ?[]const u8 = null,
    filename: ?[]const u8 = null,
};
pub const ContentPartFile = struct {
    type: []const u8 = "file",
    file: ContentPartFileInner,
};

/// Content part for chat message content arrays (text or image)
pub const ContentPart = union(enum) {
    text: ContentPartText,
    image_url: ContentPartImageUrl,
    input_audio: ContentPartInputAudio,
    file: ContentPartFile,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        const type_value = obj.get("type") orelse return error.MissingField;
        if (type_value != .string) return error.UnexpectedToken;
        const type_str = type_value.string;
        if (std.mem.eql(u8, type_str, "text")) {
            const text_value = obj.get("text") orelse return error.MissingField;
            if (text_value != .string) return error.UnexpectedToken;
            return .{ .text = .{ .type = "text", .text = text_value.string } };
        } else if (std.mem.eql(u8, type_str, "image_url")) {
            const image_url_obj = obj.get("image_url") orelse return error.MissingField;
            if (image_url_obj != .object) return error.UnexpectedToken;
            const url_value = image_url_obj.object.get("url") orelse return error.MissingField;
            if (url_value != .string) return error.UnexpectedToken;
            const detail = if (image_url_obj.object.get("detail")) |d| if (d == .string) d.string else null else null;
            return .{ .image_url = .{
                .type = "image_url",
                .image_url = .{ .url = url_value.string, .detail = detail },
            } };
        } else if (std.mem.eql(u8, type_str, "input_audio")) {
            const ia_obj = obj.get("input_audio") orelse return .{ .input_audio = .{ .input_audio = .{} } };
            const ia_data = if (ia_obj == .object) (if (ia_obj.object.get("data")) |d| (if (d == .string) d.string else "") else "") else "";
            const ia_fmt = if (ia_obj == .object) (if (ia_obj.object.get("format")) |fmt| (if (fmt == .string) fmt.string else "") else "") else "";
            return .{ .input_audio = .{
                .type = "input_audio",
                .input_audio = .{ .data = ia_data, .format = ia_fmt },
            } };
        } else if (std.mem.eql(u8, type_str, "file")) {
            const f_obj = obj.get("file") orelse return .{ .file = .{ .file = .{} } };
            const f_id = if (f_obj == .object) (if (f_obj.object.get("file_id")) |v| (if (v == .string) v.string else null) else null) else null;
            const f_data = if (f_obj == .object) (if (f_obj.object.get("file_data")) |v| (if (v == .string) v.string else null) else null) else null;
            const f_name = if (f_obj == .object) (if (f_obj.object.get("filename")) |v| (if (v == .string) v.string else null) else null) else null;
            return .{ .file = .{
                .type = "file",
                .file = .{ .file_id = f_id, .file_data = f_data, .filename = f_name },
            } };
        } else {
            return .{ .text = .{ .type = type_str, .text = "" } };
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .text => |t| {
                try jw.objectField("type"); try jw.write("text");
                try jw.objectField("text"); try jw.write(t.text);
            },
            .image_url => |img| {
                try jw.objectField("type"); try jw.write("image_url");
                try jw.objectField("image_url");
                try jw.beginObject();
                try jw.objectField("url"); try jw.write(img.image_url.url);
                if (img.image_url.detail) |d| { try jw.objectField("detail"); try jw.write(d); }
                try jw.endObject();
            },
            .input_audio => |ia| {
                try jw.objectField("type"); try jw.write("input_audio");
                try jw.objectField("input_audio");
                try jw.beginObject();
                try jw.objectField("data"); try jw.write(ia.input_audio.data);
                try jw.objectField("format"); try jw.write(ia.input_audio.format);
                try jw.endObject();
            },
            .file => |fi| {
                try jw.objectField("type"); try jw.write("file");
                try jw.objectField("file");
                try jw.beginObject();
                if (fi.file.file_id) |v| { try jw.objectField("file_id"); try jw.write(v); }
                if (fi.file.file_data) |v| { try jw.objectField("file_data"); try jw.write(v); }
                if (fi.file.filename) |v| { try jw.objectField("filename"); try jw.write(v); }
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

/// Message content — string or array of content parts
pub const MessageContent = union(enum) {
    text: []const u8,
    parts: []const ContentPart,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |t| try jw.write(t),
            .parts => |p| try jw.write(p),
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !MessageContent {
        switch (source) {
            .string => |s| return .{ .text = s },
            .array => {
                const parts = try std.json.innerParseFromValue([]const ContentPart, allocator, source, options);
                return .{ .parts = parts };
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// Usage statistics for chat completions
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    prompt_tokens_details: ?common.PromptTokensDetails = null,
    completion_tokens_details: ?common.CompletionTokensDetails = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt_tokens"); try jw.write(self.prompt_tokens);
        try jw.objectField("completion_tokens"); try jw.write(self.completion_tokens);
        try jw.objectField("total_tokens"); try jw.write(self.total_tokens);
        if (self.prompt_tokens_details) |v| { try jw.objectField("prompt_tokens_details"); try jw.write(v); }
        if (self.completion_tokens_details) |v| { try jw.objectField("completion_tokens_details"); try jw.write(v); }
        try jw.endObject();
    }
};

pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: ToolCallFunction,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("function");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.function.name);
        try jw.objectField("arguments");
        try jw.write(self.function.arguments);
        try jw.endObject();
        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        const id_val = obj.get("id") orelse return error.MissingField;
        if (id_val != .string) return error.UnexpectedToken;
        const type_val = obj.get("type") orelse return error.MissingField;
        if (type_val != .string) return error.UnexpectedToken;
        const func_val = obj.get("function") orelse return error.MissingField;
        if (func_val != .object) return error.UnexpectedToken;
        const name_val = func_val.object.get("name") orelse return error.MissingField;
        if (name_val != .string) return error.UnexpectedToken;
        const args_val = func_val.object.get("arguments") orelse return error.MissingField;
        if (args_val != .string) return error.UnexpectedToken;
        return .{
            .id = id_val.string,
            .type = type_val.string,
            .function = .{ .name = name_val.string, .arguments = args_val.string },
        };
    }
};

/// Tool definition for Chat Completions API — nested format:
/// {"type":"function","function":{"name":"...","description":"...","parameters":{}}}
pub const Tool = struct {
    type: []const u8 = "function",
    function: common.ToolFunction,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type"); try jw.write(self.type);
        try jw.objectField("function"); try self.function.jsonStringify(jw);
        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        const type_val = obj.get("type") orelse return error.MissingField;
        if (type_val != .string) return error.UnexpectedToken;

        if (obj.get("function")) |func_val| {
            const func = try std.json.parseFromValueLeaky(common.ToolFunction, allocator, func_val, options);
            return .{ .type = type_val.string, .function = func };
        } else if (obj.get("name")) |name_val| {
            if (name_val != .string) return error.UnexpectedToken;
            const desc = if (obj.get("description")) |d| (if (d == .string) d.string else null) else null;
            const params = obj.get("parameters");
            const strict = if (obj.get("strict")) |s| (if (s == .bool) s.bool else null) else null;
            return .{ .type = type_val.string, .function = .{
                .name = name_val.string,
                .description = desc,
                .parameters = params,
                .strict = strict,
            } };
        } else {
            return error.MissingField;
        }
    }
};

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
    role: Role,
    content: ?MessageContent = .{ .text = "" },
    name: ?[]const u8 = null,
    refusal: ?[]const u8 = null,
    audio: ?std.json.Value = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

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
            try jw.write(null);
        }

        if (self.name) |n| { try jw.objectField("name"); try jw.write(n); }
        if (self.refusal) |r| { try jw.objectField("refusal"); try jw.write(r); }
        if (self.audio) |a| { try jw.objectField("audio"); try jw.write(a); }
        if (self.tool_calls) |tc| { try jw.objectField("tool_calls"); try jw.write(tc); }
        if (self.tool_call_id) |tid| { try jw.objectField("tool_call_id"); try jw.write(tid); }

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
        const role = try std.json.innerParseFromValue(Role, allocator, role_value, options);

        const content: ?MessageContent = if (obj.get("content")) |content_value| switch (content_value) {
            .string => |s| .{ .text = s },
            .array => |arr| blk: {
                const parts = try allocator.alloc(ContentPart, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    parts[i] = try ContentPart.jsonParseFromValue(allocator, item, options);
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
                const calls = try allocator.alloc(ToolCall, tc.array.items.len);
                for (tc.array.items, 0..) |item, i| {
                    calls[i] = try ToolCall.jsonParseFromValue(allocator, item, options);
                }
                break :blk calls;
            } else null
        else
            null;

        const tool_call_id = if (obj.get("tool_call_id")) |tid| if (tid == .string) tid.string else null else null;

        return .{
            .role = role,
            .content = content,
            .name = name,
            .refusal = refusal,
            .audio = audio,
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
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
    tools: ?[]const Tool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
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
    metadata: ?std.json.Value = null,
    prediction: ?std.json.Value = null,
    service_tier: ?[]const u8 = null,
    web_search_options: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
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
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.prediction) |v| { try jw.objectField("prediction"); try jw.write(v); }
        if (self.service_tier) |v| { try jw.objectField("service_tier"); try jw.write(v); }
        if (self.web_search_options) |v| { try jw.objectField("web_search_options"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        if (self.verbosity) |v| { try jw.objectField("verbosity"); try jw.write(v); }
        try jw.endObject();
    }

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
                const tools = try allocator.alloc(Tool, v.array.items.len);
                for (v.array.items, 0..) |tv, i| tools[i] = try Tool.jsonParseFromValue(allocator, tv, .{});
                result.tools = tools;
            }
        }
        if (obj.get("tool_choice")) |v| { result.tool_choice = v; }
        if (obj.get("parallel_tool_calls")) |v| { result.parallel_tool_calls = if (v == .bool) v.bool else null; }
        if (obj.get("response_format")) |v| {
            result.response_format = try std.json.innerParseFromValue(common.ResponseFormat, allocator, v, options);
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
        if (obj.get("metadata")) |v| { result.metadata = v; }
        if (obj.get("prediction")) |v| { result.prediction = v; }
        if (obj.get("service_tier")) |v| { result.service_tier = if (v == .string) v.string else null; }
        if (obj.get("web_search_options")) |v| { result.web_search_options = v; }
        if (obj.get("moderation")) |v| { result.moderation = v; }
        if (obj.get("verbosity")) |v| { result.verbosity = if (v == .string) v.string else null; }

        return result;
    }
};

// ============================================================================
// Streaming Response (choices[].delta)
// ============================================================================

/// Delta content in streaming response
pub const Delta = struct {
    role: ?Role = null,
    content: ?[]const u8 = null,
    refusal: ?[]const u8 = null,
    tool_calls: ?[]const DeltaToolCall = null,
    audio: ?std.json.Value = null,

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
        if (self.audio) |a| { try jw.objectField("audio"); try jw.write(a); }
        try jw.endObject();
    }
};

/// Choice in streaming chunk
pub const StreamChoice = struct {
    index: u32 = 0,
    delta: Delta = .{},
    finish_reason: ?[]const u8 = null,
    logprobs: ?common.ChoiceLogprobs = null,

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
    usage: ?Usage = null,
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
        if (self.usage) |u| { try jw.objectField("usage"); try Usage.jsonStringify(u, jw); }
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
    role: Role,
    content: ?[]const u8,
    refusal: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    annotations: ?std.json.Value = null,
    audio: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role"); try jw.write(@tagName(self.role));
        if (self.content) |c| { try jw.objectField("content"); try jw.write(c); }
        if (self.refusal) |r| { try jw.objectField("refusal"); try jw.write(r); }
        if (self.tool_calls) |tc| { try jw.objectField("tool_calls"); try jw.write(tc); }
        if (self.annotations) |a| { try jw.objectField("annotations"); try jw.write(a); }
        if (self.audio) |au| { try jw.objectField("audio"); try jw.write(au); }
        try jw.endObject();
    }
};

/// Choice in non-streaming response
pub const ResponseChoice = struct {
    index: u32 = 0,
    message: ResponseMessage,
    finish_reason: []const u8 = "stop",
    logprobs: ?common.ChoiceLogprobs = null,

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
    usage: ?Usage = null,
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
        if (self.usage) |u| { try jw.objectField("usage"); try Usage.jsonStringify(u, jw); }
        if (self.system_fingerprint) |sf| { try jw.objectField("system_fingerprint"); try jw.write(sf); }
        if (self.service_tier) |st| { try jw.objectField("service_tier"); try jw.write(st); }
        if (self.metadata) |v| { try jw.objectField("metadata"); try jw.write(v); }
        if (self.moderation) |v| { try jw.objectField("moderation"); try jw.write(v); }
        try jw.endObject();
    }
};

/// Result type for Chat-flow stream line transforms.
/// The transformer returns a typed StreamChunk; the caller serializes to wire bytes.
pub const ChatStreamLineResult = union(enum) {
    events: []const StreamChunk,
    @"error": common.ErrorResponse,
    skip: void,
};

