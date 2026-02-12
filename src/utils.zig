const std = @import("std");

/// Parsed model information
pub const ModelInfo = struct {
    provider: []const u8,
    model: []const u8,
};

/// Model parsing errors
pub const ModelParseError = error{
    InvalidModelFormat,
    EmptyProvider,
    EmptyModel,
    OutOfMemory,
};

/// Parse model string in format "provider/model-name"
/// Examples:
///   "anthropic/claude-3-5-sonnet-latest" -> { .provider = .anthropic, .model = "claude-3-5-sonnet-latest" }
///   "openai/gpt-4" -> { .provider = .openai, .model = "gpt-4" }
///   "anthropic/models/claude" -> { .provider = .anthropic, .model = "models/claude" }
///
/// Caller is responsible for freeing model_info.model using the same allocator
pub fn parseModelString(model_str: []const u8, allocator: std.mem.Allocator) !ModelInfo {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, model_str, " \t\n\r");

    if (trimmed.len == 0) return error.InvalidModelFormat;

    // Find first slash
    const slash_idx = std.mem.indexOfScalar(u8, trimmed, '/') orelse return error.InvalidModelFormat;

    // Extract provider and model parts
    const provider_str = std.mem.trim(u8, trimmed[0..slash_idx], " \t\n\r");
    const model_part = std.mem.trim(u8, trimmed[slash_idx + 1 ..], " \t\n\r");

    if (provider_str.len == 0) return error.EmptyProvider;
    if (model_part.len == 0) return error.EmptyModel;

    // Allocate and copy provider name
    const provider_name = try allocator.dupe(u8, provider_str);

    // Allocate and copy model name
    const model_name = try allocator.dupe(u8, model_part);

    return ModelInfo{
        .provider = provider_name,
        .model = model_name,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "parseModelString: valid anthropic model" {
    const allocator = testing.allocator;

    const result = try parseModelString("anthropic/claude-3-5-sonnet-latest", allocator);
    defer allocator.free(result.model);
    defer allocator.free(result.provider);

    try testing.expectEqualStrings("anthropic", result.provider);
    try testing.expectEqualStrings("claude-3-5-sonnet-latest", result.model);
}

test "parseModelString: valid anthropic opus model" {
    const allocator = testing.allocator;

    const result = try parseModelString("anthropic/claude-3-opus-20240229", allocator);
    defer allocator.free(result.model);
    defer allocator.free(result.provider);

    try testing.expectEqualStrings("anthropic", result.provider);
    try testing.expectEqualStrings("claude-3-opus-20240229", result.model);
}

test "parseModelString: valid openai model" {
    const allocator = testing.allocator;

    const result = try parseModelString("openai/gpt-4", allocator);
    defer allocator.free(result.model);
    defer allocator.free(result.provider);

    try testing.expectEqualStrings("openai", result.provider);
    try testing.expectEqualStrings("gpt-4", result.model);
}

test "parseModelString: multiple slashes in model name" {
    const allocator = testing.allocator;

    const result = try parseModelString("anthropic/models/claude-3-5-sonnet", allocator);
    defer allocator.free(result.model);
    defer allocator.free(result.provider);

    try testing.expectEqualStrings("anthropic", result.provider);
    try testing.expectEqualStrings("models/claude-3-5-sonnet", result.model);
}

test "parseModelString: provider case is preserved" {
    const allocator = testing.allocator;

    {
        const result = try parseModelString("Anthropic/claude-3-5-sonnet", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("Anthropic", result.provider);
        try testing.expectEqualStrings("claude-3-5-sonnet", result.model);
    }

    {
        const result = try parseModelString("ANTHROPIC/claude-3-opus", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("ANTHROPIC", result.provider);
        try testing.expectEqualStrings("claude-3-opus", result.model);
    }

    {
        const result = try parseModelString("OpenAI/gpt-4", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("OpenAI", result.provider);
        try testing.expectEqualStrings("gpt-4", result.model);
    }
}

test "parseModelString: model name case is preserved" {
    const allocator = testing.allocator;

    const result = try parseModelString("anthropic/CLAUDE-3-OPUS", allocator);
    defer allocator.free(result.model);
    defer allocator.free(result.provider);

    try testing.expectEqualStrings("anthropic", result.provider);
    try testing.expectEqualStrings("CLAUDE-3-OPUS", result.model);
}

test "parseModelString: whitespace trimming" {
    const allocator = testing.allocator;

    {
        const result = try parseModelString("  anthropic/claude-3-5-sonnet  ", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("anthropic", result.provider);
        try testing.expectEqualStrings("claude-3-5-sonnet", result.model);
    }

    {
        const result = try parseModelString(" anthropic / claude-3-opus ", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("anthropic", result.provider);
        try testing.expectEqualStrings("claude-3-opus", result.model);
    }

    {
        const result = try parseModelString("\tanthropic\t/\tclaude\t", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("anthropic", result.provider);
        try testing.expectEqualStrings("claude", result.model);
    }
}

test "parseModelString: missing slash" {
    const allocator = testing.allocator;

    const result = parseModelString("claude-3-5-sonnet-latest", allocator);
    try testing.expectError(error.InvalidModelFormat, result);
}

test "parseModelString: empty provider" {
    const allocator = testing.allocator;

    const result = parseModelString("/claude-3-5-sonnet", allocator);
    try testing.expectError(error.EmptyProvider, result);
}

test "parseModelString: empty provider with whitespace" {
    const allocator = testing.allocator;

    const result = parseModelString("  /claude-3-5-sonnet", allocator);
    try testing.expectError(error.EmptyProvider, result);
}

test "parseModelString: empty model" {
    const allocator = testing.allocator;

    const result = parseModelString("anthropic/", allocator);
    try testing.expectError(error.EmptyModel, result);
}

test "parseModelString: empty model with whitespace" {
    const allocator = testing.allocator;

    const result = parseModelString("anthropic/  ", allocator);
    try testing.expectError(error.EmptyModel, result);
}

test "parseModelString: only slash" {
    const allocator = testing.allocator;

    const result = parseModelString("/", allocator);
    try testing.expectError(error.EmptyProvider, result);
}

test "parseModelString: empty string" {
    const allocator = testing.allocator;

    const result = parseModelString("", allocator);
    try testing.expectError(error.InvalidModelFormat, result);
}

test "parseModelString: whitespace only" {
    const allocator = testing.allocator;

    const result = parseModelString("   ", allocator);
    try testing.expectError(error.InvalidModelFormat, result);
}

test "parseModelString: any provider is accepted" {
    const allocator = testing.allocator;

    {
        const result = try parseModelString("google/gemini-pro", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("google", result.provider);
        try testing.expectEqualStrings("gemini-pro", result.model);
    }

    {
        const result = try parseModelString("mistral/mistral-large", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("mistral", result.provider);
        try testing.expectEqualStrings("mistral-large", result.model);
    }

    {
        const result = try parseModelString("custom-provider/model", allocator);
        defer allocator.free(result.model);
        defer allocator.free(result.provider);
        try testing.expectEqualStrings("custom-provider", result.provider);
        try testing.expectEqualStrings("model", result.model);
    }
}