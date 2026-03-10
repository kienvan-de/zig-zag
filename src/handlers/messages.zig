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

//! Messages Handler
//!
//! Thin HTTP wrapper over core.completion.messagesComplete().
//! Handles POST /v1/messages requests (Anthropic Messages API format).

const std = @import("std");
const core = @import("zig-zag-core");
const Anthropic = core.anthropic_types;
const errors = core.errors;
const log = core.log;
const config_mod = core.config;
const http = core.http;

/// Handle POST /v1/messages requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    config: *const config_mod.Config,
) !void {
    _ = method;
    _ = path;
    _ = config;

    // Parse Anthropic request
    const anthropic_request = std.json.parseFromSlice(
        Anthropic.Request,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("JSON parse error: {}", .{err});
        log.err("Raw request payload:\n{s}", .{body});
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
    defer anthropic_request.deinit();

    const is_streaming = anthropic_request.value.stream orelse false;

    if (is_streaming) {
        // Streaming: send SSE headers first, then use ChunkedWriter
        try http.sendSseHeaders(connection);
        var chunked = http.ChunkedWriter.init(connection.stream);
        core.completion.messagesComplete(chunked.writer(), allocator, anthropic_request.value) catch |err| {
            try handleStreamingError(&chunked, allocator, err);
        };
        // Send chunked terminator
        chunked.finish() catch |err| {
            log.err("[STREAM] Failed to send chunked terminator: {}", .{err});
        };
    } else {
        // Non-streaming: buffer response, then send as JSON
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        core.completion.messagesComplete(buf.writer(allocator), allocator, anthropic_request.value) catch |err| {
            try handleSyncError(allocator, connection, err);
            return;
        };
        try http.sendJsonResponse(connection, .ok, buf.items);
    }
}

/// Handle errors during streaming (after SSE headers already sent)
fn handleStreamingError(chunked: *http.ChunkedWriter, allocator: std.mem.Allocator, err: anyerror) !void {
    const error_json = errors.createErrorResponse(
        allocator,
        mapErrorMessage(err),
        mapErrorType(err),
        null,
    ) catch return;
    defer allocator.free(error_json);

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    buffer.writer(allocator).print("data: {s}\n\n", .{error_json}) catch return;
    chunked.writer().writeAll(buffer.items) catch {};
}

/// Handle errors during non-streaming (before any response sent)
fn handleSyncError(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    err: anyerror,
) !void {
    const error_json = try errors.createErrorResponse(
        allocator,
        mapErrorMessage(err),
        mapErrorType(err),
        mapErrorCode(err),
    );
    defer allocator.free(error_json);
    try http.sendJsonResponse(connection, mapHttpStatus(err), error_json);
}

fn mapErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.BudgetExceeded => "Budget exceeded. Cost controls are enabled and the budget limit has been reached.",
        error.InvalidModelFormat, error.EmptyProvider, error.EmptyModel => "Invalid model format. Expected 'provider/model-name' (e.g., 'anthropic/claude-3-5-sonnet-latest')",
        error.ProviderNotConfigured => "Provider not configured",
        error.CompatibleFieldMissing => "Provider not supported and no 'compatible' field specified",
        error.UnknownCompatibleType => "Unknown compatible provider type. Must be 'openai' or 'anthropic'",
        error.TransformFailed => "Failed to transform request",
        error.ClientInitFailed => "Failed to initialize provider client",
        error.UpstreamError => "Failed to communicate with upstream API",
        error.TransformResponseFailed => "Failed to transform response",
        else => "Internal server error",
    };
}

fn mapErrorType(err: anyerror) errors.ErrorType {
    return switch (err) {
        error.BudgetExceeded => .rate_limit_error,
        error.InvalidModelFormat, error.EmptyProvider, error.EmptyModel,
        error.ProviderNotConfigured, error.CompatibleFieldMissing,
        error.UnknownCompatibleType, error.TransformFailed,
        error.ClientInitFailed,
        => .invalid_request_error,
        error.UpstreamError, error.TransformResponseFailed => .server_error,
        else => .server_error,
    };
}

fn mapErrorCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.BudgetExceeded => "budget_exceeded",
        else => null,
    };
}

fn mapHttpStatus(err: anyerror) std.http.Status {
    return switch (err) {
        error.BudgetExceeded => .too_many_requests,
        error.InvalidModelFormat, error.EmptyProvider, error.EmptyModel,
        error.ProviderNotConfigured, error.CompatibleFieldMissing,
        error.UnknownCompatibleType, error.TransformFailed,
        error.ClientInitFailed,
        => .bad_request,
        error.UpstreamError => .bad_gateway,
        error.TransformResponseFailed => .internal_server_error,
        else => .internal_server_error,
    };
}
