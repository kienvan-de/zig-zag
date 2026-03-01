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
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const app_cache = @import("cache/app_cache.zig");
const worker_pool = @import("worker_pool.zig");
const provider = @import("provider.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from ~/.config/zig-zag/config.json
    var cfg = try config.Config.load(allocator);
    defer cfg.deinit();

    // Initialize app cache (for OIDC discovery configs, etc.)
    app_cache.init(allocator);
    defer app_cache.deinit();

    // Initialize token cache
    token_cache.init(allocator);
    defer token_cache.deinit();

    // Initialize IO worker pool (before logging so async writes work)
    const io_pool_size: usize = if (cfg.server.io_pool_size) |size|
        @intCast(size)
    else
        4;
    try worker_pool.init(allocator, io_pool_size);
    defer worker_pool.deinit();

    // Initialize logging (after worker pool for async writes)
    try log.init(.{
        .level = cfg.log.level,
        .path = cfg.log.path,
        .output = cfg.log.output,
    }, allocator);
    defer log.deinit();

    // Initialize providers (auth flows for HAI, SAP AI Core, etc.)
    log.info("Initializing providers...", .{});
    const init_result = provider.initProviders(allocator, &cfg);
    log.info("Provider initialization complete: {d}/{d} succeeded", .{ init_result.succeeded, init_result.total });

    // Exit if all providers failed (but allow starting with no providers configured)
    if (init_result.succeeded == 0 and init_result.total > 0) {
        log.err("All providers failed to initialize, exiting", .{});
        return error.NoProvidersAvailable;
    }

    // Start the HTTP server
    try server.start(allocator, &cfg);
}
