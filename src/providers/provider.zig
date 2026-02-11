const std = @import("std");
const testing = std.testing;

/// Supported provider types
pub const Provider = enum {
    anthropic,
    openai,

    /// Parse provider name from string (case-insensitive)
    pub fn fromString(name: []const u8) !Provider {
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return error.InvalidProvider;
        
        const lower = std.ascii.lowerString(&buf, name);
        
        if (std.mem.eql(u8, lower, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, lower, "openai")) return .openai;
        
        return error.UnsupportedProvider;
    }
};

/// Parsed model information
pub const ModelInfo = struct {
    provider: Provider,
    model: []const u8,
};

/// Provider-related errors
pub const ProviderError = error{
    InvalidModelFormat,
    UnsupportedProvider,
    EmptyProvider,
    EmptyModel,
    InvalidProvider,
    OutOfMemory,
};

/// Parse model string in format "provider/model-name"
/// Examples:
///   "anthropic/claude-3-5-sonnet-latest" -> { .provider = .anthropic, .model = "claude-3-5-sonnet-latest" }
///   "openai/gpt-4" -> { .provider = .openai, .model = "gpt-4" }
///   "anthropic/models/claude" -> { .provider = .anthropic, .model = "models/claude" }
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
    
    // Parse provider
    const provider = Provider.fromString(provider_str) catch |err| {
        return err;
    };
    
    // Allocate and copy model name
    const model_name = try allocator.dupe(u8, model_part);
    
    return ModelInfo{
        .provider = provider,
        .model = model_name,
    };
}

/// Check if provider is currently supported
pub fn isSupported(provider: Provider) bool {
    return switch (provider) {
        .anthropic => true,
        .openai => false, // Not yet implemented
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "parseModelString: valid anthropic model" {
    const allocator = testing.allocator;
    
    const result = try parseModelString("anthropic/claude-3-5-sonnet-latest", allocator);
    defer allocator.free(result.model);
    
    try testing.expectEqual(Provider.anthropic, result.provider);
    try testing.expectEqualStrings("claude-3-5-sonnet-latest", result.model);
}

test "parseModelString: valid anthropic opus model" {
    const allocator = testing.allocator;
    
    const result = try parseModelString("anthropic/claude-3-opus-20240229", allocator);
    defer allocator.free(result.model);
    
    try testing.expectEqual(Provider.anthropic, result.provider);
    try testing.expectEqualStrings("claude-3-opus-20240229", result.model);
}

test "parseModelString: valid openai model" {
    const allocator = testing.allocator;
    
    const result = try parseModelString("openai/gpt-4", allocator);
    defer allocator.free(result.model);
    
    try testing.expectEqual(Provider.openai, result.provider);
    try testing.expectEqualStrings("gpt-4", result.model);
}

test "parseModelString: multiple slashes in model name" {
    const allocator = testing.allocator;
    
    const result = try parseModelString("anthropic/models/claude-3-5-sonnet", allocator);
    defer allocator.free(result.model);
    
    try testing.expectEqual(Provider.anthropic, result.provider);
    try testing.expectEqualStrings("models/claude-3-5-sonnet", result.model);
}

test "parseModelString: case insensitive provider" {
    const allocator = testing.allocator;
    
    {
        const result = try parseModelString("Anthropic/claude-3-5-sonnet", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.anthropic, result.provider);
        try testing.expectEqualStrings("claude-3-5-sonnet", result.model);
    }
    
    {
        const result = try parseModelString("ANTHROPIC/claude-3-opus", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.anthropic, result.provider);
        try testing.expectEqualStrings("claude-3-opus", result.model);
    }
    
    {
        const result = try parseModelString("OpenAI/gpt-4", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.openai, result.provider);
        try testing.expectEqualStrings("gpt-4", result.model);
    }
}

test "parseModelString: model name case is preserved" {
    const allocator = testing.allocator;
    
    const result = try parseModelString("anthropic/CLAUDE-3-OPUS", allocator);
    defer allocator.free(result.model);
    
    try testing.expectEqual(Provider.anthropic, result.provider);
    try testing.expectEqualStrings("CLAUDE-3-OPUS", result.model);
}

test "parseModelString: whitespace trimming" {
    const allocator = testing.allocator;
    
    {
        const result = try parseModelString("  anthropic/claude-3-5-sonnet  ", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.anthropic, result.provider);
        try testing.expectEqualStrings("claude-3-5-sonnet", result.model);
    }
    
    {
        const result = try parseModelString(" anthropic / claude-3-opus ", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.anthropic, result.provider);
        try testing.expectEqualStrings("claude-3-opus", result.model);
    }
    
    {
        const result = try parseModelString("\tanthropic\t/\tclaude\t", allocator);
        defer allocator.free(result.model);
        try testing.expectEqual(Provider.anthropic, result.provider);
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

test "parseModelString: unsupported provider google" {
    const allocator = testing.allocator;
    
    const result = parseModelString("google/gemini-pro", allocator);
    try testing.expectError(error.UnsupportedProvider, result);
}

test "parseModelString: unsupported provider mistral" {
    const allocator = testing.allocator;
    
    const result = parseModelString("mistral/mistral-large", allocator);
    try testing.expectError(error.UnsupportedProvider, result);
}

test "parseModelString: invalid provider name" {
    const allocator = testing.allocator;
    
    const result = parseModelString("invalid-provider/model", allocator);
    try testing.expectError(error.UnsupportedProvider, result);
}

test "isSupported: anthropic is supported" {
    try testing.expect(isSupported(.anthropic));
}

test "isSupported: openai not yet supported" {
    try testing.expect(!isSupported(.openai));
}

test "Provider.fromString: valid providers" {
    try testing.expectEqual(Provider.anthropic, try Provider.fromString("anthropic"));
    try testing.expectEqual(Provider.anthropic, try Provider.fromString("Anthropic"));
    try testing.expectEqual(Provider.anthropic, try Provider.fromString("ANTHROPIC"));
    
    try testing.expectEqual(Provider.openai, try Provider.fromString("openai"));
    try testing.expectEqual(Provider.openai, try Provider.fromString("OpenAI"));
    try testing.expectEqual(Provider.openai, try Provider.fromString("OPENAI"));
}

test "Provider.fromString: invalid provider" {
    try testing.expectError(error.UnsupportedProvider, Provider.fromString("google"));
    try testing.expectError(error.UnsupportedProvider, Provider.fromString("invalid"));
    try testing.expectError(error.UnsupportedProvider, Provider.fromString(""));
}