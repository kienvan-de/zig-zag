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

const std = @import("std");
const chat_handler = @import("handlers/chat.zig");
const models_handler = @import("handlers/models.zig");
const template_handler = @import("handlers/template.zig");
const config_handler = @import("handlers/config.zig");
const config_mod = @import("config.zig");

/// Route definition
pub const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: *const fn (
        allocator: std.mem.Allocator,
        connection: std.net.Server.Connection,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        config: *const config_mod.Config,
    ) anyerror!void,
};

/// Match incoming HTTP request to a route.
/// Exact matches are checked first, then prefix matches.
/// Returns null if no route matches.
pub fn match(request_data: []const u8) ?Route {
    if (request_data.len == 0) return null;

    // Extract method and path from request line
    const method = extractMethod(request_data) orelse return null;
    const path = extractPath(request_data) orelse return null;
    const full_uri = extractFullUri(request_data) orelse return null;

    // ── Exact matches ────────────────────────────────────────────────────────

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/chat/completions")) {
        return Route{ .method = method, .path = path, .handler = chat_handler.handle };
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/v1/models")) {
        return Route{ .method = method, .path = path, .handler = models_handler.handle };
    }

    // ── Prefix matches ───────────────────────────────────────────────────────

    // GET /v1/html/* → template handler (serves embedded HTML pages)
    // Pass full URI (with query string) so templates can access query params
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/v1/html/")) {
        return Route{ .method = method, .path = full_uri, .handler = template_handler.handle };
    }

    // * /v1/config/* → config REST handler (GET, POST, DELETE)
    if (std.mem.startsWith(u8, path, "/v1/config/")) {
        return Route{ .method = method, .path = path, .handler = config_handler.handle };
    }

    return null;
}

/// Extract HTTP method from request line
fn extractMethod(request_data: []const u8) ?[]const u8 {
    const space_pos = std.mem.indexOf(u8, request_data, " ") orelse return null;
    return request_data[0..space_pos];
}

/// Extract path from request line
fn extractPath(request_data: []const u8) ?[]const u8 {
    const first_space = std.mem.indexOf(u8, request_data, " ") orelse return null;
    const remaining = request_data[first_space + 1 ..];
    const second_space = std.mem.indexOf(u8, remaining, " ") orelse return null;

    const path_with_query = remaining[0..second_space];

    // Remove query string if present
    if (std.mem.indexOf(u8, path_with_query, "?")) |query_pos| {
        return path_with_query[0..query_pos];
    }

    return path_with_query;
}

/// Extract full URI (path + query string) from request line
fn extractFullUri(request_data: []const u8) ?[]const u8 {
    const first_space = std.mem.indexOf(u8, request_data, " ") orelse return null;
    const remaining = request_data[first_space + 1 ..];
    const second_space = std.mem.indexOf(u8, remaining, " ") orelse return null;
    return remaining[0..second_space];
}

// ============================================================================
// Unit Tests
// ============================================================================
