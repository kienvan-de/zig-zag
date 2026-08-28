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
// Google AI Studio (Gemini) API Data Structures
//
// POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=...
// POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse&key=...
// GET  https://generativelanguage.googleapis.com/v1beta/models?key=...
// ============================================================================

// ============================================================================
// Content / Part structures
// ============================================================================

/// A single part inside a Content object.
pub const Part = union(enum) {
    text: struct {
        text: []const u8,
    },
    function_call: struct {
        name: []const u8,
        args: std.json.Value,
    },
    function_response: struct {
        name: []const u8,
        response: std.json.Value,
    },

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        _ = allocator;
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        if (obj.get("text")) |tv| {
            if (tv == .string) return .{ .text = .{ .text = tv.string } };
        }
        if (obj.get("functionCall")) |fc| {
            if (fc == .object) {
                const name = if (fc.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const args = fc.object.get("args") orelse .null;
                return .{ .function_call = .{ .name = name, .args = args } };
            }
        }
        if (obj.get("functionResponse")) |fr| {
            if (fr == .object) {
                const name = if (fr.object.get("name")) |n| (if (n == .string) n.string else "") else "";
                const resp = fr.object.get("response") orelse .null;
                return .{ .function_response = .{ .name = name, .response = resp } };
            }
        }
        return .{ .text = .{ .text = "" } };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |v| {
                try jw.beginObject();
                try jw.objectField("text");
                try jw.write(v.text);
                try jw.endObject();
            },
            .function_call => |v| {
                try jw.beginObject();
                try jw.objectField("functionCall");
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(v.name);
                try jw.objectField("args");
                try jw.write(v.args);
                try jw.endObject();
                try jw.endObject();
            },
            .function_response => |v| {
                try jw.beginObject();
                try jw.objectField("functionResponse");
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(v.name);
                try jw.objectField("response");
                try jw.write(v.response);
                try jw.endObject();
                try jw.endObject();
            },
        }
    }
};

/// A conversation turn: role + one or more parts.
pub const Content = struct {
    role: []const u8, // "user" | "model"
    parts: []const Part,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(self.role);
        try jw.objectField("parts");
        try jw.beginArray();
        for (self.parts) |p| try jw.write(p);
        try jw.endArray();
        try jw.endObject();
    }
};

// ============================================================================
// Tool definition
// ============================================================================

pub const FunctionDeclaration = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |d| {
            try jw.objectField("description");
            try jw.write(d);
        }
        if (self.parameters) |p| {
            try jw.objectField("parameters");
            try jw.write(p);
        }
        try jw.endObject();
    }
};

pub const GeminiTool = struct {
    function_declarations: ?[]const FunctionDeclaration = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.function_declarations) |fds| {
            try jw.objectField("functionDeclarations");
            try jw.beginArray();
            for (fds) |fd| try jw.write(fd);
            try jw.endArray();
        }
        try jw.endObject();
    }
};

/// Function calling config mode.
pub const FunctionCallingConfig = struct {
    mode: []const u8 = "AUTO", // AUTO | ANY | NONE
    allowed_function_names: ?[]const []const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("mode");
        try jw.write(self.mode);
        if (self.allowed_function_names) |names| {
            try jw.objectField("allowedFunctionNames");
            try jw.beginArray();
            for (names) |n| try jw.write(n);
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const ToolConfig = struct {
    function_calling_config: FunctionCallingConfig = .{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("functionCallingConfig");
        try jw.write(self.function_calling_config);
        try jw.endObject();
    }
};

// ============================================================================
// GenerationConfig
// ============================================================================

pub const GenerationConfig = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    max_output_tokens: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,
    response_mime_type: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.temperature) |v| { try jw.objectField("temperature"); try jw.write(v); }
        if (self.top_p) |v| { try jw.objectField("topP"); try jw.write(v); }
        if (self.top_k) |v| { try jw.objectField("topK"); try jw.write(v); }
        if (self.max_output_tokens) |v| { try jw.objectField("maxOutputTokens"); try jw.write(v); }
        if (self.stop_sequences) |ss| {
            try jw.objectField("stopSequences");
            try jw.beginArray();
            for (ss) |s| try jw.write(s);
            try jw.endArray();
        }
        if (self.response_mime_type) |m| { try jw.objectField("responseMimeType"); try jw.write(m); }
        try jw.endObject();
    }
};

// ============================================================================
// System instruction
// ============================================================================

pub const SystemInstruction = struct {
    parts: []const Part,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("parts");
        try jw.beginArray();
        for (self.parts) |p| try jw.write(p);
        try jw.endArray();
        try jw.endObject();
    }
};

// ============================================================================
// Request
//
// Gemini embeds the model in the URL, not in the JSON body.  To keep the same
// client interface as other providers (sendRequest(request)), the Request type
// carries both the JSON payload AND the resolved model name separately.
// The client uses `request.model` to build the URL and serialises
// `request.payload` as the POST body.
// ============================================================================

/// The JSON body sent to the Gemini API.
pub const RequestPayload = struct {
    contents: []const Content,
    system_instruction: ?SystemInstruction = null,
    tools: ?[]const GeminiTool = null,
    tool_config: ?ToolConfig = null,
    generation_config: ?GenerationConfig = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("contents");
        try jw.beginArray();
        for (self.contents) |c| try jw.write(c);
        try jw.endArray();
        if (self.system_instruction) |si| {
            try jw.objectField("systemInstruction");
            try jw.write(si);
        }
        if (self.tools) |ts| {
            try jw.objectField("tools");
            try jw.beginArray();
            for (ts) |t| try jw.write(t);
            try jw.endArray();
        }
        if (self.tool_config) |tc| {
            try jw.objectField("toolConfig");
            try jw.write(tc);
        }
        if (self.generation_config) |gc| {
            try jw.objectField("generationConfig");
            try jw.write(gc);
        }
        try jw.endObject();
    }
};

/// Wrapper carrying both the URL-embedded model name and the JSON payload.
/// This is the type returned by the transformer and consumed by the client.
pub const Request = struct {
    /// Resolved model name (without provider prefix), used to build the URL.
    model: []const u8,
    /// The actual JSON body.
    payload: RequestPayload,

    /// Serialise as the payload only — the model goes into the URL, not the body.
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.write(self.payload);
    }
};

// ============================================================================
// Response
// ============================================================================

pub const UsageMetadata = struct {
    prompt_token_count: u32 = 0,
    candidates_token_count: u32 = 0,
    total_token_count: u32 = 0,
};

/// A single candidate in the response.
pub const Candidate = struct {
    content: Content,
    finish_reason: ?[]const u8 = null,
    index: ?u32 = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const content_val = obj.get("content") orelse {
            // Some error responses omit content — return an empty content
            return .{
                .content = .{ .role = "model", .parts = &.{} },
                .finish_reason = null,
                .index = null,
            };
        };
        const content = try parseContent(allocator, content_val, options);

        const finish_reason: ?[]const u8 = if (obj.get("finishReason")) |v|
            if (v == .string) v.string else null
        else
            null;

        const index: ?u32 = if (obj.get("index")) |v|
            if (v == .integer) @intCast(v.integer) else null
        else
            null;

        return .{
            .content = content,
            .finish_reason = finish_reason,
            .index = index,
        };
    }
};

pub fn parseContent(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Content {
    if (source != .object) return Content{ .role = "model", .parts = &.{} };
    const obj = source.object;

    const role: []const u8 = if (obj.get("role")) |v|
        if (v == .string) v.string else "model"
    else
        "model";

    const parts_val = obj.get("parts") orelse return Content{ .role = role, .parts = &.{} };
    if (parts_val != .array) return Content{ .role = role, .parts = &.{} };

    var parts = try allocator.alloc(Part, parts_val.array.items.len);
    for (parts_val.array.items, 0..) |item, i| {
        parts[i] = try Part.jsonParseFromValue(allocator, item, options);
    }

    return Content{ .role = role, .parts = parts };
}

pub fn parseUsageMetadata(source: std.json.Value) UsageMetadata {
    if (source != .object) return .{};
    const obj = source.object;

    const prompt = if (obj.get("promptTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
    const candidates = if (obj.get("candidatesTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;
    const total = if (obj.get("totalTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0;

    return .{
        .prompt_token_count = prompt,
        .candidates_token_count = candidates,
        .total_token_count = total,
    };
}

/// Full generateContent response.
pub const Response = struct {
    candidates: []const Candidate = &.{},
    usage_metadata: UsageMetadata = .{},

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        var candidates: []Candidate = &.{};
        if (obj.get("candidates")) |cv| {
            if (cv == .array) {
                candidates = try allocator.alloc(Candidate, cv.array.items.len);
                for (cv.array.items, 0..) |item, i| {
                    candidates[i] = try Candidate.jsonParseFromValue(allocator, item, options);
                }
            }
        }

        const usage: UsageMetadata = if (obj.get("usageMetadata")) |um|
            parseUsageMetadata(um)
        else
            .{};

        return .{
            .candidates = candidates,
            .usage_metadata = usage,
        };
    }
};

// ============================================================================
// Models API
// ============================================================================

/// A single model entry from GET /v1beta/models.
pub const GeminiModel = struct {
    name: []const u8 = "",             // "models/gemini-1.5-flash"
    display_name: ?[]const u8 = null,
    supported_generation_methods: []const []const u8 = &.{},

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const name: []const u8 = if (obj.get("name")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const display_name: ?[]const u8 = if (obj.get("displayName")) |v|
            if (v == .string) v.string else null
        else
            null;

        var methods: [][]const u8 = &.{};
        if (obj.get("supportedGenerationMethods")) |mv| {
            if (mv == .array) {
                methods = try allocator.alloc([]const u8, mv.array.items.len);
                for (mv.array.items, 0..) |item, i| {
                    methods[i] = if (item == .string) item.string else "";
                }
            }
        }

        return .{
            .name = name,
            .display_name = display_name,
            .supported_generation_methods = methods,
        };
    }
};

/// Response from GET /v1beta/models.
pub const ModelsResponse = struct {
    models: []const GeminiModel = &.{},

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        var models: []GeminiModel = &.{};
        if (obj.get("models")) |mv| {
            if (mv == .array) {
                models = try allocator.alloc(GeminiModel, mv.array.items.len);
                for (mv.array.items, 0..) |item, i| {
                    models[i] = try GeminiModel.jsonParseFromValue(allocator, item, options);
                }
            }
        }

        return .{ .models = models };
    }
};

// ============================================================================
// Streaming chunk
//
// Gemini streams JSON objects where each data line is a full Response.
// ============================================================================

/// Each SSE data chunk from streamGenerateContent is a full Response JSON object.
pub const StreamChunk = Response;
