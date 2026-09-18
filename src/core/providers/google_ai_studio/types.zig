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

pub const PartText = struct {
    text: []const u8,
};
pub const PartInlineData = struct {
    mime_type: []const u8,
    data: []const u8,
};
pub const PartFileData = struct {
    mime_type: []const u8,
    file_uri: []const u8,
};
pub const PartExecutableCode = struct {
    language: []const u8,
    code: []const u8,
};
pub const PartCodeExecutionResult = struct {
    outcome: []const u8,
    output: []const u8,
};
pub const PartFunctionCall = struct {
    name: []const u8,
    args: std.json.Value,
};
pub const PartFunctionResponse = struct {
    name: []const u8,
    response: std.json.Value,
};
pub const PartThought = struct {
    thought: bool = false,
};
pub const PartOffset = struct {
    seconds: ?i64 = null,
    nanos: ?i32 = null,
};
pub const PartVideoMetadataInner = struct {
    start_offset: ?PartOffset = null,
    end_offset: ?PartOffset = null,
};
pub const PartVideoMetadata = struct {
    video_metadata: PartVideoMetadataInner = .{},
};

/// A single part inside a Content object.
pub const Part = union(enum) {
    text: PartText,
    inline_data: PartInlineData,
    file_data: PartFileData,
    executable_code: PartExecutableCode,
    code_execution_result: PartCodeExecutionResult,
    function_call: PartFunctionCall,
    function_response: PartFunctionResponse,
    thought: PartThought,
    video_metadata: PartVideoMetadata,

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
        if (obj.get("inlineData")) |v| {
            if (v == .object) {
                const mime = if (v.object.get("mimeType")) |m| (if (m == .string) m.string else "") else "";
                const data = if (v.object.get("data")) |d| (if (d == .string) d.string else "") else "";
                return .{ .inline_data = .{ .mime_type = mime, .data = data } };
            }
        }
        if (obj.get("fileData")) |v| {
            if (v == .object) {
                const mime = if (v.object.get("mimeType")) |m| (if (m == .string) m.string else "") else "";
                const uri = if (v.object.get("fileUri")) |u| (if (u == .string) u.string else "") else "";
                return .{ .file_data = .{ .mime_type = mime, .file_uri = uri } };
            }
        }
        if (obj.get("executableCode")) |v| {
            if (v == .object) {
                const lang = if (v.object.get("language")) |l| (if (l == .string) l.string else "") else "";
                const code = if (v.object.get("code")) |c| (if (c == .string) c.string else "") else "";
                return .{ .executable_code = .{ .language = lang, .code = code } };
            }
        }
        if (obj.get("codeExecutionResult")) |v| {
            if (v == .object) {
                const outcome = if (v.object.get("outcome")) |o| (if (o == .string) o.string else "") else "";
                const output = if (v.object.get("output")) |o| (if (o == .string) o.string else "") else "";
                return .{ .code_execution_result = .{ .outcome = outcome, .output = output } };
            }
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
        if (obj.get("thought")) |tv| return .{ .thought = .{ .thought = tv == .bool and tv.bool } };
        if (obj.get("videoMetadata")) |v| {
            if (v == .object) {
                const so = v.object.get("startOffset");
                const eo = v.object.get("endOffset");
                const start: ?PartOffset = if (so) |s| blk: {
                    if (s == .object) break :blk .{
                        .seconds = if (s.object.get("seconds")) |sv| (if (sv == .integer) sv.integer else null) else null,
                        .nanos = if (s.object.get("nanos")) |nv| (if (nv == .integer) @as(i32, @intCast(nv.integer)) else null) else null,
                    };
                    break :blk null;
                } else null;
                const end_: ?PartOffset = if (eo) |e| blk: {
                    if (e == .object) break :blk .{
                        .seconds = if (e.object.get("seconds")) |sv| (if (sv == .integer) sv.integer else null) else null,
                        .nanos = if (e.object.get("nanos")) |nv| (if (nv == .integer) @as(i32, @intCast(nv.integer)) else null) else null,
                    };
                    break :blk null;
                } else null;
                return .{ .video_metadata = .{ .video_metadata = .{ .start_offset = start, .end_offset = end_ } } };
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
            .inline_data => |v| {
                try jw.beginObject();
                try jw.objectField("inlineData");
                try jw.beginObject();
                try jw.objectField("mimeType"); try jw.write(v.mime_type);
                try jw.objectField("data"); try jw.write(v.data);
                try jw.endObject();
                try jw.endObject();
            },
            .file_data => |v| {
                try jw.beginObject();
                try jw.objectField("fileData");
                try jw.beginObject();
                try jw.objectField("mimeType"); try jw.write(v.mime_type);
                try jw.objectField("fileUri"); try jw.write(v.file_uri);
                try jw.endObject();
                try jw.endObject();
            },
            .executable_code => |v| {
                try jw.beginObject();
                try jw.objectField("executableCode");
                try jw.beginObject();
                try jw.objectField("language"); try jw.write(v.language);
                try jw.objectField("code"); try jw.write(v.code);
                try jw.endObject();
                try jw.endObject();
            },
            .code_execution_result => |v| {
                try jw.beginObject();
                try jw.objectField("codeExecutionResult");
                try jw.beginObject();
                try jw.objectField("outcome"); try jw.write(v.outcome);
                try jw.objectField("output"); try jw.write(v.output);
                try jw.endObject();
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
            .thought => |v| {
                try jw.beginObject();
                try jw.objectField("thought");
                try jw.write(v.thought);
                try jw.endObject();
            },
            .video_metadata => |v| {
                try jw.beginObject();
                try jw.objectField("videoMetadata");
                try jw.beginObject();
                if (v.video_metadata.start_offset) |so| {
                    try jw.objectField("startOffset");
                    try jw.beginObject();
                    if (so.seconds) |s| { try jw.objectField("seconds"); try jw.write(s); }
                    if (so.nanos) |n| { try jw.objectField("nanos"); try jw.write(n); }
                    try jw.endObject();
                }
                if (v.video_metadata.end_offset) |eo| {
                    try jw.objectField("endOffset");
                    try jw.beginObject();
                    if (eo.seconds) |s| { try jw.objectField("seconds"); try jw.write(s); }
                    if (eo.nanos) |n| { try jw.objectField("nanos"); try jw.write(n); }
                    try jw.endObject();
                }
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

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Content {
        if (source != .object) return error.UnexpectedToken;
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

/// Typed representation of the Gemini Schema proto.
/// Only fields Gemini actually supports are present — this is the whitelist.
/// Used for FunctionDeclaration.parameters and .response.
pub const GeminiSchema = struct {
    /// Gemini Type enum value: "STRING" | "INTEGER" | "NUMBER" | "BOOLEAN" | "ARRAY" | "OBJECT" | "NULL"
    type: ?[]const u8 = null,
    description: ?[]const u8 = null,
    nullable: ?bool = null,
    format: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    @"enum": ?[]const []const u8 = null,
    properties: ?[]const GeminiSchemaProperty = null,
    required: ?[]const []const u8 = null,
    items: ?*const GeminiSchema = null,
    any_of: ?[]const GeminiSchema = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    min_items: ?u64 = null,
    max_items: ?u64 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.type) |v| { try jw.objectField("type"); try jw.write(v); }
        if (self.description) |v| { try jw.objectField("description"); try jw.write(v); }
        if (self.nullable) |v| { try jw.objectField("nullable"); try jw.write(v); }
        if (self.format) |v| { try jw.objectField("format"); try jw.write(v); }
        if (self.pattern) |v| { try jw.objectField("pattern"); try jw.write(v); }
        if (self.@"enum") |vs| {
            try jw.objectField("enum");
            try jw.beginArray();
            for (vs) |v| try jw.write(v);
            try jw.endArray();
        }
        if (self.properties) |props| {
            try jw.objectField("properties");
            try jw.beginObject();
            for (props) |p| {
                try jw.objectField(p.name);
                try jw.write(p.schema);
            }
            try jw.endObject();
        }
        if (self.required) |vs| {
            try jw.objectField("required");
            try jw.beginArray();
            for (vs) |v| try jw.write(v);
            try jw.endArray();
        }
        if (self.items) |v| { try jw.objectField("items"); try jw.write(v.*); }
        if (self.any_of) |vs| {
            try jw.objectField("anyOf");
            try jw.beginArray();
            for (vs) |v| try jw.write(v);
            try jw.endArray();
        }
        if (self.minimum) |v| { try jw.objectField("minimum"); try jw.write(v); }
        if (self.maximum) |v| { try jw.objectField("maximum"); try jw.write(v); }
        if (self.min_items) |v| { try jw.objectField("minItems"); try jw.write(v); }
        if (self.max_items) |v| { try jw.objectField("maxItems"); try jw.write(v); }
        try jw.endObject();
    }
};

/// A named property entry inside GeminiSchema.properties.
pub const GeminiSchemaProperty = struct {
    name: []const u8,
    schema: GeminiSchema,
};

pub const FunctionDeclaration = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?GeminiSchema = null,
    response: ?GeminiSchema = null,
    behavior: ?[]const u8 = null, // "NON_BLOCKING" | "BEHAVIOR_UNSPECIFIED"

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
        if (self.response) |r| {
            try jw.objectField("response");
            try jw.write(r);
        }
        if (self.behavior) |b| {
            try jw.objectField("behavior");
            try jw.write(b);
        }
        try jw.endObject();
    }
};

/// Tool definition — wraps function declarations or built-in tools (googleSearch, codeExecution).
pub const GeminiTool = struct {
    function_declarations: ?[]const FunctionDeclaration = null,
    google_search: ?std.json.Value = null,
    code_execution: ?std.json.Value = null,
    google_search_retrieval: ?std.json.Value = null,
    enterprise_web_search: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.function_declarations) |fds| {
            try jw.objectField("functionDeclarations");
            try jw.beginArray();
            for (fds) |fd| try jw.write(fd);
            try jw.endArray();
        }
        if (self.google_search) |v| { try jw.objectField("googleSearch"); try jw.write(v); }
        if (self.code_execution) |v| { try jw.objectField("codeExecution"); try jw.write(v); }
        if (self.google_search_retrieval) |v| { try jw.objectField("googleSearchRetrieval"); try jw.write(v); }
        if (self.enterprise_web_search) |v| { try jw.objectField("enterpriseWebSearch"); try jw.write(v); }
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
// Safety settings
// ============================================================================

pub const SafetySetting = struct {
    category: []const u8,
    threshold: []const u8,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("category"); try jw.write(self.category);
        try jw.objectField("threshold"); try jw.write(self.threshold);
        try jw.endObject();
    }
};

// ============================================================================
// GenerationConfig
// ============================================================================

pub const ThinkingConfig = struct {
    thinking_budget: ?u32 = null,
    include_thoughts: ?bool = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.thinking_budget) |v| { try jw.objectField("thinkingBudget"); try jw.write(v); }
        if (self.include_thoughts) |v| { try jw.objectField("includeThoughts"); try jw.write(v); }
        try jw.endObject();
    }
};

pub const GenerationConfig = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    candidate_count: ?u32 = null,
    max_output_tokens: ?u32 = null,
    stop_sequences: ?[]const []const u8 = null,
    presence_penalty: ?f32 = null,
    frequency_penalty: ?f32 = null,
    response_logprobs: ?bool = null,
    logprobs: ?u32 = null,
    response_mime_type: ?[]const u8 = null,
    seed: ?i64 = null,
    audio_timestamp: ?bool = null,
    media_resolution: ?[]const u8 = null,
    thinking_config: ?ThinkingConfig = null,
    response_schema: ?GeminiSchema = null,
    speech_config: ?std.json.Value = null,
    routing_config: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.temperature) |v| { try jw.objectField("temperature"); try jw.write(v); }
        if (self.top_p) |v| { try jw.objectField("topP"); try jw.write(v); }
        if (self.top_k) |v| { try jw.objectField("topK"); try jw.write(v); }
        if (self.candidate_count) |v| { try jw.objectField("candidateCount"); try jw.write(v); }
        if (self.max_output_tokens) |v| { try jw.objectField("maxOutputTokens"); try jw.write(v); }
        if (self.stop_sequences) |ss| {
            try jw.objectField("stopSequences");
            try jw.beginArray();
            for (ss) |s| try jw.write(s);
            try jw.endArray();
        }
        if (self.presence_penalty) |v| { try jw.objectField("presencePenalty"); try jw.write(v); }
        if (self.frequency_penalty) |v| { try jw.objectField("frequencyPenalty"); try jw.write(v); }
        if (self.response_logprobs) |v| { try jw.objectField("responseLogprobs"); try jw.write(v); }
        if (self.logprobs) |v| { try jw.objectField("logprobs"); try jw.write(v); }
        if (self.response_mime_type) |m| { try jw.objectField("responseMimeType"); try jw.write(m); }
        if (self.seed) |v| { try jw.objectField("seed"); try jw.write(v); }
        if (self.audio_timestamp) |v| { try jw.objectField("audioTimestamp"); try jw.write(v); }
        if (self.media_resolution) |v| { try jw.objectField("mediaResolution"); try jw.write(v); }
        if (self.thinking_config) |v| { try jw.objectField("thinkingConfig"); try jw.write(v); }
        if (self.response_schema) |v| { try jw.objectField("responseSchema"); try jw.write(v); }
        if (self.speech_config) |v| { try jw.objectField("speechConfig"); try jw.write(v); }
        if (self.routing_config) |v| { try jw.objectField("routingConfig"); try jw.write(v); }
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
    safety_settings: ?[]const SafetySetting = null,
    cached_content: ?[]const u8 = null,
    generation_config: ?GenerationConfig = null,
    service_tier: ?[]const u8 = null,
    store: ?bool = null,

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
        if (self.safety_settings) |ss| {
            try jw.objectField("safetySettings");
            try jw.beginArray();
            for (ss) |s| try jw.write(s);
            try jw.endArray();
        }
        if (self.cached_content) |v| { try jw.objectField("cachedContent"); try jw.write(v); }
        if (self.generation_config) |gc| {
            try jw.objectField("generationConfig");
            try jw.write(gc);
        }
        if (self.service_tier) |v| { try jw.objectField("serviceTier"); try jw.write(v); }
        if (self.store) |v| { try jw.objectField("store"); try jw.write(v); }
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

pub const SafetyRating = struct {
    category: []const u8 = "",
    probability: []const u8 = "",
    blocked: ?bool = null,
    severity: ?[]const u8 = null,
    severity_score: ?f64 = null,
    probability_score: ?f64 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("category"); try jw.write(self.category);
        try jw.objectField("probability"); try jw.write(self.probability);
        if (self.blocked) |v| { try jw.objectField("blocked"); try jw.write(v); }
        if (self.severity) |v| { try jw.objectField("severity"); try jw.write(v); }
        if (self.severity_score) |v| { try jw.objectField("severityScore"); try jw.write(v); }
        if (self.probability_score) |v| { try jw.objectField("probabilityScore"); try jw.write(v); }
        try jw.endObject();
    }
};

pub const ModalityTokenCount = struct {
    modality: []const u8 = "",
    token_count: u32 = 0,
};

pub const UsageMetadata = struct {
    prompt_token_count: u32 = 0,
    candidates_token_count: u32 = 0,
    total_token_count: u32 = 0,
    cached_content_token_count: u32 = 0,
    thoughts_token_count: u32 = 0,
    tool_use_prompt_token_count: u32 = 0,
    service_tier: ?[]const u8 = null,
    prompt_tokens_details: []const ModalityTokenCount = &.{},
    cache_tokens_details: []const ModalityTokenCount = &.{},
    candidates_tokens_details: []const ModalityTokenCount = &.{},
    tool_use_prompt_tokens_details: []const ModalityTokenCount = &.{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("promptTokenCount"); try jw.write(self.prompt_token_count);
        try jw.objectField("candidatesTokenCount"); try jw.write(self.candidates_token_count);
        try jw.objectField("totalTokenCount"); try jw.write(self.total_token_count);
        try jw.objectField("cachedContentTokenCount"); try jw.write(self.cached_content_token_count);
        try jw.objectField("thoughtsTokenCount"); try jw.write(self.thoughts_token_count);
        try jw.objectField("toolUsePromptTokenCount"); try jw.write(self.tool_use_prompt_token_count);
        if (self.service_tier) |v| { try jw.objectField("serviceTier"); try jw.write(v); }
        if (self.prompt_tokens_details.len > 0) {
            try jw.objectField("promptTokensDetails");
            try jw.beginArray();
            for (self.prompt_tokens_details) |d| {
                try jw.beginObject();
                try jw.objectField("modality"); try jw.write(d.modality);
                try jw.objectField("tokenCount"); try jw.write(d.token_count);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (self.cache_tokens_details.len > 0) {
            try jw.objectField("cacheTokensDetails");
            try jw.beginArray();
            for (self.cache_tokens_details) |d| {
                try jw.beginObject();
                try jw.objectField("modality"); try jw.write(d.modality);
                try jw.objectField("tokenCount"); try jw.write(d.token_count);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (self.candidates_tokens_details.len > 0) {
            try jw.objectField("candidatesTokensDetails");
            try jw.beginArray();
            for (self.candidates_tokens_details) |d| {
                try jw.beginObject();
                try jw.objectField("modality"); try jw.write(d.modality);
                try jw.objectField("tokenCount"); try jw.write(d.token_count);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (self.tool_use_prompt_tokens_details.len > 0) {
            try jw.objectField("toolUsePromptTokensDetails");
            try jw.beginArray();
            for (self.tool_use_prompt_tokens_details) |d| {
                try jw.beginObject();
                try jw.objectField("modality"); try jw.write(d.modality);
                try jw.objectField("tokenCount"); try jw.write(d.token_count);
                try jw.endObject();
            }
            try jw.endArray();
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !UsageMetadata {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const parseModalitySlice = struct {
            fn parse(alloc: std.mem.Allocator, val: std.json.Value, opts: std.json.ParseOptions) ![]const ModalityTokenCount {
                _ = opts;
                if (val != .array) return &.{};
                const items = val.array.items;
                const out = try alloc.alloc(ModalityTokenCount, items.len);
                for (items, 0..) |item, i| {
                    if (item != .object) { out[i] = .{}; continue; }
                    const o = item.object;
                    out[i] = .{
                        .modality = if (o.get("modality")) |v| (if (v == .string) v.string else "") else "",
                        .token_count = if (o.get("tokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
                    };
                }
                return out;
            }
        }.parse;

        return .{
            .prompt_token_count = if (obj.get("promptTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .candidates_token_count = if (obj.get("candidatesTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .total_token_count = if (obj.get("totalTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .cached_content_token_count = if (obj.get("cachedContentTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .thoughts_token_count = if (obj.get("thoughtsTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .tool_use_prompt_token_count = if (obj.get("toolUsePromptTokenCount")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else 0) else 0,
            .service_tier = if (obj.get("serviceTier")) |v| (if (v == .string) v.string else null) else null,
            .prompt_tokens_details = if (obj.get("promptTokensDetails")) |v| try parseModalitySlice(allocator, v, options) else &.{},
            .cache_tokens_details = if (obj.get("cacheTokensDetails")) |v| try parseModalitySlice(allocator, v, options) else &.{},
            .candidates_tokens_details = if (obj.get("candidatesTokensDetails")) |v| try parseModalitySlice(allocator, v, options) else &.{},
            .tool_use_prompt_tokens_details = if (obj.get("toolUsePromptTokensDetails")) |v| try parseModalitySlice(allocator, v, options) else &.{},
        };
    }
};

/// A single candidate in the response.
pub const Candidate = struct {
    content: Content,
    finish_reason: ?[]const u8 = null,
    index: ?u32 = null,
    token_count: ?u32 = null,
    avg_logprobs: ?f64 = null,
    safety_ratings: ?[]const SafetyRating = null,
    citation_metadata: ?CitationMetadata = null,
    grounding_metadata: ?GroundingMetadata = null,
    logprobs_result: ?LogprobsResult = null,
    finish_message: ?[]const u8 = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const content_val = obj.get("content") orelse {
            return .{
                .content = .{ .role = "model", .parts = &.{} },
                .finish_reason = null,
                .index = null,
            };
        };
        const content = try Content.jsonParseFromValue(allocator, content_val, options);

        const finish_reason: ?[]const u8 = if (obj.get("finishReason")) |v|
            if (v == .string) v.string else null
        else
            null;

        const index: ?u32 = if (obj.get("index")) |v|
            if (v == .integer) @intCast(v.integer) else null
        else
            null;

        const token_count: ?u32 = if (obj.get("tokenCount")) |v|
            if (v == .integer) @intCast(v.integer) else null
        else
            null;

        const avg_logprobs: ?f64 = if (obj.get("avgLogprobs")) |v| switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        } else null;

        return .{
            .content = content,
            .finish_reason = finish_reason,
            .index = index,
            .token_count = token_count,
            .avg_logprobs = avg_logprobs,
            .safety_ratings = if (obj.get("safetyRatings")) |v|
                try std.json.innerParseFromValue([]const SafetyRating, allocator, v, options)
            else null,
            .citation_metadata = if (obj.get("citationMetadata")) |v|
                try std.json.innerParseFromValue(CitationMetadata, allocator, v, options)
            else null,
            .grounding_metadata = if (obj.get("groundingMetadata")) |v|
                try std.json.innerParseFromValue(GroundingMetadata, allocator, v, options)
            else null,
            .logprobs_result = if (obj.get("logprobsResult")) |v|
                try std.json.innerParseFromValue(LogprobsResult, allocator, v, options)
            else null,
            .finish_message = if (obj.get("finishMessage")) |v| (if (v == .string) v.string else null) else null,
        };
    }
};

/// Full generateContent response.
pub const Response = struct {
    candidates: []const Candidate = &.{},
    usage_metadata: UsageMetadata = .{},
    prompt_feedback: ?PromptFeedback = null,
    model_version: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    model_status: ?std.json.Value = null,

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
            try UsageMetadata.jsonParseFromValue(allocator, um, options)
        else
            .{};

        const model_version: ?[]const u8 = if (obj.get("modelVersion")) |v|
            if (v == .string) v.string else null
        else
            null;

        const response_id: ?[]const u8 = if (obj.get("responseId")) |v|
            if (v == .string) v.string else null
        else
            null;

        return .{
            .candidates = candidates,
            .usage_metadata = usage,
            .prompt_feedback = if (obj.get("promptFeedback")) |v|
                try std.json.innerParseFromValue(PromptFeedback, allocator, v, options)
            else null,
            .model_version = model_version,
            .response_id = response_id,
            .model_status = obj.get("modelStatus"),
        };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("candidates");
        try jw.write(self.candidates);
        try jw.objectField("usageMetadata");
        try jw.write(self.usage_metadata);
        if (self.prompt_feedback) |v| { try jw.objectField("promptFeedback"); try jw.write(v); }
        if (self.model_version) |v| { try jw.objectField("modelVersion"); try jw.write(v); }
        if (self.response_id) |v| { try jw.objectField("responseId"); try jw.write(v); }
        if (self.model_status) |v| { try jw.objectField("modelStatus"); try jw.write(v); }
        try jw.endObject();
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
// Gemini metadata types (Group B — fixed schemas)
// ============================================================================

/// Date object as returned by the Gemini API (e.g. in citation publicationDate).
pub const GeminiDate = struct {
    year: ?u32 = null,
    month: ?u32 = null,
    day: ?u32 = null,
};

pub const CitationSource = struct {
    startIndex: ?u32 = null,
    endIndex: ?u32 = null,
    uri: ?[]const u8 = null,
    license: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.startIndex) |v| { try jw.objectField("startIndex"); try jw.write(v); }
        if (self.endIndex) |v| { try jw.objectField("endIndex"); try jw.write(v); }
        if (self.uri) |v| { try jw.objectField("uri"); try jw.write(v); }
        if (self.license) |v| { try jw.objectField("license"); try jw.write(v); }
        try jw.endObject();
    }
};

pub const CitationMetadata = struct {
    citations: []const CitationSource = &.{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("citationSources");
        try jw.write(self.citations);
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !CitationMetadata {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;
        const cs_val = obj.get("citationSources") orelse return .{};
        return .{ .citations = try std.json.innerParseFromValue([]const CitationSource, allocator, cs_val, options) };
    }
};

pub const GroundingChunkWeb = struct {
    uri: []const u8 = "",
    title: []const u8 = "",
};
pub const GroundingChunkRetrievedContext = struct {
    uri: []const u8 = "",
    title: []const u8 = "",
};

pub const GroundingChunk = struct {
    web: ?GroundingChunkWeb = null,
    retrieved_context: ?GroundingChunkRetrievedContext = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.web) |w| {
            try jw.objectField("web");
            try jw.beginObject();
            try jw.objectField("uri"); try jw.write(w.uri);
            try jw.objectField("title"); try jw.write(w.title);
            try jw.endObject();
        }
        if (self.retrieved_context) |rc| {
            try jw.objectField("retrievedContext");
            try jw.beginObject();
            try jw.objectField("uri"); try jw.write(rc.uri);
            try jw.objectField("title"); try jw.write(rc.title);
            try jw.endObject();
        }
        try jw.endObject();
    }
};

pub const GroundingSegment = struct {
    startIndex: u32 = 0,
    endIndex: u32 = 0,
    text: []const u8 = "",
};

pub const GroundingSupport = struct {
    segment: ?GroundingSegment = null,
    groundingChunkIndices: []const u32 = &.{},
    confidenceScores: []const f64 = &.{},
};

pub const SearchEntryPoint = struct {
    renderedContent: []const u8 = "",
    sdk_blob: ?[]const u8 = null,
};

pub const GroundingMetadata = struct {
    webSearchQueries: []const []const u8 = &.{},
    groundingChunks: []const GroundingChunk = &.{},
    searchEntryPoint: ?SearchEntryPoint = null,
    groundingSupports: []const GroundingSupport = &.{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("webSearchQueries");
        try jw.write(self.webSearchQueries);
        try jw.objectField("groundingChunks");
        try jw.write(self.groundingChunks);
        if (self.searchEntryPoint) |sep| {
            try jw.objectField("searchEntryPoint");
            try jw.beginObject();
            try jw.objectField("renderedContent");
            try jw.write(sep.renderedContent);
            if (sep.sdk_blob) |sb| { try jw.objectField("sdkBlob"); try jw.write(sb); }
            try jw.endObject();
        }
        try jw.objectField("groundingSupports");
        try jw.write(self.groundingSupports);
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        var web_search_queries: [][]const u8 = &.{};
        if (obj.get("webSearchQueries")) |v| {
            if (v == .array) {
                web_search_queries = try allocator.alloc([]const u8, v.array.items.len);
                for (v.array.items, 0..) |item, i| {
                    web_search_queries[i] = if (item == .string) item.string else "";
                }
            }
        }

        var grounding_chunks: []GroundingChunk = &.{};
        if (obj.get("groundingChunks")) |v| {
            if (v == .array) {
                grounding_chunks = try allocator.alloc(GroundingChunk, v.array.items.len);
                for (v.array.items, 0..) |item, i| {
                    grounding_chunks[i] = try std.json.innerParseFromValue(GroundingChunk, allocator, item, options);
                }
            }
        }

        var search_entry_point: ?SearchEntryPoint = null;
        if (obj.get("searchEntryPoint")) |v| {
            if (v == .object) {
                const rc: []const u8 = if (v.object.get("renderedContent")) |rc_v|
                    if (rc_v == .string) rc_v.string else ""
                else
                    "";
                const sb: ?[]const u8 = if (v.object.get("sdkBlob")) |sb_v|
                    if (sb_v == .string) sb_v.string else null
                else
                    null;
                search_entry_point = .{ .renderedContent = rc, .sdk_blob = sb };
            }
        }

        var grounding_supports: []GroundingSupport = &.{};
        if (obj.get("groundingSupports")) |v| {
            if (v == .array) {
                grounding_supports = try allocator.alloc(GroundingSupport, v.array.items.len);
                for (v.array.items, 0..) |item, i| {
                    grounding_supports[i] = try std.json.innerParseFromValue(GroundingSupport, allocator, item, options);
                }
            }
        }

        return .{
            .webSearchQueries = web_search_queries,
            .groundingChunks = grounding_chunks,
            .searchEntryPoint = search_entry_point,
            .groundingSupports = grounding_supports,
        };
    }
};

pub const LogprobCandidate = struct {
    token: []const u8 = "",
    tokenId: u32 = 0,
    logProbability: f64 = 0,
};

pub const TopCandidates = struct {
    candidates: []const LogprobCandidate = &.{},
};

pub const LogprobsResult = struct {
    topCandidates: []const TopCandidates = &.{},
    chosenCandidates: []const LogprobCandidate = &.{},
};

pub const PromptFeedback = struct {
    blockReason: ?[]const u8 = null,
    safetyRatings: []const SafetyRating = &.{},
};
