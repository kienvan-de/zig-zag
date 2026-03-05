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

//! Config REST Handler
//!
//! Handles all requests to /v1/config/* routes.
//! Dispatches internally by method + path:
//!
//!   GET    /v1/config/data                  → handleGet
//!   POST   /v1/config/data                  → handlePost
//!   GET    /v1/config/copilot/auth/status   → handleCopilotAuthStatus
//!   POST   /v1/config/copilot/auth          → handleCopilotAuth
//!   DELETE /v1/config/copilot/auth          → handleCopilotAuthRevoke

const std = @import("std");
const http = @import("../http.zig");
const errors = @import("../errors.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = cfg;

    const eql = std.mem.eql;

    if (eql(u8, path, "/v1/config/data")) {
        if (eql(u8, method, "GET"))  return handleGet(allocator, connection);
        if (eql(u8, method, "POST")) return handlePost(allocator, connection, body);
    }

    if (eql(u8, path, "/v1/config/copilot/auth/status")) {
        if (eql(u8, method, "GET")) return handleCopilotAuthStatus(allocator, connection);
    }

    if (eql(u8, path, "/v1/config/copilot/auth")) {
        if (eql(u8, method, "POST"))   return handleCopilotAuth(allocator, connection);
        if (eql(u8, method, "DELETE")) return handleCopilotAuthRevoke(allocator, connection);
    }

    log.warn("Config handler: no match for {s} {s}", .{ method, path });
    return http.sendNotFound(connection);
}

// ============================================================================
// Config data — GET / POST
// ============================================================================

fn handleGet(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    const raw = config_mod.readRaw(allocator) catch |err| {
        log.err("Config read failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer allocator.free(raw);
    try http.sendJsonResponse(connection, .ok, raw);
}

fn handlePost(allocator: std.mem.Allocator, connection: std.net.Server.Connection, body: []const u8) !void {
    config_mod.writeRaw(allocator, body) catch |err| {
        log.err("Config write failed: {}", .{err});
        const msg = if (err == error.InvalidConfigFormat)
            "Invalid JSON"
        else
            "Failed to write config";
        const error_json = try errors.createErrorResponse(allocator, msg, .invalid_request_error, null);
        defer allocator.free(error_json);
        return http.sendJsonResponse(connection, .bad_request, error_json);
    };
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}

// ============================================================================
// Copilot auth — status / device flow / revoke
// (full implementation in TASK-7)
// ============================================================================

fn handleCopilotAuthStatus(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    _ = allocator;
    try http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
}

fn handleCopilotAuth(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    _ = allocator;
    try http.sendJsonResponse(connection, .ok, "{\"error\":\"not implemented\"}");
}

fn handleCopilotAuthRevoke(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    _ = allocator;
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}
