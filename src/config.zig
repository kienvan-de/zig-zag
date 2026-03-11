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

//! Wrapper-level application configuration.
//!
//! Parses the full `config.json` and splits it into:
//! - `core` — providers, logging, cost controls (passed to `zag-core`)
//! - `server` — HTTP server settings (host, port, pool sizes, timeouts)
//! - `statistics` — macOS UI display toggles

const std = @import("std");
const core = @import("zag-core");
const core_config = core.config;
const log = core.log;

/// Full application configuration — core + wrapper-specific sections.
///
/// Owns the `core.config.Config` which in turn owns the parsed JSON tree.
/// All borrowed slices (server.host, etc.) remain valid until `deinit()`.
///
/// Typical lifecycle:
/// ```
/// var app = try AppConfig.loadFromFile(allocator, path);
/// defer app.deinit();
/// core_config.set(&app.core, path);
/// ```
pub const AppConfig = struct {
    core: core_config.Config,
    server: ServerConfig,
    statistics: StatisticsConfig,

    /// Load and parse the full config.json from an explicit file path.
    ///
    /// Reads the file, parses JSON, then splits into core and wrapper sections.
    /// Core sections (providers, logging, cost_controls) are parsed by
    /// `core.config.Config.parseFromJson`.  Wrapper sections (server,
    /// statistics) are parsed here.
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.err("Failed to open config file: {s}", .{path});
            log.err("Error: {}", .{err});
            return err;
        };
        defer file.close();

        const file_content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            file_content,
            .{},
        );
        // NOTE: parsed ownership transfers to core Config on success.
        // On error before that point, we must deinit it.
        errdefer parsed.deinit();

        if (parsed.value != .object) {
            log.err("Config must be a JSON object", .{});
            return error.InvalidConfigFormat;
        }

        const root_obj = parsed.value.object;

        // Parse wrapper-specific sections before handing parsed to core
        const server_config = parseServerConfig(root_obj);
        const statistics_config = parseStatisticsConfig(root_obj);

        // Core takes ownership of parsed (providers, logging, cost_controls)
        var core_cfg = try core_config.Config.parseFromJson(allocator, parsed);
        errdefer core_cfg.deinit();

        return .{
            .core = core_cfg,
            .server = server_config,
            .statistics = statistics_config,
        };
    }

    pub fn deinit(self: *AppConfig) void {
        self.core.deinit();
    }
};

// ============================================================================
// Server config — HTTP wrapper only
// ============================================================================

pub const defaults = struct {
    pub const server_host: []const u8 = "0.0.0.0";
    pub const server_port: u16 = 8080;
    pub const server_http_pool_size: i64 = 3;
    pub const server_io_pool_size: i64 = 1;
    pub const server_max_header_size: i64 = 32 * 1024; // 32 KB
    pub const server_max_body_size: i64 = 10 * 1024 * 1024; // 10 MB
    pub const server_read_timeout_ms: i64 = 30_000; // 30 s
};

/// HTTP server configuration, parsed from the `"server"` section.
pub const ServerConfig = struct {
    port: u16 = defaults.server_port,
    host: []const u8 = defaults.server_host,
    http_pool_size: i64 = defaults.server_http_pool_size,
    io_pool_size: i64 = defaults.server_io_pool_size,
    max_header_size: i64 = defaults.server_max_header_size,
    max_body_size: i64 = defaults.server_max_body_size,
    read_timeout_ms: i64 = defaults.server_read_timeout_ms,
};

/// Statistics display toggles, parsed from the `"statistics"` section.
/// Controls which rows are visible in the macOS menu-bar app.
pub const StatisticsConfig = struct {
    show_performance: bool = true,
    show_llm: bool = true,
    show_cost: bool = true,
};

// ============================================================================
// JSON parsing helpers
// ============================================================================

fn parseServerConfig(root_obj: std.json.ObjectMap) ServerConfig {
    var cfg = ServerConfig{};
    const server_value = root_obj.get("server") orelse return cfg;
    if (server_value != .object) return cfg;
    const obj = server_value.object;

    if (obj.get("port")) |v| {
        if (v == .integer) cfg.port = @intCast(v.integer);
    }
    if (obj.get("host")) |v| {
        if (v == .string) cfg.host = v.string;
    }
    if (obj.get("http_pool_size")) |v| {
        if (v == .integer) cfg.http_pool_size = v.integer;
    }
    if (obj.get("io_pool_size")) |v| {
        if (v == .integer) cfg.io_pool_size = v.integer;
    }
    if (obj.get("max_header_size")) |v| {
        if (v == .integer) cfg.max_header_size = v.integer;
    }
    if (obj.get("max_body_size")) |v| {
        if (v == .integer) cfg.max_body_size = v.integer;
    }
    if (obj.get("read_timeout_ms")) |v| {
        if (v == .integer) cfg.read_timeout_ms = v.integer;
    }

    return cfg;
}

fn parseStatisticsConfig(root_obj: std.json.ObjectMap) StatisticsConfig {
    var cfg = StatisticsConfig{};
    const stats_value = root_obj.get("statistics") orelse return cfg;
    if (stats_value != .object) return cfg;
    const obj = stats_value.object;

    if (obj.get("show_performance")) |v| {
        if (v == .bool) cfg.show_performance = v.bool;
    }
    if (obj.get("show_llm")) |v| {
        if (v == .bool) cfg.show_llm = v.bool;
    }
    if (obj.get("show_cost")) |v| {
        if (v == .bool) cfg.show_cost = v.bool;
    }

    return cfg;
}
