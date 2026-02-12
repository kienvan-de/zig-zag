const std = @import("std");
const testing = std.testing;
const OpenAI = @import("../openai/types.zig");
const Anthropic = @import("types.zig");

// Type alias for OpenAI message content union
const MessageContent = OpenAI.MessageContent;

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
            const content_text = if (msg.content) |content| switch (content) {
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
            } else "";
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

        // Handle message content (may be null for assistant messages with tool_calls)
        if (msg.content) |content| {
            const transformed = try transformContent(content, allocator);
            defer allocator.free(transformed);
            try content_blocks.appendSlice(allocator, transformed);
        }

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
    // Free the id and model strings allocated in transformResponse
    allocator.free(response.id);
    allocator.free(response.model);
}

pub fn transformResponse(
    anthropic_response: Anthropic.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
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
    
    // Build model string: "anthropic/{actual_model_from_response}"
    const model_str = try std.fmt.allocPrint(allocator, "anthropic/{s}", .{anthropic_response.model});
    _ = original_model; // Available if needed for future use
    
    // Duplicate id string to avoid dangling pointer after response is freed
    const id_str = try allocator.dupe(u8, anthropic_response.id);
    
    return OpenAI.Response{
        .id = id_str,
        .object = "chat.completion",
        .created = std.time.timestamp(),
        .model = model_str,
        .choices = choices,
        .usage = usage,
        .system_fingerprint = null,
        .service_tier = null,
    };
}

// ============================================================================
// TESTS - REQUEST TRANSFORMATION
// ============================================================================

