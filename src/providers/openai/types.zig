const std = @import("std");

// ============================================================================
// OpenAI API Data Structures
// ============================================================================

/// Role in a conversation
pub const Role = enum {
    system,
    user,
    assistant,
    function,
    tool,

    pub fn jsonStringify(self: Role, out: anytype) !void {
        try out.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Role {
        const str = try std.json.innerParse([]const u8, allocator, source, options);
        return std.meta.stringToEnum(Role, str) orelse error.UnknownField;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Role {
        _ = allocator;
        _ = options;
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(Role, source.string) orelse error.UnknownField;
    }
};

/// Content part for message content array
pub const ContentPart = union(enum) {
    text: struct {
        type: []const u8 = "text",
        text: []const u8,
    },
    image_url: struct {
        type: []const u8 = "image_url",
        image_url: struct {
            url: []const u8,
            detail: ?[]const u8 = null, // "auto", "low", "high"
        },
    },

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
            const detail = if (image_url_obj.object.get("detail")) |d|
                if (d == .string) d.string else null
            else
                null;
            return .{ .image_url = .{
                .type = "image_url",
                .image_url = .{
                    .url = url_value.string,
                    .detail = detail,
                },
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .text => |t| {
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .image_url => |img| {
                try jw.objectField("type");
                try jw.write("image_url");
                try jw.objectField("image_url");
                try jw.beginObject();
                try jw.objectField("url");
                try jw.write(img.image_url.url);
                if (img.image_url.detail) |d| {
                    try jw.objectField("detail");
                    try jw.write(d);
                }
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

/// Function call structure (legacy)
pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Tool call function
pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Tool call in assistant message
pub const ToolCall = struct {
    id: []const u8,
    type: []const u8, // "function"
    function: ToolCallFunction,
};

/// Tool function definition
pub const ToolFunction = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null, // JSON schema

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |d| {
            try jw.objectField("description");
            try jw.write(d);
        }
        if (self.parameters) |p| {
            try jw.objectField("parameters");
            try jw.write(p);
        }
        try jw.endObject();
    }
};

/// Tool definition
pub const Tool = struct {
    type: []const u8, // "function"
    function: ToolFunction,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("function");
        try self.function.jsonStringify(jw);
        try jw.endObject();
    }
};

/// Function definition (legacy)
pub const Function = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null, // JSON schema
};

/// Response format
pub const ResponseFormat = struct {
    type: []const u8, // "text" or "json_object"
};

/// Content union type for messages
pub const MessageContent = union(enum) {
    text: []const u8,
    parts: []const ContentPart,
};

/// Represents a message in the conversation
pub const Message = struct {
    role: Role,
    content: ?MessageContent = null,
    name: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    function_call: ?FunctionCall = null,

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

        if (self.name) |n| {
            try jw.objectField("name");
            try jw.write(n);
        }

        if (self.tool_calls) |tc| {
            try jw.objectField("tool_calls");
            try jw.write(tc);
        }

        if (self.tool_call_id) |tid| {
            try jw.objectField("tool_call_id");
            try jw.write(tid);
        }

        if (self.function_call) |fc| {
            try jw.objectField("function_call");
            try jw.write(fc);
        }

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

        const name = if (obj.get("name")) |n|
            if (n == .string) n.string else null
        else
            null;

        const tool_calls = if (obj.get("tool_calls")) |tc|
            if (tc == .array) blk: {
                const calls = try allocator.alloc(ToolCall, tc.array.items.len);
                for (tc.array.items, 0..) |item, i| {
                    calls[i] = try std.json.innerParseFromValue(ToolCall, allocator, item, options);
                }
                break :blk calls;
            } else null
        else
            null;

        const tool_call_id = if (obj.get("tool_call_id")) |tid|
            if (tid == .string) tid.string else null
        else
            null;

        const function_call = if (obj.get("function_call")) |fc|
            if (fc == .object) try std.json.innerParseFromValue(FunctionCall, allocator, fc, options) else null
        else
            null;

        return .{
            .role = role,
            .content = content,
            .name = name,
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
            .function_call = function_call,
        };
    }
};

/// Request to OpenAI chat completions endpoint
pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    stream: ?bool = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    max_completion_tokens: ?u32 = null,
    top_p: ?f32 = null,
    n: ?u32 = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    tools: ?[]const Tool = null,
    tool_choice: ?std.json.Value = null, // "none", "auto", "required", or object
    parallel_tool_calls: ?bool = null,
    functions: ?[]const Function = null,
    function_call: ?[]const u8 = null, // "none", "auto", or JSON (deprecated)
    response_format: ?ResponseFormat = null,
    stop: ?[]const []const u8 = null,
    logit_bias: ?std.json.Value = null,
    logprobs: ?bool = null,
    top_logprobs: ?u8 = null,
    user: ?[]const u8 = null,
    seed: ?i64 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(self.model);

        try jw.objectField("messages");
        try jw.beginArray();
        for (self.messages) |msg| {
            try msg.jsonStringify(jw);
        }
        try jw.endArray();

        if (self.stream) |v| {
            try jw.objectField("stream");
            try jw.write(v);
        }
        if (self.temperature) |v| {
            try jw.objectField("temperature");
            try jw.write(v);
        }
        if (self.max_tokens) |v| {
            try jw.objectField("max_tokens");
            try jw.write(v);
        }
        if (self.max_completion_tokens) |v| {
            try jw.objectField("max_completion_tokens");
            try jw.write(v);
        }
        if (self.top_p) |v| {
            try jw.objectField("top_p");
            try jw.write(v);
        }
        if (self.n) |v| {
            try jw.objectField("n");
            try jw.write(v);
        }
        if (self.presence_penalty) |v| {
            try jw.objectField("presence_penalty");
            try jw.write(v);
        }
        if (self.frequency_penalty) |v| {
            try jw.objectField("frequency_penalty");
            try jw.write(v);
        }
        if (self.tools) |v| {
            try jw.objectField("tools");
            try jw.write(v);
        }
        if (self.tool_choice) |v| {
            try jw.objectField("tool_choice");
            try jw.write(v);
        }
        if (self.parallel_tool_calls) |v| {
            try jw.objectField("parallel_tool_calls");
            try jw.write(v);
        }
        if (self.functions) |v| {
            try jw.objectField("functions");
            try jw.write(v);
        }
        if (self.function_call) |v| {
            try jw.objectField("function_call");
            try jw.write(v);
        }
        if (self.response_format) |v| {
            try jw.objectField("response_format");
            try jw.write(v);
        }
        if (self.stop) |v| {
            try jw.objectField("stop");
            try jw.write(v);
        }
        if (self.logit_bias) |v| {
            try jw.objectField("logit_bias");
            try jw.write(v);
        }
        if (self.logprobs) |v| {
            try jw.objectField("logprobs");
            try jw.write(v);
        }
        if (self.top_logprobs) |v| {
            try jw.objectField("top_logprobs");
            try jw.write(v);
        }
        if (self.user) |v| {
            try jw.objectField("user");
            try jw.write(v);
        }
        if (self.seed) |v| {
            try jw.objectField("seed");
            try jw.write(v);
        }

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

        var result = Request{
            .model = model,
            .messages = messages,
        };

        if (obj.get("stream")) |v| {
            result.stream = switch (v) {
                .bool => |b| b,
                else => null,
            };
        }
        if (obj.get("temperature")) |v| {
            result.temperature = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| @floatCast(f),
                else => null,
            };
        }
        if (obj.get("max_tokens")) |v| {
            result.max_tokens = switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            };
        }
        if (obj.get("max_completion_tokens")) |v| {
            result.max_completion_tokens = switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            };
        }
        if (obj.get("top_p")) |v| {
            result.top_p = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| @floatCast(f),
                else => null,
            };
        }
        if (obj.get("n")) |v| {
            result.n = switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            };
        }
        if (obj.get("presence_penalty")) |v| {
            result.presence_penalty = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| @floatCast(f),
                else => null,
            };
        }
        if (obj.get("frequency_penalty")) |v| {
            result.frequency_penalty = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| @floatCast(f),
                else => null,
            };
        }
        if (obj.get("tools")) |v| {
            if (v == .array) {
                const tools_arr = v.array.items;
                const tools = try allocator.alloc(Tool, tools_arr.len);
                for (tools_arr, 0..) |tool_val, i| {
                    tools[i] = try std.json.parseFromValueLeaky(Tool, allocator, tool_val, .{});
                }
                result.tools = tools;
            }
        }
        if (obj.get("tool_choice")) |v| {
            result.tool_choice = v;
        }
        if (obj.get("parallel_tool_calls")) |v| {
            result.parallel_tool_calls = switch (v) {
                .bool => |b| b,
                else => null,
            };
        }
        if (obj.get("functions")) |v| {
            if (v == .array) {
                const funcs_arr = v.array.items;
                const funcs = try allocator.alloc(Function, funcs_arr.len);
                for (funcs_arr, 0..) |func_val, i| {
                    funcs[i] = try std.json.parseFromValueLeaky(Function, allocator, func_val, .{});
                }
                result.functions = funcs;
            }
        }
        if (obj.get("function_call")) |v| {
            result.function_call = switch (v) {
                .string => |s| s,
                else => null,
            };
        }
        if (obj.get("response_format")) |v| {
            if (v == .object) {
                result.response_format = try std.json.parseFromValueLeaky(ResponseFormat, allocator, v, .{});
            }
        }
        if (obj.get("stop")) |v| {
            if (v == .array) {
                const stop_arr = v.array.items;
                const stop = try allocator.alloc([]const u8, stop_arr.len);
                for (stop_arr, 0..) |stop_val, i| {
                    stop[i] = switch (stop_val) {
                        .string => |s| s,
                        else => return error.UnexpectedToken,
                    };
                }
                result.stop = stop;
            }
        }
        if (obj.get("logit_bias")) |v| {
            result.logit_bias = v;
        }
        if (obj.get("logprobs")) |v| {
            result.logprobs = switch (v) {
                .bool => |b| b,
                else => null,
            };
        }
        if (obj.get("top_logprobs")) |v| {
            result.top_logprobs = switch (v) {
                .integer => |i| @intCast(i),
                else => null,
            };
        }
        if (obj.get("user")) |v| {
            result.user = switch (v) {
                .string => |s| s,
                else => null,
            };
        }
        if (obj.get("seed")) |v| {
            result.seed = switch (v) {
                .integer => |i| i,
                else => null,
            };
        }

        return result;
    }
};

/// Delta content in streaming response
pub const Delta = struct {
    role: ?Role = null,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    function_call: ?FunctionCall = null,
};

/// Choice in streaming chunk
pub const StreamChoice = struct {
    index: u32,
    delta: Delta,
    finish_reason: ?[]const u8,
};

/// Streaming chunk response
pub const StreamChunk = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const StreamChoice,
};

/// Message in non-streaming response
pub const ResponseMessage = struct {
    role: Role,
    content: ?[]const u8,
    tool_calls: ?[]const ToolCall = null,
    function_call: ?FunctionCall = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        
        try jw.objectField("role");
        try jw.write(@tagName(self.role));
        
        if (self.content) |c| {
            try jw.objectField("content");
            try jw.write(c);
        }
        
        if (self.tool_calls) |tc| {
            try jw.objectField("tool_calls");
            try jw.write(tc);
        }
        
        if (self.function_call) |fc| {
            try jw.objectField("function_call");
            try jw.write(fc);
        }
        
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
        
        try jw.objectField("index");
        try jw.write(self.index);
        
        try jw.objectField("message");
        try self.message.jsonStringify(jw);
        
        if (self.logprobs) |lp| {
            try jw.objectField("logprobs");
            try jw.write(lp);
        }
        
        try jw.objectField("finish_reason");
        try jw.write(self.finish_reason);
        
        try jw.endObject();
    }
};

/// Usage statistics
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Non-streaming response
pub const Response = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const ResponseChoice,
    usage: Usage,
    system_fingerprint: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        
        try jw.objectField("id");
        try jw.write(self.id);
        
        try jw.objectField("object");
        try jw.write(self.object);
        
        try jw.objectField("created");
        try jw.write(self.created);
        
        try jw.objectField("model");
        try jw.write(self.model);
        
        try jw.objectField("choices");
        try jw.beginArray();
        for (self.choices) |choice| {
            try choice.jsonStringify(jw);
        }
        try jw.endArray();
        
        try jw.objectField("usage");
        try jw.write(self.usage);
        
        if (self.system_fingerprint) |sf| {
            try jw.objectField("system_fingerprint");
            try jw.write(sf);
        }
        
        if (self.service_tier) |st| {
            try jw.objectField("service_tier");
            try jw.write(st);
        }
        
        try jw.endObject();
    }
};

