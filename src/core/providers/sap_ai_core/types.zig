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
pub const OpenAIChat = @import("../openai/chat_types.zig");

// ============================================================================
// SAP AI Core Orchestration API Data Structures
// ============================================================================

// ----------------------------------------------------------------------------
// LLM Model Configuration
// ----------------------------------------------------------------------------

/// Full LLM model details including optional params, timeout, and retry config.
pub const ModelConfig = struct {
    name: []const u8,
    version: []const u8 = "latest",
    /// Free-form model parameters (temperature, max_tokens, top_p, etc.)
    params: ?std.json.Value = null,
    /// Request timeout in seconds (default 600, range 1–1200)
    timeout: ?u32 = null,
    /// Retry attempts (default 2, max 5)
    max_retries: ?u32 = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name"); try jw.write(self.name);
        try jw.objectField("version"); try jw.write(self.version);
        if (self.params) |p| { try jw.objectField("params"); try jw.write(p); }
        if (self.timeout) |t| { try jw.objectField("timeout"); try jw.write(t); }
        if (self.max_retries) |r| { try jw.objectField("max_retries"); try jw.write(r); }
        try jw.endObject();
    }
};

// ----------------------------------------------------------------------------
// Prompt Templating
// ----------------------------------------------------------------------------

/// Inline prompt template configuration
pub const PromptConfig = struct {
    template: []const OpenAIChat.Message,
    tools: ?[]const OpenAIChat.Tool = null,
    tool_choice: ?std.json.Value = null,
    /// Default values for template {{placeholders}}
    defaults: ?std.json.Value = null,
    /// Output format constraint (text, json_object, json_schema)
    response_format: ?OpenAIChat.ResponseFormat = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("template"); try jw.write(self.template);
        if (self.tools) |t| { try jw.objectField("tools"); try jw.write(t); }
        if (self.tool_choice) |tc| { try jw.objectField("tool_choice"); try jw.write(tc); }
        if (self.defaults) |d| { try jw.objectField("defaults"); try jw.write(d); }
        if (self.response_format) |rf| { try jw.objectField("response_format"); try jw.write(rf); }
        try jw.endObject();
    }
};

/// Prompt templating module — pairs a prompt template with a model config
pub const PromptTemplatingModule = struct {
    prompt: PromptConfig,
    model: ModelConfig,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt"); try self.prompt.jsonStringify(jw);
        try jw.objectField("model"); try self.model.jsonStringify(jw);
        try jw.endObject();
    }
};

// ----------------------------------------------------------------------------
// Content Filtering Module
// ----------------------------------------------------------------------------

/// Azure Content Safety threshold: 0=most strict, 6=most permissive
pub const AzureThreshold = u8; // literal values: 0, 2, 4, 6

pub const AzureContentSafetyInput = struct {
    hate: ?AzureThreshold = null,
    self_harm: ?AzureThreshold = null,
    sexual: ?AzureThreshold = null,
    violence: ?AzureThreshold = null,
    prompt_shield: ?bool = null, // blocks jailbreaks and prompt injections
};

pub const AzureContentSafetyOutput = struct {
    hate: ?AzureThreshold = null,
    self_harm: ?AzureThreshold = null,
    sexual: ?AzureThreshold = null,
    violence: ?AzureThreshold = null,
    protected_material_code: ?bool = null,
};

pub const InputFilterConfig = union(enum) {
    azure_content_safety: struct {
        type: []const u8 = "azure_content_safety",
        config: ?AzureContentSafetyInput = null,
    },
    llama_guard_3_8b: struct {
        type: []const u8 = "llama_guard_3_8b",
        config: ?std.json.Value = null,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .azure_content_safety => |v| try jw.write(v),
            .llama_guard_3_8b => |v| try jw.write(v),
        }
    }
};

pub const OutputFilterConfig = union(enum) {
    azure_content_safety: struct {
        type: []const u8 = "azure_content_safety",
        config: ?AzureContentSafetyOutput = null,
    },
    llama_guard_3_8b: struct {
        type: []const u8 = "llama_guard_3_8b",
        config: ?std.json.Value = null,
    },

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .azure_content_safety => |v| try jw.write(v),
            .llama_guard_3_8b => |v| try jw.write(v),
        }
    }
};

pub const FilteringStreamOptions = struct {
    overlap: ?u32 = null, // chars of prior chunk sent to filter for context
};

pub const InputFilteringConfig = struct {
    filters: []const InputFilterConfig,
};

pub const OutputFilteringConfig = struct {
    filters: []const OutputFilterConfig,
    stream_options: ?FilteringStreamOptions = null,
};

pub const FilteringModuleConfig = struct {
    input: ?InputFilteringConfig = null,
    output: ?OutputFilteringConfig = null,
};

// ----------------------------------------------------------------------------
// Data Masking Module
// ----------------------------------------------------------------------------

pub const DpiEntityConfig = struct {
    type: []const u8, // e.g. "profile-email", "profile-person", or regex entity
    regex: ?[]const u8 = null,
    replacement_strategy: ?[]const u8 = null,
};

pub const DpiConfig = struct {
    type: []const u8 = "sap_data_privacy_integration",
    method: []const u8, // "anonymization" | "pseudonymization"
    entities: []const DpiEntityConfig,
    allowlist: ?[]const []const u8 = null,
    mask_grounding_input: ?std.json.Value = null,
    mask_file_input_method: ?[]const u8 = null,
};

pub const MaskingModuleConfig = struct {
    /// Current field name (deprecated field `masking_providers` omitted)
    providers: []const DpiConfig,
};

// ----------------------------------------------------------------------------
// Grounding Module
// ----------------------------------------------------------------------------

pub const GroundingSearchConfig = struct {
    max_chunk_count: ?u32 = null,
    max_document_count: ?u32 = null,
};

pub const DocumentGroundingFilter = struct {
    id: ?[]const u8 = null,
    data_repository_type: []const u8, // "vector" | "help.sap.com" | etc.
    data_repositories: ?[]const []const u8 = null, // default ["*"]
    search_config: ?GroundingSearchConfig = null,
    data_repository_metadata: ?std.json.Value = null,
    document_metadata: ?std.json.Value = null,
    chunk_metadata: ?std.json.Value = null,
};

pub const GroundingPlaceholders = struct {
    input: []const []const u8, // template variable names used as search query
    output: []const u8,        // template variable name for grounding results
};

pub const GroundingConfig = struct {
    filters: ?[]const DocumentGroundingFilter = null,
    placeholders: GroundingPlaceholders,
    metadata_params: ?[]const []const u8 = null,
};

pub const GroundingModuleConfig = struct {
    type: []const u8 = "document_grounding_service",
    config: GroundingConfig,
};

// ----------------------------------------------------------------------------
// Translation Module
// ----------------------------------------------------------------------------

pub const TranslationModuleConfig = struct {
    input: ?std.json.Value = null,
    output: ?std.json.Value = null,
};

// ----------------------------------------------------------------------------
// Module Configs
// ----------------------------------------------------------------------------

/// Single module configuration object
pub const ModulesConfig = struct {
    prompt_templating: PromptTemplatingModule,
    filtering: ?FilteringModuleConfig = null,
    masking: ?MaskingModuleConfig = null,
    grounding: ?GroundingModuleConfig = null,
    translation: ?TranslationModuleConfig = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt_templating"); try self.prompt_templating.jsonStringify(jw);
        if (self.filtering) |v| { try jw.objectField("filtering"); try jw.write(v); }
        if (self.masking) |v| { try jw.objectField("masking"); try jw.write(v); }
        if (self.grounding) |v| { try jw.objectField("grounding"); try jw.write(v); }
        if (self.translation) |v| { try jw.objectField("translation"); try jw.write(v); }
        try jw.endObject();
    }
};

// ----------------------------------------------------------------------------
// Stream Configuration
// ----------------------------------------------------------------------------

pub const StreamConfig = struct {
    enabled: bool,
    chunk_size: ?u32 = null,
    delimiters: ?[]const []const u8 = null, // required when translation module is used

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("enabled"); try jw.write(self.enabled);
        if (self.chunk_size) |cs| { try jw.objectField("chunk_size"); try jw.write(cs); }
        if (self.delimiters) |d| { try jw.objectField("delimiters"); try jw.write(d); }
        try jw.endObject();
    }
};

// ----------------------------------------------------------------------------
// Orchestration Config
// ----------------------------------------------------------------------------

pub const OrchestrationConfig = struct {
    /// Single module config or a list of fallback configs
    modules: ModulesConfig,
    stream: StreamConfig,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("modules"); try self.modules.jsonStringify(jw);
        try jw.objectField("stream"); try self.stream.jsonStringify(jw);
        try jw.endObject();
    }
};

// Keep Config as an alias for backwards compat with transformer
pub const Config = OrchestrationConfig;

// ----------------------------------------------------------------------------
// Top-level Request
// ----------------------------------------------------------------------------

/// SAP AI Core Orchestration completion request
pub const Request = struct {
    config: Config,
    /// Template variable substitution values  e.g. {"user_query": "Hello"}
    placeholder_values: ?std.json.Value = null,
    /// Prior conversation context merged with template messages
    messages_history: ?[]const OpenAIChat.Message = null,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("config"); try self.config.jsonStringify(jw);
        if (self.placeholder_values) |v| { try jw.objectField("placeholder_values"); try jw.write(v); }
        if (self.messages_history) |v| {
            try jw.objectField("messages_history");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

// ============================================================================
// Response Structures
// ============================================================================

/// Citation from grounding module
pub const Citation = struct {
    ref_id: ?u32 = null,
    title: []const u8,
    url: []const u8,
    start_index: ?u32 = null,
    end_index: ?u32 = null,
};

/// Generic module result (filtering, masking, grounding, translation)
pub const GenericModuleResult = struct {
    message: []const u8 = "",
    data: ?std.json.Value = null,
};

/// Intermediate results from all orchestration modules
pub const IntermediateResults = struct {
    templating: ?[]const OpenAIChat.Message = null,
    llm: ?std.json.Value = null,
    grounding: ?GenericModuleResult = null,
    input_translation: ?std.json.Value = null,
    input_masking: ?GenericModuleResult = null,
    input_filtering: ?GenericModuleResult = null,
    output_filtering: ?GenericModuleResult = null,
    output_translation: ?GenericModuleResult = null,
    output_unmasking: ?std.json.Value = null,
};

/// SAP AI Core Response (non-streaming)
pub const Response = struct {
    request_id: []const u8,
    intermediate_results: ?IntermediateResults = null,
    final_result: OpenAIChat.Response,
    intermediate_failures: ?std.json.Value = null,
};

/// SAP AI Core Streaming Chunk
pub const StreamChunk = struct {
    request_id: []const u8,
    intermediate_results: ?IntermediateResults = null,
    final_result: OpenAIChat.StreamChunk,
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
