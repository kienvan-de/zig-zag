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

/// Prompt configuration containing messages, tools, and model
pub const PromptConfig = struct {
    template: []const OpenAI.Message,
    tools: ?[]const OpenAI.Tool = null,
    tool_choice: ?OpenAI.ToolChoice = null,
    model: ModelConfig,

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

        try jw.objectField("model");
        try self.model.jsonStringify(jw);

        try jw.endObject();
    }
};

/// Prompt templating module configuration
pub const PromptTemplatingModule = struct {
    prompt: PromptConfig,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt");
        try self.prompt.jsonStringify(jw);
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
    final_result: std.json.Value, // OpenAI.Response format
};

/// SAP AI Core Streaming Chunk
pub const StreamChunk = struct {
    request_id: []const u8,
    intermediate_results: ?IntermediateResults = null,
    final_result: std.json.Value, // OpenAI.StreamChunk format
};

