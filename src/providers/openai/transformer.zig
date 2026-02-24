const std = @import("std");
const testing = std.testing;
const OpenAI = @import("types.zig");
const client = @import("client.zig");

/// OpenAI transformer is a pass-through since the proxy accepts OpenAI format
/// and the OpenAI API also expects OpenAI format - no transformation needed!

// ============================================================================
// Streaming State (stateless for OpenAI - just holds original_model)
// ============================================================================

/// State for OpenAI streaming (minimal - just tracks original model name)
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

/// Transform OpenAI ModelsResponse to OpenAI.Model array with provider prefix
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(client.ModelsResponse),
    provider_name: []const u8,
) ![]OpenAI.Model {
    var models = try allocator.alloc(OpenAI.Model, response.value.data.len);
    errdefer allocator.free(models);

    for (response.value.data, 0..) |upstream_model, i| {
        // Create prefixed model ID: {provider_name}/{model_id}
        const prefixed_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, upstream_model.id });

        models[i] = OpenAI.Model{
            .id = prefixed_id,
            .object = "model",
            .created = upstream_model.created orelse 0,
            .owned_by = try allocator.dupe(u8, upstream_model.owned_by orelse "unknown"),
        };
    }

    return models;
}

/// Transform OpenAI request to OpenAI format (pass-through)
/// Since the input is already in OpenAI format, we just return it as-is
pub fn transform(
    request: OpenAI.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !OpenAI.Request {
    _ = allocator; // No allocation needed for pass-through
    
    // Create a copy with the correct model name (without provider prefix)
    return OpenAI.Request{
        .model = model,
        .messages = request.messages,
        .stream = request.stream,
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .max_completion_tokens = request.max_completion_tokens,
        .top_p = request.top_p,
        .n = request.n,
        .presence_penalty = request.presence_penalty,
        .frequency_penalty = request.frequency_penalty,
        .tools = request.tools,
        .tool_choice = request.tool_choice,
        .parallel_tool_calls = request.parallel_tool_calls,
        .functions = request.functions,
        .function_call = request.function_call,
        .response_format = request.response_format,
        .stop = request.stop,
        .logit_bias = request.logit_bias,
        .logprobs = request.logprobs,
        .top_logprobs = request.top_logprobs,
        .user = request.user,
        .seed = request.seed,
    };
}

/// Transform OpenAI response to OpenAI format
/// For compatible providers, we need to set the model back to the original format
pub fn transformResponse(
    response: OpenAI.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !OpenAI.Response {
    // Allocate model string to return original_model (e.g., "groq/llama-3.1-70b")
    const model_str = try allocator.dupe(u8, original_model);
    
    return OpenAI.Response{
        .id = response.id,
        .object = response.object,
        .created = response.created,
        .model = model_str,
        .choices = response.choices,
        .usage = response.usage,
        .system_fingerprint = response.system_fingerprint,
        .service_tier = response.service_tier,
    };
}

/// Cleanup transformed request (no-op for pass-through)
pub fn cleanupRequest(request: OpenAI.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
    // No cleanup needed - request is just a shallow copy of the original
}

/// Cleanup transformed response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    // Free the model string allocated in transformResponse
    allocator.free(response.model);
}

/// Transform a single SSE line for streaming responses
/// Replaces the model field in the JSON chunk with the original model name
/// Returns null if line should be passed through unchanged (e.g., "data: [DONE]")
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const original_model = state.original_model;
    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return null; // Pass through non-data lines unchanged
    }

    const json_part = line["data: ".len..];
    
    // Handle [DONE] marker
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        return allocator.dupe(u8, "data: [DONE]") catch null;
    }

    // Parse the JSON chunk
    const parsed = std.json.parseFromSlice(
        OpenAI.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always },
    ) catch {
        return null; // Pass through unparseable lines unchanged
    };
    defer parsed.deinit();

    // Create new chunk with original model
    const new_chunk = OpenAI.StreamChunk{
        .id = parsed.value.id,
        .object = parsed.value.object,
        .created = parsed.value.created,
        .model = original_model,
        .choices = parsed.value.choices,
        .usage = parsed.value.usage,
    };

    // Serialize back to JSON
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    
    buffer.writer(allocator).print("data: {f}", .{std.json.fmt(new_chunk, .{})}) catch return null;
    
    return buffer.toOwnedSlice(allocator) catch null;
}

// ============================================================================
// Unit Tests
// ============================================================================

