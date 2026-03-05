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
//!   /v1/html/config  → templates.config_ui
//!   /v1/html/<unknown> → 404

const std = @import("std");
const http = @import("../http.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const templates = @import("../templates/mod.zig");

const HTML_PREFIX = "/v1/html/";

pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = method;
    _ = body;
    _ = cfg;

    // Strip "/v1/html/" prefix to get template name
    const name = if (std.mem.startsWith(u8, path, HTML_PREFIX))
        path[HTML_PREFIX.len..]
    else
        "";

    log.info("GET {s} (template: '{s}')", .{ path, name });

    if (std.mem.eql(u8, name, "config")) {
        return sendHtml(allocator, connection, templates.config_ui);
    }

    log.warn("Template handler: unknown template '{s}'", .{name});
    return http.sendNotFound(connection);
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
