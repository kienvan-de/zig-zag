const std = @import("std");
const testing = std.testing;
const OpenAI = @import("../openai/types.zig");
const Anthropic = @import("types.zig");

// Type alias for OpenAI message content union
const MessageContent = @TypeOf(@as(OpenAI.Message, undefined).content);

/// Transformation errors
pub const TransformError = error{
    EmptyMessages,
    InvalidMessageSequence,
    UnsupportedContentType,
    AllMessagesAreSystem,
    OutOfMemory,
};

/// Extract system prompt from OpenAI messages
/// System messages are removed from the message list and concatenated
pub fn extractSystemPrompt(
    messages: []const OpenAI.Message,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    var system_parts = std.ArrayList([]const u8){};
    defer system_parts.deinit(allocator);

    for (messages) |msg| {
        if (msg.role == .system) {
            const content_text = switch (msg.content) {
                .text => |s| s,
                .parts => |parts| blk: {
                    // Extract text from parts
                    for (parts) |part| {
                        if (part == .text) {
                            try system_parts.append(allocator, part.text.text);
                        }
                    }
                    break :blk "";
                },
            };
            if (content_text.len > 0) {
                try system_parts.append(allocator, content_text);
            }
        }
    }

    if (system_parts.items.len == 0) {
        return null;
    }

    // Concatenate with newlines
    return try std.mem.join(allocator, "\n\n", system_parts.items);
}

/// Transform OpenAI content to Anthropic content blocks
pub fn transformContent(
    content: MessageContent,
    allocator: std.mem.Allocator,
) ![]Anthropic.ContentBlockParam {
    var blocks = std.ArrayList(Anthropic.ContentBlockParam){};
    errdefer blocks.deinit(allocator);

    switch (content) {
        .text => |text| {
            try blocks.append(allocator, .{ .text = .{ .type = "text", .text = text } });
        },
        .parts => |parts| {
            for (parts) |part| {
                switch (part) {
                    .text => |text_part| {
                        try blocks.append(allocator, .{ .text = .{
                            .type = "text",
                            .text = text_part.text,
                        } });
                    },
                    .image_url => |image_part| {
                        // Parse image URL: can be base64 or URL
                        const url = image_part.image_url.url;
                        if (std.mem.startsWith(u8, url, "data:")) {
                            // Base64 format: data:image/png;base64,<data>
                            const comma_idx = std.mem.indexOfScalar(u8, url, ',') orelse return error.UnsupportedContentType;
                            const base64_data = url[comma_idx + 1 ..];
                            const semicolon_idx = std.mem.indexOfScalar(u8, url[5..], ';') orelse return error.UnsupportedContentType;
                            const media_type = url[5 .. 5 + semicolon_idx];

                            try blocks.append(allocator, .{ .image = .{
                                .type = "image",
                                .source = .{ .base64 = .{
                                    .type = "base64",
                                    .media_type = media_type,
                                    .data = base64_data,
                                } },
                            } });
                        } else {
                            // URL format
                            try blocks.append(allocator, .{ .image = .{
                                .type = "image",
                                .source = .{ .url = .{
                                    .type = "url",
                                    .url = url,
                                } },
                            } });
                        }
                    },
                }
            }
        },
    }

    return try blocks.toOwnedSlice(allocator);
}

/// Transform tool calls to Anthropic tool_use content blocks
/// TODO: Implement proper JSON parsing for tool arguments
pub fn transformToolCalls(
    tool_calls: []const OpenAI.ToolCall,
    allocator: std.mem.Allocator,
) ![]Anthropic.ContentBlockParam {
    _ = tool_calls;
    _ = allocator;
    // TODO: Parse tool_call.function.arguments (JSON string) into std.json.Value
    // For now, return empty array to allow basic tests to pass
    return &[_]Anthropic.ContentBlockParam{};
}

/// Normalize messages: remove system, merge consecutive same-role, ensure alternation
pub fn normalizeMessages(
    messages: []const OpenAI.Message,
    allocator: std.mem.Allocator,
) ![]Anthropic.Message {
    var normalized = std.ArrayList(Anthropic.Message){};
    errdefer {
        for (normalized.items) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        normalized.deinit(allocator);
    }

    var last_role: ?Anthropic.Role = null;
    var pending_content = std.ArrayList(Anthropic.ContentBlockParam){};
    defer pending_content.deinit(allocator);

    for (messages) |msg| {
        // Skip system messages
        if (msg.role == .system) continue;

        // Map role
        const anthro_role: Anthropic.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system => unreachable, // Already filtered
            .tool, .function => .user, // Tool responses become user messages
        };

        // Transform content
        var content_blocks = std.ArrayList(Anthropic.ContentBlockParam){};
        defer content_blocks.deinit(allocator);

        // Handle message content
        const transformed = try transformContent(msg.content, allocator);
        defer allocator.free(transformed);
        try content_blocks.appendSlice(allocator, transformed);

        // TODO: Handle tool calls (assistant messages)
        // Requires JSON parsing for tool arguments
        if (msg.tool_calls) |_| {
            // Skip tool calls for now
        }

        // TODO: Handle tool response (tool/function messages)
        // Requires proper content transformation
        if (msg.role == .tool or msg.role == .function) {
            // Skip tool/function messages for now
        }

        // Check if we need to merge with previous message
        if (last_role) |prev_role| {
            if (prev_role == anthro_role) {
                // Merge with pending content
                try pending_content.appendSlice(allocator, content_blocks.items);
                continue;
            } else {
                // Flush pending content
                if (pending_content.items.len > 0) {
                    const msg_content = try pending_content.toOwnedSlice(allocator);
                    try normalized.append(allocator, .{
                        .role = prev_role,
                        .content = .{ .blocks = msg_content },
                    });
                    pending_content.clearRetainingCapacity();
                }
            }
        }

        // Start new pending message
        try pending_content.appendSlice(allocator, content_blocks.items);
        last_role = anthro_role;
    }

    // Flush final pending content
    if (last_role) |role| {
        if (pending_content.items.len > 0) {
            const msg_content = try pending_content.toOwnedSlice(allocator);
            try normalized.append(allocator, .{
                .role = role,
                .content = .{ .blocks = msg_content },
            });
        }
    }

    // Validate: ensure first message is user
    if (normalized.items.len > 0 and normalized.items[0].role != .user) {
        // Insert synthetic user message
        var synthetic_content = try allocator.alloc(Anthropic.ContentBlockParam, 1);
        synthetic_content[0] = .{ .text = .{
            .type = "text",
            .text = "[Conversation start]",
        } };
        try normalized.insert(allocator, 0, .{
            .role = .user,
            .content = .{ .blocks = synthetic_content },
        });
    }

    if (normalized.items.len == 0) {
        return error.EmptyMessages;
    }

    return try normalized.toOwnedSlice(allocator);
}

/// Main transformation function
pub fn transform(
    request: OpenAI.Request,
    target_model: []const u8,
    allocator: std.mem.Allocator,
) !Anthropic.Request {
    const system_prompt = try extractSystemPrompt(request.messages, allocator);
    const messages = try normalizeMessages(request.messages, allocator);

    return Anthropic.Request{
        .model = target_model,
        .messages = messages,
        .system = system_prompt,
        .max_tokens = request.max_tokens orelse 4096,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stream = request.stream,
    };
}

// ============================================================================
// RESPONSE TRANSFORMATION (Anthropic → OpenAI)
// ============================================================================

/// Transform Anthropic stop reason to OpenAI finish reason
pub fn transformStopReason(stop_reason: ?[]const u8) []const u8 {
    if (stop_reason == null) return "stop";
    
    const reason = stop_reason.?;
    if (std.mem.eql(u8, reason, "end_turn")) return "stop";
    if (std.mem.eql(u8, reason, "max_tokens")) return "length";
    if (std.mem.eql(u8, reason, "stop_sequence")) return "stop";
    if (std.mem.eql(u8, reason, "tool_use")) return "tool_calls";
    
    return "stop"; // default
}

/// Extract text content from Anthropic ContentBlock array
pub fn extractTextFromBlocks(blocks: []const Anthropic.ContentBlock, allocator: std.mem.Allocator) ![]const u8 {
    var text_parts = std.ArrayList([]const u8){};
    defer text_parts.deinit(allocator);
    
    for (blocks) |block| {
        // ContentBlock is a simple struct with type and text fields
        if (std.mem.eql(u8, block.type, "text")) {
            try text_parts.append(allocator, block.text);
        }
    }
    
    if (text_parts.items.len == 0) {
        return try allocator.dupe(u8, "");
    }
    
    return try std.mem.join(allocator, "", text_parts.items);
}

/// Transform Anthropic response to OpenAI response (non-streaming)
/// Cleanup function for Anthropic.Request
pub fn cleanupRequest(request: Anthropic.Request, allocator: std.mem.Allocator) void {
    if (request.system) |s| allocator.free(s);
    for (request.messages) |msg| {
        switch (msg.content) {
            .text => {},
            .blocks => |blocks| allocator.free(blocks),
        }
    }
    allocator.free(request.messages);
}

/// Cleanup function for OpenAI.Response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    if (response.choices.len > 0) {
        if (response.choices[0].message.content) |content| {
            allocator.free(content);
        }
    }
    allocator.free(response.choices);
}

pub fn transformResponse(
    anthropic_response: Anthropic.Response,
    allocator: std.mem.Allocator,
) !OpenAI.Response {
    // Extract text content from content blocks
    const content_text = try extractTextFromBlocks(anthropic_response.content, allocator);
    
    // Create message
    const message = OpenAI.ResponseMessage{
        .role = .assistant,
        .content = content_text,
        .tool_calls = null,
        .function_call = null,
    };
    
    // Create choice
    const choice = OpenAI.ResponseChoice{
        .index = 0,
        .message = message,
        .finish_reason = transformStopReason(anthropic_response.stop_reason),
    };
    
    var choices = try allocator.alloc(OpenAI.ResponseChoice, 1);
    choices[0] = choice;
    
    // Map usage
    const usage = OpenAI.Usage{
        .prompt_tokens = anthropic_response.usage.input_tokens,
        .completion_tokens = anthropic_response.usage.output_tokens,
        .total_tokens = anthropic_response.usage.input_tokens + anthropic_response.usage.output_tokens,
    };
    
    return OpenAI.Response{
        .id = anthropic_response.id,
        .object = "chat.completion",
        .created = std.time.timestamp(),
        .model = anthropic_response.model,
        .choices = choices,
        .usage = usage,
        .system_fingerprint = null,
        .service_tier = null,
    };
}

// ============================================================================
// TESTS - REQUEST TRANSFORMATION
// ============================================================================

test "extractSystemPrompt: single system message" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{
            .role = .system,
            .content = .{ .text = "You are a helpful assistant." },
        },
    };

    const result = try extractSystemPrompt(&messages, allocator);
    defer if (result) |r| allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqualStrings("You are a helpful assistant.", result.?);
}

test "extractSystemPrompt: multiple system messages" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{
            .role = .system,
            .content = .{ .text = "You are a helpful assistant." },
        },
        .{
            .role = .system,
            .content = .{ .text = "Always be concise." },
        },
    };

    const result = try extractSystemPrompt(&messages, allocator);
    defer if (result) |r| allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqualStrings("You are a helpful assistant.\n\nAlways be concise.", result.?);
}

test "extractSystemPrompt: no system messages" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{
            .role = .user,
            .content = .{ .text = "Hello" },
        },
    };

    const result = try extractSystemPrompt(&messages, allocator);
    try testing.expect(result == null);
}

test "extractSystemPrompt: system at different positions" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{
            .role = .user,
            .content = .{ .text = "Hello" },
        },
        .{
            .role = .system,
            .content = .{ .text = "System note 1" },
        },
        .{
            .role = .assistant,
            .content = .{ .text = "Hi there" },
        },
        .{
            .role = .system,
            .content = .{ .text = "System note 2" },
        },
    };

    const result = try extractSystemPrompt(&messages, allocator);
    defer if (result) |r| allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqualStrings("System note 1\n\nSystem note 2", result.?);
}

test "extractSystemPrompt: empty system message" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{
            .role = .system,
            .content = .{ .text = "" },
        },
    };

    const result = try extractSystemPrompt(&messages, allocator);
    try testing.expect(result == null);
}

test "transformContent: simple string" {
    const allocator = testing.allocator;

    const msg = OpenAI.Message{ .role = .user, .content = .{ .text = "Hello world" } };
    const blocks = try transformContent(msg.content, allocator);
    defer allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expect(blocks[0] == .text);
    try testing.expectEqualStrings("Hello world", blocks[0].text.text);
}

test "transformContent: text parts" {
    const allocator = testing.allocator;

    const parts = [_]OpenAI.ContentPart{
        .{ .text = .{ .type = "text", .text = "Hello" } },
        .{ .text = .{ .type = "text", .text = "World" } },
    };
    const msg = OpenAI.Message{ .role = .user, .content = .{ .parts = &parts } };
    const blocks = try transformContent(msg.content, allocator);
    defer allocator.free(blocks);

    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqualStrings("Hello", blocks[0].text.text);
    try testing.expectEqualStrings("World", blocks[1].text.text);
}

test "transformContent: image URL" {
    const allocator = testing.allocator;

    const parts = [_]OpenAI.ContentPart{
        .{ .image_url = .{ .type = "image_url", .image_url = .{ .url = "https://example.com/image.png" } } },
    };
    const msg = OpenAI.Message{ .role = .user, .content = .{ .parts = &parts } };
    const blocks = try transformContent(msg.content, allocator);
    defer allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expect(blocks[0] == .image);
    try testing.expectEqualStrings("https://example.com/image.png", blocks[0].image.source.url.url);
}

test "transformContent: image base64" {
    const allocator = testing.allocator;

    const parts = [_]OpenAI.ContentPart{
        .{ .image_url = .{ .type = "image_url", .image_url = .{ .url = "data:image/png;base64,iVBORw0KGgo=" } } },
    };
    const msg = OpenAI.Message{ .role = .user, .content = .{ .parts = &parts } };
    const blocks = try transformContent(msg.content, allocator);
    defer allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expect(blocks[0] == .image);
    try testing.expectEqualStrings("image/png", blocks[0].image.source.base64.media_type);
    try testing.expectEqualStrings("iVBORw0KGgo=", blocks[0].image.source.base64.data);
}

test "normalizeMessages: basic alternation preserved" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
        .{ .role = .assistant, .content = .{ .text = "Hi" } },
        .{ .role = .user, .content = .{ .text = "How are you?" } },
    };

    const result = try normalizeMessages(&messages, allocator);
    defer {
        for (result) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(Anthropic.Role.user, result[0].role);
    try testing.expectEqual(Anthropic.Role.assistant, result[1].role);
    try testing.expectEqual(Anthropic.Role.user, result[2].role);
}

test "normalizeMessages: consecutive user messages merged" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
        .{ .role = .user, .content = .{ .text = "World" } },
    };

    const result = try normalizeMessages(&messages, allocator);
    defer {
        for (result) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(Anthropic.Role.user, result[0].role);
    try testing.expectEqual(@as(usize, 2), result[0].content.blocks.len);
}

test "normalizeMessages: consecutive assistant messages merged" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
        .{ .role = .assistant, .content = .{ .text = "Hi" } },
        .{ .role = .assistant, .content = .{ .text = "How can I help?" } },
    };

    const result = try normalizeMessages(&messages, allocator);
    defer {
        for (result) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(Anthropic.Role.user, result[0].role);
    try testing.expectEqual(Anthropic.Role.assistant, result[1].role);
    try testing.expectEqual(@as(usize, 2), result[1].content.blocks.len);
}

test "normalizeMessages: system messages removed" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .system, .content = .{ .text = "System prompt" } },
        .{ .role = .user, .content = .{ .text = "Hello" } },
        .{ .role = .assistant, .content = .{ .text = "Hi" } },
    };

    const result = try normalizeMessages(&messages, allocator);
    defer {
        for (result) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(Anthropic.Role.user, result[0].role);
    try testing.expectEqual(Anthropic.Role.assistant, result[1].role);
}

test "normalizeMessages: first message is assistant gets synthetic user" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .assistant, .content = .{ .text = "Hello" } },
    };

    const result = try normalizeMessages(&messages, allocator);
    defer {
        for (result) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(Anthropic.Role.user, result[0].role);
    try testing.expectEqualStrings("[Conversation start]", result[0].content.blocks[0].text.text);
    try testing.expectEqual(Anthropic.Role.assistant, result[1].role);
}

test "transform: basic request" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .system, .content = .{ .text = "You are helpful." } },
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };

    const request = OpenAI.Request{
        .model = "anthropic/claude-3-5-sonnet-latest",
        .messages = &messages,
        .stream = null,
        .max_tokens = null,
        .temperature = null,
        .top_p = null,
        .n = null,
        .stop = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
        .tools = null,
        .tool_choice = null,
        .response_format = null,
        .functions = null,
        .function_call = null,
    };

    const result = try transform(request, "claude-3-5-sonnet-latest", allocator);
    defer {
        if (result.system) |s| allocator.free(s);
        for (result.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result.messages);
    }

    try testing.expectEqualStrings("claude-3-5-sonnet-latest", result.model);
    try testing.expect(result.system != null);
    try testing.expectEqualStrings("You are helpful.", result.system.?);
    try testing.expectEqual(@as(usize, 1), result.messages.len);
    try testing.expectEqual(@as(u32, 4096), result.max_tokens);
}

test "transform: max_tokens default" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };

    const request = OpenAI.Request{
        .model = "anthropic/claude-3-5-sonnet-latest",
        .messages = &messages,
        .stream = null,
        .max_tokens = null,
        .temperature = null,
        .top_p = null,
        .n = null,
        .stop = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
        .tools = null,
        .tool_choice = null,
        .response_format = null,
        .functions = null,
        .function_call = null,
    };

    const result = try transform(request, "claude-3-5-sonnet-latest", allocator);
    defer {
        if (result.system) |s| allocator.free(s);
        for (result.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result.messages);
    }

    try testing.expectEqual(@as(u32, 4096), result.max_tokens);
}

test "transform: max_tokens provided" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };

    const request = OpenAI.Request{
        .model = "anthropic/claude-3-5-sonnet-latest",
        .messages = &messages,
        .stream = null,
        .max_tokens = 2000,
        .temperature = null,
        .top_p = null,
        .n = null,
        .stop = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
        .tools = null,
        .tool_choice = null,
        .response_format = null,
        .functions = null,
        .function_call = null,
    };

    const result = try transform(request, "claude-3-5-sonnet-latest", allocator);
    defer {
        if (result.system) |s| allocator.free(s);
        for (result.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result.messages);
    }

    try testing.expectEqual(@as(u32, 2000), result.max_tokens);
}

test "transform: temperature passthrough" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };

    const request = OpenAI.Request{
        .model = "anthropic/claude-3-5-sonnet-latest",
        .messages = &messages,
        .stream = null,
        .max_tokens = null,
        .temperature = 0.7,
        .top_p = null,
        .n = null,
        .stop = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
        .tools = null,
        .tool_choice = null,
        .response_format = null,
        .functions = null,
        .function_call = null,
    };

    const result = try transform(request, "claude-3-5-sonnet-latest", allocator);
    defer {
        if (result.system) |s| allocator.free(s);
        for (result.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result.messages);
    }

    try testing.expect(result.temperature != null);
    try testing.expectEqual(@as(f32, 0.7), result.temperature.?);
}

test "transform: stream passthrough" {
    const allocator = testing.allocator;

    const messages = [_]OpenAI.Message{
        .{ .role = .user, .content = .{ .text = "Hello" } },
    };

    const request = OpenAI.Request{
        .model = "anthropic/claude-3-5-sonnet-latest",
        .messages = &messages,
        .stream = true,
        .max_tokens = null,
        .temperature = null,
        .top_p = null,
        .n = null,
        .stop = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
        .tools = null,
        .tool_choice = null,
        .response_format = null,
        .functions = null,
        .function_call = null,
    };

    const result = try transform(request, "claude-3-5-sonnet-latest", allocator);
    defer {
        if (result.system) |s| allocator.free(s);
        for (result.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(result.messages);
    }

    try testing.expect(result.stream != null);
    try testing.expect(result.stream.?);
}

// ============================================================================
// TESTS - RESPONSE TRANSFORMATION
// ============================================================================

test "transformStopReason: end_turn to stop" {
    const result = transformStopReason("end_turn");
    try testing.expectEqualStrings("stop", result);
}

test "transformStopReason: max_tokens to length" {
    const result = transformStopReason("max_tokens");
    try testing.expectEqualStrings("length", result);
}

test "transformStopReason: stop_sequence to stop" {
    const result = transformStopReason("stop_sequence");
    try testing.expectEqualStrings("stop", result);
}

test "transformStopReason: tool_use to tool_calls" {
    const result = transformStopReason("tool_use");
    try testing.expectEqualStrings("tool_calls", result);
}

test "transformStopReason: null defaults to stop" {
    const result = transformStopReason(null);
    try testing.expectEqualStrings("stop", result);
}

test "transformStopReason: unknown defaults to stop" {
    const result = transformStopReason("unknown_reason");
    try testing.expectEqualStrings("stop", result);
}

test "extractTextFromBlocks: single text block" {
    const allocator = testing.allocator;
    
    const blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "Hello world" },
    };
    
    const result = try extractTextFromBlocks(&blocks, allocator);
    defer allocator.free(result);
    
    try testing.expectEqualStrings("Hello world", result);
}

test "extractTextFromBlocks: multiple text blocks" {
    const allocator = testing.allocator;
    
    const blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "Hello " },
        .{ .type = "text", .text = "world" },
        .{ .type = "text", .text = "!" },
    };
    
    const result = try extractTextFromBlocks(&blocks, allocator);
    defer allocator.free(result);
    
    try testing.expectEqualStrings("Hello world!", result);
}

test "extractTextFromBlocks: empty blocks" {
    const allocator = testing.allocator;
    
    const blocks = [_]Anthropic.ContentBlock{};
    
    const result = try extractTextFromBlocks(&blocks, allocator);
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "extractTextFromBlocks: mixed content types" {
    const allocator = testing.allocator;
    
    const blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "Hello" },
        .{ .type = "image", .text = "" }, // Non-text block, should be skipped
        .{ .type = "text", .text = " world" },
    };
    
    const result = try extractTextFromBlocks(&blocks, allocator);
    defer allocator.free(result);
    
    try testing.expectEqualStrings("Hello world", result);
}

test "transformResponse: basic response" {
    const allocator = testing.allocator;
    
    const content_blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "Hello! How can I help you today?" },
    };
    
    const anthropic_resp = Anthropic.Response{
        .id = "msg_123",
        .type = "message",
        .role = "assistant",
        .content = &content_blocks,
        .model = "claude-3-5-sonnet-20241022",
        .stop_reason = "end_turn",
        .stop_sequence = null,
        .usage = .{
            .input_tokens = 10,
            .output_tokens = 20,
        },
    };
    
    const result = try transformResponse(anthropic_resp, allocator);
    defer {
        if (result.choices[0].message.content) |content| {
            allocator.free(content);
        }
        allocator.free(result.choices);
    }
    
    try testing.expectEqualStrings("msg_123", result.id);
    try testing.expectEqualStrings("chat.completion", result.object);
    try testing.expectEqualStrings("claude-3-5-sonnet-20241022", result.model);
    try testing.expectEqual(@as(usize, 1), result.choices.len);
    try testing.expectEqual(OpenAI.Role.assistant, result.choices[0].message.role);
    try testing.expectEqualStrings("Hello! How can I help you today?", result.choices[0].message.content.?);
    try testing.expectEqualStrings("stop", result.choices[0].finish_reason);
    try testing.expectEqual(@as(u32, 10), result.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 20), result.usage.completion_tokens);
    try testing.expectEqual(@as(u32, 30), result.usage.total_tokens);
}

test "transformResponse: multiple content blocks" {
    const allocator = testing.allocator;
    
    const content_blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "First part. " },
        .{ .type = "text", .text = "Second part." },
    };
    
    const anthropic_resp = Anthropic.Response{
        .id = "msg_456",
        .type = "message",
        .role = "assistant",
        .content = &content_blocks,
        .model = "claude-3-opus-20240229",
        .stop_reason = "end_turn",
        .stop_sequence = null,
        .usage = .{
            .input_tokens = 5,
            .output_tokens = 15,
        },
    };
    
    const result = try transformResponse(anthropic_resp, allocator);
    defer {
        if (result.choices[0].message.content) |content| {
            allocator.free(content);
        }
        allocator.free(result.choices);
    }
    
    try testing.expectEqualStrings("First part. Second part.", result.choices[0].message.content.?);
}

test "transformResponse: max_tokens stop reason" {
    const allocator = testing.allocator;
    
    const content_blocks = [_]Anthropic.ContentBlock{
        .{ .type = "text", .text = "Response text" },
    };
    
    const anthropic_resp = Anthropic.Response{
        .id = "msg_789",
        .type = "message",
        .role = "assistant",
        .content = &content_blocks,
        .model = "claude-3-5-sonnet-20241022",
        .stop_reason = "max_tokens",
        .stop_sequence = null,
        .usage = .{
            .input_tokens = 100,
            .output_tokens = 4096,
        },
    };
    
    const result = try transformResponse(anthropic_resp, allocator);
    defer {
        if (result.choices[0].message.content) |content| {
            allocator.free(content);
        }
        allocator.free(result.choices);
    }
    
    try testing.expectEqualStrings("length", result.choices[0].finish_reason);
}

test "transformResponse: empty content" {
    const allocator = testing.allocator;
    
    const content_blocks = [_]Anthropic.ContentBlock{};
    
    const anthropic_resp = Anthropic.Response{
        .id = "msg_empty",
        .type = "message",
        .role = "assistant",
        .content = &content_blocks,
        .model = "claude-3-5-sonnet-20241022",
        .stop_reason = "end_turn",
        .stop_sequence = null,
        .usage = .{
            .input_tokens = 10,
            .output_tokens = 0,
        },
    };
    
    const result = try transformResponse(anthropic_resp, allocator);
    defer {
        if (result.choices[0].message.content) |content| {
            allocator.free(content);
        }
        allocator.free(result.choices);
    }
    
    try testing.expectEqualStrings("", result.choices[0].message.content.?);
}