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

// Provider clients
const HaiClient = @import("providers/hai/client.zig").HaiClient;
const SapAiCoreClient = @import("providers/sap_ai_core/client.zig").SapAiCoreClient;
const CopilotClient = @import("providers/copilot/client.zig").CopilotClient;

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
// Provider Initialization
// ============================================================================

/// Result of provider initialization
pub const InitResult = struct {
    succeeded: u32,
    failed: u32,
    total: u32,
};

/// Initialize all configured providers (sequential)
/// For HAI/SAP AI Core: calls getAccessToken() to trigger auth
/// For OpenAI/Anthropic: just logs (API key auth, no init needed)
/// For compatible providers: just logs
/// Returns count of succeeded/failed providers
pub fn initProviders(allocator: std.mem.Allocator, cfg: *const config_mod.Config) InitResult {
    var result = InitResult{ .succeeded = 0, .failed = 0, .total = 0 };

    var iter = cfg.providers.iterator();
    while (iter.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const provider_config = entry.value_ptr;
        result.total += 1;

        // Try init, log error but continue to next provider
        initProvider(allocator, provider_name, provider_config) catch |err| {
            log.err("Provider '{s}' initialization failed: {}", .{ provider_name, err });
            result.failed += 1;
            continue;
        };

        result.succeeded += 1;
    }

    return result;
}

/// Initialize a single provider
fn initProvider(
    allocator: std.mem.Allocator,
    name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !void {
    const p = Provider.fromString(name) catch {
        // Not a native provider, check compatible field
        if (provider_config.getString("compatible")) |compatible| {
            log.info("Provider '{s}' (compatible with {s}) - no init required", .{ name, compatible });
            return;
        }
        log.warn("Provider '{s}' - unknown provider type, skipping init", .{name});
        return error.UnsupportedProvider;
    };

    switch (p) {
        .hai => {
            log.info("Initializing provider 'hai' (OIDC auth)...", .{});
            var client = try HaiClient.init(allocator, provider_config);
            defer client.deinit();

            // getAccessToken triggers browser auth if needed
            const token = try client.getAccessToken();
            allocator.free(token);

            log.info("Provider 'hai' initialized successfully", .{});
        },
        .sap_ai_core => {
            log.info("Initializing provider 'sap_ai_core' (client credentials)...", .{});
            var client = try SapAiCoreClient.init(allocator, provider_config);
            defer client.deinit();

            // getAccessToken fetches token via client_credentials
            const token = try client.getAccessToken();
            allocator.free(token);

            log.info("Provider 'sap_ai_core' initialized successfully", .{});
        },
        .openai => {
            log.info("Provider 'openai' - no init required (API key auth)", .{});
        },
        .copilot => {
            log.info("Initializing provider 'copilot' (GitHub OAuth + token exchange)...", .{});
            var client = try CopilotClient.init(allocator, provider_config);
            defer client.deinit();

            // getAccessToken validates the full token chain:
            // apps.json → token endpoint → api_base
            const token = try client.getAccessToken();
            allocator.free(token);

            log.info("Provider 'copilot' initialized successfully", .{});
        },
        .anthropic => {
            log.info("Provider 'anthropic' - no init required (API key auth)", .{});
        },
    }
}

// ============================================================================
// TESTS
// ============================================================================
