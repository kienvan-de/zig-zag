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

/// Provider-related errors
pub const ProviderError = error{
    UnsupportedProvider,
    InvalidProvider,
};

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