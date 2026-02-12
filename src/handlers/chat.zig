//! Chat Completions Handler
//!
//! This module handles POST /v1/chat/completions requests and routes them to
//! appropriate LLM providers using comptime generics.
//!
//! ## Adding a New Provider
//!
//! 1. Create provider folder: `src/newprovider/`
//!    - `types.zig` - Provider-specific request/response schemas
//!    - `client.zig` - HTTP client with `init()`, `deinit()`, `sendRequest()`
//!    - `transformer.zig` - OpenAI ↔ Provider transformations
//!
//! 2. Implement required interfaces:
//!    - Client: `init(allocator, api_key)`, `deinit()`, `sendRequest(request)`
//!    - Transformer: `transform()`, `transformResponse()`, `cleanupRequest()`, `cleanupResponse()`
//!    - Types: `Request` and `Response` structs
//!
//! 3. Add provider import:
//!    ```zig
//!    const newprovider = struct {
//!        const types = @import("../newprovider/types.zig");
//!        const client = @import("../newprovider/client.zig");
//!        const transformer = @import("../newprovider/transformer.zig");
//!    };
//!    ```
//!
//! 4. Add case to switch statement:
//!    ```zig
//!    .newprovider => try handleProvider(
//!        newprovider.client.ClientType,
//!        newprovider.transformer,
//!        newprovider.types,
//!        allocator, connection, openai_request.value, model_info.model, api_key
//!    ),
//!    ```
//!
//! The comptime system will verify all interfaces at compile time!

const std = @import("std");
const OpenAI = @import("../providers/openai/types.zig");
const errors = @import("../errors.zig");
const http = @import("../http.zig");
const utils = @import("../utils.zig");
const provider = @import("../provider.zig");

// Provider modules
const anthropic = struct {
    const types = @import("../providers/anthropic/types.zig");
    const client = @import("../providers/anthropic/client.zig");
    const transformer = @import("../providers/anthropic/transformer.zig");
};

const openai = struct {
    const types = @import("../providers/openai/types.zig");
    const client = @import("../providers/openai/client.zig");
    const transformer = @import("../providers/openai/transformer.zig");
};

/// Handle POST /v1/chat/completions requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    body: []const u8,
    config: *const @import("../config.zig").Config,
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

    // Try to get provider config by name (allows any provider name, not just enum values)
    const provider_name = openai_request.value.model[0..std.mem.indexOf(u8, openai_request.value.model, "/").?];
    const provider_config = config.providers.getPtr(provider_name) orelse {
        const error_json = try errors.createErrorResponse(
            allocator,
            "Provider not configured",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };

    // Check if this is a native provider or a compatible one
    if (provider.isSupported(model_info.provider)) {
        // Native provider - use its own client/transformer
        switch (model_info.provider) {
            .anthropic => {
                try handleProvider(
                    anthropic.client.AnthropicClient,
                    anthropic.transformer,
                    anthropic.types,
                    allocator,
                    connection,
                    openai_request.value,
                    model_info.model,
                    provider_config,
                );
            },
            .openai => {
                try handleProvider(
                    openai.client.OpenAIClient,
                    openai.transformer,
                    openai.types,
                    allocator,
                    connection,
                    openai_request.value,
                    model_info.model,
                    provider_config,
                );
            },
        }
    } else {
        // Not a native provider - check for "compatible" field
        const compatible = provider_config.getString("compatible") orelse {
            const error_json = try errors.createErrorResponse(
                allocator,
                "Provider not supported and no 'compatible' field specified",
                .invalid_request_error,
                null,
            );
            defer allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
        };

        // Route based on compatibility
        if (std.mem.eql(u8, compatible, "openai")) {
            try handleProvider(
                openai.client.OpenAIClient,
                openai.transformer,
                openai.types,
                allocator,
                connection,
                openai_request.value,
                model_info.model,
                provider_config,
            );
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            try handleProvider(
                anthropic.client.AnthropicClient,
                anthropic.transformer,
                anthropic.types,
                allocator,
                connection,
                openai_request.value,
                model_info.model,
                provider_config,
            );
        } else {
            const error_json = try errors.createErrorResponse(
                allocator,
                "Unknown compatible provider type. Must be 'openai' or 'anthropic'",
                .invalid_request_error,
                null,
            );
            defer allocator.free(error_json);
            try http.sendJsonResponse(connection, .bad_request, error_json);
            return;
        }
    }
}

/// Generic provider handler using comptime duck typing
///
/// **How Interface Checking Works:**
/// - No explicit interface definition needed (unlike Java/Go)
/// - Compiler checks methods when they're called
/// - If method missing or wrong signature = COMPILE ERROR
/// - Zero runtime overhead - all checks at compile time
///
/// **Required Interface (enforced by compiler when used):**
///
/// Client type must have:
///   - `init(allocator: Allocator, api_key: []const u8) Client`
///   - `deinit(self: *Client) void`
///   - `sendRequest(self: *Client, request: anytype) !std.json.Parsed(Types.Response)`
///
/// Transformer module must have:
///   - `transform(request: OpenAI.Request, model: []const u8, allocator: Allocator) !ProviderRequest`
///   - `transformResponse(response: ProviderResponse, allocator: Allocator) !OpenAI.Response`
///   - `cleanupRequest(request: ProviderRequest, allocator: Allocator) void`
///   - `cleanupResponse(response: OpenAI.Response, allocator: Allocator) void`
///
/// Types module must have:
///   - `Request: type`
///   - `Response: type`
///
/// **Example of what happens if interface violated:**
/// ```zig
/// // Missing transform() function
/// const BadTransformer = struct {};
/// handleProvider(Client, BadTransformer, Types, ...) 
/// // ❌ Compile Error: container 'BadTransformer' has no member named 'transform'
///
/// // Wrong signature
/// const BadTransformer2 = struct {
///     pub fn transform(x: i32) void {}  // Wrong params!
/// };
/// handleProvider(Client, BadTransformer2, Types, ...)
/// // ❌ Compile Error: expected 3 arguments, found 1
/// ```
///
/// **Key Point:** The compiler discovers the interface requirements by analyzing
/// the function body. When it sees `Transformer.transform(...)`, it checks if
/// that function exists with the correct signature. No pre-declaration needed!
fn handleProvider(
    comptime Client: type,
    comptime Transformer: type,
    comptime _: type,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    openai_request: OpenAI.Request,
    model: []const u8,
    provider_config: *const @import("../config.zig").ProviderConfig,
) !void {
    // Transform OpenAI request to provider format
    const provider_request = Transformer.transform(
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
    defer Transformer.cleanupRequest(provider_request, allocator);

    // Initialize client and send request
    var client = Client.init(allocator, provider_config) catch |err| {
        std.debug.print("Client initialization error: {}\n", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Failed to initialize provider client",
            .invalid_request_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_request, error_json);
        return;
    };
    defer client.deinit();

    const provider_response = client.sendRequest(provider_request) catch |err| {
        std.debug.print("Provider API error: {}\n", .{err});
        const error_json = try errors.createErrorFromStatus(
            allocator,
            .bad_gateway,
            "Failed to communicate with upstream API",
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_gateway, error_json);
        return;
    };
    defer provider_response.deinit();

    // Transform provider response back to OpenAI format
    const openai_response = try Transformer.transformResponse(
        provider_response.value,
        allocator,
        openai_request.model,
    );
    defer Transformer.cleanupResponse(openai_response, allocator);

    // Serialize OpenAI response
    var response_buffer = std.ArrayList(u8){};
    defer response_buffer.deinit(allocator);
    try response_buffer.writer(allocator).print("{f}", .{std.json.fmt(openai_response, .{})});

    // Send response
    try http.sendJsonResponse(connection, .ok, response_buffer.items);
}