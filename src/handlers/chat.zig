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

//! Chat Completions Handler
//!
//! Thin HTTP wrapper over core.dispatcher.complete(core.chat_pipeline.run, ...).
//! Handles POST /v1/chat/completions requests.

const std = @import("std");
const net = @import("zag-core").net;
const core = @import("zag-core");
const OpenAIChat = core.openai_types;
const errors = core.errors;
const log = core.log;
const http = @import("../http.zig");

/// Handle POST /v1/chat/completions requests
pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    _ = method;
    log.info("POST {s}", .{path});

    // Parse OpenAI request
    const openai_request = std.json.parseFromSlice(
        OpenAIChat.Request,
        allocator,
        body,
        .{},
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
    defer openai_request.deinit();

    const is_streaming = openai_request.value.stream orelse false;

    if (is_streaming) {
        // Lazy SSE: headers are sent by SseWriter on the first byte. This lets a
        // connection-time upstream error still return a proper HTTP status.
        var sse = http.SseWriter.init(connection);
        // Upstream error body captured before any stream byte (overwritten per attempt).
        var err_buf = std.ArrayList(u8).empty;
        defer err_buf.deinit(allocator);
        var err_writer = http.ArrayListWriter{ .list = &err_buf, .allocator = allocator };
        core.dispatcher.complete(core.chat_pipeline.run, &sse, &err_writer, allocator, openai_request.value) catch |err| {
            if (sse.headers_sent) {
                // Already streaming — deliver the error as an SSE event.
                try http.sendStreamingError(&sse, allocator, err, MODEL_EXAMPLE);
            } else {
                // No bytes sent yet — send a normal HTTP error response.
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
        core.dispatcher.complete(core.chat_pipeline.run, &list_writer, &err_writer, allocator, openai_request.value) catch |err| {
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
