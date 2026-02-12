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

test "transform creates pass-through request with updated model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const messages = [_]OpenAI.Message{
        .{
            .role = .user,
            .content = .{ .text = "Hello!" },
            .name = null,
            .tool_calls = null,
            .tool_call_id = null,
            .function_call = null,
        },
    };

    const original_request = OpenAI.Request{
        .model = "openai/gpt-4",
        .messages = &messages,
        .stream = null,
        .temperature = 0.7,
        .max_tokens = 1000,
        .top_p = null,
        .n = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .tools = null,
        .tool_choice = null,
        .functions = null,
        .function_call = null,
        .response_format = null,
        .stop = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
    };

    const transformed = try transform(original_request, "gpt-4", allocator);

    try testing.expectEqualStrings("gpt-4", transformed.model);
    try testing.expectEqual(messages.len, transformed.messages.len);
    try testing.expectEqual(0.7, transformed.temperature.?);
    try testing.expectEqual(1000, transformed.max_tokens.?);
}

test "transform preserves all request fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const messages = [_]OpenAI.Message{
        .{
            .role = .system,
            .content = .{ .text = "You are a helpful assistant." },
            .name = null,
            .tool_calls = null,
            .tool_call_id = null,
            .function_call = null,
        },
        .{
            .role = .user,
            .content = .{ .text = "Hello!" },
            .name = null,
            .tool_calls = null,
            .tool_call_id = null,
            .function_call = null,
        },
    };

    const original_request = OpenAI.Request{
        .model = "openai/gpt-3.5-turbo",
        .messages = &messages,
        .stream = false,
        .temperature = 0.5,
        .max_tokens = 500,
        .top_p = 0.9,
        .n = 1,
        .presence_penalty = 0.1,
        .frequency_penalty = 0.2,
        .tools = null,
        .tool_choice = null,
        .functions = null,
        .function_call = null,
        .response_format = null,
        .stop = null,
        .logit_bias = null,
        .user = "test-user",
        .seed = 42,
    };

    const transformed = try transform(original_request, "gpt-3.5-turbo", allocator);

    try testing.expectEqualStrings("gpt-3.5-turbo", transformed.model);
    try testing.expectEqual(false, transformed.stream.?);
    try testing.expectEqual(0.5, transformed.temperature.?);
    try testing.expectEqual(500, transformed.max_tokens.?);
    try testing.expectEqual(0.9, transformed.top_p.?);
    try testing.expectEqual(1, transformed.n.?);
    try testing.expectEqual(0.1, transformed.presence_penalty.?);
    try testing.expectEqual(0.2, transformed.frequency_penalty.?);
    try testing.expectEqualStrings("test-user", transformed.user.?);
    try testing.expectEqual(42, transformed.seed.?);
}

test "transformResponse is pass-through with model override" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const response_message = OpenAI.ResponseMessage{
        .role = .assistant,
        .content = "Hello! How can I help you?",
        .tool_calls = null,
        .function_call = null,
    };

    const choices = [_]OpenAI.ResponseChoice{
        .{
            .index = 0,
            .message = response_message,
            .finish_reason = "stop",
        },
    };

    const usage = OpenAI.Usage{
        .prompt_tokens = 10,
        .completion_tokens = 20,
        .total_tokens = 30,
    };

    const original_response = OpenAI.Response{
        .id = "chatcmpl-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4",
        .choices = &choices,
        .usage = usage,
        .system_fingerprint = null,
        .service_tier = null,
    };

    const transformed = try transformResponse(original_response, allocator, "openai/gpt-4");

    try testing.expectEqualStrings("chatcmpl-123", transformed.id);
    try testing.expectEqualStrings("chat.completion", transformed.object);
    try testing.expectEqual(1234567890, transformed.created);
    try testing.expectEqualStrings("openai/gpt-4", transformed.model);
    try testing.expectEqual(10, transformed.usage.prompt_tokens);
    try testing.expectEqual(20, transformed.usage.completion_tokens);
    try testing.expectEqual(30, transformed.usage.total_tokens);
}

test "cleanupRequest is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const messages = [_]OpenAI.Message{
        .{
            .role = .user,
            .content = .{ .text = "Test" },
            .name = null,
            .tool_calls = null,
            .tool_call_id = null,
            .function_call = null,
        },
    };

    const request = OpenAI.Request{
        .model = "gpt-4",
        .messages = &messages,
        .stream = null,
        .temperature = null,
        .max_tokens = null,
        .top_p = null,
        .n = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .tools = null,
        .tool_choice = null,
        .functions = null,
        .function_call = null,
        .response_format = null,
        .stop = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
    };

    // Should not crash or cause issues
    cleanupRequest(request, allocator);
}

test "cleanupResponse frees model string" {
    const allocator = testing.allocator;

    const response_message = OpenAI.ResponseMessage{
        .role = .assistant,
        .content = "Test",
        .tool_calls = null,
        .function_call = null,
    };

    const choices = [_]OpenAI.ResponseChoice{
        .{
            .index = 0,
            .message = response_message,
            .finish_reason = "stop",
        },
    };

    const usage = OpenAI.Usage{
        .prompt_tokens = 5,
        .completion_tokens = 10,
        .total_tokens = 15,
    };

    // Allocate model string like transformResponse does
    const model_str = try allocator.dupe(u8, "openai/gpt-4");

    const response = OpenAI.Response{
        .id = "test-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = model_str,
        .choices = &choices,
        .usage = usage,
        .system_fingerprint = null,
        .service_tier = null,
    };

    // Should free the model string without leaking
    cleanupResponse(response, allocator);
}

test "transform handles minimal request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const messages = [_]OpenAI.Message{
        .{
            .role = .user,
            .content = .{ .text = "Hi" },
            .name = null,
            .tool_calls = null,
            .tool_call_id = null,
            .function_call = null,
        },
    };

    const minimal_request = OpenAI.Request{
        .model = "openai/gpt-4",
        .messages = &messages,
        .stream = null,
        .temperature = null,
        .max_tokens = null,
        .top_p = null,
        .n = null,
        .presence_penalty = null,
        .frequency_penalty = null,
        .tools = null,
        .tool_choice = null,
        .functions = null,
        .function_call = null,
        .response_format = null,
        .stop = null,
        .logit_bias = null,
        .user = null,
        .seed = null,
    };

    const transformed = try transform(minimal_request, "gpt-4", allocator);

    try testing.expectEqualStrings("gpt-4", transformed.model);
    try testing.expect(transformed.temperature == null);
    try testing.expect(transformed.max_tokens == null);
    try testing.expect(transformed.stream == null);
}