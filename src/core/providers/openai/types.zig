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

/// OpenAI error details.
/// Wire: {"error":{"message":"...","type":"...","param":null,"code":"..."}}
/// Shared between /v1/chat/completions and /v1/responses.
/// Used by: OpenAI, Groq, HAI, Copilot, OpenRouter, and all OpenAI-compatible providers.
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

/// OpenAI error response wrapper (`{"error": {...}}`).
/// Shared between /v1/chat/completions and /v1/responses.
pub const ErrorResponse = struct {
    @"error": ErrorDetails,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("error");
        try self.@"error".jsonStringify(jw);
        try jw.endObject();
    }
};

/// Response for GET /v1/models
pub const ModelsResponse = struct {
    object: []const u8 = "list",
    data: []const Model,
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
        if (self.parameters) |p| { try jw.objectField("parameters"); try jw.write(p); }
        if (self.strict) |s| { try jw.objectField("strict"); try jw.write(s); }
        try jw.endObject();
    }
};


/// Response format — supports text, json_object, and json_schema (Structured Outputs).
/// For the Responses API `text.format`, `name`/`description`/`schema`/`strict` are used
/// instead of the nested `json_schema` wrapper used by Chat Completions.
pub const ResponseFormat = struct {
    type: []const u8,
    /// Chat Completions: nested schema wrapper {"type":"json_schema","json_schema":{...}}
    json_schema: ?std.json.Value = null,
    /// Responses API flat fields
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    schema: ?std.json.Value = null,
    strict: ?bool = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type"); try jw.write(self.type);
        if (self.json_schema) |v| { try jw.objectField("json_schema"); try jw.write(v); }
        if (self.name) |v| { try jw.objectField("name"); try jw.write(v); }
        if (self.description) |v| { try jw.objectField("description"); try jw.write(v); }
        if (self.schema) |v| { try jw.objectField("schema"); try jw.write(v); }
        if (self.strict) |v| { try jw.objectField("strict"); try jw.write(v); }
        try jw.endObject();
    }
};

/// Stream options
pub const StreamOptions = struct {
    include_usage: ?bool = null,
    include_obfuscation: ?bool = null,
};

// ============================================================================
// Shared token detail and logprob types
// ============================================================================

/// Breakdown of prompt / input token categories.
pub const PromptTokensDetails = struct {
    cached_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    audio_tokens: u32 = 0,
    text_tokens: u32 = 0,
    image_tokens: u32 = 0,
};

/// Breakdown of completion / output token categories.
pub const CompletionTokensDetails = struct {
    reasoning_tokens: u32 = 0,
    audio_tokens: u32 = 0,
    accepted_prediction_tokens: u32 = 0,
    rejected_prediction_tokens: u32 = 0,
    text_tokens: u32 = 0,
};

/// One candidate token with its log-probability.
pub const TopLogprob = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: ?[]const u32 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("token"); try jw.write(self.token);
        try jw.objectField("logprob"); try jw.write(self.logprob);
        if (self.bytes) |v| { try jw.objectField("bytes"); try jw.write(v); }
        try jw.endObject();
    }
};

/// Log-probability entry for a single output token.
pub const LogprobEntry = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: ?[]const u32 = null,
    top_logprobs: []const TopLogprob = &.{},

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("token"); try jw.write(self.token);
        try jw.objectField("logprob"); try jw.write(self.logprob);
        if (self.bytes) |v| { try jw.objectField("bytes"); try jw.write(v); }
        try jw.objectField("top_logprobs"); try jw.write(self.top_logprobs);
        try jw.endObject();
    }
};

/// Log-probability data for a choice — present when logprobs was requested.
pub const ChoiceLogprobs = struct {
    content: ?[]const LogprobEntry = null,
    refusal: ?[]const LogprobEntry = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        if (self.content) |v| { try jw.objectField("content"); try jw.write(v); }
        if (self.refusal) |v| { try jw.objectField("refusal"); try jw.write(v); }
        try jw.endObject();
    }
};
