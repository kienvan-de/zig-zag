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
const testing = std.testing;
const config_mod = @import("config.zig");
const log = @import("log.zig");



/// Supported provider types
pub const Provider = enum {
    anthropic,
    openai,
    sap_ai_core,
    hai,
    copilot,

    /// Parse provider name from string (case-insensitive)
    pub fn fromString(name: []const u8) !Provider {
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return error.InvalidProvider;

        const lower = std.ascii.lowerString(&buf, name);

        if (std.mem.eql(u8, lower, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, lower, "openai")) return .openai;
        if (std.mem.eql(u8, lower, "sap_ai_core")) return .sap_ai_core;
        if (std.mem.eql(u8, lower, "hai")) return .hai;
        if (std.mem.eql(u8, lower, "copilot")) return .copilot;

        return error.UnsupportedProvider;
    }
};

/// Provider-related errors — defined in errors.zig
pub const ProviderError = @import("errors.zig").ProviderError;

/// Check if provider is currently supported
pub fn isSupported(p: Provider) bool {
    return switch (p) {
        .anthropic => true,
        .openai => true,
        .sap_ai_core => true,
        .hai => true,
        .copilot => true,
    };
}

// ============================================================================
// Provider Initialization (placeholder)
// ============================================================================

/// Log configured providers at startup.
/// Authentication is lazy — each provider authenticates on first request.
pub fn logConfiguredProviders(cfg: *const config_mod.Config) void {
    const count = cfg.providers.count();
    if (count == 0) {
        log.info("No providers configured", .{});
        return;
    }

    var iter = cfg.providers.keyIterator();
    while (iter.next()) |key_ptr| {
        log.info("Provider configured: {s}", .{key_ptr.*});
    }

    log.info("{d} provider(s) configured (auth is lazy, on first request)", .{count});
}

// ============================================================================
// TESTS
// ============================================================================
