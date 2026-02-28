const std = @import("std");

// ============================================================================
// Anthropic API Data Structures
// ============================================================================

// ============================================================================
// Error Response Structures
// ============================================================================

/// Anthropic error details
pub const ErrorDetails = struct {
    type: []const u8,
    message: []const u8,
};

/// Anthropic error response wrapper
pub const ErrorResponse = struct {
    @"error": ErrorDetails,
};

// ============================================================================
// Request/Response Structures
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

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .base64 => |v| try jw.write(v),
            .url => |v| try jw.write(v),
        }
    }
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

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .base64_pdf => |v| try jw.write(v),
            .plain_text => |v| try jw.write(v),
            .url_pdf => |v| try jw.write(v),
        }
    }
};

/// Tool result block for content
pub const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    content: ?[]const u8 = null,
    is_error: ?bool = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("tool_use_id");
        try jw.write(self.tool_use_id);
        if (self.content) |c| {
            try jw.objectField("content");
            try jw.write(c);
        }
        if (self.is_error) |e| {
            try jw.objectField("is_error");
            try jw.write(e);
        }
        try jw.endObject();
    }
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
    tool_result: ToolResultBlock,
    thinking: struct {
        type: []const u8 = "thinking",
        thinking: []const u8,
        signature: []const u8,
    },
    redacted_thinking: struct {
        type: []const u8 = "redacted_thinking",
        data: []const u8,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |v| try jw.write(v),
            .image => |v| try jw.write(v),
            .document => |v| try jw.write(v),
            .tool_use => |v| try jw.write(v),
            .tool_result => |v| try jw.write(v),
            .thinking => |v| try jw.write(v),
            .redacted_thinking => |v| try jw.write(v),
        }
    }
};

pub const Message = struct {
    role: Role,
    content: union(enum) {
        text: []const u8,
        blocks: []const ContentBlockParam,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(self.role);
        try jw.objectField("content");
        switch (self.content) {
            .text => |t| try jw.write(t),
            .blocks => |blocks| {
                try jw.beginArray();
                for (blocks) |block| {
                    try jw.write(block);
                }
                try jw.endArray();
            },
        }
        try jw.endObject();
    }

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

/// Tool definition for Anthropic API
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema: std.json.Value,
};

/// Tool choice for Anthropic API
pub const ToolChoice = union(enum) {
    auto: struct {
        type: []const u8 = "auto",
    },
    any: struct {
        type: []const u8 = "any",
    },
    tool: struct {
        type: []const u8 = "tool",
        name: []const u8,
    },

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        switch (self) {
            .auto => |v| try out.write(v),
            .any => |v| try out.write(v),
            .tool => |v| try out.write(v),
        }
    }
};

/// Metadata for Anthropic API
pub const Metadata = struct {
    user_id: ?[]const u8 = null,
};

/// Request to Anthropic messages API
pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    max_tokens: u32, // REQUIRED in Anthropic API
    system: ?[]const u8 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    stream: ?bool = null,
    stop_sequences: ?[]const []const u8 = null,
    tools: ?[]const Tool = null,
    tool_choice: ?ToolChoice = null,
    metadata: ?Metadata = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(self.model);

        try jw.objectField("messages");
        try jw.beginArray();
        for (self.messages) |msg| {
            try jw.write(msg);
        }
        try jw.endArray();

        try jw.objectField("max_tokens");
        try jw.write(self.max_tokens);

        if (self.system) |s| {
            try jw.objectField("system");
            try jw.write(s);
        }

        if (self.temperature) |t| {
            try jw.objectField("temperature");
            try jw.write(t);
        }

        if (self.top_p) |t| {
            try jw.objectField("top_p");
            try jw.write(t);
        }

        if (self.top_k) |t| {
            try jw.objectField("top_k");
            try jw.write(t);
        }

        if (self.stream) |s| {
            try jw.objectField("stream");
            try jw.write(s);
        }

        if (self.stop_sequences) |ss| {
            try jw.objectField("stop_sequences");
            try jw.beginArray();
            for (ss) |seq| {
                try jw.write(seq);
            }
            try jw.endArray();
        }

        if (self.tools) |tools| {
            try jw.objectField("tools");
            try jw.beginArray();
            for (tools) |tool| {
                try jw.write(tool);
            }
            try jw.endArray();
        }

        if (self.tool_choice) |tc| {
            try jw.objectField("tool_choice");
            try jw.write(tc);
        }

        if (self.metadata) |m| {
            try jw.objectField("metadata");
            try jw.write(m);
        }

        try jw.endObject();
    }
};

/// Content block in response - can be text or tool_use
pub const ContentBlock = union(enum) {
    text: struct {
        type: []const u8,
        text: []const u8,
    },
    tool_use: struct {
        type: []const u8,
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
    },

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const type_value = obj.get("type") orelse return error.MissingField;
        if (type_value != .string) return error.UnexpectedToken;
        const type_str = type_value.string;

        if (std.mem.eql(u8, type_str, "text")) {
            const text_value = obj.get("text") orelse return error.MissingField;
            if (text_value != .string) return error.UnexpectedToken;
            return .{ .text = .{
                .type = type_str,
                .text = text_value.string,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_use")) {
            const id_value = obj.get("id") orelse return error.MissingField;
            if (id_value != .string) return error.UnexpectedToken;
            const name_value = obj.get("name") orelse return error.MissingField;
            if (name_value != .string) return error.UnexpectedToken;
            const input_value = obj.get("input") orelse std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
            return .{ .tool_use = .{
                .type = type_str,
                .id = id_value.string,
                .name = name_value.string,
                .input = input_value,
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        switch (self) {
            .text => |v| try out.write(v),
            .tool_use => |v| try out.write(v),
        }
    }
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
    index: u32 = 0,
    content_block: struct {
        type: []const u8 = "",
        text: []const u8 = "",
    } = .{},
};

/// Text delta in streaming
pub const TextDelta = struct {
    type: []const u8 = "",
    text: []const u8 = "",
};

/// Content block delta event data
pub const ContentBlockDeltaData = struct {
    type: []const u8 = "",
    index: u32 = 0,
    delta: TextDelta = .{},
};

/// Content block stop event data
pub const ContentBlockStopData = struct {
    type: []const u8 = "",
    index: u32 = 0,
};

/// Message delta event data
pub const MessageDeltaData = struct {
    type: []const u8 = "",
    delta: struct {
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
    } = .{},
    usage: struct {
        output_tokens: u32 = 0,
    } = .{},
};

/// Ping event data
pub const PingData = struct {
    type: []const u8,
};

// ============================================================================
// Streaming Event Types for SSE Parsing
// ============================================================================

/// Generic streaming event wrapper
pub const StreamEvent = struct {
    event_type: []const u8,
    data: []const u8,
};

/// Message start event - contains initial message metadata
pub const MessageStart = struct {
    type: []const u8,
    message: struct {
        id: []const u8,
        type: []const u8,
        role: []const u8,
        content: []const std.json.Value,
        model: []const u8,
        stop_reason: ?[]const u8,
        stop_sequence: ?[]const u8,
        usage: Usage,
    },
};

/// Content block start event
pub const ContentBlockStart = struct {
    type: []const u8 = "",
    index: u32 = 0,
    content_block: ContentBlockInfo = .{},
};

/// Content block info in start event
pub const ContentBlockInfo = struct {
    type: []const u8 = "",
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

/// Content block delta event
pub const ContentBlockDelta = struct {
    type: []const u8 = "",
    index: u32 = 0,
    delta: DeltaContent = .{},
};

/// Delta content - can be text_delta or input_json_delta
pub const DeltaContent = struct {
    type: []const u8 = "",
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
};

/// Content block stop event
pub const ContentBlockStop = struct {
    type: []const u8 = "",
    index: u32 = 0,
};

/// Message delta event - contains stop reason
pub const MessageDelta = struct {
    type: []const u8 = "",
    delta: struct {
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
    } = .{},
    usage: struct {
        output_tokens: u32 = 0,
    } = .{},
};

/// Message stop event
pub const MessageStop = struct {
    type: []const u8 = "",
};

// ============================================================================
// Models API Structures
// ============================================================================

/// Model info from Anthropic /v1/models endpoint
pub const AnthropicModel = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    type: []const u8 = "model_info",
};

/// Response from Anthropic /v1/models endpoint
pub const AnthropicModelsResponse = struct {
    data: []const AnthropicModel = &.{},
    next_cursor: ?[]const u8 = null,
    type: []const u8 = "list",
};

// ============================================================================
// Unit Tests
// ============================================================================
