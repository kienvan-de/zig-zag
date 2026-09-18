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
    system,
    user,
    assistant,

    pub fn jsonStringify(self: Role, out: anytype) !void {
        try out.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Role {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options) catch return error.UnknownField;
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

pub const ImageSourceBase64 = struct {
    type: []const u8 = "base64",
    media_type: []const u8, // "image/jpeg", "image/png", "image/gif", "image/webp"
    data: []const u8,
};

pub const ImageSourceUrl = struct {
    type: []const u8 = "url",
    url: []const u8,
};

pub const ImageSourceFile = struct {
    type: []const u8 = "file",
    file_id: []const u8,
};

pub const ImageSource = union(enum) {
    base64: ImageSourceBase64,
    url: ImageSourceUrl,
    file: ImageSourceFile,

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

pub const DocumentSourceBase64Pdf = struct {
    type: []const u8 = "base64",
    media_type: []const u8 = "application/pdf",
    data: []const u8,
};

pub const DocumentSourcePlainText = struct {
    type: []const u8 = "text",
    media_type: []const u8 = "text/plain",
    data: []const u8,
};

pub const DocumentSourceUrlPdf = struct {
    type: []const u8 = "url",
    url: []const u8,
};

pub const DocumentSourceFile = struct {
    type: []const u8 = "file",
    file_id: []const u8,
};

pub const DocumentSource = union(enum) {
    base64_pdf: DocumentSourceBase64Pdf,
    plain_text: DocumentSourcePlainText,
    url_pdf: DocumentSourceUrlPdf,
    file: DocumentSourceFile,

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

/// Tool result content — either a plain string or an array of text content blocks.
pub const ToolResultContent = union(enum) {
    text: []const u8,
    blocks: []const SearchResultTextContent, // reuses {type, text} shape

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |s| try jw.write(s),
            .blocks => |b| try jw.write(b),
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !ToolResultContent {
        switch (source) {
            .string => |s| return .{ .text = s },
            .array => return .{ .blocks = try std.json.innerParseFromValue([]const SearchResultTextContent, allocator, source, options) },
            else => return error.UnexpectedToken,
        }
    }
};

/// Tool result block for content
pub const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    content: ?ToolResultContent = null,
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

        const content: ?ToolResultContent = if (obj.get("content")) |cv| switch (cv) {
            .null => null,
            else => try ToolResultContent.jsonParseFromValue(allocator, cv, options),
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

pub const CharLocationCitation = struct {
    type: []const u8 = "char_location",
    cited_text: []const u8 = "",
    document_index: u32 = 0,
    document_title: ?[]const u8 = null,
    start_char_index: u32 = 0,
    end_char_index: u32 = 0,
    file_id: ?[]const u8 = null,
};

pub const PageLocationCitation = struct {
    type: []const u8 = "page_location",
    cited_text: []const u8 = "",
    document_index: u32 = 0,
    document_title: ?[]const u8 = null,
    start_page_number: u32 = 0,
    end_page_number: u32 = 0,
    file_id: ?[]const u8 = null,
};

pub const ContentBlockLocationCitation = struct {
    type: []const u8 = "content_block_location",
    cited_text: []const u8 = "",
    document_index: u32 = 0,
    document_title: ?[]const u8 = null,
    start_block_index: u32 = 0,
    end_block_index: u32 = 0,
    file_id: ?[]const u8 = null,
};

pub const WebSearchResultLocationCitation = struct {
    type: []const u8 = "web_search_result_location",
    cited_text: []const u8 = "",
    encrypted_index: []const u8 = "",
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const SearchResultLocationCitation = struct {
    type: []const u8 = "search_result_location",
    cited_text: []const u8 = "",
    search_result_index: u32 = 0,
    start_block_index: u32 = 0,
    end_block_index: u32 = 0,
    source: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const CitationEntry = union(enum) {
    char_location: CharLocationCitation,
    page_location: PageLocationCitation,
    content_block_location: ContentBlockLocationCitation,
    web_search_result_location: WebSearchResultLocationCitation,
    search_result_location: SearchResultLocationCitation,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !CitationEntry {
        if (source != .object) return error.UnexpectedToken;
        const type_v = source.object.get("type") orelse return error.MissingField;
        if (type_v != .string) return error.UnexpectedToken;
        const t = type_v.string;
        if (std.mem.eql(u8, t, "char_location")) return .{ .char_location = try std.json.innerParseFromValue(CharLocationCitation, allocator, source, options) };
        if (std.mem.eql(u8, t, "page_location")) return .{ .page_location = try std.json.innerParseFromValue(PageLocationCitation, allocator, source, options) };
        if (std.mem.eql(u8, t, "content_block_location")) return .{ .content_block_location = try std.json.innerParseFromValue(ContentBlockLocationCitation, allocator, source, options) };
        if (std.mem.eql(u8, t, "web_search_result_location")) return .{ .web_search_result_location = try std.json.innerParseFromValue(WebSearchResultLocationCitation, allocator, source, options) };
        if (std.mem.eql(u8, t, "search_result_location")) return .{ .search_result_location = try std.json.innerParseFromValue(SearchResultLocationCitation, allocator, source, options) };
        return error.UnknownField;
    }
};

// ============================================================================
// Tool result content types (Group B — fixed schemas)
// ============================================================================

pub const WebSearchResult = struct {
    type: []const u8 = "web_search_result",
    title: []const u8 = "",
    url: []const u8 = "",
    encrypted_content: []const u8 = "",
    page_age: ?[]const u8 = null,
    favicon_url: ?[]const u8 = null,
};

/// The nested document returned by a web_fetch tool call.
pub const WebFetchDocument = struct {
    type: []const u8 = "document",
    source: DocumentSource,
};

pub const WebFetchResult = struct {
    type: []const u8 = "web_fetch_result",
    url: []const u8 = "",
    retrieved_at: []const u8 = "",
    content: ?WebFetchDocument = null,
};

pub const CodeExecutionOutput = struct {
    type: []const u8 = "code_execution_output",
    file_id: []const u8 = "",
};

pub const CodeExecutionResult = struct {
    type: []const u8 = "code_execution_result",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    return_code: i32 = 0,
    content: []const CodeExecutionOutput = &.{},
};

/// Variant returned when PFC / web_search is active — stdout is encrypted.
pub const EncryptedCodeExecutionResult = struct {
    type: []const u8 = "encrypted_code_execution_result",
    encrypted_stdout: []const u8 = "",
    stderr: []const u8 = "",
    return_code: i32 = 0,
    content: []const CodeExecutionOutput = &.{},
};

/// Union covering both plain and encrypted code execution results.
pub const CodeExecutionResultContent = union(enum) {
    plain: CodeExecutionResult,
    encrypted: EncryptedCodeExecutionResult,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .plain => |v| try jw.write(v),
            .encrypted => |v| try jw.write(v),
        }
    }
};

pub const BashCodeExecutionOutput = struct {
    type: []const u8 = "bash_code_execution_output",
    file_id: []const u8 = "",
};

pub const BashCodeExecutionResult = struct {
    type: []const u8 = "bash_code_execution_result",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    return_code: i32 = 0,
    content: []const BashCodeExecutionOutput = &.{},
};

/// Union covering all three text editor command result shapes.

pub const TextEditorCodeExecutionView = struct {
    type: []const u8 = "text_editor_code_execution_view_result",
    content: []const u8 = "",
    file_type: []const u8 = "",
    num_lines: u32 = 0,
    start_line: u32 = 1,
    total_lines: u32 = 0,
};

pub const TextEditorCodeExecutionCreate = struct {
    type: []const u8 = "text_editor_code_execution_create_result",
    is_file_update: bool = false,
};

pub const TextEditorCodeExecutionStrReplace = struct {
    type: []const u8 = "text_editor_code_execution_str_replace_result",
    old_start: u32 = 0,
    old_lines: u32 = 0,
    new_start: u32 = 0,
    new_lines: u32 = 0,
    lines: []const []const u8 = &.{},
};

pub const TextEditorCodeExecutionResult = union(enum) {
    view: TextEditorCodeExecutionView,
    create: TextEditorCodeExecutionCreate,
    str_replace: TextEditorCodeExecutionStrReplace,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !TextEditorCodeExecutionResult {
        if (v == .object) {
            if (v.object.get("type")) |t| if (t == .string) {
                if (std.mem.eql(u8, t.string, "text_editor_code_execution_create_result"))
                    return .{ .create = try std.json.innerParseFromValue(@TypeOf(@as(TextEditorCodeExecutionResult, undefined).create), allocator, v, options) };
                if (std.mem.eql(u8, t.string, "text_editor_code_execution_str_replace_result"))
                    return .{ .str_replace = try std.json.innerParseFromValue(@TypeOf(@as(TextEditorCodeExecutionResult, undefined).str_replace), allocator, v, options) };
            };
        }
        return .{ .view = try std.json.innerParseFromValue(@TypeOf(@as(TextEditorCodeExecutionResult, undefined).view), allocator, v, options) };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .view => |v| try jw.write(v),
            .create => |v| try jw.write(v),
            .str_replace => |v| try jw.write(v),
        }
    }
};

pub const ToolReference = struct {
    type: []const u8 = "tool_reference",
    tool_name: []const u8 = "",
    cache_control: ?CacheControl = null,
};

pub const ToolSearchToolSearchResult = struct {
    type: []const u8 = "tool_search_tool_search_result",
    tool_references: []const ToolReference = &.{},
};

pub const SearchResultTextContent = struct {
    type: []const u8 = "text",
    text: []const u8 = "",
};

pub const SearchResultCitations = struct {
    enabled: bool = false,
};

/// Content block param for messages (request)

pub const ContentBlockParamText = struct {
    type: []const u8 = "text",
    text: []const u8,
    cache_control: ?CacheControl = null,
    citations: ?[]const CitationEntry = null,
};

pub const ContentBlockParamImage = struct {
    type: []const u8 = "image",
    source: ImageSource,
    cache_control: ?CacheControl = null,
    transformations: ?std.json.Value = null,
};

pub const ContentBlockParamDocument = struct {
    type: []const u8 = "document",
    source: DocumentSource,
    title: ?[]const u8 = null,
    context: ?[]const u8 = null,
    cache_control: ?CacheControl = null,
    citations: ?SearchResultCitations = null,
};

pub const ContentBlockParamToolUse = struct {
    type: []const u8 = "tool_use",
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
    cache_control: ?CacheControl = null,
    caller: ?Caller = null,
    toolset_name: ?[]const u8 = null,
};

pub const ContentBlockParamServerToolUse = struct {
    type: []const u8 = "server_tool_use",
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
    cache_control: ?CacheControl = null,
    caller: ?Caller = null,
};

pub const ContentBlockParamWebSearchToolResult = struct {
    type: []const u8 = "web_search_tool_result",
    tool_use_id: []const u8,
    content: []const WebSearchResult,
    cache_control: ?CacheControl = null,
    caller: ?Caller = null,
};

pub const ContentBlockParamWebFetchToolResult = struct {
    type: []const u8 = "web_fetch_tool_result",
    tool_use_id: []const u8,
    content: WebFetchResult,
    cache_control: ?CacheControl = null,
    caller: ?Caller = null,
};

pub const ContentBlockParamCodeExecutionToolResult = struct {
    type: []const u8 = "code_execution_tool_result",
    tool_use_id: []const u8,
    content: CodeExecutionResultContent,
};

pub const ContentBlockParamBashCodeExecutionToolResult = struct {
    type: []const u8 = "bash_code_execution_tool_result",
    tool_use_id: []const u8,
    content: BashCodeExecutionResult,
    cache_control: ?CacheControl = null,
};

pub const ContentBlockParamTextEditorCodeExecutionToolResult = struct {
    type: []const u8 = "text_editor_code_execution_tool_result",
    tool_use_id: []const u8,
    content: TextEditorCodeExecutionResult,
    cache_control: ?CacheControl = null,
};

pub const ContentBlockParamToolSearchToolResult = struct {
    type: []const u8 = "tool_search_tool_result",
    tool_use_id: []const u8,
    content: ToolSearchToolSearchResult,
    cache_control: ?CacheControl = null,
};

pub const ContentBlockParamSearchResult = struct {
    type: []const u8 = "search_result",
    title: ?[]const u8 = null,
    source: ?[]const u8 = null,
    content: []const SearchResultTextContent,
    cache_control: ?CacheControl = null,
    citations: ?SearchResultCitations = null,
};

pub const ContentBlockParamThinking = struct {
    type: []const u8 = "thinking",
    thinking: []const u8,
    signature: []const u8,
};

pub const ContentBlockParamRedactedThinking = struct {
    type: []const u8 = "redacted_thinking",
    data: []const u8,
};

pub const ContentBlockParamContainerUpload = struct {
    type: []const u8 = "container_upload",
    file_id: []const u8,
    cache_control: ?CacheControl = null,
};

pub const ContentBlockParam = union(enum) {
    text: ContentBlockParamText,
    image: ContentBlockParamImage,
    document: ContentBlockParamDocument,
    tool_use: ContentBlockParamToolUse,
    server_tool_use: ContentBlockParamServerToolUse,
    tool_result: ToolResultBlock,
    web_search_tool_result: ContentBlockParamWebSearchToolResult,
    web_fetch_tool_result: ContentBlockParamWebFetchToolResult,
    code_execution_tool_result: ContentBlockParamCodeExecutionToolResult,
    bash_code_execution_tool_result: ContentBlockParamBashCodeExecutionToolResult,
    text_editor_code_execution_tool_result: ContentBlockParamTextEditorCodeExecutionToolResult,
    tool_search_tool_result: ContentBlockParamToolSearchToolResult,
    search_result: ContentBlockParamSearchResult,
    thinking: ContentBlockParamThinking,
    redacted_thinking: ContentBlockParamRedactedThinking,
    container_upload: ContentBlockParamContainerUpload,

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
            const text_citations: ?[]const CitationEntry = if (obj.get("citations")) |cv|
                try std.json.innerParseFromValue([]const CitationEntry, allocator, cv, options)
            else
                null;
            return .{ .text = .{
                .type = type_str,
                .text = text_val.string,
                .cache_control = cache_control,
                .citations = text_citations,
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
            const doc_citations: ?SearchResultCitations = if (obj.get("citations")) |cv|
                try std.json.innerParseFromValue(SearchResultCitations, allocator, cv, options)
            else
                null;
            return .{ .document = .{
                .type = type_str,
                .source = doc_source,
                .title = title,
                .context = context,
                .cache_control = cache_control,
                .citations = doc_citations,
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
                .content = try std.json.innerParseFromValue([]const WebSearchResult, allocator, content_val, options),
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
                .content = try std.json.innerParseFromValue(WebFetchResult, allocator, content_val, options),
                .cache_control = cache_control,
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            const content_type = if (content_val == .object) content_val.object.get("type") else null;
            const is_encrypted = if (content_type) |t| (t == .string and std.mem.eql(u8, t.string, "encrypted_code_execution_result")) else false;
            const content: CodeExecutionResultContent = if (is_encrypted)
                .{ .encrypted = try std.json.innerParseFromValue(EncryptedCodeExecutionResult, allocator, content_val, options) }
            else
                .{ .plain = try std.json.innerParseFromValue(CodeExecutionResult, allocator, content_val, options) };
            return .{ .code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = content,
            } };
        } else if (std.mem.eql(u8, type_str, "bash_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .bash_code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = try std.json.innerParseFromValue(BashCodeExecutionResult, allocator, content_val, options),
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "text_editor_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .text_editor_code_execution_tool_result = .{
                .tool_use_id = tuid.string,
                .content = try TextEditorCodeExecutionResult.jsonParseFromValue(allocator, content_val, options),
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "tool_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse return error.MissingField;
            return .{ .tool_search_tool_result = .{
                .tool_use_id = tuid.string,
                .content = try std.json.innerParseFromValue(ToolSearchToolSearchResult, allocator, content_val, options),
                .cache_control = cache_control,
            } };
        } else if (std.mem.eql(u8, type_str, "search_result")) {
            const title = if (obj.get("title")) |v| (if (v == .string) v.string else null) else null;
            const src = if (obj.get("source")) |v| (if (v == .string) v.string else null) else null;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            const citations: ?SearchResultCitations = if (obj.get("citations")) |v|
                try std.json.innerParseFromValue(SearchResultCitations, allocator, v, options)
            else
                null;
            return .{ .search_result = .{
                .title = title,
                .source = src,
                .content = try std.json.innerParseFromValue([]const SearchResultTextContent, allocator, content_val, options),
                .cache_control = cache_control,
                .citations = citations,
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
        return jsonParseFromValue(allocator, json_value, options);
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

/// Per-capability config entry used in browser_toolset / computer_toolset configs maps.
pub const ToolConfigEntry = struct {
    enabled: bool = false,
    defer_loading: ?bool = null,
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

pub const ToolChoiceAuto = struct {
    type: []const u8 = "auto",
    disable_parallel_tool_use: ?bool = null,
};

pub const ToolChoiceAny = struct {
    type: []const u8 = "any",
    disable_parallel_tool_use: ?bool = null,
};

pub const ToolChoiceTool = struct {
    type: []const u8 = "tool",
    name: []const u8,
    disable_parallel_tool_use: ?bool = null,
};

pub const ToolChoiceNone = struct {
    type: []const u8 = "none",
};

pub const ToolChoice = union(enum) {
    auto: ToolChoiceAuto,
    any: ToolChoiceAny,
    tool: ToolChoiceTool,
    none: ToolChoiceNone,

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

/// A single text block in a system prompt array (with optional cache_control).
pub const SystemTextBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
    cache_control: ?CacheControl = null,
};

/// System parameter — either a plain string or an array of SystemTextBlock.
pub const SystemParam = union(enum) {
    text: []const u8,
    blocks: []const SystemTextBlock,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |s| try jw.write(s),
            .blocks => |blks| {
                try jw.beginArray();
                for (blks) |blk| {
                    try jw.beginObject();
                    try jw.objectField("type"); try jw.write(blk.type);
                    try jw.objectField("text"); try jw.write(blk.text);
                    if (blk.cache_control) |cc| {
                        try jw.objectField("cache_control"); try jw.write(cc);
                    }
                    try jw.endObject();
                }
                try jw.endArray();
            },
        }
    }
};

/// Request to Anthropic messages API
pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    max_tokens: u32, // REQUIRED in Anthropic API
    system: ?SystemParam = null,
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
    // fallback model list
    fallbacks: ?std.json.Value = null,

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

        // System: string or array of SystemTextBlock
        const system: ?SystemParam = if (obj.get("system")) |sys_val| blk: {
            switch (sys_val) {
                .string => |s| break :blk SystemParam{ .text = s },
                .array => |arr| {
                    var blks = try allocator.alloc(SystemTextBlock, arr.items.len);
                    for (arr.items, 0..) |item, i| {
                        blks[i] = try std.json.innerParseFromValue(SystemTextBlock, allocator, item, options);
                    }
                    break :blk SystemParam{ .blocks = blks };
                },
                else => break :blk null,
            }
        } else null;

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

        // fallbacks
        const fallbacks: ?std.json.Value = obj.get("fallbacks");

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
            .fallbacks = fallbacks,
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

        if (self.fallbacks) |fb| {
            try jw.objectField("fallbacks");
            try jw.write(fb);
        }

        if (self.betas) |b| {
            try jw.objectField("betas");
            try jw.write(b);
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

pub const ContentBlockText = struct {
    type: []const u8,
    text: []const u8,
    citations: ?[]const CitationEntry = null,
};

pub const ContentBlockToolUse = struct {
    type: []const u8,
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
    caller: ?Caller = null,
    toolset_name: ?[]const u8 = null,
};

pub const ContentBlockServerToolUse = struct {
    type: []const u8,
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
    caller: ?Caller = null,
};

pub const ContentBlockThinking = struct {
    type: []const u8,
    thinking: []const u8,
    signature: []const u8,
};

pub const ContentBlockRedactedThinking = struct {
    type: []const u8,
    data: []const u8,
};

pub const ContentBlockToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    is_error: ?bool = null,
    content: std.json.Value,
    cache_control: ?CacheControl = null,
    toolset_name: ?[]const u8 = null,
};

pub const ContentBlockWebSearchToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: []const WebSearchResult,
    caller: ?Caller = null,
};

pub const ContentBlockWebFetchToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: WebFetchResult,
    caller: ?Caller = null,
};

pub const ContentBlockCodeExecutionToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: CodeExecutionResultContent,
};

pub const ContentBlockBashCodeExecutionToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: BashCodeExecutionResult,
};

pub const ContentBlockTextEditorCodeExecutionToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: TextEditorCodeExecutionResult,
};

pub const ContentBlockToolSearchToolResult = struct {
    type: []const u8,
    tool_use_id: []const u8,
    content: ToolSearchToolSearchResult,
};

pub const ContentBlockFallback = struct {
    type: []const u8 = "fallback",
};

pub const ContentBlock = union(enum) {
    text: ContentBlockText,
    tool_use: ContentBlockToolUse,
    server_tool_use: ContentBlockServerToolUse,
    thinking: ContentBlockThinking,
    redacted_thinking: ContentBlockRedactedThinking,
    tool_result: ContentBlockToolResult,
    web_search_tool_result: ContentBlockWebSearchToolResult,
    web_fetch_tool_result: ContentBlockWebFetchToolResult,
    code_execution_tool_result: ContentBlockCodeExecutionToolResult,
    bash_code_execution_tool_result: ContentBlockBashCodeExecutionToolResult,
    text_editor_code_execution_tool_result: ContentBlockTextEditorCodeExecutionToolResult,
    tool_search_tool_result: ContentBlockToolSearchToolResult,
    fallback: ContentBlockFallback,

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
            const cb_text_citations: ?[]const CitationEntry = if (obj.get("citations")) |cv|
                try std.json.innerParseFromValue([]const CitationEntry, allocator, cv, options)
            else
                null;
            return .{ .text = .{
                .type = type_str,
                .text = text_value.string,
                .citations = cb_text_citations,
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
            const toolset_name_cb: ?[]const u8 = if (obj.get("toolset_name")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;
            return .{ .tool_use = .{
                .type = type_str,
                .id = id_value.string,
                .name = name_value.string,
                .input = input_value,
                .caller = caller,
                .toolset_name = toolset_name_cb,
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
            const tr_cache_control: ?CacheControl = if (obj.get("cache_control")) |v|
                try std.json.innerParseFromValue(CacheControl, allocator, v, options)
            else
                null;
            const tr_toolset_name: ?[]const u8 = if (obj.get("toolset_name")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;
            return .{ .tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .is_error = is_error,
                .content = content_val,
                .cache_control = tr_cache_control,
                .toolset_name = tr_toolset_name,
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
                .content = try std.json.innerParseFromValue([]const WebSearchResult, allocator, content_val, options),
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
                .content = try std.json.innerParseFromValue(WebFetchResult, allocator, content_val, options),
                .caller = caller,
            } };
        } else if (std.mem.eql(u8, type_str, "code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            const content_type = if (content_val == .object) content_val.object.get("type") else null;
            const is_encrypted = if (content_type) |t| (t == .string and std.mem.eql(u8, t.string, "encrypted_code_execution_result")) else false;
            const content: CodeExecutionResultContent = if (is_encrypted)
                .{ .encrypted = try std.json.innerParseFromValue(EncryptedCodeExecutionResult, allocator, content_val, options) }
            else
                .{ .plain = try std.json.innerParseFromValue(CodeExecutionResult, allocator, content_val, options) };
            return .{ .code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = content,
            } };
        } else if (std.mem.eql(u8, type_str, "bash_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .bash_code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = try std.json.innerParseFromValue(BashCodeExecutionResult, allocator, content_val, options),
            } };
        } else if (std.mem.eql(u8, type_str, "text_editor_code_execution_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .text_editor_code_execution_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = try TextEditorCodeExecutionResult.jsonParseFromValue(allocator, content_val, options),
            } };
        } else if (std.mem.eql(u8, type_str, "tool_search_tool_result")) {
            const tuid = obj.get("tool_use_id") orelse return error.MissingField;
            if (tuid != .string) return error.UnexpectedToken;
            const content_val = obj.get("content") orelse std.json.Value{ .null = {} };
            return .{ .tool_search_tool_result = .{
                .type = type_str,
                .tool_use_id = tuid.string,
                .content = try std.json.innerParseFromValue(ToolSearchToolSearchResult, allocator, content_val, options),
            } };
        } else if (std.mem.eql(u8, type_str, "fallback")) {
            return .{ .fallback = .{ .type = type_str } };
        } else {
            return error.UnknownField;
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
                if (v.toolset_name) |tn| { try out.objectField("toolset_name"); try out.write(tn); }
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
                if (v.cache_control) |cc| { try out.objectField("cache_control"); try out.write(cc); }
                if (v.toolset_name) |tn| { try out.objectField("toolset_name"); try out.write(tn); }
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
            .fallback => |v| {
                try out.beginObject();
                try out.objectField("type"); try out.write(v.type);
                try out.endObject();
            },
        }
    }
};

pub const OutputTokensDetails = struct {
    thinking_tokens: u32 = 0,
};

pub const CacheCreation = struct {
    ephemeral_1h_input_tokens: u32 = 0,
    ephemeral_5m_input_tokens: u32 = 0,
};

pub const ServerToolUsage = struct {
    web_search_requests: u32 = 0,
    web_fetch_requests: u32 = 0,
};

/// Usage statistics
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32 = 0,
    cache_creation_input_tokens: ?u32 = null, // GAP-12
    cache_read_input_tokens: ?u32 = null,      // GAP-12
    inference_geo: ?[]const u8 = null,
    output_tokens_details: ?OutputTokensDetails = null,
    service_tier: ?[]const u8 = null,
    server_tool_use: ?ServerToolUsage = null,
    cache_creation: ?CacheCreation = null,

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
        if (self.inference_geo) |v| {
            try jw.objectField("inference_geo");
            try jw.write(v);
        }
        if (self.output_tokens_details) |v| {
            try jw.objectField("output_tokens_details");
            try jw.write(v);
        }
        if (self.service_tier) |v| {
            try jw.objectField("service_tier");
            try jw.write(v);
        }
        if (self.server_tool_use) |v| {
            try jw.objectField("server_tool_use");
            try jw.write(v);
        }
        if (self.cache_creation) |v| {
            try jw.objectField("cache_creation");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

/// Stop details for Response (extended stop reason info)
pub const StopDetails = struct {
    type: []const u8 = "refusal",
    category: ?[]const u8 = null,
    explanation: ?[]const u8 = null,
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
    stop_details: ?StopDetails = null,

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
        if (self.stop_details) |v| { try jw.objectField("stop_details"); try jw.write(v); }
        try jw.endObject();
    }
};

// ============================================================================
// Streaming Event Types for SSE Parsing
// ============================================================================

/// Message start event - contains initial message metadata

pub const MessageStartMessage = struct {
    id: []const u8,
    type: []const u8 = "",
    role: []const u8 = "",
    content: []const std.json.Value = &.{},
    model: []const u8 = "",
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
    usage: Usage = .{ .input_tokens = 0 },
};

pub const MessageStart = struct {
    type: []const u8,
    message: MessageStartMessage,
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
    content: ?[]const WebSearchResult = null, // web_search_tool_result block (complete, no deltas)
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

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        if (self.text) |v| {
            try jw.objectField("text");
            try jw.write(v);
        }
        if (self.partial_json) |v| {
            try jw.objectField("partial_json");
            try jw.write(v);
        }
        if (self.thinking) |v| {
            try jw.objectField("thinking");
            try jw.write(v);
        }
        if (self.signature) |v| {
            try jw.objectField("signature");
            try jw.write(v);
        }
        try jw.endObject();
    }
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
    server_tool_use: ?ServerToolUsage = null,
    output_tokens_details: ?OutputTokensDetails = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.input_tokens) |v| {
            try jw.objectField("input_tokens");
            try jw.write(v);
        }
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
        if (self.server_tool_use) |v| {
            try jw.objectField("server_tool_use");
            try jw.write(v);
        }
        if (self.output_tokens_details) |v| {
            try jw.objectField("output_tokens_details");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

/// Message delta event - contains stop reason

pub const MessageDeltaDelta = struct {
    stop_reason: ?[]const u8 = null,
    stop_sequence: ?[]const u8 = null,
};

pub const MessageDelta = struct {
    type: []const u8 = "",
    delta: MessageDeltaDelta = .{},
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

/// Ping event — emitted periodically by Anthropic on the SSE stream.
pub const Ping = struct {
    type: []const u8 = "ping",
};

/// Typed union of all Anthropic SSE events. Returned by transformer stream
/// functions so callers own serialization — the transformer only transforms.
pub const SseEvent = union(enum) {
    message_start: MessageStart,
    content_block_start: ContentBlockStart,
    content_block_delta: ContentBlockDelta,
    content_block_stop: ContentBlockStop,
    message_delta: MessageDelta,
    message_stop: MessageStop,
    ping: Ping,
    error_event: SseErrorEvent,
};

/// Result type for Messages-flow stream line transforms.
/// The transformer returns a slice of typed SseEvents; the caller serializes to wire bytes.
pub const MessagesStreamLineResult = union(enum) {
    events: []const SseEvent,
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
