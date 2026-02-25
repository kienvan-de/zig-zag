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
const log = @import("../log.zig");

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

const sap_ai_core = struct {
    const types = @import("../providers/sap_ai_core/types.zig");
    const client = @import("../providers/sap_ai_core/client.zig");
    const transformer = @import("../providers/sap_ai_core/transformer.zig");
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
        log.err("JSON parse error: {}", .{err});
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

    // Check if streaming
    const is_streaming = openai_request.value.stream orelse false;

    // Parse model string to extract provider
    const model_info = utils.parseModelString(openai_request.value.model, allocator) catch |err| {
        log.err("Model parsing error: {} for model '{s}'", .{ err, openai_request.value.model });
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

    defer allocator.free(model_info.provider);

    // Try to get provider config by name (allows any provider name, not just enum values)
    const provider_config = config.providers.getPtr(model_info.provider) orelse {
        log.err("Provider not configured: '{s}'", .{model_info.provider});
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

    // Check if this is a native provider
    if (provider.Provider.fromString(model_info.provider)) |native_provider| {
        // Native provider - route based on enum
        switch (native_provider) {
            .anthropic => {
                if (is_streaming) {
                    try handleProviderStreaming(
                        anthropic.client.AnthropicClient,
                        anthropic.transformer,
                        allocator,
                        connection,
                        openai_request.value,
                        model_info.model,
                        provider_config,
                    );
                } else {
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
                }
            },
            .openai => {
                if (is_streaming) {
                    try handleProviderStreaming(
                        openai.client.OpenAIClient,
                        openai.transformer,
                        allocator,
                        connection,
                        openai_request.value,
                        model_info.model,
                        provider_config,
                    );
                } else {
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
                }
            },
            .sap_ai_core => {
                if (is_streaming) {
                    try handleProviderStreaming(
                        sap_ai_core.client.SapAiCoreClient,
                        sap_ai_core.transformer,
                        allocator,
                        connection,
                        openai_request.value,
                        model_info.model,
                        provider_config,
                    );
                } else {
                    try handleProvider(
                        sap_ai_core.client.SapAiCoreClient,
                        sap_ai_core.transformer,
                        sap_ai_core.types,
                        allocator,
                        connection,
                        openai_request.value,
                        model_info.model,
                        provider_config,
                    );
                }
            },
        }
    } else |_| {
        // Not a native provider - check for "compatible" field
        const compatible = provider_config.getString("compatible") orelse {
            log.err("Provider '{s}' not supported and no 'compatible' field specified", .{model_info.provider});
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
            if (is_streaming) {
                try handleProviderStreaming(
                    openai.client.OpenAIClient,
                    openai.transformer,
                    allocator,
                    connection,
                    openai_request.value,
                    model_info.model,
                    provider_config,
                );
            } else {
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
            }
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            if (is_streaming) {
                try handleProviderStreaming(
                    anthropic.client.AnthropicClient,
                    anthropic.transformer,
                    allocator,
                    connection,
                    openai_request.value,
                    model_info.model,
                    provider_config,
                );
            } else {
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
            }
        } else {
            log.err("Unknown compatible provider type: '{s}'. Must be 'openai' or 'anthropic'", .{compatible});
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

/// Generic streaming provider handler
fn handleProviderStreaming(
    comptime Client: type,
    comptime Transformer: type,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    openai_request: OpenAI.Request,
    model: []const u8,
    provider_config: *const @import("../config.zig").ProviderConfig,
) !void {
    const start_time = std.time.milliTimestamp();
    log.info("[STREAM] POST /v1/chat/completions - request received for model '{s}'", .{openai_request.model});

    // Transform OpenAI request to provider format
    const transform_start = std.time.milliTimestamp();
    const provider_request = Transformer.transform(
        openai_request,
        model,
        allocator,
    ) catch |err| {
        log.err("[STREAM] Transform request error: {} for model '{s}'", .{ err, openai_request.model });
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
    const transform_time = std.time.milliTimestamp() - transform_start;
    log.debug("[STREAM] Transform request completed in {d}ms", .{transform_time});

    // Initialize client
    const client_init_start = std.time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[STREAM] Client initialization error: {} for model '{s}'", .{ err, openai_request.model });
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
    const client_init_time = std.time.milliTimestamp() - client_init_start;
    log.debug("[STREAM] Client init completed in {d}ms", .{client_init_time});

    // Start streaming request and get iterator
    const stream_connect_start = std.time.milliTimestamp();
    const stream_result = client.sendStreamingRequest(provider_request) catch |err| {
        log.err("[STREAM] Provider streaming error: {} for model '{s}'", .{ err, openai_request.model });
        const error_json = try errors.createErrorResponse(
            allocator,
            "Failed to communicate with upstream API",
            .server_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .bad_gateway, error_json);
        return;
    };
    defer client.freeStreamingResult(stream_result);
    const stream_connect_time = std.time.milliTimestamp() - stream_connect_start;
    log.debug("[STREAM] Stream connection established in {d}ms", .{stream_connect_time});

    // Send SSE headers to client
    try http.sendSseHeaders(connection);

    // Initialize streaming state
    var state = Transformer.StreamState.init(allocator, openai_request.model);
    defer state.deinit();

    // Process each chunk from upstream
    const process_start = std.time.milliTimestamp();
    var chunk_count: u32 = 0;
    var first_chunk_time: ?i64 = null;
    while (stream_result.iterator.next()) |line| {
        // Transform the chunk
        if (Transformer.transformStreamLine(line, &state, allocator)) |transformed| {
            if (first_chunk_time == null) {
                first_chunk_time = std.time.milliTimestamp() - process_start;
                log.debug("[STREAM] Time to first chunk: {d}ms", .{first_chunk_time.?});
            }
            chunk_count += 1;
            defer allocator.free(transformed);
            _ = try connection.stream.writeAll(transformed);
            _ = try connection.stream.writeAll("\n\n");
        }
        // Skip null returns (non-data lines, parse errors, or events with no output)
    }
    const process_time = std.time.milliTimestamp() - process_start;
    log.debug("[STREAM] Processed {d} chunks in {d}ms", .{ chunk_count, process_time });

    const total_elapsed = std.time.milliTimestamp() - start_time;
    log.info("[STREAM] POST /v1/chat/completions - completed | model='{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | stream_connect={d}ms | process={d}ms | chunks={d}", .{
        openai_request.model,
        total_elapsed,
        transform_time,
        client_init_time,
        stream_connect_time,
        process_time,
        chunk_count,
    });
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
    const start_time = std.time.milliTimestamp();
    log.info("[SYNC] POST /v1/chat/completions - request received for model '{s}'", .{openai_request.model});

    // Transform OpenAI request to provider format
    const transform_start = std.time.milliTimestamp();
    const provider_request = Transformer.transform(
        openai_request,
        model,
        allocator,
    ) catch |err| {
        log.err("[SYNC] Transform request error: {} for model '{s}'", .{ err, openai_request.model });
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
    const transform_request_time = std.time.milliTimestamp() - transform_start;
    log.debug("[SYNC] Transform request completed in {d}ms", .{transform_request_time});

    // Initialize client
    const client_init_start = std.time.milliTimestamp();
    var client = Client.init(allocator, provider_config) catch |err| {
        log.err("[SYNC] Client initialization error: {} for model '{s}'", .{ err, openai_request.model });
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
    const client_init_time = std.time.milliTimestamp() - client_init_start;
    log.debug("[SYNC] Client init completed in {d}ms", .{client_init_time});

    // Send request to provider
    const provider_request_start = std.time.milliTimestamp();
    const provider_response = client.sendRequest(provider_request) catch |err| {
        log.err("[SYNC] Provider API error: {} for model '{s}'", .{ err, openai_request.model });
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
    const provider_request_time = std.time.milliTimestamp() - provider_request_start;
    log.debug("[SYNC] Provider request/response completed in {d}ms", .{provider_request_time});

    // Transform provider response back to OpenAI format
    const transform_response_start = std.time.milliTimestamp();
    const openai_response = try Transformer.transformResponse(
        provider_response.value,
        allocator,
        openai_request.model,
    );
    defer Transformer.cleanupResponse(openai_response, allocator);
    const transform_response_time = std.time.milliTimestamp() - transform_response_start;
    log.debug("[SYNC] Transform response completed in {d}ms", .{transform_response_time});

    // Serialize OpenAI response
    const serialize_start = std.time.milliTimestamp();
    var response_buffer = std.ArrayList(u8){};
    defer response_buffer.deinit(allocator);
    try response_buffer.writer(allocator).print("{f}", .{std.json.fmt(openai_response, .{})});
    const serialize_time = std.time.milliTimestamp() - serialize_start;
    log.debug("[SYNC] Response serialization completed in {d}ms", .{serialize_time});

    // Send response
    const send_start = std.time.milliTimestamp();
    try http.sendJsonResponse(connection, .ok, response_buffer.items);
    const send_time = std.time.milliTimestamp() - send_start;
    log.debug("[SYNC] Response sent in {d}ms", .{send_time});

    const total_elapsed = std.time.milliTimestamp() - start_time;
    log.info("[SYNC] POST /v1/chat/completions - completed | model='{s}' | total={d}ms | transform_req={d}ms | client_init={d}ms | provider_req={d}ms | transform_resp={d}ms | serialize={d}ms | send={d}ms", .{
        openai_request.model,
        total_elapsed,
        transform_request_time,
        client_init_time,
        provider_request_time,
        transform_response_time,
        serialize_time,
        send_time,
    });
}
