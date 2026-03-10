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

//! Models Handler
//!
//! Thin HTTP wrapper over core.completion.listModels().
//! Handles GET /v1/models requests.

const std = @import("std");
const core = @import("zig-zag-core");
const OpenAI = core.openai_types;
const errors = core.errors;
const log = core.log;
const config_mod = core.config;
const http = @import("../http.zig");

/// Handle GET /v1/models request
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = method;
    _ = path;
    _ = body;
    _ = cfg;

    const models = core.completion.listModels(allocator) catch |err| {
        log.err("Failed to list models: {}", .{err});
        const error_json = try errors.createErrorResponse(
            allocator,
            "Failed to fetch models",
            .server_error,
            null,
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .internal_server_error, error_json);
        return;
    };
    defer core.completion.freeModels(allocator, models);

    const response = OpenAI.ModelsResponse{
        .data = models,
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try json_buf.writer(allocator).print("{f}", .{std.json.fmt(response, .{})});

    try http.sendJsonResponse(connection, .ok, json_buf.items);
}
