// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

// ============================================================================
// OpenAI Common Types
// Shared between /v1/chat/completions (chat_types.zig)
// and /v1/responses (responses_types.zig).
// ============================================================================

/// Model object from /v1/models endpoint
pub const Model = struct {
    id: []const u8,
    object: []const u8 = "model",
    created: i64 = 0,
    owned_by: []const u8 = "unknown",
};

/// Response for GET /v1/models
pub const ModelsResponse = struct {
    object: []const u8 = "list",
    data: []const Model,
};

/// Role in a conversation
pub const Role = enum {
    system,
    user,
    assistant,
    developer,
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
        prompt_cache_breakpoint: ?std.json.Value = null,
    },
    image_url: struct {
        type: []const u8 = "image_url",
        image_url: struct {
            url: []const u8,
            detail: ?[]const u8 = null,
        },
        prompt_cache_breakpoint: ?std.json.Value = null,
    },
    input_audio: struct {
        type: []const u8 = "input_audio",
        input_audio: std.json.Value,
        prompt_cache_breakpoint: ?std.json.Value = null,
    },
    file: struct {
        type: []const u8 = "file",
        file: std.json.Value,
        prompt_cache_breakpoint: ?std.json.Value = null,
    },
    refusal: struct {
        type: []const u8 = "refusal",
        refusal: []const u8,
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
            return .{ .text = .{ .type = "text", .text = text_value.string, .prompt_cache_breakpoint = obj.get("prompt_cache_breakpoint") } };
        } else if (std.mem.eql(u8, type_str, "image_url")) {
            const image_url_obj = obj.get("image_url") orelse return error.MissingField;
            if (image_url_obj != .object) return error.UnexpectedToken;
            const url_value = image_url_obj.object.get("url") orelse return error.MissingField;
            if (url_value != .string) return error.UnexpectedToken;
            const detail = if (image_url_obj.object.get("detail")) |d| if (d == .string) d.string else null else null;
            return .{ .image_url = .{
                .type = "image_url",
                .image_url = .{ .url = url_value.string, .detail = detail },
                .prompt_cache_breakpoint = obj.get("prompt_cache_breakpoint"),
            } };
        } else if (std.mem.eql(u8, type_str, "input_audio")) {
            const audio_val = obj.get("input_audio") orelse return error.MissingField;
            return .{ .input_audio = .{ .type = "input_audio", .input_audio = audio_val, .prompt_cache_breakpoint = obj.get("prompt_cache_breakpoint") } };
        } else if (std.mem.eql(u8, type_str, "file")) {
            const file_val = obj.get("file") orelse return error.MissingField;
            return .{ .file = .{ .type = "file", .file = file_val, .prompt_cache_breakpoint = obj.get("prompt_cache_breakpoint") } };
        } else if (std.mem.eql(u8, type_str, "refusal")) {
            const refusal_val = obj.get("refusal") orelse return error.MissingField;
            if (refusal_val != .string) return error.UnexpectedToken;
            return .{ .refusal = .{ .type = "refusal", .refusal = refusal_val.string } };
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
                if (t.prompt_cache_breakpoint) |v| { try jw.objectField("prompt_cache_breakpoint"); try jw.write(v); }
            },
            .image_url => |img| {
                try jw.objectField("type"); try jw.write("image_url");
                try jw.objectField("image_url");
                try jw.beginObject();
                try jw.objectField("url"); try jw.write(img.image_url.url);
                if (img.image_url.detail) |d| { try jw.objectField("detail"); try jw.write(d); }
                try jw.endObject();
                if (img.prompt_cache_breakpoint) |v| { try jw.objectField("prompt_cache_breakpoint"); try jw.write(v); }
            },
            .input_audio => |a| {
                try jw.objectField("type"); try jw.write("input_audio");
                try jw.objectField("input_audio"); try jw.write(a.input_audio);
                if (a.prompt_cache_breakpoint) |v| { try jw.objectField("prompt_cache_breakpoint"); try jw.write(v); }
            },
            .file => |f| {
                try jw.objectField("type"); try jw.write("file");
                try jw.objectField("file"); try jw.write(f.file);
                if (f.prompt_cache_breakpoint) |v| { try jw.objectField("prompt_cache_breakpoint"); try jw.write(v); }
            },
            .refusal => |r| {
                try jw.objectField("type"); try jw.write("refusal");
                try jw.objectField("refusal"); try jw.write(r.refusal);
            },
        }
        try jw.endObject();
    }
};

/// Function call structure (legacy)
pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

/// Tool call function
pub const ToolCallFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

/// Tool call in assistant message
pub const ToolCall = union(enum) {
    function: struct {
        id: []const u8,
        type: []const u8 = "function",
        function: ToolCallFunction,
    },
    custom: struct {
        id: []const u8,
        type: []const u8 = "custom",
        custom: std.json.Value,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .function => |v| try jw.write(v),
            .custom => |v| {
                try jw.beginObject();
                try jw.objectField("id"); try jw.write(v.id);
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("custom"); try jw.write(v.custom);
                try jw.endObject();
            },
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        const type_val = obj.get("type") orelse return error.MissingField;
        if (type_val != .string) return error.UnexpectedToken;
        const id_val = obj.get("id") orelse return error.MissingField;
        if (id_val != .string) return error.UnexpectedToken;

        if (std.mem.eql(u8, type_val.string, "function")) {
            const func_val = obj.get("function") orelse return error.MissingField;
            if (func_val != .object) return error.UnexpectedToken;
            const name_val = func_val.object.get("name") orelse return error.MissingField;
            if (name_val != .string) return error.UnexpectedToken;
            const args_val = func_val.object.get("arguments") orelse return error.MissingField;
            if (args_val != .string) return error.UnexpectedToken;
            return .{ .function = .{
                .id = id_val.string,
                .type = type_val.string,
                .function = .{ .name = name_val.string, .arguments = args_val.string },
            } };
        } else if (std.mem.eql(u8, type_val.string, "custom")) {
            const custom_val = obj.get("custom") orelse return error.MissingField;
            return .{ .custom = .{ .id = id_val.string, .type = type_val.string, .custom = custom_val } };
        } else {
            return error.UnexpectedToken;
        }
    }
};

/// Tool function definition
pub const ToolFunction = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
    strict: ?bool = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name"); try jw.write(self.name);
        if (self.description) |d| { try jw.objectField("description"); try jw.write(d); }
        if (self.strict) |s| { try jw.objectField("strict"); try jw.write(s); }
        if (self.parameters) |p| { try jw.objectField("parameters"); try jw.write(p); }
        try jw.endObject();
    }
};

/// Tool definition
pub const Tool = union(enum) {
    function: struct {
        type: []const u8 = "function",
        function: ToolFunction,
    },
    custom: struct {
        type: []const u8 = "custom",
        custom: std.json.Value,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .function => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("function"); try v.function.jsonStringify(jw);
                try jw.endObject();
            },
            .custom => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("custom"); try jw.write(v.custom);
                try jw.endObject();
            },
        }
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

        if (std.mem.eql(u8, type_val.string, "function")) {
            const func_val = obj.get("function") orelse return error.MissingField;
            const func = try std.json.parseFromValueLeaky(ToolFunction, allocator, func_val, options);
            return .{ .function = .{ .type = type_val.string, .function = func } };
        } else if (std.mem.eql(u8, type_val.string, "custom")) {
            const custom_val = obj.get("custom") orelse return error.MissingField;
            return .{ .custom = .{ .type = type_val.string, .custom = custom_val } };
        } else {
            return error.UnexpectedToken;
        }
    }
};

/// Function definition (legacy)
pub const Function = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
};

/// Response format — supports text, json_object, and json_schema (Structured Outputs)
pub const ResponseFormat = struct {
    type: []const u8,
    json_schema: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type"); try jw.write(self.type);
        if (self.json_schema) |v| { try jw.objectField("json_schema"); try jw.write(v); }
        try jw.endObject();
    }
};

/// Stream options
pub const StreamOptions = struct {
    include_usage: ?bool = null,
    include_obfuscation: ?bool = null,
};

/// Content union type for messages
pub const MessageContent = union(enum) {
    text: []const u8,
    parts: []const ContentPart,
};

/// Usage statistics
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    prompt_tokens_details: ?std.json.Value = null,
    completion_tokens_details: ?std.json.Value = null,

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

// ============================================================================
// Error Response Structures (OpenAI format)
// ============================================================================

/// OpenAI error details
pub const ErrorDetails = struct {
    message: []const u8,
    type: []const u8,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("message"); try jw.write(self.message);
        try jw.objectField("type"); try jw.write(self.type);
        try jw.objectField("param"); try jw.write(self.param);
        try jw.objectField("code"); try jw.write(self.code);
        try jw.endObject();
    }
};

/// OpenAI error response wrapper
pub const ErrorResponse = struct {
    @"error": ErrorDetails,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("error");
        try self.@"error".jsonStringify(jw);
        try jw.endObject();
    }
};
