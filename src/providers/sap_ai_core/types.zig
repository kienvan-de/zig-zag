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

// Reuse OpenAI types for the inner content
pub const OpenAI = @import("../openai/types.zig");

// ============================================================================
// SAP AI Core Orchestration API Data Structures
// ============================================================================

/// Model configuration in SAP AI Core
pub const ModelConfig = struct {
    name: []const u8,
    version: []const u8 = "latest",

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.endObject();
    }
};

/// Prompt configuration containing messages and tools
pub const PromptConfig = struct {
    template: []const OpenAI.Message,
    tools: ?[]const OpenAI.Tool = null,
    tool_choice: ?std.json.Value = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("template");
        try jw.write(self.template);

        if (self.tools) |tools| {
            try jw.objectField("tools");
            try jw.write(tools);
        }

        if (self.tool_choice) |tc| {
            try jw.objectField("tool_choice");
            try jw.write(tc);
        }

        try jw.endObject();
    }
};

/// Prompt templating module configuration
pub const PromptTemplatingModule = struct {
    prompt: PromptConfig,
    model: ModelConfig,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt");
        try self.prompt.jsonStringify(jw);
        try jw.objectField("model");
        try self.model.jsonStringify(jw);
        try jw.endObject();
    }
};

/// Modules configuration
pub const ModulesConfig = struct {
    prompt_templating: PromptTemplatingModule,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt_templating");
        try self.prompt_templating.jsonStringify(jw);
        try jw.endObject();
    }
};

/// Stream configuration
pub const StreamConfig = struct {
    enabled: bool,
    chunk_size: ?u32 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("enabled");
        try jw.write(self.enabled);
        if (self.chunk_size) |cs| {
            try jw.objectField("chunk_size");
            try jw.write(cs);
        }
        try jw.endObject();
    }
};

/// Main config wrapper
pub const Config = struct {
    modules: ModulesConfig,
    stream: StreamConfig,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("modules");
        try self.modules.jsonStringify(jw);
        try jw.objectField("stream");
        try self.stream.jsonStringify(jw);
        try jw.endObject();
    }
};

/// SAP AI Core Request (wraps OpenAI-format content)
pub const Request = struct {
    config: Config,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("config");
        try self.config.jsonStringify(jw);
        try jw.endObject();
    }
};

// ============================================================================
// Response Structures
// ============================================================================

/// Intermediate results from orchestration
pub const IntermediateResults = struct {
    templating: ?[]const OpenAI.Message = null,
    llm: ?std.json.Value = null, // Can be Response or StreamChunk
};

/// SAP AI Core Response (non-streaming)
pub const Response = struct {
    request_id: []const u8,
    intermediate_results: ?IntermediateResults = null,
    final_result: OpenAI.Response,
};

/// SAP AI Core Streaming Chunk
pub const StreamChunk = struct {
    request_id: []const u8,
    intermediate_results: ?IntermediateResults = null,
    final_result: OpenAI.StreamChunk,
};

// ============================================================================
// Error Response Structures
// ============================================================================

/// SAP AI Core error details
pub const ErrorDetails = struct {
    request_id: ?[]const u8 = null,
    code: ?i64 = null, // SAP uses numeric HTTP status code
    message: ?[]const u8 = null,
    location: ?[]const u8 = null,
    intermediate_results: ?IntermediateResults = null,
};

/// SAP AI Core error response wrapper
pub const ErrorResponse = struct {
    @"error": ErrorDetails,
};

// ============================================================================
// SAP AI Core Models API Structures
// ============================================================================

/// Model version info from SAP AI Core models endpoint
pub const SapModelVersion = struct {
    name: []const u8,
    isLatest: bool = false,
    deprecated: bool = false,
    retirementDate: []const u8 = "",
    contextLength: ?u64 = null,
    inputTypes: ?[]const []const u8 = null,
    capabilities: ?[]const []const u8 = null,
    streamingSupported: bool = false,
};

/// Allowed scenario for a model
pub const SapAllowedScenario = struct {
    executableId: []const u8 = "",
    scenarioId: []const u8 = "",
};

/// Model resource from SAP AI Core models endpoint
pub const SapModel = struct {
    model: []const u8,
    executableId: []const u8,
    description: []const u8 = "",
    versions: []const SapModelVersion = &.{},
    displayName: []const u8 = "",
    accessType: []const u8 = "",
    provider: []const u8 = "",
    allowedScenarios: []const SapAllowedScenario = &.{},
};

/// Response from SAP AI Core /v2/lm/scenarios/foundation-models/models endpoint
pub const SapModelsResponse = struct {
    count: u64 = 0,
    resources: []const SapModel = &.{},
};

