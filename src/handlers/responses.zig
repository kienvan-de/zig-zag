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

//! Responses Handler
//!
//! Thin HTTP wrapper over core.completion.responsesComplete().
//! Handles POST /v1/responses requests.

const std = @import("std");
const net = @import("zag-core").net;
const core = @import("zag-core");
const ResponsesTypes = core.openai_responses_types;
const errors = core.errors;
const log = core.log;
const http = @import("../http.zig");

/// Handle POST /v1/responses requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    _ = method;
    _ = path;

    const request = std.json.parseFromSlice(
        ResponsesTypes.ResponsesRequest,
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
    defer request.deinit();

    const is_streaming = request.value.stream orelse false;

    if (is_streaming) {
        try http.sendSseHeaders(connection);
        var chunked = http.ChunkedWriter.init(connection);
        core.completion.responsesComplete(&chunked, allocator, request.value) catch |err| {
            try handleStreamingError(&chunked, allocator, err);
        };
        chunked.finish() catch |err| {
            log.err("[RESPONSES] Failed to send chunked terminator: {}", .{err});
        };
    } else {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var list_writer = http.ArrayListWriter{ .list = &buf, .allocator = allocator };
        core.completion.responsesComplete(&list_writer, allocator, request.value) catch |err| {
            try handleSyncError(allocator, connection, err);
            return;
        };
        try http.sendJsonResponse(connection, .ok, buf.items);
    }
}

fn handleStreamingError(chunked: *http.ChunkedWriter, allocator: std.mem.Allocator, err: anyerror) !void {
    const error_json = errors.createErrorResponse(
        allocator,
        mapErrorMessage(err),
        mapErrorType(err),
        null,
    ) catch return;
    defer allocator.free(error_json);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    buffer.print(allocator, "data: {s}\n\n", .{error_json}) catch return;
    chunked.writeAll(buffer.items) catch {};
}

fn handleSyncError(
    allocator: std.mem.Allocator,
    connection: net.Connection,
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
        error.AuthRequired => "Authentication required. Please authenticate this provider via POST /v1/config/{provider}/auth",
        error.InvalidModelFormat, error.EmptyProvider, error.EmptyModel => "Invalid model format. Expected 'provider/model-name' (e.g., 'openai/gpt-4o')",
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
        error.AuthRequired => .invalid_request_error,
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
        error.AuthRequired => "auth_required",
        else => null,
    };
}

fn mapHttpStatus(err: anyerror) std.http.Status {
    return switch (err) {
        error.BudgetExceeded => .too_many_requests,
        error.AuthRequired => .unauthorized,
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
