const std = @import("std");
const testing = std.testing;
const OpenAI = @import("../openai/types.zig");
const Anthropic = @import("types.zig");

// ============================================================================
// Streaming State and Transformation
// ============================================================================

/// State for Anthropic→OpenAI streaming conversion
/// Anthropic events are stateful, so we need to track context across events
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    message_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    original_model: []const u8,
    created: i64,
    current_tool_call_index: ?u32 = null,
    current_tool_call_id: ?[]const u8 = null,
    current_tool_call_name: ?[]const u8 = null,
    sent_role: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) StreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            .created = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *StreamState) void {
        _ = self;
        // No owned allocations to free - we use slices from parsed JSON
    }
};

/// Transform a single Anthropic SSE line to OpenAI SSE format
/// Returns null if no output should be emitted for this event
/// Returns allocated string that caller must free
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return null;
    }

    const json_part = line["data: ".len..];

    // Try to determine event type by parsing
    const type_info = std.json.parseFromSlice(
        struct { type: []const u8 },
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer type_info.deinit();

    const event_type = type_info.value.type;

    if (std.mem.eql(u8, event_type, "message_start")) {
        return handleMessageStart(json_part, state, allocator);
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
        return handleContentBlockStart(json_part, state, allocator);
    } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
        return handleContentBlockDelta(json_part, state, allocator);
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        return handleMessageDelta(json_part, state, allocator);
    } else if (std.mem.eql(u8, event_type, "message_stop")) {
        return null; // We'll emit [DONE] separately
    }
    // Ignore: content_block_stop, ping, etc.
    return null;
}

fn handleMessageStart(json_part: []const u8, state: *StreamState, allocator: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        Anthropic.MessageStart,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    state.message_id = parsed.value.message.id;
    state.model = parsed.value.message.model;

    // Emit initial chunk with role
    state.sent_role = true;
    return buildOpenAIChunk(state, .{ .role = .assistant }, null, allocator);
}

fn handleContentBlockStart(json_part: []const u8, state: *StreamState, allocator: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        Anthropic.ContentBlockStart,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    const block_type = parsed.value.content_block.type;

    if (std.mem.eql(u8, block_type, "tool_use")) {
        // Start of tool call - emit tool_calls delta with id, type, name
        state.current_tool_call_index = parsed.value.index;
        state.current_tool_call_id = parsed.value.content_block.id;
        state.current_tool_call_name = parsed.value.content_block.name;

        const tool_call = OpenAI.DeltaToolCall{
            .index = parsed.value.index,
            .id = parsed.value.content_block.id,
            .type = "function",
            .function = .{
                .name = parsed.value.content_block.name,
                .arguments = null,
            },
        };

        var tool_calls: [1]OpenAI.DeltaToolCall = .{tool_call};
        return buildOpenAIChunk(state, .{ .tool_calls = &tool_calls }, null, allocator);
    }
    // For text blocks, we wait for content_block_delta
    return null;
}

fn handleContentBlockDelta(json_part: []const u8, state: *StreamState, allocator: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        Anthropic.ContentBlockDelta,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    const delta_type = parsed.value.delta.type;

    if (std.mem.eql(u8, delta_type, "text_delta")) {
        // Text content
        if (parsed.value.delta.text) |text| {
            return buildOpenAIChunk(state, .{ .content = text }, null, allocator);
        }
    } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
        // Tool call arguments
        if (parsed.value.delta.partial_json) |partial| {
            const tool_call = OpenAI.DeltaToolCall{
                .index = parsed.value.index,
                .id = null,
                .type = null,
                .function = .{
                    .name = null,
                    .arguments = partial,
                },
            };

            var tool_calls: [1]OpenAI.DeltaToolCall = .{tool_call};
            return buildOpenAIChunk(state, .{ .tool_calls = &tool_calls }, null, allocator);
        }
    }
    return null;
}

fn handleMessageDelta(json_part: []const u8, state: *StreamState, allocator: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        Anthropic.MessageDelta,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    // Emit final chunk with finish_reason
    const finish_reason = transformStopReason(parsed.value.delta.stop_reason);
    return buildOpenAIChunk(state, .{}, finish_reason, allocator);
}

/// Build an OpenAI streaming chunk from state and delta info
fn buildOpenAIChunk(
    state: *StreamState,
    delta: OpenAI.Delta,
    finish_reason: ?[]const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const choice = OpenAI.StreamChoice{
        .index = 0,
        .delta = delta,
        .finish_reason = finish_reason,
    };

    var choices: [1]OpenAI.StreamChoice = .{choice};

    const chunk = OpenAI.StreamChunk{
        .id = state.message_id orelse "msg_unknown",
        .object = "chat.completion.chunk",
        .created = state.created,
        .model = state.original_model,
        .choices = &choices,
    };

    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    buffer.writer(allocator).print("data: {f}", .{std.json.fmt(chunk, .{})}) catch return null;

    return buffer.toOwnedSlice(allocator) catch null;
}

// Type alias for OpenAI message content union
const MessageContent = OpenAI.MessageContent;

/// Parsed tool_choice from OpenAI (can be string or object)
pub const ToolChoiceOption = union(enum) {
    mode: []const u8, // "none", "auto", "required"
    specific: struct {
        function: struct {
            name: []const u8,
        },
    },
};

/// Transformation errors
pub const TransformError = error{
    EmptyMessages,
    InvalidMessageSequence,
    UnsupportedContentType,
    AllMessagesAreSystem,
    OutOfMemory,
    InvalidJson,
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

/// Transform OpenAI tool calls to Anthropic tool_use content blocks
pub fn transformToolCalls(
    tool_calls: []const OpenAI.ToolCall,
    allocator: std.mem.Allocator,
) ![]Anthropic.ContentBlockParam {
    var blocks = std.ArrayList(Anthropic.ContentBlockParam){};
    errdefer blocks.deinit(allocator);

    for (tool_calls) |tc| {
        // Parse the arguments JSON string into a std.json.Value
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, tc.function.arguments, .{}) catch {
            // If parsing fails, use empty object
            try blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = tc.id,
                .name = tc.function.name,
                .input = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
            } });
            continue;
        };

        try blocks.append(allocator, .{ .tool_use = .{
            .type = "tool_use",
            .id = tc.id,
            .name = tc.function.name,
            .input = parsed.value,
        } });
    }

    return try blocks.toOwnedSlice(allocator);
}

/// Transform OpenAI tool/function message to Anthropic tool_result content block
pub fn transformToolResult(
    tool_call_id: []const u8,
    content: ?MessageContent,
    allocator: std.mem.Allocator,
) !Anthropic.ContentBlockParam {
    _ = allocator;
    const content_str: ?[]const u8 = if (content) |c| switch (c) {
        .text => |t| t,
        .parts => |parts| blk: {
            // Take first text part
            for (parts) |part| {
                if (part == .text) {
                    break :blk part.text.text;
                }
            }
            break :blk null;
        },
    } else null;

    return .{ .tool_result = .{
        .type = "tool_result",
        .tool_use_id = tool_call_id,
        .content = content_str,
        .is_error = null,
    } };
}

/// Transform OpenAI tools to Anthropic tools
pub fn transformTools(
    tools: []const OpenAI.Tool,
    allocator: std.mem.Allocator,
) ![]Anthropic.Tool {
    var anthro_tools = try allocator.alloc(Anthropic.Tool, tools.len);
    errdefer allocator.free(anthro_tools);

    for (tools, 0..) |tool, i| {
        anthro_tools[i] = .{
            .name = tool.function.name,
            .description = tool.function.description,
            .input_schema = tool.function.parameters orelse std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
        };
    }

    return anthro_tools;
}

/// Transform OpenAI tool_choice (std.json.Value) to Anthropic tool_choice
pub fn transformToolChoice(
    tool_choice: std.json.Value,
) ?Anthropic.ToolChoice {
    switch (tool_choice) {
        .string => |mode| {
            if (std.mem.eql(u8, mode, "auto")) {
                return .{ .auto = .{ .type = "auto" } };
            } else if (std.mem.eql(u8, mode, "none")) {
                return null; // No tool choice means don't use tools
            } else if (std.mem.eql(u8, mode, "required")) {
                return .{ .any = .{ .type = "any" } };
            }
            return .{ .auto = .{ .type = "auto" } };
        },
        .object => |obj| {
            // Object format: {"type": "function", "function": {"name": "..."}}
            if (obj.get("function")) |func_val| {
                if (func_val == .object) {
                    if (func_val.object.get("name")) |name_val| {
                        if (name_val == .string) {
                            return .{ .tool = .{
                                .type = "tool",
                                .name = name_val.string,
                            } };
                        }
                    }
                }
            }
            return .{ .auto = .{ .type = "auto" } };
        },
        else => return .{ .auto = .{ .type = "auto" } },
    }
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

        // Handle tool/function messages - these need tool_result blocks
        if (msg.role == .tool or msg.role == .function) {
            const tool_call_id = msg.tool_call_id orelse "";
            const tool_result = try transformToolResult(tool_call_id, msg.content, allocator);
            try content_blocks.append(allocator, tool_result);
        } else {
            // Handle message content (may be null for assistant messages with tool_calls)
            if (msg.content) |content| {
                const transformed = try transformContent(content, allocator);
                defer allocator.free(transformed);
                try content_blocks.appendSlice(allocator, transformed);
            }

            // Handle tool calls (assistant messages)
            if (msg.tool_calls) |tool_calls| {
                const tool_use_blocks = try transformToolCalls(tool_calls, allocator);
                defer allocator.free(tool_use_blocks);
                try content_blocks.appendSlice(allocator, tool_use_blocks);
            }
        }

        // Skip if no content
        if (content_blocks.items.len == 0) continue;

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

    // Transform tools if present
    const tools: ?[]Anthropic.Tool = if (request.tools) |t| try transformTools(t, allocator) else null;

    // Transform tool_choice if present
    const tool_choice: ?Anthropic.ToolChoice = if (request.tool_choice) |tc| transformToolChoice(tc) else null;

    // Transform stop sequences
    const stop_sequences: ?[]const []const u8 = request.stop;

    // Transform metadata (user -> user_id)
    const metadata: ?Anthropic.Metadata = if (request.user) |u| .{ .user_id = u } else null;

    return Anthropic.Request{
        .model = target_model,
        .messages = messages,
        .system = system_prompt,
        .max_tokens = request.max_tokens orelse request.max_completion_tokens orelse 4096,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_k = null,
        .stream = request.stream,
        .stop_sequences = stop_sequences,
        .tools = tools,
        .tool_choice = tool_choice,
        .metadata = metadata,
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
        switch (block) {
            .text => |t| {
                try text_parts.append(allocator, t.text);
            },
            .tool_use => {},
        }
    }

    if (text_parts.items.len == 0) {
        return try allocator.dupe(u8, "");
    }

    return try std.mem.join(allocator, "", text_parts.items);
}

/// Extract tool_use blocks from Anthropic ContentBlock array and convert to OpenAI ToolCall array
pub fn extractToolCalls(blocks: []const Anthropic.ContentBlock, allocator: std.mem.Allocator) !?[]OpenAI.ToolCall {
    var tool_calls = std.ArrayList(OpenAI.ToolCall){};
    defer tool_calls.deinit(allocator);

    for (blocks) |block| {
        switch (block) {
            .tool_use => |tu| {
                // Stringify the input JSON
                var args_list = std.ArrayList(u8){};
                defer args_list.deinit(allocator);
                try args_list.writer(allocator).print("{f}", .{std.json.fmt(tu.input, .{})});
                const args_str = try args_list.toOwnedSlice(allocator);

                try tool_calls.append(allocator, .{
                    .id = tu.id,
                    .type = "function",
                    .function = .{
                        .name = tu.name,
                        .arguments = args_str,
                    },
                });
            },
            .text => {},
        }
    }

    if (tool_calls.items.len == 0) {
        return null;
    }

    return try tool_calls.toOwnedSlice(allocator);
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
    if (request.tools) |tools| allocator.free(tools);
}

/// Cleanup function for OpenAI.Response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    if (response.choices.len > 0) {
        if (response.choices[0].message.content) |content| {
            allocator.free(content);
        }
        if (response.choices[0].message.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                allocator.free(tc.function.arguments);
            }
            allocator.free(tool_calls);
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

    // Extract tool calls from content blocks
    const tool_calls = try extractToolCalls(anthropic_response.content, allocator);

    // Create message
    const message = OpenAI.ResponseMessage{
        .role = .assistant,
        .content = if (content_text.len > 0) content_text else null,
        .tool_calls = tool_calls,
        .function_call = null,
    };

    // Create choice
    const choice = OpenAI.ResponseChoice{
        .index = 0,
        .message = message,
        .finish_reason = transformStopReason(anthropic_response.stop_reason),
        .logprobs = null,
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