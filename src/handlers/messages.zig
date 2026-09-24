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
//! Thin HTTP wrapper over core.dispatcher.complete(core.messages_pipeline.run, ...).
//! Handles POST /v1/messages requests (Anthropic Messages API format).

const std = @import("std");
const net = @import("zag-core").net;
const core = @import("zag-core");
const Anthropic = core.anthropic_types;
const errors = core.errors;
const log = core.log;
const http = @import("../http.zig");

/// Handle POST /v1/messages requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    _ = method;
    log.info("POST {s}", .{path});

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
        // Lazy SSE: headers sent by SseWriter on first byte, so a connection-time
        // upstream error can still return a proper HTTP status.
        var sse = http.SseWriter.init(connection);
        var err_buf = std.ArrayList(u8).empty;
        defer err_buf.deinit(allocator);
        var err_writer = http.ArrayListWriter{ .list = &err_buf, .allocator = allocator };
        core.dispatcher.complete(core.messages_pipeline.run, &sse, &err_writer, allocator, anthropic_request.value) catch |err| {
            if (sse.headers_sent) {
                try http.sendStreamingError(&sse, allocator, err, MODEL_EXAMPLE);
            } else {
                try http.sendSyncError(connection, allocator, err, err_buf.items, MODEL_EXAMPLE);
                return;
            }
        };
        // Ensure a valid 200 SSE response even if the stream produced no bytes.
        sse.ensureHeaders() catch {};
        // Send chunked terminator (no-op if headers were never sent).
        sse.finish() catch |err| {
            log.err("[STREAM] Failed to send chunked terminator: {}", .{err});
        };
    } else {
        // Non-streaming: buffer response, then send as JSON
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var list_writer = http.ArrayListWriter{ .list = &buf, .allocator = allocator };
        // Separate buffer for the upstream error body (overwritten per attempt).
        var err_buf = std.ArrayList(u8).empty;
        defer err_buf.deinit(allocator);
        var err_writer = http.ArrayListWriter{ .list = &err_buf, .allocator = allocator };
        core.dispatcher.complete(core.messages_pipeline.run, &list_writer, &err_writer, allocator, anthropic_request.value) catch |err| {
            try http.sendSyncError(connection, allocator, err, err_buf.items, MODEL_EXAMPLE);
            return;
        };
        try http.sendJsonResponse(connection, .ok, buf.items);
    }
}

/// Full "invalid model format" message for this handler, embedding an example
/// model. Passed to `http.sendSyncError`/`sendStreamingError`; the sole
/// per-handler difference in error text.
const MODEL_EXAMPLE = "Invalid model format. Expected 'provider/model-name' (e.g., 'anthropic/claude-3-5-sonnet-latest')";
