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

