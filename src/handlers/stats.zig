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

//! Stats Handler
//!
//! GET /v1/stats/costs — returns per-model cost breakdown and configured budget.
//! Response: {"budget": <f64>, "costs": {"provider": {"model": {input, cache_write, cache_read, output}}}}

const std = @import("std");
const net = @import("zag-core").net;
const core = @import("zag-core");
const log = core.log;
const http = @import("../http.zig");

pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) !void {
    _ = method;
    _ = body;

    if (!std.mem.eql(u8, path, "/v1/stats/costs")) {
        return http.sendJsonResponse(connection, .not_found, "{\"error\":\"Not Found\"}");
    }

    const cfg = core.config.get();
    const budget = cfg.cost_controls.budget;

    const costs_json = core.utils.serializeAllCosts(allocator) catch |err| {
        log.err("[stats] serializeAllCosts failed: {}", .{err});
        return http.sendJsonResponse(connection, .ok, "{\"budget\":0,\"costs\":{}}");
    };
    defer allocator.free(costs_json);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{{\"budget\":{d:.6},\"costs\":{s}}}", .{ budget, costs_json });

    try http.sendJsonResponse(connection, .ok, buf.items);
}
