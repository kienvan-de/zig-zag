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
