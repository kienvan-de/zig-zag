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

/// Tool definition
pub const Tool = struct {
    type: []const u8, // "function"
    function: struct {
        name: []const u8,
        description: ?[]const u8 = null,
        parameters: ?std.json.Value = null, // JSON schema
    },
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

/// Represents a message in the conversation
pub const Message = struct {
    role: Role,
    content: union(enum) {
        text: []const u8,
        parts: []const ContentPart,
    },
    name: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    function_call: ?FunctionCall = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        
        if (json_value != .object) return error.UnexpectedToken;
        const obj = json_value.object;
        
        const role_value = obj.get("role") orelse return error.MissingField;
        const role = try std.json.innerParseFromValue(Role, allocator, role_value, options);
        
        const content_value = obj.get("content") orelse return error.MissingField;
        
        const ContentUnion = @TypeOf(@as(@This(), undefined).content);
        const content: ContentUnion = switch (content_value) {
            .string => |s| .{ .text = s },
            .array => |arr| blk: {
                var parts = try allocator.alloc(ContentPart, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    parts[i] = try std.json.innerParseFromValue(ContentPart, allocator, item, options);
                }
                break :blk .{ .parts = parts };
            },
            .null => .{ .text = "" },
            else => return error.UnexpectedToken,
        };

        const name = if (obj.get("name")) |n| 
            if (n == .string) n.string else null
        else null;

        const tool_calls = if (obj.get("tool_calls")) |tc|
            if (tc == .array) blk: {
                var calls = try allocator.alloc(ToolCall, tc.array.items.len);
                for (tc.array.items, 0..) |item, i| {
                    calls[i] = try std.json.innerParseFromValue(ToolCall, allocator, item, options);
                }
                break :blk calls;
            } else null
        else null;

        const tool_call_id = if (obj.get("tool_call_id")) |tid|
            if (tid == .string) tid.string else null
        else null;

        const function_call = if (obj.get("function_call")) |fc|
            if (fc == .object) try std.json.innerParseFromValue(FunctionCall, allocator, fc, options) else null
        else null;
        
        return .{
            .role = role,
            .content = content,
            .name = name,
            .tool_calls = tool_calls,
            .tool_call_id = tool_call_id,
            .function_call = function_call,
        };
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        
        const role_value = obj.get("role") orelse return error.MissingField;
        const role = try std.json.innerParseFromValue(Role, allocator, role_value, options);
        
        const content_value = obj.get("content") orelse return error.MissingField;
        
        const ContentUnion = @TypeOf(@as(@This(), undefined).content);
        const content: ContentUnion = switch (content_value) {
            .string => |s| .{ .text = s },
            .array => |arr| blk: {
                var parts = try allocator.alloc(ContentPart, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    parts[i] = try std.json.innerParseFromValue(ContentPart, allocator, item, options);
                }
                break :blk .{ .parts = parts };
            },
            .null => .{ .text = "" },
            else => return error.UnexpectedToken,
        };

        const name = if (obj.get("name")) |n| 
            if (n == .string) n.string else null
        else null;

        const tool_calls = if (obj.get("tool_calls")) |tc|
            if (tc == .array) blk: {
                var calls = try allocator.alloc(ToolCall, tc.array.items.len);
                for (tc.array.items, 0..) |item, i| {
                    calls[i] = try std.json.innerParseFromValue(ToolCall, allocator, item, options);
                }
                break :blk calls;
            } else null
        else null;

        const tool_call_id = if (obj.get("tool_call_id")) |tid|
            if (tid == .string) tid.string else null
        else null;

        const function_call = if (obj.get("function_call")) |fc|
            if (fc == .object) try std.json.innerParseFromValue(FunctionCall, allocator, fc, options) else null
        else null;
        
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
    top_p: ?f32 = null,
    n: ?u32 = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    tools: ?[]const Tool = null,
    tool_choice: ?[]const u8 = null, // "none", "auto", or JSON
    functions: ?[]const Function = null,
    function_call: ?[]const u8 = null, // "none", "auto", or JSON
    response_format: ?ResponseFormat = null,
    stop: ?[]const []const u8 = null,
    logit_bias: ?std.json.Value = null,
    user: ?[]const u8 = null,
    seed: ?i64 = null,
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
};

/// Choice in non-streaming response
pub const ResponseChoice = struct {
    index: u32,
    message: ResponseMessage,
    finish_reason: []const u8,
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
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Role enum values" {
    const testing = std.testing;
    
    const system_role = Role.system;
    const user_role = Role.user;
    const assistant_role = Role.assistant;
    const function_role = Role.function;
    const tool_role = Role.tool;
    
    try testing.expect(system_role == Role.system);
    try testing.expect(user_role == Role.user);
    try testing.expect(assistant_role == Role.assistant);
    try testing.expect(function_role == Role.function);
    try testing.expect(tool_role == Role.tool);
}

test "Role enum string conversion" {
    const testing = std.testing;
    
    try testing.expectEqualStrings("system", @tagName(Role.system));
    try testing.expectEqualStrings("user", @tagName(Role.user));
    try testing.expectEqualStrings("assistant", @tagName(Role.assistant));
    try testing.expectEqualStrings("function", @tagName(Role.function));
    try testing.expectEqualStrings("tool", @tagName(Role.tool));
}

test "Role from string" {
    const testing = std.testing;
    
    const system = std.meta.stringToEnum(Role, "system");
    const user = std.meta.stringToEnum(Role, "user");
    const assistant = std.meta.stringToEnum(Role, "assistant");
    const function = std.meta.stringToEnum(Role, "function");
    const tool = std.meta.stringToEnum(Role, "tool");
    const invalid = std.meta.stringToEnum(Role, "invalid");
    
    try testing.expect(system == Role.system);
    try testing.expect(user == Role.user);
    try testing.expect(assistant == Role.assistant);
    try testing.expect(function == Role.function);
    try testing.expect(tool == Role.tool);
    try testing.expect(invalid == null);
}

test "Message struct creation" {
    const testing = std.testing;
    
    const msg = Message{
        .role = .user,
        .content = .{ .text = "Hello, GPT!" },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqualStrings("Hello, GPT!", msg.content.text);
}

test "Request struct with minimal fields" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
    };
    
    try testing.expectEqualStrings("gpt-4", req.model);
    try testing.expectEqual(1, req.messages.len);
    try testing.expect(req.stream == null);
    try testing.expect(req.temperature == null);
    try testing.expect(req.max_tokens == null);
}

test "Request struct with all optional fields" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .system, .content = .{ .text = "You are helpful." } },
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
        .stream = false,
        .temperature = 0.7,
        .max_tokens = 1000,
        .top_p = 1.0,
        .n = 1,
        .presence_penalty = 0.0,
        .frequency_penalty = 0.0,
    };
    
    try testing.expectEqualStrings("gpt-4", req.model);
    try testing.expectEqual(2, req.messages.len);
    try testing.expect(req.messages[0].role == Role.system);
    try testing.expect(req.messages[1].role == Role.user);
    try testing.expectEqual(false, req.stream.?);
    try testing.expectEqual(@as(f32, 0.7), req.temperature.?);
    try testing.expectEqual(@as(u32, 1000), req.max_tokens.?);
    try testing.expectEqual(@as(f32, 1.0), req.top_p.?);
}

test "Request JSON parsing from minimal sample" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "gpt-4",
        \\  "messages": [
        \\    {
        \\      "role": "user",
        \\      "content": "Hello!"
        \\    }
        \\  ]
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("gpt-4", parsed.value.model);
    try testing.expectEqual(1, parsed.value.messages.len);
    try testing.expect(parsed.value.messages[0].role == Role.user);
    try testing.expectEqualStrings("Hello!", parsed.value.messages[0].content.text);
}

test "Request JSON parsing with optional fields" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "gpt-4",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello!"}
        \\  ],
        \\  "temperature": 0.7,
        \\  "max_tokens": 1000,
        \\  "stream": false
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqual(@as(f32, 0.7), parsed.value.temperature.?);
    try testing.expectEqual(@as(u32, 1000), parsed.value.max_tokens.?);
    try testing.expectEqual(false, parsed.value.stream.?);
}

test "Request JSON parsing with multiple messages" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "gpt-4",
        \\  "messages": [
        \\    {"role": "system", "content": "You are helpful."},
        \\    {"role": "user", "content": "Hello!"},
        \\    {"role": "assistant", "content": "Hi there!"},
        \\    {"role": "user", "content": "How are you?"}
        \\  ]
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqual(4, parsed.value.messages.len);
    try testing.expect(parsed.value.messages[0].role == Role.system);
    try testing.expect(parsed.value.messages[1].role == Role.user);
    try testing.expect(parsed.value.messages[2].role == Role.assistant);
}

test "Response struct creation" {
    const testing = std.testing;
    
    const response_msg = ResponseMessage{
        .role = .assistant,
        .content = "Hello!",
    };
    
    var choices = [_]ResponseChoice{
        .{
            .index = 0,
            .message = response_msg,
            .finish_reason = "stop",
        },
    };
    
    const resp = Response{
        .id = "chatcmpl-123",
        .object = "chat.completion",
        .created = 1677652288,
        .model = "gpt-4-0613",
        .choices = &choices,
        .usage = Usage{
            .prompt_tokens = 56,
            .completion_tokens = 15,
            .total_tokens = 71,
        },
    };
    
    try testing.expectEqualStrings("chatcmpl-123", resp.id);
    try testing.expectEqual(1, resp.choices.len);
    try testing.expectEqualStrings("Hello!", resp.choices[0].message.content.?);
    try testing.expectEqual(@as(u32, 71), resp.usage.total_tokens);
}

test "Response JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion",
        \\  "created": 1677652288,
        \\  "model": "gpt-4-0613",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "Hello!"
        \\      },
        \\      "finish_reason": "stop"
        \\    }
        \\  ],
        \\  "usage": {
        \\    "prompt_tokens": 56,
        \\    "completion_tokens": 15,
        \\    "total_tokens": 71
        \\  }
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Response, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("chatcmpl-123", parsed.value.id);
    try testing.expectEqual(1, parsed.value.choices.len);
    try testing.expect(parsed.value.choices[0].message.role == Role.assistant);
    try testing.expectEqual(@as(u32, 56), parsed.value.usage.prompt_tokens);
}

test "StreamChunk struct creation" {
    const testing = std.testing;
    
    const delta = Delta{
        .role = .assistant,
        .content = "",
    };
    
    var choices = [_]StreamChoice{
        .{
            .index = 0,
            .delta = delta,
            .finish_reason = null,
        },
    };
    
    const chunk = StreamChunk{
        .id = "chatcmpl-123",
        .object = "chat.completion.chunk",
        .created = 1694268190,
        .model = "gpt-4-0613",
        .choices = &choices,
    };
    
    try testing.expectEqualStrings("chatcmpl-123", chunk.id);
    try testing.expectEqualStrings("chat.completion.chunk", chunk.object);
    try testing.expectEqual(1, chunk.choices.len);
}

test "StreamChunk JSON parsing with role" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion.chunk",
        \\  "created": 1694268190,
        \\  "model": "gpt-4-0613",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "delta": {
        \\        "role": "assistant",
        \\        "content": ""
        \\      },
        \\      "finish_reason": null
        \\    }
        \\  ]
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(StreamChunk, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expect(parsed.value.choices[0].delta.role.? == Role.assistant);
    try testing.expectEqualStrings("", parsed.value.choices[0].delta.content.?);
    try testing.expect(parsed.value.choices[0].finish_reason == null);
}

test "StreamChunk JSON parsing with content" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion.chunk",
        \\  "created": 1694268190,
        \\  "model": "gpt-4-0613",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "delta": {
        \\        "content": "Hello"
        \\      },
        \\      "finish_reason": null
        \\    }
        \\  ]
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(StreamChunk, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expect(parsed.value.choices[0].delta.role == null);
    try testing.expectEqualStrings("Hello", parsed.value.choices[0].delta.content.?);
}

test "StreamChunk JSON parsing with finish_reason" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "id": "chatcmpl-123",
        \\  "object": "chat.completion.chunk",
        \\  "created": 1694268190,
        \\  "model": "gpt-4-0613",
        \\  "choices": [
        \\    {
        \\      "index": 0,
        \\      "delta": {},
        \\      "finish_reason": "stop"
        \\    }
        \\  ]
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(StreamChunk, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("stop", parsed.value.choices[0].finish_reason.?);
}

test "Request with stream field variations" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    // Test with stream = true
    const req_streaming = Request{
        .model = "gpt-4",
        .messages = &messages,
        .stream = true,
    };
    try testing.expectEqual(true, req_streaming.stream.?);
    
    // Test with stream = false
    const req_non_streaming = Request{
        .model = "gpt-4",
        .messages = &messages,
        .stream = false,
    };
    try testing.expectEqual(false, req_non_streaming.stream.?);
}

test "Delta with only content field" {
    const testing = std.testing;
    
    const delta = Delta{
        .content = "Hello",
    };
    
    try testing.expect(delta.role == null);
    try testing.expectEqualStrings("Hello", delta.content.?);
}

test "Delta with only role field" {
    const testing = std.testing;
    
    const delta = Delta{
        .role = .assistant,
    };
    
    try testing.expect(delta.role.? == Role.assistant);
    try testing.expect(delta.content == null);
}

test "Role JSON parsing from string" {
    const testing = std.testing;
    
    const json_system = "\"system\"";
    const json_user = "\"user\"";
    const json_assistant = "\"assistant\"";
    const json_function = "\"function\"";
    const json_tool = "\"tool\"";
    
    const parsed_system = try std.json.parseFromSlice(Role, testing.allocator, json_system, .{});
    defer parsed_system.deinit();
    const parsed_user = try std.json.parseFromSlice(Role, testing.allocator, json_user, .{});
    defer parsed_user.deinit();
    const parsed_assistant = try std.json.parseFromSlice(Role, testing.allocator, json_assistant, .{});
    defer parsed_assistant.deinit();
    const parsed_function = try std.json.parseFromSlice(Role, testing.allocator, json_function, .{});
    defer parsed_function.deinit();
    const parsed_tool = try std.json.parseFromSlice(Role, testing.allocator, json_tool, .{});
    defer parsed_tool.deinit();
    
    try testing.expect(parsed_system.value == Role.system);
    try testing.expect(parsed_user.value == Role.user);
    try testing.expect(parsed_assistant.value == Role.assistant);
    try testing.expect(parsed_function.value == Role.function);
    try testing.expect(parsed_tool.value == Role.tool);
}

test "Role JSON parsing rejects invalid role" {
    const testing = std.testing;
    
    const json_invalid = "\"invalid_role\"";
    
    const result = std.json.parseFromSlice(Role, testing.allocator, json_invalid, .{});
    try testing.expectError(error.UnknownField, result);
}

test "Message with all role types" {
    const testing = std.testing;
    
    const system_msg = Message{ .role = .system, .content = .{ .text = "System prompt" } };
    const user_msg = Message{ .role = .user, .content = .{ .text = "User message" } };
    const assistant_msg = Message{ .role = .assistant, .content = .{ .text = "Assistant response" } };
    const function_msg = Message{ .role = .function, .content = .{ .text = "Function result" } };
    const tool_msg = Message{ .role = .tool, .content = .{ .text = "Tool output" } };
    
    try testing.expect(system_msg.role == Role.system);
    try testing.expect(user_msg.role == Role.user);
    try testing.expect(assistant_msg.role == Role.assistant);
    try testing.expect(function_msg.role == Role.function);
    try testing.expect(tool_msg.role == Role.tool);
}

test "Usage struct calculations" {
    const testing = std.testing;
    
    const usage = Usage{
        .prompt_tokens = 56,
        .completion_tokens = 15,
        .total_tokens = 71,
    };
    
    try testing.expectEqual(@as(u32, 71), usage.prompt_tokens + usage.completion_tokens);
}

test "Full request with Role enum from real sample" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "gpt-4",
        \\  "messages": [
        \\    {
        \\      "role": "system",
        \\      "content": "You are a helpful assistant."
        \\    },
        \\    {
        \\      "role": "user",
        \\      "content": "Hello, how are you?"
        \\    },
        \\    {
        \\      "role": "assistant",
        \\      "content": "I'm doing well, thank you!"
        \\    }
        \\  ],
        \\  "temperature": 0.7,
        \\  "stream": false
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqual(3, parsed.value.messages.len);
    try testing.expect(parsed.value.messages[0].role == Role.system);
    try testing.expect(parsed.value.messages[1].role == Role.user);
    try testing.expect(parsed.value.messages[2].role == Role.assistant);
    try testing.expectEqualStrings("You are a helpful assistant.", parsed.value.messages[0].content.text);
    try testing.expectEqualStrings("Hello, how are you?", parsed.value.messages[1].content.text);
}

test "StreamChunk Delta role transitions" {
    const testing = std.testing;
    
    // First chunk with role
    const delta1 = Delta{ .role = .assistant, .content = "" };
    try testing.expect(delta1.role.? == Role.assistant);
    
    // Subsequent chunks with only content
    const delta2 = Delta{ .content = "Hello" };
    try testing.expect(delta2.role == null);
    try testing.expectEqualStrings("Hello", delta2.content.?);
    
    // Final chunk with neither
    const delta3 = Delta{};
    try testing.expect(delta3.role == null);
    try testing.expect(delta3.content == null);
}

test "Request with function calling roles" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "What's the weather?" } },
        .{ .role = .function, .content = .{ .text = "{\"temp\": 72, \"condition\": \"sunny\"}" } },
        .{ .role = .assistant, .content = .{ .text = "It's 72°F and sunny!" } },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
    };
    
    try testing.expectEqual(3, req.messages.len);
    try testing.expect(req.messages[0].role == Role.user);
    try testing.expect(req.messages[1].role == Role.function);
    try testing.expect(req.messages[2].role == Role.assistant);
}

test "Request with tool calling roles" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Search for Zig documentation" } },
        .{ .role = .tool, .content = .{ .text = "Found 5 results..." } },
        .{ .role = .assistant, .content = .{ .text = "Here are the results" } },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
    };
    
    try testing.expectEqual(3, req.messages.len);
    try testing.expect(req.messages[0].role == Role.user);
    try testing.expect(req.messages[1].role == Role.tool);
    try testing.expect(req.messages[2].role == Role.assistant);
}

test "Message with image_url content" {
    const testing = std.testing;
    
    var parts = [_]ContentPart{
        .{ .text = .{
            .text = "What's in this image?",
        } },
        .{ .image_url = .{
            .image_url = .{
                .url = "https://example.com/image.png",
                .detail = "high",
            },
        } },
    };
    
    const msg = Message{
        .role = .user,
        .content = .{ .parts = &parts },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqual(@as(usize, 2), msg.content.parts.len);
    try testing.expectEqualStrings("text", msg.content.parts[0].text.type);
    try testing.expectEqualStrings("image_url", msg.content.parts[1].image_url.type);
}

test "Message with tool_calls" {
    const testing = std.testing;
    
    var tool_calls = [_]ToolCall{
        .{
            .id = "call_abc123",
            .type = "function",
            .function = .{
                .name = "get_weather",
                .arguments = "{\"location\": \"San Francisco\"}",
            },
        },
    };
    
    const msg = Message{
        .role = .assistant,
        .content = .{ .text = "" },
        .tool_calls = &tool_calls,
    };
    
    try testing.expect(msg.role == Role.assistant);
    try testing.expectEqual(@as(usize, 1), msg.tool_calls.?.len);
    try testing.expectEqualStrings("call_abc123", msg.tool_calls.?[0].id);
    try testing.expectEqualStrings("get_weather", msg.tool_calls.?[0].function.name);
}

test "Message with tool_call_id" {
    const testing = std.testing;
    
    const msg = Message{
        .role = .tool,
        .content = .{ .text = "{\"temp\": 72, \"condition\": \"sunny\"}" },
        .tool_call_id = "call_abc123",
    };
    
    try testing.expect(msg.role == Role.tool);
    try testing.expectEqualStrings("call_abc123", msg.tool_call_id.?);
}

test "Request with tools" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "What's the weather?" } },
    };
    
    var tools = [_]Tool{
        .{
            .type = "function",
            .function = .{
                .name = "get_weather",
                .description = "Get the current weather",
                .parameters = null,
            },
        },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
        .tools = &tools,
        .tool_choice = "auto",
    };
    
    try testing.expectEqual(@as(usize, 1), req.tools.?.len);
    try testing.expectEqualStrings("get_weather", req.tools.?[0].function.name);
    try testing.expectEqualStrings("auto", req.tool_choice.?);
}

test "Request with response_format" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Return JSON" } },
    };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
        .response_format = .{ .type = "json_object" },
    };
    
    try testing.expectEqualStrings("json_object", req.response_format.?.type);
}

test "Request with stop sequences" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };
    
    var stop_seqs = [_][]const u8{ "\n", "END" };
    
    const req = Request{
        .model = "gpt-4",
        .messages = &messages,
        .stop = &stop_seqs,
    };
    
    try testing.expectEqual(@as(usize, 2), req.stop.?.len);
    try testing.expectEqualStrings("\n", req.stop.?[0]);
    try testing.expectEqualStrings("END", req.stop.?[1]);
}

test "Delta with tool_calls" {
    const testing = std.testing;
    
    var tool_calls = [_]ToolCall{
        .{
            .id = "call_abc123",
            .type = "function",
            .function = .{
                .name = "get_weather",
                .arguments = "{}",
            },
        },
    };
    
    const delta = Delta{
        .tool_calls = &tool_calls,
    };
    
    try testing.expect(delta.role == null);
    try testing.expect(delta.content == null);
    try testing.expectEqual(@as(usize, 1), delta.tool_calls.?.len);
}

test "Response with system_fingerprint" {
    const testing = std.testing;
    
    const response_msg = ResponseMessage{
        .role = .assistant,
        .content = "Hello!",
    };
    
    var choices = [_]ResponseChoice{
        .{
            .index = 0,
            .message = response_msg,
            .finish_reason = "stop",
        },
    };
    
    const resp = Response{
        .id = "chatcmpl-123",
        .object = "chat.completion",
        .created = 1677652288,
        .model = "gpt-4-0613",
        .choices = &choices,
        .usage = Usage{
            .prompt_tokens = 10,
            .completion_tokens = 5,
            .total_tokens = 15,
        },
        .system_fingerprint = "fp_44709d6fcb",
        .service_tier = "default",
    };
    
    try testing.expectEqualStrings("fp_44709d6fcb", resp.system_fingerprint.?);
    try testing.expectEqualStrings("default", resp.service_tier.?);
}

test "ResponseMessage with tool_calls" {
    const testing = std.testing;
    
    var tool_calls = [_]ToolCall{
        .{
            .id = "call_abc123",
            .type = "function",
            .function = .{
                .name = "get_weather",
                .arguments = "{\"location\": \"SF\"}",
            },
        },
    };
    
    const msg = ResponseMessage{
        .role = .assistant,
        .content = null,
        .tool_calls = &tool_calls,
    };
    
    try testing.expect(msg.content == null);
    try testing.expectEqual(@as(usize, 1), msg.tool_calls.?.len);
    try testing.expectEqualStrings("call_abc123", msg.tool_calls.?[0].id);
}