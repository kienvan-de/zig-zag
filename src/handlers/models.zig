//! Models Handler
//!
//! This module handles GET /v1/models requests and aggregates models from all
//! configured providers using comptime generics.

const std = @import("std");
const http = @import("../http.zig");
const errors = @import("../errors.zig");
const config_mod = @import("../config.zig");
const OpenAI = @import("../providers/openai/types.zig");
const provider_mod = @import("../provider.zig");

// Provider modules
const openai = struct {
    const client = @import("../providers/openai/client.zig");
    const transformer = @import("../providers/openai/transformer.zig");
};

const anthropic = struct {
    const client = @import("../providers/anthropic/client.zig");
    const transformer = @import("../providers/anthropic/transformer.zig");
};

const sap_ai_core = struct {
    const client = @import("../providers/sap_ai_core/client.zig");
    const transformer = @import("../providers/sap_ai_core/transformer.zig");
};

/// Handle GET /v1/models request
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = body; // GET request, no body needed

    var all_models = std.ArrayList(OpenAI.Model){};
    defer all_models.deinit(allocator);

    // Iterate all configured providers
    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const provider_config = entry.value_ptr;

        // Try to fetch models from this provider
        const models = fetchModelsForProvider(allocator, provider_name, provider_config) catch |err| {
            std.debug.print("Failed to fetch models from {s}: {}\n", .{ provider_name, err });
            continue;
        };

        if (models) |model_list| {
            defer allocator.free(model_list);

            // Add to aggregated list
            for (model_list) |model| {
                try all_models.append(allocator, model);
            }
        }
    }

    // Build response
    const response = OpenAI.ModelsResponse{
        .data = all_models.items,
    };

    // Serialize to JSON
    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);

    try json_buf.writer(allocator).print("{f}", .{std.json.fmt(response, .{})});

    // Send response
    try http.sendJsonResponse(connection, .ok, json_buf.items);
}

/// Fetch models for a provider based on its type or compatibility
fn fetchModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]OpenAI.Model {
    // Get provider type
    const provider_type_str = provider_config.getString("type") orelse return null;

    // Check if this is a native provider
    if (provider_mod.Provider.fromString(provider_type_str)) |native_provider| {
        return switch (native_provider) {
            .openai => try fetchModels(
                openai.client.OpenAIClient,
                openai.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .anthropic => try fetchModels(
                anthropic.client.AnthropicClient,
                anthropic.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .sap_ai_core => try fetchModels(
                sap_ai_core.client.SapAiCoreClient,
                sap_ai_core.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
        };
    } else |_| {
        // Not a native provider - check for "compatible" field
        const compatible = provider_config.getString("compatible") orelse return null;

        if (std.mem.eql(u8, compatible, "openai")) {
            return try fetchModels(
                openai.client.OpenAIClient,
                openai.transformer,
                allocator,
                provider_name,
                provider_config,
            );
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            return try fetchModels(
                anthropic.client.AnthropicClient,
                anthropic.transformer,
                allocator,
                provider_name,
                provider_config,
            );
        }

        return null;
    }
}

/// Generic function to fetch models using comptime client and transformer
fn fetchModels(
    comptime ClientType: type,
    comptime transformer: type,
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]OpenAI.Model {
    var client = try ClientType.init(allocator, provider_config);
    defer client.deinit();

    // Call listModels on the client
    const response = try client.listModels();

    // Handle null response (provider doesn't support models listing)
    if (@TypeOf(response) == ?void) {
        return null;
    }

    // For optional responses that are null
    if (@typeInfo(@TypeOf(response)) == .optional) {
        if (response == null) {
            return null;
        }
    }

    // Transform to OpenAI models with provider prefix
    defer {
        // Deinit parsed response if it has a deinit method
        if (@TypeOf(response) == std.json.Parsed(openai.client.ModelsResponse)) {
            var r = response;
            r.deinit();
        }
    }

    return try transformer.transformModelsResponse(allocator, response, provider_name);
}