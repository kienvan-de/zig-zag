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

//! Template Handler
//!
//! Serves embedded HTML templates for GET /v1/html/* routes.
//! Dispatches by path suffix after "/v1/html/":
//!   /v1/html/config       => templates.config_ui (static)
//!   /v1/html/device_flow  => templates.device_flow with query param substitution
//!   /v1/html/<unknown>    => 404

const std = @import("std");
const core = @import("zag-core");
const log = core.log;
const http = @import("../http.zig");
const templates = @import("../templates/mod.zig");

const HTML_PREFIX = "/v1/html/";

pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    _ = method;
    _ = body;

    // Split path from query string
    var path_part = path;
    var query_string: []const u8 = "";
    if (std.mem.indexOf(u8, path, "?")) |qi| {
        path_part = path[0..qi];
        query_string = path[qi + 1 ..];
    }

    // Strip "/v1/html/" prefix to get template name
    const name = if (std.mem.startsWith(u8, path_part, HTML_PREFIX))
        path_part[HTML_PREFIX.len..]
    else
        "";

    log.info("GET {s} (template: '{s}')", .{ path, name });

    if (std.mem.eql(u8, name, "config")) {
        return sendHtml(allocator, connection, templates.config_ui);
    }

    if (std.mem.eql(u8, name, "device_flow")) {
        return handleDeviceFlow(allocator, connection, query_string);
    }

    log.warn("Template handler: unknown template '{s}'", .{name});
    return http.sendNotFound(connection);
}

/// Serve device_flow.html with {{USER_CODE}} and {{VERIFICATION_URI}} replaced
/// from query parameters: ?user_code=XXXX&verification_uri=https://...
fn handleDeviceFlow(allocator: std.mem.Allocator, connection: std.net.Server.Connection, query_string: []const u8) !void {
    var user_code: []const u8 = "";
    var verification_uri: []const u8 = "";

    // Parse query parameters
    var iter = std.mem.splitScalar(u8, query_string, '&');
    while (iter.next()) |param| {
        if (std.mem.indexOf(u8, param, "=")) |eq| {
            const key = param[0..eq];
            const value = param[eq + 1 ..];
            if (std.mem.eql(u8, key, "user_code")) {
                user_code = value;
            } else if (std.mem.eql(u8, key, "verification_uri")) {
                verification_uri = value;
            }
        }
    }

    // URL-decode verification_uri (handles %3A => :, %2F => /, etc.)
    const decoded_uri = try urlDecode(allocator, verification_uri);
    defer allocator.free(decoded_uri);

    // Replace {{USER_CODE}} placeholders
    const after_code = try std.mem.replaceOwned(u8, allocator, templates.device_flow, "{{USER_CODE}}", user_code);
    defer allocator.free(after_code);

    // Replace {{VERIFICATION_URI}} placeholders
    const html = try std.mem.replaceOwned(u8, allocator, after_code, "{{VERIFICATION_URI}}", decoded_uri);
    defer allocator.free(html);

    return sendHtml(allocator, connection, html);
}

/// Simple percent-decoding for URL query values
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    try result.ensureTotalCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const high = hexVal(input[i + 1]);
            const low_val = hexVal(input[i + 2]);
            if (high != null and low_val != null) {
                try result.append(allocator, (high.? << 4) | low_val.?);
                i += 3;
                continue;
            }
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
            continue;
        }
        try result.append(allocator, input[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn sendHtml(allocator: std.mem.Allocator, connection: std.net.Server.Connection, content: []const u8) !void {
    const header = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{content.len},
    );
    defer allocator.free(header);

    _ = try connection.stream.writeAll(header);
    _ = try connection.stream.writeAll(content);
}
