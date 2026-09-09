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
    file: struct {
        type: []const u8 = "file",
        file_id: []const u8,
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

        if (std.mem.eql(u8, type_str, "base64")) {
            const media_type = obj.get("media_type") orelse return error.MissingField;
            if (media_type != .string) return error.UnexpectedToken;
            const data = obj.get("data") orelse return error.MissingField;
            if (data != .string) return error.UnexpectedToken;
            return .{ .base64 = .{ .type = type_str, .media_type = media_type.string, .data = data.string } };
        } else if (std.mem.eql(u8, type_str, "url")) {
            const url_val = obj.get("url") orelse return error.MissingField;
            if (url_val != .string) return error.UnexpectedToken;
            return .{ .url = .{ .type = type_str, .url = url_val.string } };
        } else if (std.mem.eql(u8, type_str, "file")) {
            const file_id_val = obj.get("file_id") orelse return error.MissingField;
            if (file_id_val != .string) return error.UnexpectedToken;
            return .{ .file = .{ .type = type_str, .file_id = file_id_val.string } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .base64 => |v| try jw.write(v),
            .url => |v| try jw.write(v),
            .file => |v| try jw.write(v),
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
    file: struct {
        type: []const u8 = "file",
        file_id: []const u8,
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

        const media_type_val = obj.get("media_type");

        if (std.mem.eql(u8, type_str, "base64")) {
            const data = obj.get("data") orelse return error.MissingField;
            if (data != .string) return error.UnexpectedToken;
            const mt = if (media_type_val) |m| (if (m == .string) m.string else "application/pdf") else "application/pdf";
            return .{ .base64_pdf = .{ .type = type_str, .media_type = mt, .data = data.string } };
        } else if (std.mem.eql(u8, type_str, "text")) {
            const data = obj.get("data") orelse return error.MissingField;
            if (data != .string) return error.UnexpectedToken;
            const mt = if (media_type_val) |m| (if (m == .string) m.string else "text/plain") else "text/plain";
            return .{ .plain_text = .{ .type = type_str, .media_type = mt, .data = data.string } };
        } else if (std.mem.eql(u8, type_str, "url")) {
            const url_val = obj.get("url") orelse return error.MissingField;
            if (url_val != .string) return error.UnexpectedToken;
            return .{ .url_pdf = .{ .type = type_str, .url = url_val.string } };
        } else if (std.mem.eql(u8, type_str, "file")) {
            const file_id_val = obj.get("file_id") orelse return error.MissingField;
            if (file_id_val != .string) return error.UnexpectedToken;
            return .{ .file = .{ .type = type_str, .file_id = file_id_val.string } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .base64_pdf => |v| try jw.write(v),
            .plain_text => |v| try jw.write(v),
            .url_pdf => |v| try jw.write(v),
            .file => |v| try jw.write(v),
        }
    }
};

/// Tool result block for content
pub const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    content: ?[]const u8 = null,
    is_error: ?bool = null,
    cache_control: ?CacheControl = null,
    toolset_name: ?[]const u8 = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const tool_use_id_val = obj.get("tool_use_id") orelse return error.MissingField;
        if (tool_use_id_val != .string) return error.UnexpectedToken;

        const is_error: ?bool = if (obj.get("is_error")) |v| switch (v) {
            .bool => |b| b,
            else => null,
        } else null;

        // content can be a string or an array of content blocks — flatten to string
        const content: ?[]const u8 = if (obj.get("content")) |cv| switch (cv) {
            .string => |s| s,
            .null => null,
            .array => |arr| blk: {
                var parts = std.ArrayList([]const u8).empty;
                defer parts.deinit(allocator);
                for (arr.items) |item| {
                    if (item != .object) continue;
                    const text_val = item.object.get("text") orelse continue;
                    if (text_val == .string) {
                        try parts.append(allocator, text_val.string);
                    }
                }
                if (parts.items.len == 0) break :blk null;
                if (parts.items.len == 1) break :blk parts.items[0];
                break :blk try std.mem.join(allocator, "\n", parts.items);
            },
            else => null,
        } else null;

        const cache_control: ?CacheControl = if (obj.get("cache_control")) |v|
            try std.json.innerParseFromValue(CacheControl, allocator, v, options)
        else
            null;

        const toolset_name: ?[]const u8 = if (obj.get("toolset_name")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        return .{
            .tool_use_id = tool_use_id_val.string,
            .content = content,
            .is_error = is_error,
            .cache_control = cache_control,
            .toolset_name = toolset_name,
        };
    }

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
        if (self.cache_control) |cc| {
            try jw.objectField("cache_control");
            try jw.write(cc);
        }
        if (self.toolset_name) |tn| {
            try jw.objectField("toolset_name");
            try jw.write(tn);
        }
        try jw.endObject();
    }
};

/// Caller info for tool_use / server_tool_use blocks
pub const Caller = struct {
    type: []const u8,
    tool_id: ?[]const u8 = null,
};

/// Citations on a text content block
pub const CitationEntry = std.json.Value;

/// Content block param for messages (request)
pub const ContentBlockParam = union(enum) {
    text: struct {
        type: []const u8 = "text",
        text: []const u8,
        cache_control: ?CacheControl = null,
        citations: ?std.json.Value = null,
    },
    image: struct {
        type: []const u8 = "image",
        source: ImageSource,
        cache_control: ?CacheControl = null,
        transformations: ?std.json.Value = null,
    },
    document: struct {
        type: []const u8 = "document",
        source: DocumentSource,
        title: ?[]const u8 = null,
        context: ?[]const u8 = null,
        cache_control: ?CacheControl = null,
        citations: ?std.json.Value = null,
    },
    tool_use: struct {
        type: []const u8 = "tool_use",
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
        cache_control: ?CacheControl = null,
        caller: ?Caller = null,
        toolset_name: ?[]const u8 = null,
    },
    server_tool_use: struct {
        type: []const u8 = "server_tool_use",
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
        cache_control: ?CacheControl = null,
        caller: ?Caller = null,
    },
    tool_result: ToolResultBlock,
    web_search_tool_result: struct {
        type: []const u8 = "web_search_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
        caller: ?Caller = null,
    },
    web_fetch_tool_result: struct {
        type: []const u8 = "web_fetch_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
        caller: ?Caller = null,
    },
    code_execution_tool_result: struct {
        type: []const u8 = "code_execution_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
    },
    bash_code_execution_tool_result: struct {
        type: []const u8 = "bash_code_execution_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
    },
    text_editor_code_execution_tool_result: struct {
        type: []const u8 = "text_editor_code_execution_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
    },
    tool_search_tool_result: struct {
        type: []const u8 = "tool_search_tool_result",
        tool_use_id: []const u8,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
    },
    search_result: struct {
        type: []const u8 = "search_result",
        title: ?[]const u8 = null,
        source: ?[]const u8 = null,
        content: std.json.Value,
        cache_control: ?CacheControl = null,
        citations: ?std.json.Value = null,
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
    container_upload: struct {
        type: []const u8 = "container_upload",
        file_id: []const u8,
        cache_control: ?CacheControl = null,
    },

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const type_value = obj.get("type") orelse return error.MissingField;
        if (type_value != .string) return error.UnexpectedToken;
        const type_str = type_value.string;

        const cache_control: ?CacheControl = if (obj.get("cache_control")) |v|
            try std.json.innerParseFromValue(CacheControl, allocator, v, options)
        else
            null;

        if (std.mem.eql(u8, type_str, "text")) {
            const text_val = obj.get("text") orelse return error.MissingField;
            if (text_val != .string) return error.UnexpectedToken;
            return .{ .text = .{
                .type = type_str,
                .text = text_val.string,
                .cache_control = cache_control,
                .citations = obj.get("citations"),
            } };
        } else if (std.mem.eql(u8, type_str, "image")) {
            const source_val = obj.get("source") orelse return error.MissingField;
            const img_source = try ImageSource.jsonParseFromValue(allocator, source_val, options);
            return .{ .image = .{
                .type = type_str,
                .source = img_source,
                .cache_control = cache_control,
                .transformations = obj.get("transformations"),
            } };
        } else if (std.mem.eql(u8, type_str, "document")) {
            const source_val = obj.get("source") orelse return error.MissingField;
            const doc_source = try DocumentSource.jsonParseFromValue(allocator, source_val, options);
            const title = if (obj.get("title")) |v| (if (v == .string) v.string else null) else null;
            const context = if (obj.get("context")) |v| (if (v == .string) v.string else null) else null;
            return .{ .document = .{
                .type = type_str,
                .source = doc_source,
                .title = title,
                .context = context,
                .cache_control = cache_control,
                .citations = obj.get("citations"),
            } };
        } else if (std.mem.eql(u8, type_str, "tool_use")) {
            const id_val = obj.get("id") orelse return error.MissingField;
            if (id_val != .string) return error.UnexpectedToken;
            const name_val = obj.get("name") orelse return error.MissingField;
            if (name_val != .string) return error.UnexpectedToken;
            const input_val = obj.get("input") orelse std.json.Value{ .object = std.json.ObjectMap{} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            const toolset_name: ?[]const u8 = if (obj.get("toolset_name")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;
            return .{ .tool_use = .{
                .type = type_str,
                .id = id_val.string,
                .name = name_val.string,
                .input = input_val,
                .cache_control = cache_control,
                .caller = caller,
                .toolset_name = toolset_name,
            } };
        } else if (std.mem.eql(u8, type_str, "server_tool_use")) {
            const id_val = obj.get("id") orelse return error.MissingField;
            if (id_val != .string) return error.UnexpectedToken;
            const name_val = obj.get("name") orelse return error.MissingField;
            if (name_val != .string) return error.UnexpectedToken;
            const input_val = obj.get("input") orelse std.json.Value{ .object = std.json.ObjectMap{} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .server_tool_use = .{
                .type = type_str,
                .id = id_val.string,
                .name = name_val.string,
                .input = input_val,
                .cache_control = cache_control,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_result")) {
            return .{ .tool_result = try ToolResultBlock.jsonParseFromValue(allocator, source, options) };
        } else if (std.mem.eql(u8, type_str, "web_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .web_search_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
                .cache_control = cache_control,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "web_fetch_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .web_fetch_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
                .cache_control = cache_control,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
            } };
        } else if (std.mem.eql(u8, type_str, "bash_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .bash_code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "text_editor_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .text_editor_code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .tool_search_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content_val,
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "search_result")) {
            const title = if (obj.get("title")) |v| (if (v == .string) v.string else null) else null;
            const src = if (obj.get("source")) |v| (if (v == .string) v.string else null) else null;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .search_result = .{
                .title = title,
                .source = src,
                .content = content_val,
                .cache_control = cache_control,
                .citations = obj.get("citations"),
            } };
        } else if (std.mem.eql(u8, type_str, "thinking")) {
            const thinking_val = obj.get("thinking") orelse return error.MissingField;
            if (thinking_val != .string) return error.UnexpectedToken;
            const sig_val = obj.get("signature") orelse return error.MissingField;
            if (sig_val != .string) return error.UnexpectedToken;
            return .{ .thinking = .{ .type = type_str, .thinking = thinking_val.string, .signature = sig_val.string } };
        } else if (std.mem.eql(u8, type_str, "redacted_thinking")) {
            const data_val = obj.get("data") orelse return error.MissingField;
            if (data_val != .string) return error.UnexpectedToken;
            return .{ .redacted_thinking = .{ .type = type_str, .data = data_val.string } };
        } else if (std.mem.eql(u8, type_str, "container_upload")) {
            const file_id_val = obj.get("file_id") orelse return error.MissingField;
            if (file_id_val != .string) return error.UnexpectedToken;
            return .{ .container_upload = .{
                .file_id = file_id_val.string,
                .cache_control = cache_control,
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("text"); try jw.write(v.text);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.citations) |c| { try jw.objectField("citations"); try jw.write(c); }
                try jw.endObject();
            },
            .image => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("source"); try jw.write(v.source);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.transformations) |t| { try jw.objectField("transformations"); try jw.write(t); }
                try jw.endObject();
            },
            .document => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("source"); try jw.write(v.source);
                if (v.title) |t| { try jw.objectField("title"); try jw.write(t); }
                if (v.context) |c| { try jw.objectField("context"); try jw.write(c); }
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.citations) |c| { try jw.objectField("citations"); try jw.write(c); }
                try jw.endObject();
            },
            .tool_use => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("id"); try jw.write(v.id);
                try jw.objectField("name"); try jw.write(v.name);
                try jw.objectField("input"); try jw.write(v.input);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.caller) |c| { try jw.objectField("caller"); try jw.write(c); }
                if (v.toolset_name) |tn| { try jw.objectField("toolset_name"); try jw.write(tn); }
                try jw.endObject();
            },
            .server_tool_use => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("id"); try jw.write(v.id);
                try jw.objectField("name"); try jw.write(v.name);
                try jw.objectField("input"); try jw.write(v.input);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.caller) |c| { try jw.objectField("caller"); try jw.write(c); }
                try jw.endObject();
            },
            .tool_result => |v| try jw.write(v),
            .web_search_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.caller) |c| { try jw.objectField("caller"); try jw.write(c); }
                try jw.endObject();
            },
            .web_fetch_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.caller) |c| { try jw.objectField("caller"); try jw.write(c); }
                try jw.endObject();
            },
            .code_execution_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                try jw.endObject();
            },
            .bash_code_execution_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                try jw.endObject();
            },
            .text_editor_code_execution_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                try jw.endObject();
            },
            .tool_search_tool_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("tool_use_id"); try jw.write(v.tool_use_id);
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                try jw.endObject();
            },
            .search_result => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                if (v.title) |t| { try jw.objectField("title"); try jw.write(t); }
                if (v.source) |s| { try jw.objectField("source"); try jw.write(s); }
                try jw.objectField("content"); try jw.write(v.content);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                if (v.citations) |c| { try jw.objectField("citations"); try jw.write(c); }
                try jw.endObject();
            },
            .thinking => |v| try jw.write(v),
            .redacted_thinking => |v| try jw.write(v),
            .container_upload => |v| {
                try jw.beginObject();
                try jw.objectField("type"); try jw.write(v.type);
                try jw.objectField("file_id"); try jw.write(v.file_id);
                if (v.cache_control) |cc| { try jw.objectField("cache_control"); try jw.write(cc); }
                try jw.endObject();
            },
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

/// Cache control for prompt caching
pub const CacheControl = struct {
    type: []const u8 = "ephemeral",
    ttl: ?[]const u8 = null,
};

/// Extended thinking configuration (GAP-1)
pub const ThinkingConfig = struct {
    type: []const u8, // "enabled" | "disabled" | "adaptive"
    budget_tokens: ?u32 = null,
    display: ?[]const u8 = null,
};

/// Output config for structured JSON output (GAP-7)
pub const OutputConfig = struct {
    effort: ?[]const u8 = null,
    format: ?std.json.Value = null,
};

/// Tool definition for Anthropic API
pub const Tool = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    input_schema: ?std.json.Value = null,
    type: []const u8 = "custom",
    cache_control: ?CacheControl = null,
    defer_loading: ?bool = null,
    strict: ?bool = null,
    allowed_callers: ?std.json.Value = null,
    eager_input_streaming: ?std.json.Value = null,
    input_examples: ?std.json.Value = null,
    // text_editor fields
    max_characters: ?u32 = null,
    // web_search / web_fetch fields
    max_uses: ?u32 = null,
    max_content_tokens: ?u32 = null,
    allowed_domains: ?std.json.Value = null,
    blocked_domains: ?std.json.Value = null,
    user_location: ?std.json.Value = null,
    response_inclusion: ?[]const u8 = null,
    citations: ?std.json.Value = null,
    use_cache: ?bool = null,
    // toolset fields (browser_toolset, computer_toolset)
    configs: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        // Only emit type when non-default (built-in tools need it; custom tools don't)
        if (!std.mem.eql(u8, self.type, "custom")) {
            try jw.objectField("type");
            try jw.write(self.type);
        }
        if (self.name) |n| {
            try jw.objectField("name");
            try jw.write(n);
        }
        if (self.description) |d| {
            try jw.objectField("description");
            try jw.write(d);
        }
        if (self.input_schema) |is| {
            try jw.objectField("input_schema");
            try jw.write(is);
        }
        if (self.cache_control) |cc| {
            try jw.objectField("cache_control");
            try jw.write(cc);
        }
        if (self.defer_loading) |dl| {
            try jw.objectField("defer_loading");
            try jw.write(dl);
        }
        if (self.strict) |s| {
            try jw.objectField("strict");
            try jw.write(s);
        }
        if (self.allowed_callers) |ac| {
            try jw.objectField("allowed_callers");
            try jw.write(ac);
        }
        if (self.eager_input_streaming) |eis| {
            try jw.objectField("eager_input_streaming");
            try jw.write(eis);
        }
        if (self.input_examples) |ie| {
            try jw.objectField("input_examples");
            try jw.write(ie);
        }
        if (self.max_characters) |mc| {
            try jw.objectField("max_characters");
            try jw.write(mc);
        }
        if (self.max_uses) |mu| {
            try jw.objectField("max_uses");
            try jw.write(mu);
        }
        if (self.max_content_tokens) |mct| {
            try jw.objectField("max_content_tokens");
            try jw.write(mct);
        }
        if (self.allowed_domains) |ad| {
            try jw.objectField("allowed_domains");
            try jw.write(ad);
        }
        if (self.blocked_domains) |bd| {
            try jw.objectField("blocked_domains");
            try jw.write(bd);
        }
        if (self.user_location) |ul| {
            try jw.objectField("user_location");
            try jw.write(ul);
        }
        if (self.response_inclusion) |ri| {
            try jw.objectField("response_inclusion");
            try jw.write(ri);
        }
        if (self.citations) |c| {
            try jw.objectField("citations");
            try jw.write(c);
        }
        if (self.use_cache) |uc| {
            try jw.objectField("use_cache");
            try jw.write(uc);
        }
        if (self.configs) |cfg| {
            try jw.objectField("configs");
            try jw.write(cfg);
        }
        try jw.endObject();
    }
};

/// Tool choice for Anthropic API
pub const ToolChoice = union(enum) {
    auto: struct {
        type: []const u8 = "auto",
        disable_parallel_tool_use: ?bool = null,
    },
    any: struct {
        type: []const u8 = "any",
        disable_parallel_tool_use: ?bool = null,
    },
    tool: struct {
        type: []const u8 = "tool",
        name: []const u8,
        disable_parallel_tool_use: ?bool = null,
    },
    none: struct {
        type: []const u8 = "none",
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

        const dptl: ?bool = if (obj.get("disable_parallel_tool_use")) |v| switch (v) {
            .bool => |b| b,
            else => null,
        } else null;

        if (std.mem.eql(u8, type_str, "auto")) {
            return .{ .auto = .{ .type = type_str, .disable_parallel_tool_use = dptl } };
        } else if (std.mem.eql(u8, type_str, "any")) {
            return .{ .any = .{ .type = type_str, .disable_parallel_tool_use = dptl } };
        } else if (std.mem.eql(u8, type_str, "tool")) {
            const name_value = obj.get("name") orelse return error.MissingField;
            if (name_value != .string) return error.UnexpectedToken;
            return .{ .tool = .{ .type = type_str, .name = name_value.string, .disable_parallel_tool_use = dptl } };
        } else if (std.mem.eql(u8, type_str, "none")) {
            return .{ .none = .{ .type = type_str } };
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        switch (self) {
            .auto => |v| try out.write(v),
            .any => |v| try out.write(v),
            .tool => |v| try out.write(v),
            .none => |v| try out.write(v),
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
    // GAP-1: extended thinking
    thinking: ?ThinkingConfig = null,
    // GAP-5: beta features
    betas: ?[]const []const u8 = null,
    // GAP-6: service tier
    service_tier: ?[]const u8 = null,
    // GAP-7: structured output
    output_config: ?OutputConfig = null,
    // GAP-8: code execution container
    container: ?Container = null,
    // GAP-9: inference geography
    inference_geo: ?[]const u8 = null,
    // top-level cache control
    cache_control: ?CacheControl = null,

    /// Parse system field that can be either a string or array of content blocks.
    /// Array format: [{"type": "text", "text": "..."}, ...]
    /// Concatenates text values with newline separator.
    fn parseSystemField(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
        switch (value) {
            .string => |s| return s,
            .array => |arr| {
                if (arr.items.len == 0) return null;
                // Collect text from each block
                var parts = std.ArrayList([]const u8).empty;
                defer parts.deinit(allocator);
                for (arr.items) |item| {
                    if (item != .object) continue;
                    const text_val = item.object.get("text") orelse continue;
                    if (text_val == .string) {
                        try parts.append(allocator, text_val.string);
                    }
                }
                if (parts.items.len == 0) return null;
                if (parts.items.len == 1) return parts.items[0];
                return try std.mem.join(allocator, "\n", parts.items);
            },
            .null => return null,
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        // Required fields
        const model_val = obj.get("model") orelse return error.MissingField;
        if (model_val != .string) return error.UnexpectedToken;

        const messages_val = obj.get("messages") orelse return error.MissingField;
        if (messages_val != .array) return error.UnexpectedToken;
        var messages = try allocator.alloc(Message, messages_val.array.items.len);
        for (messages_val.array.items, 0..) |item, i| {
            messages[i] = try std.json.innerParseFromValue(Message, allocator, item, options);
        }

        const max_tokens_val = obj.get("max_tokens") orelse return error.MissingField;
        const max_tokens: u32 = switch (max_tokens_val) {
            .integer => |v| @intCast(v),
            else => return error.UnexpectedToken,
        };

        // System: string or array of content blocks
        const system: ?[]const u8 = if (obj.get("system")) |sys_val|
            try parseSystemField(allocator, sys_val)
        else
            null;

        // Optional simple fields
        const temperature: ?f32 = if (obj.get("temperature")) |v| switch (v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => return error.UnexpectedToken,
        } else null;

        const top_p: ?f32 = if (obj.get("top_p")) |v| switch (v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => return error.UnexpectedToken,
        } else null;

        const top_k: ?u32 = if (obj.get("top_k")) |v| switch (v) {
            .integer => |i| @intCast(i),
            else => return error.UnexpectedToken,
        } else null;

        const stream: ?bool = if (obj.get("stream")) |v| switch (v) {
            .bool => |b| b,
            else => return error.UnexpectedToken,
        } else null;

        // stop_sequences: optional array of strings
        const stop_sequences: ?[]const []const u8 = if (obj.get("stop_sequences")) |v| blk: {
            if (v != .array) return error.UnexpectedToken;
            var seqs = try allocator.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .string) return error.UnexpectedToken;
                seqs[i] = item.string;
            }
            break :blk seqs;
        } else null;

        // tools
        const tools: ?[]const Tool = if (obj.get("tools")) |v| blk: {
            if (v != .array) return error.UnexpectedToken;
            var t = try allocator.alloc(Tool, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                t[i] = try std.json.innerParseFromValue(Tool, allocator, item, options);
            }
            break :blk t;
        } else null;

        // tool_choice
        const tool_choice: ?ToolChoice = if (obj.get("tool_choice")) |v|
            try ToolChoice.jsonParseFromValue(allocator, v, options)
        else
            null;

        // metadata
        const metadata: ?Metadata = if (obj.get("metadata")) |v|
            try std.json.innerParseFromValue(Metadata, allocator, v, options)
        else
            null;

        // GAP-1: thinking config
        const thinking: ?ThinkingConfig = if (obj.get("thinking")) |v|
            try std.json.innerParseFromValue(ThinkingConfig, allocator, v, options)
        else
            null;

        // GAP-5: betas
        const betas: ?[]const []const u8 = if (obj.get("betas")) |v| blk: {
            if (v != .array) break :blk null;
            var b = try allocator.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .string) { allocator.free(b); break :blk null; }
                b[i] = item.string;
            }
            break :blk b;
        } else null;

        // GAP-6: service_tier
        const service_tier: ?[]const u8 = if (obj.get("service_tier")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        // GAP-7: output_config
        const output_config: ?OutputConfig = if (obj.get("output_config")) |v|
            try std.json.innerParseFromValue(OutputConfig, allocator, v, options)
        else
            null;

        // GAP-8: container
        const container: ?Container = if (obj.get("container")) |v|
            try std.json.innerParseFromValue(Container, allocator, v, options)
        else
            null;

        // GAP-9: inference_geo
        const inference_geo: ?[]const u8 = if (obj.get("inference_geo")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        // top-level cache_control
        const cache_control: ?CacheControl = if (obj.get("cache_control")) |v|
            try std.json.innerParseFromValue(CacheControl, allocator, v, options)
        else
            null;

        return .{
            .model = model_val.string,
            .messages = messages,
            .max_tokens = max_tokens,
            .system = system,
            .temperature = temperature,
            .top_p = top_p,
            .top_k = top_k,
            .stream = stream,
            .stop_sequences = stop_sequences,
            .tools = tools,
            .tool_choice = tool_choice,
            .metadata = metadata,
            .thinking = thinking,
            .betas = betas,
            .service_tier = service_tier,
            .output_config = output_config,
            .container = container,
            .inference_geo = inference_geo,
            .cache_control = cache_control,
        };
    }

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

        if (self.thinking) |t| {
            try jw.objectField("thinking");
            try jw.write(t);
        }

        if (self.service_tier) |st| {
            try jw.objectField("service_tier");
            try jw.write(st);
        }

        if (self.output_config) |oc| {
            try jw.objectField("output_config");
            try jw.write(oc);
        }

        if (self.container) |c| {
            try jw.objectField("container");
            try jw.write(c);
        }

        if (self.inference_geo) |ig| {
            try jw.objectField("inference_geo");
            try jw.write(ig);
        }

        if (self.cache_control) |cc| {
            try jw.objectField("cache_control");
            try jw.write(cc);
        }

        try jw.endObject();
    }
};

/// Container skill entry
pub const ContainerSkill = struct {
    skill_id: []const u8,
    type: []const u8,
    version: ?[]const u8 = null,
};

/// Container metadata returned in responses (and sent in requests)
pub const Container = struct {
    id: []const u8,
    expires_at: ?[]const u8 = null,
    skills: ?[]const ContainerSkill = null,
};

/// Content block in response — mirrors all variants from ContentBlockParam
pub const ContentBlock = union(enum) {
    text: struct {
        type: []const u8,
        text: []const u8,
        citations: ?std.json.Value = null,
    },
    tool_use: struct {
        type: []const u8,
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
        caller: ?Caller = null,
    },
    server_tool_use: struct {
        type: []const u8,
        id: []const u8,
        name: []const u8,
        input: std.json.Value,
        caller: ?Caller = null,
    },
    thinking: struct {
        type: []const u8,
        thinking: []const u8,
        signature: []const u8,
    },
    redacted_thinking: struct {
        type: []const u8,
        data: []const u8,
    },
    tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        is_error: ?bool = null,
        content: std.json.Value,
    },
    web_search_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
        caller: ?Caller = null,
    },
    web_fetch_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
        caller: ?Caller = null,
    },
    code_execution_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
    },
    bash_code_execution_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
    },
    text_editor_code_execution_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
    },
    tool_search_tool_result: struct {
        type: []const u8,
        tool_use_id: []const u8,
        content: std.json.Value,
    },

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
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
                .citations = obj.get("citations"),
            } };
        } else if (std.mem.eql(u8, type_str, "tool_use")) {
            const id_value = obj.get("id") orelse return error.MissingField;
            if (id_value != .string) return error.UnexpectedToken;
            const name_value = obj.get("name") orelse return error.MissingField;
            if (name_value != .string) return error.UnexpectedToken;
            const input_value = obj.get("input") orelse std.json.Value{ .object = std.json.ObjectMap{} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .tool_use = .{
                .type = type_str,
                .id = id_value.string,
                .name = name_value.string,
                .input = input_value,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "server_tool_use")) {
            const id_value = obj.get("id") orelse return error.MissingField;
            if (id_value != .string) return error.UnexpectedToken;
            const name_value = obj.get("name") orelse return error.MissingField;
            if (name_value != .string) return error.UnexpectedToken;
            const input_value = obj.get("input") orelse std.json.Value{ .object = std.json.ObjectMap{} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .server_tool_use = .{
                .type = type_str,
                .id = id_value.string,
                .name = name_value.string,
                .input = input_value,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "thinking")) {
            const thinking_val = obj.get("thinking") orelse return error.MissingField;
            if (thinking_val != .string) return error.UnexpectedToken;
            const sig_val = obj.get("signature") orelse return error.MissingField;
            if (sig_val != .string) return error.UnexpectedToken;
            return .{ .thinking = .{
                .type = type_str,
                .thinking = thinking_val.string,
                .signature = sig_val.string,
            } };
        } else if (std.mem.eql(u8, type_str, "redacted_thinking")) {
            const data_val = obj.get("data") orelse return error.MissingField;
            if (data_val != .string) return error.UnexpectedToken;
            return .{ .redacted_thinking = .{
                .type = type_str,
                .data = data_val.string,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const is_error: ?bool = if (obj.get("is_error")) |v| switch (v) {
                .bool => |b| b,
                else => null,
            } else null;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .is_error = is_error,
                .content = content_val,
            } };
        } else if (std.mem.eql(u8, type_str, "web_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .web_search_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "web_fetch_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            const caller: ?Caller = if (obj.get("caller")) |v|
                try std.json.innerParseFromValue(Caller, allocator, v, options)
            else
                null;
            return .{ .web_fetch_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
            } };
        } else if (std.mem.eql(u8, type_str, "bash_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .bash_code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
            } };
        } else if (std.mem.eql(u8, type_str, "text_editor_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .text_editor_code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .tool_search_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content_val,
            } };
        } else {
            // Unknown block type — skip gracefully instead of failing
            return .{ .text = .{ .type = type_str, .text = "" } };
        }
    }

    pub fn jsonStringify(self: @This(), out: anytype) !void {
        switch (self) {
            .text => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("text"); try out.write(v.text);
                if (v.citations) |c| { try out.objectField("citations"); try out.write(c); }
                try out.endObject();
            },
            .tool_use => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("id"); try out.write(v.id);
                try out.objectField("name"); try out.write(v.name);
                try out.objectField("input"); try out.write(v.input);
                if (v.caller) |c| { try out.objectField("caller"); try out.write(c); }
                try out.endObject();
            },
            .server_tool_use => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("id"); try out.write(v.id);
                try out.objectField("name"); try out.write(v.name);
                try out.objectField("input"); try out.write(v.input);
                if (v.caller) |c| { try out.objectField("caller"); try out.write(c); }
                try out.endObject();
            },
            .thinking => |v| try out.write(v),
            .redacted_thinking => |v| try out.write(v),
            .tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                if (v.is_error) |e| { try out.objectField("is_error"); try out.write(e); }
                try out.objectField("content"); try out.write(v.content);
                try out.endObject();
            },
            .web_search_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                if (v.caller) |c| { try out.objectField("caller"); try out.write(c); }
                try out.endObject();
            },
            .web_fetch_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                if (v.caller) |c| { try out.objectField("caller"); try out.write(c); }
                try out.endObject();
            },
            .code_execution_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                try out.endObject();
            },
            .bash_code_execution_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                try out.endObject();
            },
            .text_editor_code_execution_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                try out.endObject();
            },
            .tool_search_tool_result => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.objectField("tool_use_id"); try out.write(v.tool_use_id);
                try out.objectField("content"); try out.write(v.content);
                try out.endObject();
            },
        }
    }
};

/// Usage statistics
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
    cache_creation_input_tokens: ?u32 = null, // GAP-12
    cache_read_input_tokens: ?u32 = null,      // GAP-12

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("input_tokens");
        try jw.write(self.input_tokens);
        try jw.objectField("output_tokens");
        try jw.write(self.output_tokens);
        if (self.cache_creation_input_tokens) |v| {
            try jw.objectField("cache_creation_input_tokens");
            try jw.write(v);
        }
        if (self.cache_read_input_tokens) |v| {
            try jw.objectField("cache_read_input_tokens");
            try jw.write(v);
        }
        try jw.endObject();
    }
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
    container: ?Container = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id"); try jw.write(self.id);
        try jw.objectField("type"); try jw.write(self.type);
        try jw.objectField("role"); try jw.write(self.role);
        try jw.objectField("content"); try jw.write(self.content);
        try jw.objectField("model"); try jw.write(self.model);
        try jw.objectField("stop_reason"); try jw.write(self.stop_reason);
        try jw.objectField("stop_sequence"); try jw.write(self.stop_sequence);
        try jw.objectField("usage"); try jw.write(self.usage);
        if (self.container) |v| { try jw.objectField("container"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Streaming Event Types for SSE Parsing
// ============================================================================

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
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    data: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null, // web_search_tool_result block
    content: ?std.json.Value = null, // web_search_tool_result block (complete, no deltas)
};

/// Content block delta event
pub const ContentBlockDelta = struct {
    type: []const u8 = "",
    index: u32 = 0,
    delta: DeltaContent = .{},
};

/// Delta content - can be text_delta, input_json_delta, thinking_delta, or signature_delta
pub const DeltaContent = struct {
    type: []const u8 = "",
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

/// Content block stop event
pub const ContentBlockStop = struct {
    type: []const u8 = "",
    index: u32 = 0,
};

/// Usage in message_delta events — superset of the basic Usage struct
pub const MessageDeltaUsage = struct {
    input_tokens: ?u32 = null,
    output_tokens: u32 = 0,
    cache_creation_input_tokens: ?u32 = null,
    cache_read_input_tokens: ?u32 = null,
    server_tool_use: ?struct { web_search_requests: ?u32 = null } = null,
};

/// Message delta event - contains stop reason
pub const MessageDelta = struct {
    type: []const u8 = "",
    delta: struct {
        stop_reason: ?[]const u8 = null,
        stop_sequence: ?[]const u8 = null,
    } = .{},
    usage: MessageDeltaUsage = .{},
};

/// Message stop event
pub const MessageStop = struct {
    type: []const u8 = "",
};

/// SSE error event — can appear at any point in the stream
pub const SseErrorEvent = struct {
    type: []const u8 = "",
    @"error": ErrorDetails = .{ .type = "", .message = "" },
};

// ============================================================================
// Streaming Transform Types (shared across transformers)
// ============================================================================

/// Usage data returned by AnthropicStreamState.getUsage() across all transformers.
/// Named struct avoids anonymous struct type mismatch across compilation units.
pub const StreamUsage = struct {
    input_tokens: u32,
    output_tokens: u32,
};

/// Result of transforming a single SSE line to Anthropic format.
/// Used by all transformers' `transformStreamLineToAnthropic` functions.
pub const AnthropicStreamLineResult = union(enum) {
    /// Formatted SSE bytes to write to the client (caller must free)
    output: []const u8,
    /// Nothing to send for this line
    skip: void,
};

// ============================================================================
// Models API Structures
// ============================================================================

/// Model info from the /v1/models endpoint
pub const Model = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    type: []const u8 = "model_info",
};

/// Response from the /v1/models endpoint
pub const ModelsResponse = struct {
    data: []const Model = &.{},
    next_cursor: ?[]const u8 = null,
    type: []const u8 = "list",
};

// ============================================================================
// Unit Tests
// ============================================================================
