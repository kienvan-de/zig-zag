const std = @import("std");
const testing = std.testing;
const OpenAI = @import("types.zig");

/// OpenAI transformer is a pass-through since the proxy accepts OpenAI format
/// and the OpenAI API also expects OpenAI format - no transformation needed!

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
        .top_p = request.top_p,
        .n = request.n,
        .presence_penalty = request.presence_penalty,
        .frequency_penalty = request.frequency_penalty,
        .tools = request.tools,
        .tool_choice = request.tool_choice,
        .functions = request.functions,
        .function_call = request.function_call,
        .response_format = request.response_format,
        .stop = request.stop,
        .logit_bias = request.logit_bias,
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

// ============================================================================
// Unit Tests
// ============================================================================

