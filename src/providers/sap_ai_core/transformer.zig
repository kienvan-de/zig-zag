const std = @import("std");
const OpenAI = @import("../openai/types.zig");
const SapAiCore = @import("types.zig");
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
    _ = allocator;

    return SapAiCore.Request{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = request.messages,
                        .tools = request.tools,
                        .model = .{
                            .name = model,
                            .version = "latest",
                        },
                    },
                },
            },
            .stream = if (request.stream) |s|
                .{ .enabled = s, .chunk_size = null }
            else
                .{ .enabled = false, .chunk_size = null },
        },
    };
}

/// Cleanup transformed request
pub fn cleanupRequest(request: SapAiCore.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
    // No cleanup needed - request uses references from original
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
                duped[i] = OpenAI.ToolCall{
                    .id = try allocator.dupe(u8, tc.id),
                    .type = try allocator.dupe(u8, tc.type),
                    .function = OpenAI.ToolCallFunction{
                        .name = try allocator.dupe(u8, tc.function.name),
                        .arguments = try allocator.dupe(u8, tc.function.arguments),
                    },
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
            allocator.free(tc.id);
            allocator.free(tc.type);
            allocator.free(tc.function.name);
            allocator.free(tc.function.arguments);
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

/// Transform a single SSE line for streaming responses
/// Extracts final_result from SAP AI Core wrapper and adds provider prefix to model
/// Returns null if line should be skipped
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const original_model = state.original_model;

    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return null;
    }

    const json_part = line["data: ".len..];

    // Handle [DONE] marker
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        return allocator.dupe(u8, "data: [DONE]") catch null;
    }

    // Parse the SAP AI Core wrapper
    const parsed = std.json.parseFromSlice(
        SapAiCore.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        log.debug("[SAP] [STREAM] Failed to parse wrapper chunk: {}", .{err});
        return null;
    };
    defer parsed.deinit();

    const final_result = parsed.value.final_result;

    // Skip empty chunks (initial templating results)
    if (final_result.id.len == 0) {
        return null;
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
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    buffer.writer(allocator).print("data: {f}", .{std.json.fmt(openai_chunk, .{})}) catch return null;

    return buffer.toOwnedSlice(allocator) catch null;
}