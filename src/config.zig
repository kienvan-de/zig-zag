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
const provider_mod = @import("provider.zig");
const log_mod = @import("log.zig");
const app_cache = @import("cache/app_cache.zig");
const LogOutput = log_mod.LogOutput;

/// Provider-specific configuration
/// Wraps a parsed JSON object and provides type-safe accessors
pub const ProviderConfig = struct {
    allocator: std.mem.Allocator,
    name: []const u8, // Provider name from config key (e.g., "openai", "groq")
    raw: std.json.Value,

    /// Get string value from config
    pub fn getString(self: *const ProviderConfig, key: []const u8) ?[]const u8 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    /// Get integer value from config
    pub fn getInt(self: *const ProviderConfig, key: []const u8) ?i64 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Get float value from config
    pub fn getFloat(self: *const ProviderConfig, key: []const u8) ?f64 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Get boolean value from config
    pub fn getBool(self: *const ProviderConfig, key: []const u8) ?bool {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Cleanup provider config (no-op now, kept for API compatibility)
    pub fn deinit(self: *ProviderConfig) void {
        _ = self;
    }
};

// ============================================================================
// Default Values (single source of truth)
// ============================================================================

pub const defaults = struct {
    // Server
    pub const server_host: []const u8 = "0.0.0.0";
    pub const server_port: u16 = 8080;
    pub const server_http_pool_size: i64 = 3;
    pub const server_io_pool_size: i64 = 4;
    pub const server_max_header_size: i64 = 32 * 1024; // 32 KB
    pub const server_max_body_size: i64 = 10 * 1024 * 1024; // 10 MB
    pub const server_read_timeout_ms: i64 = 30_000; // 30 s

    // Logging
    pub const log_max_file_size_mb: i64 = 10;
    pub const log_max_files: i64 = 5;
    pub const log_buffer_size: i64 = 100;
    pub const log_flush_interval_ms: i64 = 1_000;

    // Provider (shared across all providers)
    pub const provider_timeout_ms: i64 = 60_000; // 60 s
    pub const provider_max_response_size_mb: i64 = 10;
};

/// Server configuration
pub const ServerConfig = struct {
    port: u16 = defaults.server_port,
    host: []const u8 = defaults.server_host,
    http_pool_size: i64 = defaults.server_http_pool_size,
    io_pool_size: i64 = defaults.server_io_pool_size,
    max_header_size: i64 = defaults.server_max_header_size,
    max_body_size: i64 = defaults.server_max_body_size,
    read_timeout_ms: i64 = defaults.server_read_timeout_ms,
};

/// Logging configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    path: ?[]const u8 = null, // null = use OS default
    max_file_size_mb: i64 = defaults.log_max_file_size_mb,
    max_files: i64 = defaults.log_max_files,
    buffer_size: i64 = defaults.log_buffer_size,
    flush_interval_ms: i64 = defaults.log_flush_interval_ms,
    output: LogOutput = .stderr, // output destination: "file" or "stderr"
};

/// Statistics display configuration
pub const StatisticsConfig = struct {
    show_performance: bool = true,
    show_llm: bool = true,
    show_cost: bool = true,
};

/// Cost controls configuration
pub const CostControlsConfig = struct {
    enabled: bool = false,
    budget: f64 = 0.0,
    days_duration: u32 = 0, // 0 = no reset (lifetime budget)
};

/// Main application configuration
pub const Config = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(ProviderConfig),
    server: ServerConfig,
    log: LogConfig,
    statistics: StatisticsConfig,
    cost_controls: CostControlsConfig,
    _parsed: std.json.Parsed(std.json.Value), // Keep root parsed alive

    /// Load configuration from ZIG_ZAG_CONFIG env var or ~/.config/zig-zag/config.json
    pub fn load(allocator: std.mem.Allocator) !Config {
        if (std.posix.getenv("ZIG_ZAG_CONFIG")) |config_path| {
            return loadFromFile(allocator, config_path);
        }

        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/.config/zig-zag/config.json",
            .{home},
        );

        return loadFromFile(allocator, config_path);
    }

    /// Load configuration from specific file path
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        // Read file
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log_mod.err("Failed to open config file: {s}", .{path});
            log_mod.err("Error: {}", .{err});
            return err;
        };
        defer file.close();

        const file_content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(file_content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            file_content,
            .{},
        );
        errdefer parsed.deinit();

        // Validate it's an object
        if (parsed.value != .object) {
            parsed.deinit();
            log_mod.err("Config must be a JSON object", .{});
            return error.InvalidConfigFormat;
        }

        const root_obj = parsed.value.object;

        // Parse server config (optional, with defaults)
        var server_config = ServerConfig{};
        if (root_obj.get("server")) |server_value| {
            if (server_value != .object) {
                parsed.deinit();
                log_mod.err("Server config must be an object", .{});
                return error.InvalidConfigFormat;
            }
            const server_obj = server_value.object;
            if (server_obj.get("port")) |port_value| {
                if (port_value == .integer) {
                    server_config.port = @intCast(port_value.integer);
                }
            }
            if (server_obj.get("host")) |host_value| {
                if (host_value == .string) {
                    server_config.host = host_value.string;
                }
            }
            if (server_obj.get("http_pool_size")) |v| {
                if (v == .integer) server_config.http_pool_size = v.integer;
            }
            if (server_obj.get("io_pool_size")) |v| {
                if (v == .integer) server_config.io_pool_size = v.integer;
            }
            if (server_obj.get("max_header_size")) |v| {
                if (v == .integer) {
                    server_config.max_header_size = v.integer;
                }
            }
            if (server_obj.get("max_body_size")) |v| {
                if (v == .integer) {
                    server_config.max_body_size = v.integer;
                }
            }
            if (server_obj.get("read_timeout_ms")) |v| {
                if (v == .integer) {
                    server_config.read_timeout_ms = v.integer;
                }
            }
        }

        // Cache server port so providers can build server URLs (e.g. Copilot redirect)
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{server_config.port}) catch "8080";
        app_cache.put("server_port", port_str) catch {};

        // Parse logging config (optional, with defaults)
        var log_config = LogConfig{};
        if (root_obj.get("logging")) |log_value| {
            if (log_value == .object) {
                const log_obj = log_value.object;
                if (log_obj.get("level")) |level_value| {
                    if (level_value == .string) {
                        log_config.level = log_mod.parseLevel(level_value.string);
                    }
                }
                if (log_obj.get("path")) |path_value| {
                    if (path_value == .string) {
                        log_config.path = path_value.string;
                    }
                }
                if (log_obj.get("max_file_size_mb")) |v| {
                    if (v == .integer) {
                        log_config.max_file_size_mb = v.integer;
                    }
                }
                if (log_obj.get("max_files")) |v| {
                    if (v == .integer) {
                        log_config.max_files = v.integer;
                    }
                }
                if (log_obj.get("buffer_size")) |v| {
                    if (v == .integer) {
                        log_config.buffer_size = v.integer;
                    }
                }
                if (log_obj.get("flush_interval_ms")) |v| {
                    if (v == .integer) {
                        log_config.flush_interval_ms = v.integer;
                    }
                }
                if (log_obj.get("output")) |v| {
                    if (v == .string) {
                        if (std.mem.eql(u8, v.string, "stderr")) {
                            log_config.output = .stderr;
                        } else {
                            log_config.output = .file;
                        }
                    }
                }
            }
        }

        // Parse statistics config (optional, with defaults)
        var statistics_config = StatisticsConfig{};
        if (root_obj.get("statistics")) |stats_value| {
            if (stats_value == .object) {
                const stats_obj = stats_value.object;
                if (stats_obj.get("show_performance")) |v| {
                    if (v == .bool) {
                        statistics_config.show_performance = v.bool;
                    }
                }
                if (stats_obj.get("show_llm")) |v| {
                    if (v == .bool) {
                        statistics_config.show_llm = v.bool;
                    }
                }
                if (stats_obj.get("show_cost")) |v| {
                    if (v == .bool) {
                        statistics_config.show_cost = v.bool;
                    }
                }
            }
        }

        // Parse cost controls config (optional, with defaults)
        var cost_controls_config = CostControlsConfig{};
        if (root_obj.get("cost_controls")) |cost_value| {
            if (cost_value == .object) {
                const cost_obj = cost_value.object;
                if (cost_obj.get("enabled")) |v| {
                    if (v == .bool) {
                        cost_controls_config.enabled = v.bool;
                    }
                }
                if (cost_obj.get("budget")) |v| {
                    if (v == .float) {
                        cost_controls_config.budget = v.float;
                    } else if (v == .integer) {
                        cost_controls_config.budget = @floatFromInt(v.integer);
                    }
                }
                if (cost_obj.get("days_duration")) |v| {
                    if (v == .integer and v.integer >= 0) {
                        cost_controls_config.days_duration = @intCast(v.integer);
                    }
                }
            }
        }

        // Get providers object
        const providers_value = root_obj.get("providers") orelse {
            parsed.deinit();
            log_mod.err("Config must contain 'providers' object", .{});
            return error.InvalidConfigFormat;
        };

        if (providers_value != .object) {
            parsed.deinit();
            log_mod.err("'providers' must be a JSON object", .{});
            return error.InvalidConfigFormat;
        }

        // Create provider map
        var providers = std.StringHashMap(ProviderConfig).init(allocator);
        errdefer {
            var it = providers.valueIterator();
            while (it.next()) |prov_config| {
                prov_config.deinit();
            }
            providers.deinit();
        }

        // Iterate over providers and reference their values directly
        var iter = providers_value.object.iterator();
        while (iter.next()) |entry| {
            const provider_name = entry.key_ptr.*;
            const provider_value_ptr = entry.value_ptr;

            // Validate provider config is an object
            if (provider_value_ptr.* != .object) {
                log_mod.err("Provider config must be an object: {s}", .{provider_name});
                return error.InvalidProviderConfig;
            }

            // Create a wrapper that references the value in the root parsed object
            const provider_config = ProviderConfig{
                .allocator = allocator,
                .name = provider_name,
                .raw = provider_value_ptr.*,
            };

            try providers.put(provider_name, provider_config);
        }

        // Keep the root parsed object alive - all provider configs reference it
        return Config{
            .allocator = allocator,
            .providers = providers,
            .server = server_config,
            .log = log_config,
            .statistics = statistics_config,
            .cost_controls = cost_controls_config,
            ._parsed = parsed,
        };
    }

    /// Get configuration for specific provider
    pub fn getProviderConfig(self: *const Config, provider: provider_mod.Provider) ?*const ProviderConfig {
        const provider_name = @tagName(provider);
        return self.providers.getPtr(provider_name);
    }

    /// Check if provider is configured
    pub fn hasProvider(self: *const Config, provider: provider_mod.Provider) bool {
        const provider_name = @tagName(provider);
        return self.providers.contains(provider_name);
    }

    /// Cleanup configuration
    pub fn deinit(self: *Config) void {
        var it = self.providers.valueIterator();
        while (it.next()) |prov_config| {
            prov_config.deinit();
        }
        self.providers.deinit();
        self._parsed.deinit();
    }
};

/// Configuration errors — defined in errors.zig
pub const ConfigError = @import("errors.zig").ConfigError;

// ============================================================================
// Raw Config File Access
// ============================================================================

/// Resolve the config file path (same logic as Config.load)
fn resolveConfigPath(buf: []u8) ![]const u8 {
    if (std.posix.getenv("ZIG_ZAG_CONFIG")) |config_path| {
        return config_path;
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return try std.fmt.bufPrint(buf, "{s}/.config/zig-zag/config.json", .{home});
}

/// Read the raw config file bytes.
/// Caller owns the returned slice and must free it.
pub fn readRaw(allocator: std.mem.Allocator) ![]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try resolveConfigPath(&path_buf);

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        log_mod.err("readRaw: failed to open config file: {s}", .{config_path});
        return err;
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
}

/// Write raw JSON bytes to the config file atomically.
/// Validates that `json` is valid JSON before writing.
/// Uses a .tmp file + rename to avoid partial writes on crash.
pub fn writeRaw(allocator: std.mem.Allocator, json: []const u8) !void {
    // Validate JSON first — refuse to write garbage
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return error.InvalidConfigFormat;
    };
    parsed.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try resolveConfigPath(&path_buf);

    // Build .tmp path
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{config_path});

    // Write to .tmp
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| {
        log_mod.err("writeRaw: failed to create tmp file: {s}", .{tmp_path});
        return err;
    };
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    try tmp_file.writeAll(json);
    tmp_file.close();

    // Atomic rename .tmp → config file
    std.fs.cwd().rename(tmp_path, config_path) catch |err| {
        log_mod.err("writeRaw: failed to rename {s} → {s}", .{ tmp_path, config_path });
        return err;
    };

    log_mod.info("Config written to {s} ({d} bytes)", .{ config_path, json.len });
}

// ============================================================================
// Unit Tests
// ============================================================================
