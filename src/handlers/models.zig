//! Models Handler
//!
//! This module handles GET /v1/models requests and aggregates models from all
//! configured providers.

const std = @import("std");
const http = @import("../http.zig");
const errors = @import("../errors.zig");
const config_mod = @import("../config.zig");
const OpenAI = @import("../providers/openai/types.zig");

// Provider clients
const openai_client = @import("../providers/openai/client.zig");

/// Model object in OpenAI format
pub const Model = struct {
    id: []const u8,
    object: []const u8 = "model",
    created: i64,
    owned_by: []const u8,
};

/// Response for GET /v1/models
pub const ModelsResponse = struct {
    object: []const u8 = "list",
    data: []const Model,
};

/// Handle GET /v1/models request
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = body; // GET request, no body needed

    var all_models = std.ArrayList(Model){};
    defer all_models.deinit(allocator);

    // Iterate all configured providers
    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const provider_config = entry.value_ptr;

        // Get provider type
        const provider_type_str = provider_config.getString("type") orelse continue;

        // Only handle OpenAI-compatible providers for now
        if (std.mem.eql(u8, provider_type_str, "openai") or
            std.mem.eql(u8, provider_type_str, "groq"))
        {
            // Fetch models from this provider
            const models = fetchOpenAIModels(allocator, provider_name, provider_config) catch |err| {
                std.debug.print("Failed to fetch models from {s}: {}\n", .{ provider_name, err });
                continue;
            };
            defer allocator.free(models);

            // Add to aggregated list
            for (models) |model| {
                try all_models.append(allocator, model);
            }
        }
    }

    // Build response
    const response = ModelsResponse{
        .data = all_models.items,
    };

    // Serialize to JSON
    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);

    try json_buf.writer(allocator).print("{f}", .{std.json.fmt(response, .{})});

    // Send response
    try http.sendJsonResponse(connection, .ok, json_buf.items);
}

/// Fetch models from an OpenAI-compatible provider
fn fetchOpenAIModels(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) ![]Model {
    var client = try openai_client.OpenAIClient.init(allocator, provider_config);
    defer client.deinit();

    // Build URL
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "{s}/v1/models", .{client.api_url});
    const uri = try std.Uri.parse(url);

    // Build Authorization header
    var auth_buffer: [512]u8 = undefined;
    const auth_value = try std.fmt.bufPrint(&auth_buffer, "Bearer {s}", .{client.api_key});

    var extra_headers_buf: [2]std.http.Header = undefined;
    var extra_headers_count: usize = 1;
    extra_headers_buf[0] = .{ .name = "Authorization", .value = auth_value };

    if (client.organization) |org| {
        extra_headers_buf[1] = .{ .name = "OpenAI-Organization", .value = org };
        extra_headers_count = 2;
    }

    const extra_headers = extra_headers_buf[0..extra_headers_count];

    // Make GET request
    var req = try client.client.request(.GET, uri, .{
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    // Send request (no body for GET)
    var buf: [4096]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&buf);
    try body_writer.end();
    try req.connection.?.flush();

    // Receive response
    const redirect_buffer: [0]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        return error.UpstreamError;
    }

    // Read response body
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const response_body = try reader.allocRemaining(allocator, std.io.Limit.limited(client.max_response_size));
    defer allocator.free(response_body);

    // Parse response
    const parsed = try std.json.parseFromSlice(
        struct {
            object: []const u8,
            data: []const struct {
                id: []const u8,
                object: []const u8 = "model",
                created: i64 = 0,
                owned_by: []const u8 = "unknown",
            },
        },
        allocator,
        response_body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Transform models with provider prefix
    var models = try allocator.alloc(Model, parsed.value.data.len);
    errdefer allocator.free(models);

    for (parsed.value.data, 0..) |upstream_model, i| {
        // Create prefixed model ID: {provider_name}/{model_id}
        const prefixed_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, upstream_model.id });

        models[i] = Model{
            .id = prefixed_id,
            .object = "model",
            .created = upstream_model.created,
            .owned_by = try allocator.dupe(u8, upstream_model.owned_by),
        };
    }

    return models;
}