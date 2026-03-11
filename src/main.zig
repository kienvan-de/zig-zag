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
const core = @import("zag-core");
const core_config = core.config;
const log = core.log;
const token_cache = core.cache;
const app_cache = core.app_cache;
const worker_pool = @import("worker_pool.zig");
const metrics = core.metrics;
const utils = core.utils;
const provider = core.provider;
const pricing = core.pricing;
const app_config = @import("config.zig");
const server = @import("server.zig");

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

    // Initialize caches before config loading
    app_cache.init(allocator);
    defer app_cache.deinit();

    token_cache.init(allocator);
    defer token_cache.deinit();

    // Resolve config file path: env var ZIG_ZAG_CONFIG, or OS default
    const config_path = resolveConfigPath();

    // Load full application config (wrapper + core sections)
    var cfg = try app_config.AppConfig.loadFromFile(allocator, config_path);
    defer cfg.deinit();

    // Initialize IO worker pool (before logging so async writes work)
    try worker_pool.init(allocator, @intCast(cfg.server.io_pool_size));
    defer worker_pool.deinit();

    // Initialize logging (after worker pool for async writes)
    try log.init(.{
        .level = cfg.core.log.level,
        .path = cfg.core.log.path,
        .output = cfg.core.log.output,
    }, allocator);
    defer log.deinit();

    // Load persisted metrics (tokens, costs, period_start) from previous session
    metrics.load();
    defer metrics.persist();

    // If the budget period expired while the proxy was offline, reset now so
    // the macOS app shows correct stats before the first request arrives.
    utils.checkBudgetPeriodOnStartup(&cfg.core);

    // Set global config singleton + config file path for core module access
    core_config.set(&cfg.core, config_path);

    log.info("zig-zag v{s}", .{version});

    // Log configured providers (auth is lazy, on first request)
    provider.logConfiguredProviders(&cfg.core);

    // Initialize pricing engine (load cost CSVs for configured providers)
    var provider_names_buf: [32][]const u8 = undefined;
    var provider_name_count: usize = 0;
    {
        var piter = cfg.core.providers.keyIterator();
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

// ============================================================================
// Config path resolution — wrapper responsibility (not in core)
// ============================================================================

const builtin = @import("builtin");

var resolved_path_buf: [std.fs.max_path_bytes]u8 = undefined;

/// Resolve config file path: $ZIG_ZAG_CONFIG env var, or OS-specific default.
fn resolveConfigPath() []const u8 {
    if (std.posix.getenv("ZIG_ZAG_CONFIG")) |env_path| {
        return env_path;
    }
    return defaultConfigPath() catch "config.json";
}

fn defaultConfigPath() ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        return std.fmt.bufPrint(
            &resolved_path_buf,
            "{s}/.config/zig-zag/config.json",
            .{home},
        );
    } else if (builtin.os.tag == .windows) {
        if (std.posix.getenv("LOCALAPPDATA")) |app_data| {
            return std.fmt.bufPrint(
                &resolved_path_buf,
                "{s}\\zig-zag\\config.json",
                .{app_data},
            );
        }
        return "config.json";
    } else {
        return std.fmt.bufPrint(
            &resolved_path_buf,
            "{s}/.config/zig-zag/config.json",
            .{home},
        );
    }
}
