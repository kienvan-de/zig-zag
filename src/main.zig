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
const build_options = @import("build_options");
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const app_cache = @import("cache/app_cache.zig");
const worker_pool = @import("worker_pool.zig");
const metrics = @import("metrics.zig");
const provider = @import("provider.zig");
const pricing = @import("pricing.zig");

const version = build_options.version;

pub fn main() !void {
    // Handle --version / -v flag
    var args = std.process.args();
    _ = args.next(); // skip program name
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, "zig-zag " ++ version ++ "\n") catch {};
            return;
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize caches before config so Config.load can populate them
    app_cache.init(allocator);
    defer app_cache.deinit();

    token_cache.init(allocator);
    defer token_cache.deinit();

    // Load configuration from ~/.config/zig-zag/config.json
    var cfg = try config.Config.load(allocator);
    defer cfg.deinit();

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

    // Load persisted metrics (tokens, costs, period_start) from previous session
    metrics.load();
    defer metrics.persist();

    log.info("zig-zag v{s}", .{version});

    // Log configured providers (auth is lazy, on first request)
    provider.logConfiguredProviders(&cfg);

    // Initialize pricing engine (load cost CSVs for configured providers)
    var provider_names_buf: [32][]const u8 = undefined;
    var provider_name_count: usize = 0;
    {
        var piter = cfg.providers.keyIterator();
        while (piter.next()) |key_ptr| {
            if (provider_name_count < provider_names_buf.len) {
                provider_names_buf[provider_name_count] = key_ptr.*;
                provider_name_count += 1;
            }
        }
    }
    pricing.init(allocator, provider_names_buf[0..provider_name_count]);
    defer pricing.deinit();
    pricing.scheduleAutoUpdate();

    // Start the HTTP server
    try server.start(allocator, &cfg);
}
