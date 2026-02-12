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
