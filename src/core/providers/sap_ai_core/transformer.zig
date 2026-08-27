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
const OpenAI = @import("../openai/chat_types.zig");
const Anthropic = @import("../anthropic/types.zig");
const SapAiCore = @import("types.zig");
const openai_transformer = @import("../openai/chat_transformer.zig");
const log = @import("../../log.zig");

/// Check if a model has orchestration scenario
fn hasOrchestrationScenario(sap_model: SapAiCore.SapModel) bool {
    for (sap_model.allowedScenarios) |scenario| {
        if (std.mem.eql(u8, scenario.scenarioId, "orchestration")) {
            return true;
        }
    }
    return false;
}

/// Check if a model has a valid latest non-deprecated version
fn hasValidLatestVersion(sap_model: SapAiCore.SapModel) bool {
    for (sap_model.versions) |version| {
        if (version.isLatest and !version.deprecated) {
            return true;
        }
    }
    return false;
}

/// Transform SAP AI Core SapModelsResponse to OpenAI.Model array with provider prefix
/// Filters to only include models with:
/// - isLatest = true and deprecated = false (in versions)
/// - scenarioId = "orchestration" (in allowedScenarios)
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(SapAiCore.SapModelsResponse),
    provider_name: []const u8,
) ![]OpenAI.Model {
    const resources = response.value.resources;

    // First pass: count valid models
    var valid_count: usize = 0;
    for (resources) |sap_model| {
        if (hasValidLatestVersion(sap_model) and hasOrchestrationScenario(sap_model)) {
            valid_count += 1;
        }
    }

    var models = try allocator.alloc(OpenAI.Model, valid_count);
    errdefer allocator.free(models);

    // Second pass: populate valid models
    var idx: usize = 0;
    for (resources) |sap_model| {
        if (hasValidLatestVersion(sap_model) and hasOrchestrationScenario(sap_model)) {
            // Create prefixed model ID: {provider_name}/{model_id}
            const prefixed_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, sap_model.model });

            models[idx] = OpenAI.Model{
                .id = prefixed_id,
                .object = "model",
                .created = 0,
                .owned_by = try allocator.dupe(u8, sap_model.provider),
            };
            idx += 1;
        }
    }

    return models;
}

// ============================================================================
// Streaming State
// ============================================================================

/// State for SAP AI Core streaming (tracks original model name with provider prefix)
pub const StreamState = struct {
    original_model: []const u8,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) StreamState {
        _ = allocator;
        return .{ .original_model = original_model };
    }

    pub fn deinit(self: *StreamState) void {
        _ = self;
    }
};

// ============================================================================
// Request Transformation: OpenAI -> SAP AI Core
// ============================================================================

/// Transform OpenAI request to SAP AI Core orchestration format
pub fn transform(
    request: OpenAI.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !SapAiCore.Request {
    // Build model params from OpenAI request fields (S1 — model params forwarding)
    var params_obj: std.json.ObjectMap = .{};
    defer params_obj.deinit(allocator);

    if (request.temperature) |v| try params_obj.put(allocator, "temperature", .{ .float = v });
    if (request.max_tokens) |v| try params_obj.put(allocator, "max_tokens", .{ .integer = v });
    if (request.max_completion_tokens) |v| try params_obj.put(allocator, "max_completion_tokens", .{ .integer = v });
    if (request.top_p) |v| try params_obj.put(allocator, "top_p", .{ .float = v });
    if (request.n) |v| try params_obj.put(allocator, "n", .{ .integer = v });
    if (request.presence_penalty) |v| try params_obj.put(allocator, "presence_penalty", .{ .float = v });
    if (request.frequency_penalty) |v| try params_obj.put(allocator, "frequency_penalty", .{ .float = v });
    if (request.seed) |v| try params_obj.put(allocator, "seed", .{ .integer = v });
    if (request.logprobs) |v| try params_obj.put(allocator, "logprobs", .{ .bool = v });
    if (request.top_logprobs) |v| try params_obj.put(allocator, "top_logprobs", .{ .integer = v });
    if (request.logit_bias) |v| try params_obj.put(allocator, "logit_bias", v);
    if (request.stop) |seqs| {
        var arr = std.json.Array.init(allocator);
        for (seqs) |s| try arr.append(.{ .string = s });
        try params_obj.put(allocator, "stop", .{ .array = arr });
    }

    const params: ?std.json.Value = if (params_obj.count() > 0)
        .{ .object = try params_obj.clone(allocator) }
    else
        null;

    const is_streaming = request.stream orelse false;

    return SapAiCore.Request{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = request.messages,
                        .tools = request.tools,
                        .tool_choice = request.tool_choice, // S2
                        .response_format = request.response_format, // S3
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params, // S1
                    },
                },
            },
            .stream = .{
                .enabled = is_streaming,
                // Inject include_usage into chunk_size workaround is not applicable here;
                // SAP AI Core's stream.enabled drives token usage in the final chunk (S19)
                .chunk_size = null,
            },
        },
    };
}

/// Cleanup transformed request — frees the params object if allocated
pub fn cleanupRequest(request: SapAiCore.Request, allocator: std.mem.Allocator) void {
    if (request.config.modules.prompt_templating.model.params) |p| {
        var obj = p.object;
        obj.deinit(allocator);
    }
}

// ============================================================================
// Response Transformation: SAP AI Core -> OpenAI
// ============================================================================

/// Deep copy a ResponseMessage
fn dupeResponseMessage(allocator: std.mem.Allocator, msg: OpenAI.ResponseMessage) !OpenAI.ResponseMessage {
    return OpenAI.ResponseMessage{
        .role = msg.role,
        .content = if (msg.content) |c| try allocator.dupe(u8, c) else null,
        .tool_calls = if (msg.tool_calls) |tcs| blk: {
            const duped = try allocator.alloc(OpenAI.ToolCall, tcs.len);
            for (tcs, 0..) |tc, i| {
                duped[i] = switch (tc) {
                    .function => |f| OpenAI.ToolCall{ .function = .{
                        .id = try allocator.dupe(u8, f.id),
                        .type = try allocator.dupe(u8, f.type),
                        .function = OpenAI.ToolCallFunction{
                            .name = try allocator.dupe(u8, f.function.name),
                            .arguments = try allocator.dupe(u8, f.function.arguments),
                        },
                    } },
                    .custom => |c| OpenAI.ToolCall{ .custom = .{
                        .id = try allocator.dupe(u8, c.id),
                        .type = try allocator.dupe(u8, c.type),
                        .custom = c.custom,
                    } },
                };
            }
            break :blk duped;
        } else null,
        .function_call = if (msg.function_call) |fc| OpenAI.FunctionCall{
            .name = try allocator.dupe(u8, fc.name),
            .arguments = try allocator.dupe(u8, fc.arguments),
        } else null,
    };
}

/// Deep copy a ResponseChoice
fn dupeResponseChoice(allocator: std.mem.Allocator, choice: OpenAI.ResponseChoice) !OpenAI.ResponseChoice {
    return OpenAI.ResponseChoice{
        .index = choice.index,
        .message = try dupeResponseMessage(allocator, choice.message),
        .finish_reason = try allocator.dupe(u8, choice.finish_reason),
        .logprobs = choice.logprobs, // json.Value is managed separately
    };
}

/// Transform SAP AI Core response to OpenAI format
pub fn transformResponse(
    response: SapAiCore.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !OpenAI.Response {
    const final_result = response.final_result;

    // Allocate model string with provider prefix
    const model_str = try allocator.dupe(u8, original_model);

    // Deep copy choices since response may be freed
    const choices = try allocator.alloc(OpenAI.ResponseChoice, final_result.choices.len);
    for (final_result.choices, 0..) |choice, i| {
        choices[i] = try dupeResponseChoice(allocator, choice);
    }

    return OpenAI.Response{
        .id = try allocator.dupe(u8, final_result.id),
        .object = try allocator.dupe(u8, final_result.object),
        .created = final_result.created,
        .model = model_str,
        .choices = choices,
        .usage = final_result.usage orelse OpenAI.Usage{
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
        },
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Free a ResponseMessage's allocated fields
fn freeResponseMessage(allocator: std.mem.Allocator, msg: OpenAI.ResponseMessage) void {
    if (msg.content) |c| allocator.free(c);
    if (msg.tool_calls) |tcs| {
        for (tcs) |tc| {
            switch (tc) {
                .function => |f| {
                    allocator.free(f.id);
                    allocator.free(f.type);
                    allocator.free(f.function.name);
                    allocator.free(f.function.arguments);
                },
                .custom => |c| {
                    allocator.free(c.id);
                    allocator.free(c.type);
                },
            }
        }
        allocator.free(tcs);
    }
    if (msg.function_call) |fc| {
        allocator.free(fc.name);
        allocator.free(fc.arguments);
    }
}

/// Cleanup transformed response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    allocator.free(response.id);
    allocator.free(response.object);
    allocator.free(response.model);
    for (response.choices) |choice| {
        freeResponseMessage(allocator, choice.message);
        allocator.free(choice.finish_reason);
    }
    allocator.free(response.choices);
}

// ============================================================================
// Streaming Transformation
// ============================================================================

// ============================================================================
// Error Response Transformation
// ============================================================================

/// Transform SAP AI Core error response to OpenAI error format
pub fn transformErrorResponse(sap_error: SapAiCore.ErrorDetails) OpenAI.ErrorResponse {
    // Map SAP numeric code to OpenAI string code
    const code: ?[]const u8 = if (sap_error.code) |c| switch (c) {
        400 => "bad_request",
        401 => "invalid_api_key",
        403 => "forbidden",
        404 => "not_found",
        429 => "rate_limit_exceeded",
        500 => "server_error",
        503 => "service_unavailable",
        else => "unknown_error",
    } else null;

    // Determine error type based on code
    const error_type: []const u8 = if (sap_error.code) |c|
        if (c >= 400 and c < 500) "invalid_request_error" else "server_error"
    else
        "server_error";

    return OpenAI.ErrorResponse{
        .@"error" = OpenAI.ErrorDetails{
            .message = sap_error.message orelse "Unknown error from SAP AI Core",
            .type = error_type,
            .param = null,
            .code = code,
        },
    };
}

/// Same as transformErrorResponse but uses a pre-duplicated message (avoids use-after-free)
fn transformErrorResponseDuped(sap_error: SapAiCore.ErrorDetails, duped_message: []const u8) OpenAI.ErrorResponse {
    const code: ?[]const u8 = if (sap_error.code) |c| switch (c) {
        400 => "bad_request",
        401 => "invalid_api_key",
        403 => "forbidden",
        404 => "not_found",
        429 => "rate_limit_exceeded",
        500 => "server_error",
        503 => "service_unavailable",
        else => "unknown_error",
    } else null;

    const error_type: []const u8 = if (sap_error.code) |c|
        if (c >= 400 and c < 500) "invalid_request_error" else "server_error"
    else
        "server_error";

    return OpenAI.ErrorResponse{
        .@"error" = OpenAI.ErrorDetails{
            .message = duped_message,
            .type = error_type,
            .param = null,
            .code = code,
        },
    };
}

/// Try to parse JSON as SAP AI Core error response
fn tryParseError(json_part: []const u8, allocator: std.mem.Allocator) ?OpenAI.ErrorResponse {
    const parsed = std.json.parseFromSlice(
        SapAiCore.ErrorResponse,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    // Must dupe the message since parsed memory is freed by defer above
    const msg = parsed.value.@"error".message orelse "Unknown error from SAP AI Core";
    const duped_msg = allocator.dupe(u8, msg) catch return null;

    return transformErrorResponseDuped(parsed.value.@"error", duped_msg);
}

/// Transform a single SSE line for streaming responses
/// Extracts final_result from SAP AI Core wrapper and adds provider prefix to model
/// Returns StreamLineResult with chunk, error, or skip
/// Caller must check for [DONE] before calling
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) OpenAI.StreamLineResult {
    const original_model = state.original_model;

    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return .{ .skip = {} };
    }

    const json_part = line["data: ".len..];

    // Try to parse as SAP AI Core stream chunk first
    const parsed = std.json.parseFromSlice(
        SapAiCore.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        // Failed to parse as stream chunk - try parsing as error response
        if (tryParseError(json_part, allocator)) |error_response| {
            log.warn("[SAP] [STREAM] Provider returned error: {s}", .{error_response.@"error".message});
            return .{ .@"error" = error_response };
        }
        log.debug("[SAP] [STREAM] Failed to parse chunk: {} | raw: {s}", .{ err, json_part });
        return .{ .skip = {} };
    };
    defer parsed.deinit();

    const final_result = parsed.value.final_result;

    // Skip empty chunks (initial templating results)
    if (final_result.id.len == 0) {
        return .{ .skip = {} };
    }

    // Create OpenAI chunk with original model (including provider prefix)
    const openai_chunk = OpenAI.StreamChunk{
        .id = final_result.id,
        .object = final_result.object,
        .created = final_result.created,
        .model = original_model,
        .choices = final_result.choices,
        .usage = final_result.usage,
    };

    // Serialize to JSON
    var buffer = std.ArrayList(u8).empty;
    buffer.print(allocator, "{f}", .{std.json.fmt(openai_chunk, .{})}) catch return .{ .skip = {} };
    defer buffer.deinit(allocator);

    // Parse back to get Parsed that owns the data
    const new_parsed = std.json.parseFromSlice(
        OpenAI.StreamChunk,
        allocator,
        buffer.items,
        .{ .allocate = .alloc_always },
    ) catch return .{ .skip = {} };

    return .{ .chunk = new_parsed };
}

// ============================================================================
// Anthropic <-> SAP AI Core Reverse Transforms (for /v1/messages endpoint)
// Chains: Anthropic <-> OpenAI (via openai_transformer) <-> SapAiCore (via existing)
// ============================================================================

/// Transform Anthropic request to SAP AI Core request
/// Chain: Anthropic -> OpenAI (openai_transformer) -> SapAiCore (existing transform)
pub fn transformFromAnthropic(
    request: Anthropic.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !SapAiCore.Request {
    // Step 1: Anthropic -> OpenAI
    const openai_request = try openai_transformer.transformFromAnthropic(request, model, allocator);
    errdefer openai_transformer.cleanupFromAnthropicRequest(openai_request, allocator);

    // Step 2: OpenAI -> SapAiCore (borrows slices from openai_request; params are cloned)
    return try transform(openai_request, model, allocator);
}

/// Cleanup a request created by transformFromAnthropic.
pub fn cleanupFromAnthropicRequest(request: SapAiCore.Request, allocator: std.mem.Allocator) void {
    // Free the params clone if present
    cleanupRequest(request, allocator);
    // The template messages and tools were allocated by openai_transformer.transformFromAnthropic.
    const openai_request = OpenAI.Request{
        .model = request.config.modules.prompt_templating.model.name,
        .messages = request.config.modules.prompt_templating.prompt.template,
        .tools = request.config.modules.prompt_templating.prompt.tools,
    };
    openai_transformer.cleanupFromAnthropicRequest(openai_request, allocator);
}

/// Transform SAP AI Core response to Anthropic response
/// Chain: SapAiCore -> OpenAI (existing transformResponse) -> Anthropic (openai_transformer)
pub fn transformToAnthropicResponse(
    response: SapAiCore.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !Anthropic.Response {
    // Step 1: SapAiCore -> OpenAI
    const openai_response = try transformResponse(response, allocator, original_model);
    defer cleanupResponse(openai_response, allocator);

    // Step 2: OpenAI -> Anthropic
    return try openai_transformer.transformToAnthropicResponse(openai_response, allocator, original_model);
}

/// Cleanup a response created by transformToAnthropicResponse
pub fn cleanupAnthropicResponse(response: Anthropic.Response, allocator: std.mem.Allocator) void {
    openai_transformer.cleanupAnthropicResponse(response, allocator);
}

// ============================================================================
// Anthropic SSE Streaming (SapAiCore → OpenAI → Anthropic SSE events)
// Chains through the OpenAI transformer's AnthropicStreamState.
// ============================================================================

pub const AnthropicStreamLineResult = Anthropic.AnthropicStreamLineResult;

/// State machine that wraps OpenAI's AnthropicStreamState, handling the
/// SapAiCore envelope (final_result unwrapping) first.
pub const AnthropicStreamState = struct {
    allocator: std.mem.Allocator,
    /// Inner OpenAI→Anthropic stream state (handles SSE event generation)
    inner: openai_transformer.AnthropicStreamState,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) AnthropicStreamState {
        return .{
            .allocator = allocator,
            .inner = openai_transformer.AnthropicStreamState.init(allocator, original_model),
        };
    }

    pub fn deinit(self: *AnthropicStreamState) void {
        self.inner.deinit();
    }

    pub fn getUsage(self: *const AnthropicStreamState) Anthropic.StreamUsage {
        return self.inner.getUsage();
    }
};

/// Convert a SapAiCore SSE line into Anthropic SSE event bytes.
/// Chain: SapAiCore SSE line → unwrap final_result → OpenAI SSE line → Anthropic SSE events
pub fn transformStreamLineToAnthropic(
    line: []const u8,
    state: *AnthropicStreamState,
    allocator: std.mem.Allocator,
) AnthropicStreamLineResult {
    // Only process "data: " lines
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return .{ .skip = {} };
    }

    const json_part = line["data: ".len..];

    // Handle [DONE]
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        return openai_transformer.transformStreamLineToAnthropic(line, &state.inner, allocator);
    }

    // Step 1: Unwrap SapAiCore envelope to get OpenAI chunk
    // Use existing transformStreamLine which extracts final_result and returns an OpenAI chunk
    var sap_stream_state = StreamState.init(allocator, state.inner.original_model);
    defer sap_stream_state.deinit();
    const sap_result = transformStreamLine(line, &sap_stream_state, allocator);

    switch (sap_result) {
        .chunk => |parsed| {
            var chunk = parsed;
            defer chunk.deinit();

            // Step 2: Re-serialize the OpenAI chunk as a "data: {...}" line
            // and feed it through the OpenAI→Anthropic transformer
            var buf = std.ArrayList(u8).empty;
            buf.print(allocator, "data: {f}", .{std.json.fmt(chunk.value, .{})}) catch return .{ .skip = {} };
            defer buf.deinit(allocator);

            return openai_transformer.transformStreamLineToAnthropic(buf.items, &state.inner, allocator);
        },
        .@"error" => {
            return .{ .skip = {} };
        },
        .skip => {
            return .{ .skip = {} };
        },
    }
}
