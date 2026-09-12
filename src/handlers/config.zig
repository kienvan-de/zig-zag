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
//!   GET    /v1/config/data                  -> handleGet
//!   POST   /v1/config/data                  -> handlePost
//!   GET    /v1/config/{provider}/auth        -> provider auth status
//!   POST   /v1/config/{provider}/auth        -> start provider auth flow
//!   DELETE /v1/config/{provider}/auth        -> revoke provider auth

const std = @import("std");
const net = @import("zag-core").net;
const core = @import("zag-core");
const errors = core.errors;
const config_mod = core.config;
const log = core.log;

const http = @import("../http.zig");
const templates = @import("../templates/mod.zig");

// ============================================================================
// Top-level dispatcher
// ============================================================================

pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    const eql = std.mem.eql;

    if (eql(u8, path, "/v1/config/data")) {
        if (eql(u8, method, "GET")) return handleGet(allocator, connection);
        if (eql(u8, method, "POST")) return handlePost(allocator, connection, body);
    }

    // Match /v1/config/{provider}/auth
    const auth_prefix = "/v1/config/";
    const auth_suffix = "/auth";
    if (std.mem.startsWith(u8, path, auth_prefix) and std.mem.endsWith(u8, path, auth_suffix)) {
        const rest = path[auth_prefix.len..];
        const provider_name = rest[0 .. rest.len - auth_suffix.len];
        if (provider_name.len > 0 and std.mem.indexOfScalar(u8, provider_name, '/') == null) {
            return dispatchProviderAuth(allocator, connection, method, provider_name);
        }
    }

    log.warn("Config handler: no match for {s} {s}", .{ method, path });
    return http.sendNotFound(connection);
}

// ============================================================================
// Config data -- GET / POST
// ============================================================================

fn handleGet(allocator: std.mem.Allocator, connection: net.Connection) !void {
    const raw = config_mod.readRaw(allocator) catch |err| {
        log.err("Config read failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer allocator.free(raw);
    try http.sendJsonResponse(connection, .ok, raw);
}

fn handlePost(allocator: std.mem.Allocator, connection: net.Connection, body: []const u8) !void {
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
// Provider auth -- GET / POST / DELETE
// ============================================================================

fn dispatchProviderAuth(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    provider_name: []const u8,
) !void {
    const eql = std.mem.eql;

    if (eql(u8, method, "GET")) {
        const status = config_mod.checkAuthStatus(allocator, provider_name);
        const json = switch (status) {
            .authenticated => "{\"status\":\"authenticated\"}",
            .configured => "{\"status\":\"configured\"}",
            .unauthenticated => "{\"status\":\"unauthenticated\"}",
        };
        return http.sendJsonResponse(connection, .ok, json);
    }

    if (eql(u8, method, "POST")) {
        const result = config_mod.initiateAuth(allocator, provider_name, .{
            .callback_success_html = templates.callback_success,
            .callback_error_html = templates.callback_error,
        });
        switch (result) {
            .authenticated => {
                return http.sendJsonResponse(connection, .ok, "{\"status\":\"authenticated\"}");
            },
            .device_flow => |df| {
                const DeviceFlowResponse = struct {
                    user_code: []const u8,
                    verification_uri: []const u8,
                };
                var buf = std.ArrayList(u8).empty;
                buf.print(allocator, "{f}", .{std.json.fmt(DeviceFlowResponse{
                    .user_code = df.user_code,
                    .verification_uri = df.verification_uri,
                }, .{})}) catch return http.sendInternalError(connection);
                const resp = buf.toOwnedSlice(allocator) catch return http.sendInternalError(connection);
                defer allocator.free(resp);
                return http.sendJsonResponse(connection, .ok, resp);
            },
            .err => |e| {
                const ErrorResp = struct { status: []const u8, message: []const u8 };
                var buf = std.ArrayList(u8).empty;
                buf.print(allocator, "{f}", .{std.json.fmt(ErrorResp{
                    .status = "error",
                    .message = e.message,
                }, .{})}) catch return http.sendInternalError(connection);
                const resp = buf.toOwnedSlice(allocator) catch return http.sendInternalError(connection);
                defer allocator.free(resp);
                return http.sendJsonResponse(connection, .bad_request, resp);
            },
        }
    }

    if (eql(u8, method, "DELETE")) {
        config_mod.revokeAuth(allocator, provider_name);
        return http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
    }

    return http.sendNotFound(connection);
}
