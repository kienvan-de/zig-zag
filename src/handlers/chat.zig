const std = @import("std");
const OpenAI = @import("../providers/openai.zig");
const Anthropic = @import("../providers/anthropic.zig");
const AnthropicClient = @import("../clients/anthropic.zig").AnthropicClient;
const anthropic_transformer = @import("../transformers/anthropic.zig");
const errors = @import("../errors.zig");
const http = @import("../http.zig");
const utils = @import("../utils.zig");
const provider = @import("../providers/provider.zig");

/// Handle POST /v1/chat/completions requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    body: []const u8,
    api_key: []const u8,
) !void {
    // Parse OpenAI request
    const openai_request = std.json.parseFromSlice(
        OpenAI.Request,
        allocator,
        body,
        .{},
    ) catch |err| {
        std.debug.print("JSON parse error: {}\n", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Invalid JSON in request body",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer openai_request.deinit();

    // Check if streaming (Phase 5)
    if (openai_request.value.stream orelse false) {
        const error_json = try errors.createErrorResponse(
            allocator,
            "Streaming not yet supported (Phase 5)",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    }

    // Parse model string to extract provider
    const model_info = utils.parseModelString(openai_request.value.model, allocator) catch |err| {
        std.debug.print("Model parsing error: {}\n", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Invalid model format. Expected 'provider/model-name' (e.g., 'anthropic/claude-3-5-sonnet-latest')",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer allocator.free(model_info.model);

    // Check if provider is supported
    if (!provider.isSupported(model_info.provider)) {
        const error_json = try errors.createErrorResponse(
            allocator,
            "Provider not yet supported",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    }

    // Route to appropriate provider
    switch (model_info.provider) {
        .anthropic => {
            try handleAnthropic(allocator, connection, openai_request.value, model_info.model, api_key);
        },
        .openai => {
            const error_json = try errors.createErrorResponse(
                allocator,
                "OpenAI provider not yet implemented",
                .invalid_request_error,
                null,
            );
            defer allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
        },
    }
}

/// Handle Anthropic provider requests
fn handleAnthropic(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    openai_request: OpenAI.Request,
    model: []const u8,
    api_key: []const u8,
) !void {
    // Transform to Anthropic request
    const anthropic_request = anthropic_transformer.transform(
        openai_request,
        model,
        allocator,
    ) catch |err| {
        std.debug.print("Transformation error: {}\n", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Failed to transform request",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer {
        if (anthropic_request.system) |s| allocator.free(s);
        for (anthropic_request.messages) |msg| {
            switch (msg.content) {
                .text => {},
                .blocks => |blocks| allocator.free(blocks),
            }
        }
        allocator.free(anthropic_request.messages);
    }

    // Send to Anthropic
    var client = AnthropicClient.init(allocator, api_key);
    defer client.deinit();

    const anthropic_response_json = client.sendRequest(anthropic_request) catch |err| {
        std.debug.print("Anthropic API error: {}\n", .{err});
        const error_json = try errors.createErrorFromStatus(
            allocator,
            .bad_gateway,
            "Failed to communicate with upstream API",
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_gateway, error_json);
        return;
    };
    defer allocator.free(anthropic_response_json);

    // Parse Anthropic response
    const anthropic_response = std.json.parseFromSlice(
        Anthropic.Response,
        allocator,
        anthropic_response_json,
        .{},
    ) catch |err| {
        std.debug.print("Anthropic response parse error: {}\n", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Invalid response from upstream API",
            .server_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .internal_server_error, error_json);
        return;
    };
    defer anthropic_response.deinit();

    // Transform back to OpenAI format
    const openai_response = try anthropic_transformer.transformResponse(
        anthropic_response.value,
        allocator,
    );
    defer {
        if (openai_response.choices[0].message.content) |content| {
            allocator.free(content);
        }
        allocator.free(openai_response.choices);
    }

    // Serialize OpenAI response
    var response_buffer = std.ArrayList(u8){};
    defer response_buffer.deinit(allocator);
    try response_buffer.writer(allocator).print("{any}", .{std.json.fmt(openai_response, .{})});

    // Send response
    try http.sendJsonResponse(connection, .ok, response_buffer.items);
}