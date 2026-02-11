const std = @import("std");

// ============================================================================
// Anthropic API Data Structures
// ============================================================================

/// Role in Anthropic conversation (only user and assistant)
pub const Role = enum {
    user,
    assistant,

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

/// Message in conversation
/// Image source for content blocks
pub const ImageSource = union(enum) {
    base64: struct {
        type: []const u8 = "base64",
        media_type: []const u8, // "image/jpeg", "image/png", "image/gif", "image/webp"
        data: []const u8,
    },
    url: struct {
        type: []const u8 = "url",
        url: []const u8,
    },
};

/// Document source for content blocks
pub const DocumentSource = union(enum) {
    base64_pdf: struct {
        type: []const u8 = "base64",
        media_type: []const u8 = "application/pdf",
        data: []const u8,
    },
    plain_text: struct {
        type: []const u8 = "text",
        media_type: []const u8 = "text/plain",
        data: []const u8,
    },
    url_pdf: struct {
        type: []const u8 = "url",
        url: []const u8,
    },
};

/// Content block param for messages (request)
pub const ContentBlockParam = union(enum) {
    text: struct {
        type: []const u8 = "text",
        text: []const u8,
    },
    image: struct {
        type: []const u8 = "image",
        source: ImageSource,
    },
    document: struct {
        type: []const u8 = "document",
        source: DocumentSource,
        title: ?[]const u8 = null,
        context: ?[]const u8 = null,
    },
    tool_use: struct {
        type: []const u8 = "tool_use",
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
    },
    tool_result: struct {
        type: []const u8 = "tool_result",
        tool_use_id: []const u8,
        content: ?[]const u8 = null, // Can be string or array of content blocks
        is_error: ?bool = null,
    },
    thinking: struct {
        type: []const u8 = "thinking",
        thinking: []const u8,
        signature: []const u8,
    },
    redacted_thinking: struct {
        type: []const u8 = "redacted_thinking",
        data: []const u8,
    },
};

pub const Message = struct {
    role: Role,
    content: union(enum) {
        text: []const u8,
        blocks: []const ContentBlockParam,
    },

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
                var blocks = try allocator.alloc(ContentBlockParam, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    blocks[i] = try std.json.innerParseFromValue(ContentBlockParam, allocator, item, options);
                }
                break :blk .{ .blocks = blocks };
            },
            else => return error.UnexpectedToken,
        };
        
        return .{
            .role = role,
            .content = content,
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
                var blocks = try allocator.alloc(ContentBlockParam, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    blocks[i] = try std.json.innerParseFromValue(ContentBlockParam, allocator, item, options);
                }
                break :blk .{ .blocks = blocks };
            },
            else => return error.UnexpectedToken,
        };
        
        return .{
            .role = role,
            .content = content,
        };
    }
};

/// Request to Anthropic messages API
pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    max_tokens: u32, // REQUIRED in Anthropic API
    system: ?[]const u8 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    stream: ?bool = null,
};

/// Content block in response
pub const ContentBlock = struct {
    type: []const u8,
    text: []const u8,
};

/// Usage statistics
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

/// Non-streaming response
pub const Response = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8, // Always "assistant"
    content: []const ContentBlock,
    model: []const u8,
    stop_reason: ?[]const u8,
    stop_sequence: ?[]const u8,
    usage: Usage,
};

// ============================================================================
// Streaming Event Structures
// ============================================================================

/// Message start event data
pub const MessageStartData = struct {
    type: []const u8,
    message: struct {
        id: []const u8,
        type: []const u8,
        role: []const u8,
        content: []const ContentBlock,
        model: []const u8,
        stop_reason: ?[]const u8,
        stop_sequence: ?[]const u8,
        usage: Usage,
    },
};

/// Content block start event data
pub const ContentBlockStartData = struct {
    type: []const u8,
    index: u32,
    content_block: struct {
        type: []const u8,
        text: []const u8,
    },
};

/// Text delta in streaming
pub const TextDelta = struct {
    type: []const u8,
    text: []const u8,
};

/// Content block delta event data
pub const ContentBlockDeltaData = struct {
    type: []const u8,
    index: u32,
    delta: TextDelta,
};

/// Content block stop event data
pub const ContentBlockStopData = struct {
    type: []const u8,
    index: u32,
};

/// Message delta event data
pub const MessageDeltaData = struct {
    type: []const u8,
    delta: struct {
        stop_reason: ?[]const u8,
        stop_sequence: ?[]const u8,
    },
    usage: struct {
        output_tokens: u32,
    },
};

/// Ping event data
pub const PingData = struct {
    type: []const u8,
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Role enum values" {
    const testing = std.testing;
    
    const user_role = Role.user;
    const assistant_role = Role.assistant;
    
    try testing.expect(user_role == Role.user);
    try testing.expect(assistant_role == Role.assistant);
}

test "Role enum string conversion" {
    const testing = std.testing;
    
    try testing.expectEqualStrings("user", @tagName(Role.user));
    try testing.expectEqualStrings("assistant", @tagName(Role.assistant));
}

test "Role from string" {
    const testing = std.testing;
    
    const user = std.meta.stringToEnum(Role, "user");
    const assistant = std.meta.stringToEnum(Role, "assistant");
    const system = std.meta.stringToEnum(Role, "system"); // Not valid in Anthropic
    
    try testing.expect(user == Role.user);
    try testing.expect(assistant == Role.assistant);
    try testing.expect(system == null); // Anthropic doesn't support system role in messages
}

test "Role JSON parsing" {
    const testing = std.testing;
    
    const json_user = "\"user\"";
    const json_assistant = "\"assistant\"";
    
    const parsed_user = try std.json.parseFromSlice(Role, testing.allocator, json_user, .{});
    defer parsed_user.deinit();
    const parsed_assistant = try std.json.parseFromSlice(Role, testing.allocator, json_assistant, .{});
    defer parsed_assistant.deinit();
    
    try testing.expect(parsed_user.value == Role.user);
    try testing.expect(parsed_assistant.value == Role.assistant);
}

test "Role JSON parsing rejects system role" {
    const testing = std.testing;
    
    const json_system = "\"system\"";
    
    const result = std.json.parseFromSlice(Role, testing.allocator, json_system, .{});
    try testing.expectError(error.UnknownField, result);
}

test "Message struct creation" {
    const testing = std.testing;
    
    const msg = Message{
        .role = .user,
        .content = .{ .text = "Hello!" },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqualStrings("Hello!", msg.content.text);
}

test "Request with minimal required fields" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    const req = Request{
        .model = "claude-3-5-sonnet-20241022",
        .messages = &messages,
        .max_tokens = 1024,
    };
    
    try testing.expectEqualStrings("claude-3-5-sonnet-20241022", req.model);
    try testing.expectEqual(1, req.messages.len);
    try testing.expectEqual(@as(u32, 1024), req.max_tokens);
    try testing.expect(req.system == null);
}

test "Request with system prompt" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    const req = Request{
        .model = "claude-3-5-sonnet-20241022",
        .messages = &messages,
        .max_tokens = 1024,
        .system = "You are a helpful assistant.",
    };
    
    try testing.expectEqualStrings("You are a helpful assistant.", req.system.?);
}

test "Request with all optional fields" {
    const testing = std.testing;
    
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
        .{ .role = .assistant, .content = .{ .text = "Hi there!" } },
        .{ .role = .user, .content = .{ .text = "How are you?" } },
    };
    
    const req = Request{
        .model = "claude-3-5-sonnet-20241022",
        .messages = &messages,
        .max_tokens = 1024,
        .system = "You are helpful.",
        .temperature = 0.7,
        .top_p = 1.0,
        .stream = false,
    };
    
    try testing.expectEqual(3, req.messages.len);
    try testing.expectEqual(@as(f32, 0.7), req.temperature.?);
    try testing.expectEqual(@as(f32, 1.0), req.top_p.?);
    try testing.expectEqual(false, req.stream.?);
}

test "Request JSON parsing minimal" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "messages": [
        \\    {
        \\      "role": "user",
        \\      "content": "Hello!"
        \\    }
        \\  ],
        \\  "max_tokens": 1024
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("claude-3-5-sonnet-20241022", parsed.value.model);
    try testing.expectEqual(1, parsed.value.messages.len);
    try testing.expect(parsed.value.messages[0].role == Role.user);
    try testing.expectEqualStrings("Hello!", parsed.value.messages[0].content.text);
    try testing.expectEqual(@as(u32, 1024), parsed.value.max_tokens);
}

test "Request JSON parsing with system prompt" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello!"}
        \\  ],
        \\  "system": "You are a helpful assistant.",
        \\  "max_tokens": 1024,
        \\  "temperature": 0.7,
        \\  "stream": false
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("You are a helpful assistant.", parsed.value.system.?);
    try testing.expectEqual(@as(f32, 0.7), parsed.value.temperature.?);
    try testing.expectEqual(false, parsed.value.stream.?);
}

test "Request JSON parsing with alternating messages" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello!"},
        \\    {"role": "assistant", "content": "Hi there!"},
        \\    {"role": "user", "content": "How are you?"}
        \\  ],
        \\  "max_tokens": 1024
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Request, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqual(3, parsed.value.messages.len);
    try testing.expect(parsed.value.messages[0].role == Role.user);
    try testing.expect(parsed.value.messages[1].role == Role.assistant);
    try testing.expect(parsed.value.messages[2].role == Role.user);
}

test "ContentBlock struct creation" {
    const testing = std.testing;
    
    const block = ContentBlock{
        .type = "text",
        .text = "Hello, world!",
    };
    
    try testing.expectEqualStrings("text", block.type);
    try testing.expectEqualStrings("Hello, world!", block.text);
}

test "Response struct creation" {
    const testing = std.testing;
    
    var content = [_]ContentBlock{
        .{ .type = "text", .text = "Hello!" },
    };
    
    const resp = Response{
        .id = "msg_01XFDUDYJgAACzvnptvVbrkw",
        .type = "message",
        .role = "assistant",
        .content = &content,
        .model = "claude-3-5-sonnet-20241022",
        .stop_reason = "end_turn",
        .stop_sequence = null,
        .usage = Usage{
            .input_tokens = 12,
            .output_tokens = 18,
        },
    };
    
    try testing.expectEqualStrings("msg_01XFDUDYJgAACzvnptvVbrkw", resp.id);
    try testing.expectEqual(1, resp.content.len);
    try testing.expectEqualStrings("Hello!", resp.content[0].text);
    try testing.expectEqual(@as(u32, 12), resp.usage.input_tokens);
}

test "Response JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "id": "msg_01XFDUDYJgAACzvnptvVbrkw",
        \\  "type": "message",
        \\  "role": "assistant",
        \\  "content": [
        \\    {
        \\      "type": "text",
        \\      "text": "Hello! I'm doing well, thank you for asking."
        \\    }
        \\  ],
        \\  "model": "claude-3-5-sonnet-20241022",
        \\  "stop_reason": "end_turn",
        \\  "stop_sequence": null,
        \\  "usage": {
        \\    "input_tokens": 12,
        \\    "output_tokens": 18
        \\  }
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(Response, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("msg_01XFDUDYJgAACzvnptvVbrkw", parsed.value.id);
    try testing.expectEqualStrings("assistant", parsed.value.role);
    try testing.expectEqual(1, parsed.value.content.len);
    try testing.expectEqualStrings("text", parsed.value.content[0].type);
    try testing.expectEqualStrings("Hello! I'm doing well, thank you for asking.", parsed.value.content[0].text);
    try testing.expectEqualStrings("end_turn", parsed.value.stop_reason.?);
    try testing.expectEqual(@as(u32, 12), parsed.value.usage.input_tokens);
    try testing.expectEqual(@as(u32, 18), parsed.value.usage.output_tokens);
}

test "Usage struct" {
    const testing = std.testing;
    
    const usage = Usage{
        .input_tokens = 100,
        .output_tokens = 50,
    };
    
    try testing.expectEqual(@as(u32, 100), usage.input_tokens);
    try testing.expectEqual(@as(u32, 50), usage.output_tokens);
    try testing.expectEqual(@as(u32, 150), usage.input_tokens + usage.output_tokens);
}

test "TextDelta struct creation" {
    const testing = std.testing;
    
    const delta = TextDelta{
        .type = "text_delta",
        .text = "Hello",
    };
    
    try testing.expectEqualStrings("text_delta", delta.type);
    try testing.expectEqualStrings("Hello", delta.text);
}

test "ContentBlockDeltaData JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "type": "content_block_delta",
        \\  "index": 0,
        \\  "delta": {
        \\    "type": "text_delta",
        \\    "text": "Hello"
        \\  }
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(ContentBlockDeltaData, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("content_block_delta", parsed.value.type);
    try testing.expectEqual(@as(u32, 0), parsed.value.index);
    try testing.expectEqualStrings("text_delta", parsed.value.delta.type);
    try testing.expectEqualStrings("Hello", parsed.value.delta.text);
}

test "ContentBlockStartData JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "type": "content_block_start",
        \\  "index": 0,
        \\  "content_block": {
        \\    "type": "text",
        \\    "text": ""
        \\  }
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(ContentBlockStartData, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("content_block_start", parsed.value.type);
    try testing.expectEqual(@as(u32, 0), parsed.value.index);
    try testing.expectEqualStrings("text", parsed.value.content_block.type);
}

test "MessageDeltaData JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "type": "message_delta",
        \\  "delta": {
        \\    "stop_reason": "end_turn",
        \\    "stop_sequence": null
        \\  },
        \\  "usage": {
        \\    "output_tokens": 18
        \\  }
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(MessageDeltaData, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("message_delta", parsed.value.type);
    try testing.expectEqualStrings("end_turn", parsed.value.delta.stop_reason.?);
    try testing.expectEqual(@as(u32, 18), parsed.value.usage.output_tokens);
}

test "PingData JSON parsing" {
    const testing = std.testing;
    
    const json_data =
        \\{
        \\  "type": "ping"
        \\}
    ;
    
    const parsed = try std.json.parseFromSlice(PingData, testing.allocator, json_data, .{});
    defer parsed.deinit();
    
    try testing.expectEqualStrings("ping", parsed.value.type);
}

test "Request max_tokens is required" {
    const testing = std.testing;
    
    // This test verifies that max_tokens is not optional
    var messages = [_]Message{
        .{ .role = .user, .content = .{ .text = "Hello!" } },
    };
    
    // This should compile because max_tokens is provided
    const req = Request{
        .model = "claude-3-5-sonnet-20241022",
        .messages = &messages,
        .max_tokens = 1024,
    };
    
    try testing.expect(req.max_tokens > 0);
}

test "Anthropic only supports user and assistant roles" {
    const testing = std.testing;
    
    // Verify we can create user and assistant messages
    const user_msg = Message{ .role = .user, .content = .{ .text = "Hello" } };
    const assistant_msg = Message{ .role = .assistant, .content = .{ .text = "Hi" } };
    
    try testing.expect(user_msg.role == Role.user);
    try testing.expect(assistant_msg.role == Role.assistant);
    
    // Verify system is not a valid role (compile-time check via enum)
    // If we tried: Message{ .role = .system, ... } it would fail to compile
}

test "Message with tool_use content block" {
    const testing = std.testing;
    
    var blocks = [_]ContentBlockParam{
        .{ .tool_use = .{
            .id = "toolu_01A09q90qw90lq917835lq9",
            .name = "get_weather",
            .input = .{ .object = std.json.ObjectMap.init(testing.allocator) },
        } },
    };
    
    const msg = Message{
        .role = .assistant,
        .content = .{ .blocks = &blocks },
    };
    
    try testing.expect(msg.role == Role.assistant);
    try testing.expectEqualStrings("tool_use", msg.content.blocks[0].tool_use.type);
    try testing.expectEqualStrings("get_weather", msg.content.blocks[0].tool_use.name);
}

test "Message with tool_result content block" {
    const testing = std.testing;
    
    var blocks = [_]ContentBlockParam{
        .{ .tool_result = .{
            .tool_use_id = "toolu_01A09q90qw90lq917835lq9",
            .content = "The weather is sunny",
            .is_error = false,
        } },
    };
    
    const msg = Message{
        .role = .user,
        .content = .{ .blocks = &blocks },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqualStrings("tool_result", msg.content.blocks[0].tool_result.type);
    try testing.expectEqualStrings("toolu_01A09q90qw90lq917835lq9", msg.content.blocks[0].tool_result.tool_use_id);
}

test "Message with image content block" {
    const testing = std.testing;
    
    var blocks = [_]ContentBlockParam{
        .{ .image = .{
            .source = .{ .base64 = .{
                .media_type = "image/png",
                .data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            } },
        } },
    };
    
    const msg = Message{
        .role = .user,
        .content = .{ .blocks = &blocks },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqualStrings("image", msg.content.blocks[0].image.type);
}

test "Message with document content block" {
    const testing = std.testing;
    
    var blocks = [_]ContentBlockParam{
        .{ .document = .{
            .source = .{ .plain_text = .{
                .data = "This is a document",
            } },
            .title = "Sample Document",
            .context = "Context information",
        } },
    };
    
    const msg = Message{
        .role = .user,
        .content = .{ .blocks = &blocks },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqualStrings("document", msg.content.blocks[0].document.type);
    try testing.expectEqualStrings("Sample Document", msg.content.blocks[0].document.title.?);
}

test "Message with mixed content blocks" {
    const testing = std.testing;
    
    var blocks = [_]ContentBlockParam{
        .{ .text = .{
            .text = "Here's an image:",
        } },
        .{ .image = .{
            .source = .{ .url = .{
                .url = "https://example.com/image.png",
            } },
        } },
    };
    
    const msg = Message{
        .role = .user,
        .content = .{ .blocks = &blocks },
    };
    
    try testing.expect(msg.role == Role.user);
    try testing.expectEqual(@as(usize, 2), msg.content.blocks.len);
    try testing.expectEqualStrings("text", msg.content.blocks[0].text.type);
    try testing.expectEqualStrings("image", msg.content.blocks[1].image.type);
}