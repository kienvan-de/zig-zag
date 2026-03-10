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

// ============================================================================
// Global config singleton — set by wrapper, accessed by core
// ============================================================================

var global_config: ?*const Config = null;
var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var config_path_len: usize = 0;

/// Set the global config singleton reference and store the config file path.
///
/// Must be called **exactly once** by the wrapper (e.g. `main.zig` or `lib.zig`)
/// after `Config.loadFromFile()` completes successfully.
/// All core modules obtain configuration via `config.get()`, so the proxy will
/// panic on the first access if this function was never called.
///
/// The `path` is stored internally so that `readRaw()` and `writeRaw()` can
/// access the same file without the caller passing it again.
///
/// **Example (wrapper startup)**:
/// ```zig
/// const path = resolveConfigPath();   // wrapper decides the path
/// var cfg = try Config.loadFromFile(allocator, path);
/// config.set(&cfg, path);
/// ```
pub fn set(cfg: *const Config, path: []const u8) void {
    global_config = cfg;
    @memcpy(config_path_buf[0..path.len], path);
    config_path_len = path.len;
}

/// Return the stored config file path.
/// Panics if `set()` has not been called yet.
pub fn getPath() []const u8 {
    if (config_path_len == 0) @panic("config path not set — call config.set() first");
    return config_path_buf[0..config_path_len];
}

/// Return the global config singleton.
///
/// This is the primary entry-point used throughout the core and handler code
/// to read configuration at runtime.  It is safe to call from any thread
/// because the pointer is set once at startup and never mutated afterwards.
///
/// **Panics** if `set()` has not been called yet.
pub fn get() *const Config {
    return global_config orelse @panic("config not set — call config.set() first");
}

/// Provider-specific configuration backed by a raw JSON object.
///
/// Each key inside the top-level `"providers"` object in `config.json` is
/// parsed into a `ProviderConfig`.  The struct does **not** copy data — it
/// holds a reference into the root `std.json.Parsed` tree owned by `Config`,
/// so it remains valid for the lifetime of the parent `Config`.
///
/// Type-safe accessors (`getString`, `getInt`, `getFloat`, `getBool`) let
/// provider client code read values without touching raw JSON directly.
pub const ProviderConfig = struct {
    allocator: std.mem.Allocator,
    /// Provider name taken from the config key (e.g. `"openai"`, `"groq"`, `"anthropic"`).
    name: []const u8,
    /// The raw JSON object for this provider — a reference into the root parsed tree.
    raw: std.json.Value,

    /// Look up a string value by `key` in this provider's JSON object.
    ///
    /// Returns `null` when the key is missing or the value is not a JSON string.
    pub fn getString(self: *const ProviderConfig, key: []const u8) ?[]const u8 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    /// Look up an integer value by `key` in this provider's JSON object.
    ///
    /// Returns `null` when the key is missing or the value is not a JSON integer.
    pub fn getInt(self: *const ProviderConfig, key: []const u8) ?i64 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Look up a floating-point value by `key` in this provider's JSON object.
    ///
    /// JSON integers are transparently promoted to `f64`, so a config entry
    /// like `"timeout": 30` is returned as `30.0`.
    /// Returns `null` when the key is missing or the value is neither float nor integer.
    pub fn getFloat(self: *const ProviderConfig, key: []const u8) ?f64 {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Look up a boolean value by `key` in this provider's JSON object.
    ///
    /// Returns `null` when the key is missing or the value is not a JSON boolean.
    pub fn getBool(self: *const ProviderConfig, key: []const u8) ?bool {
        const obj = self.raw.object;
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Release resources owned by this provider config.
    ///
    /// Currently a no-op because all data is borrowed from the root parsed
    /// tree (freed by `Config.deinit()`).  Retained for API compatibility so
    /// callers that iterate and deinit individual providers keep compiling.
    pub fn deinit(self: *ProviderConfig) void {
        _ = self;
    }
};

// ============================================================================
// Default Values (single source of truth)
// ============================================================================

/// Compile-time default values for every configurable setting.
///
/// This namespace is the **single source of truth** for defaults — struct
/// field initialisers in `ServerConfig`, `LogConfig`, etc. reference these
/// constants so that a missing JSON key always falls back to a well-known
/// value without duplicating magic numbers.
pub const defaults = struct {
    // ── Server ──────────────────────────────────────────────────────────
    /// Default bind address (all interfaces).
    pub const server_host: []const u8 = "0.0.0.0";
    /// Default listening port.
    pub const server_port: u16 = 8080;
    /// Number of HTTP worker threads in the server pool.
    pub const server_http_pool_size: i64 = 3;
    /// Number of I/O worker threads for background tasks.
    pub const server_io_pool_size: i64 = 1;
    /// Maximum HTTP header size in bytes (32 KB).
    pub const server_max_header_size: i64 = 32 * 1024; // 32 KB
    /// Maximum HTTP body size in bytes (10 MB).
    pub const server_max_body_size: i64 = 10 * 1024 * 1024; // 10 MB
    /// Read timeout per connection in milliseconds (30 s).
    pub const server_read_timeout_ms: i64 = 30_000; // 30 s

    // ── Logging ─────────────────────────────────────────────────────────
    /// Maximum size of a single log file before rotation, in megabytes.
    pub const log_max_file_size_mb: i64 = 10;
    /// Maximum number of rotated log files to retain.
    pub const log_max_files: i64 = 5;
    /// In-memory log buffer size (number of entries).
    pub const log_buffer_size: i64 = 100;
    /// Interval between automatic log flushes, in milliseconds.
    pub const log_flush_interval_ms: i64 = 1_000;

    // ── Provider (shared across all providers) ──────────────────────────
    /// Upstream request timeout in milliseconds (60 s).
    pub const provider_timeout_ms: i64 = 60_000; // 60 s
    /// Maximum upstream response body size in megabytes.
    pub const provider_max_response_size_mb: i64 = 10;
};

/// HTTP server configuration, parsed from the `"server"` section of `config.json`.
///
/// Every field has a sensible default (see `defaults`) so the entire section
/// can be omitted from the config file.
pub const ServerConfig = struct {
    port: u16 = defaults.server_port,
    host: []const u8 = defaults.server_host,
    http_pool_size: i64 = defaults.server_http_pool_size,
    io_pool_size: i64 = defaults.server_io_pool_size,
    max_header_size: i64 = defaults.server_max_header_size,
    max_body_size: i64 = defaults.server_max_body_size,
    read_timeout_ms: i64 = defaults.server_read_timeout_ms,
};

/// Logging configuration, parsed from the `"logging"` section of `config.json`.
///
/// Controls log level, output destination (`stderr` or rotating files),
/// file rotation policy, and the in-memory buffer that batches writes.
/// All fields are optional and fall back to `defaults`.
pub const LogConfig = struct {
    level: std.log.Level = .info,
    /// Explicit log file path.  `null` means use the OS-default location.
    path: ?[]const u8 = null,
    max_file_size_mb: i64 = defaults.log_max_file_size_mb,
    max_files: i64 = defaults.log_max_files,
    buffer_size: i64 = defaults.log_buffer_size,
    flush_interval_ms: i64 = defaults.log_flush_interval_ms,
    /// Output destination — `"file"` or `"stderr"` in the JSON; defaults to `.stderr`.
    output: LogOutput = .stderr,
};

/// Statistics display toggles, parsed from the `"statistics"` section of `config.json`.
///
/// These flags control which informational rows are visible in the macOS
/// menu-bar app.  They have no effect on the proxy's runtime behaviour —
/// metrics are always collected regardless of these settings.
pub const StatisticsConfig = struct {
    /// Show the RAM / CPU / Network performance row.
    show_performance: bool = true,
    /// Show the Providers / Input-Output tokens row.
    show_llm: bool = true,
    /// Show the cost row.  Overridden to `true` when `CostControlsConfig.enabled` is set.
    show_cost: bool = true,
};

/// Cost / budget controls, parsed from the `"cost_controls"` section of `config.json`.
///
/// When `enabled` is `true` the proxy enforces a spending limit:
/// - Requests are rejected with **429 Too Many Requests** once the budget is exhausted.
/// - The cost row in the macOS app always shows regardless of `StatisticsConfig.show_cost`,
///   and displays **remaining budget** instead of total spent.
/// - On startup, if the budget period has expired, both costs **and** token counts
///   are reset before any request is served (see `utils.checkBudgetPeriodOnStartup`).
pub const CostControlsConfig = struct {
    /// Master switch — `false` disables all budget enforcement.
    enabled: bool = false,
    /// Spending limit in USD for the current period.
    budget: f64 = 0.0,
    /// Budget reset period in days.  `0` = lifetime (never resets),
    /// `1` = daily, `30` = monthly, etc.
    days_duration: u32 = 0,
};

/// Main application configuration — the top-level result of parsing `config.json`.
///
/// Owns the root `std.json.Parsed` tree and a hash-map of `ProviderConfig`
/// entries.  All string slices inside nested structs (e.g. `ServerConfig.host`,
/// `ProviderConfig.name`) are **borrowed** from the parsed tree, so they remain
/// valid until `deinit()` is called.
///
/// Typical lifecycle:
/// ```
/// var cfg = try Config.loadFromFile(allocator, path);
/// defer cfg.deinit();
/// config.set(&cfg, path);                 // publish as global singleton
/// ```
pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Map of provider name → `ProviderConfig` (e.g. `"openai"` → config object).
    providers: std.StringHashMap(ProviderConfig),
    server: ServerConfig,
    log: LogConfig,
    statistics: StatisticsConfig,
    cost_controls: CostControlsConfig,
    /// The root parsed JSON tree.  Kept alive so that all borrowed slices
    /// in `ProviderConfig` and other structs remain valid.
    _parsed: std.json.Parsed(std.json.Value),

    /// Load and parse configuration from an explicit file path.
    ///
    /// The file must contain a JSON object with at least a `"providers"` key.
    /// Optional top-level keys (`"server"`, `"logging"`, `"statistics"`,
    /// `"cost_controls"`) are merged with their respective defaults.
    ///
    /// On success the returned `Config` owns all allocated memory; call
    /// `deinit()` when it is no longer needed.
    ///
    /// **Side-effect:** caches `server.port` in `app_cache` so that provider
    /// clients (e.g. Copilot redirect URI) can discover the port without a
    /// direct config dependency.
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

    /// Return a pointer to the `ProviderConfig` for the given `provider`, or
    /// `null` if that provider is not present in the config file.
    ///
    /// The returned pointer borrows into `self.providers` and is valid for
    /// the lifetime of this `Config`.
    pub fn getProviderConfig(self: *const Config, provider: provider_mod.Provider) ?*const ProviderConfig {
        const provider_name = @tagName(provider);
        return self.providers.getPtr(provider_name);
    }

    /// Return `true` if the given `provider` has an entry in the `"providers"`
    /// section of the config file (regardless of whether its fields are valid).
    pub fn hasProvider(self: *const Config, provider: provider_mod.Provider) bool {
        const provider_name = @tagName(provider);
        return self.providers.contains(provider_name);
    }

    /// Release all resources owned by this configuration.
    ///
    /// Deinitialises every `ProviderConfig`, the provider hash-map, and the
    /// root parsed JSON tree.  After this call **all** borrowed slices
    /// (provider names, string config values, `ServerConfig.host`, etc.)
    /// become invalid.
    pub fn deinit(self: *Config) void {
        var it = self.providers.valueIterator();
        while (it.next()) |prov_config| {
            prov_config.deinit();
        }
        self.providers.deinit();
        self._parsed.deinit();
    }
};

/// Configuration error set, re-exported from `errors.zig`.
///
/// Includes errors such as `InvalidConfigFormat`, `InvalidProviderConfig`,
/// and `HomeNotFound` that can be returned during config loading and
/// validation.
pub const ConfigError = @import("errors.zig").ConfigError;

// ============================================================================
// Raw Config File Access
// ============================================================================

/// Read the raw config file as an unprocessed byte slice.
///
/// Uses the config file path stored by `set()`.
/// The caller **owns** the returned slice and must free it with `allocator`.
/// Maximum file size: 1 MB.
pub fn readRaw(allocator: std.mem.Allocator) ![]const u8 {
    const config_path = getPath();

    const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
        log_mod.err("readRaw: failed to open config file: {s}", .{config_path});
        return err;
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
}

/// Atomically write raw JSON bytes to the config file.
///
/// 1. **Validates** that `json` is syntactically valid JSON — refuses to
///    write malformed data (returns `error.InvalidConfigFormat`).
/// 2. Writes to a temporary `.tmp` sibling file.
/// 3. Performs an atomic **rename** (`.tmp` → config path) so that readers
///    never observe a partially-written file, even on crash.
///
/// Uses the config file path stored by `set()`.
pub fn writeRaw(allocator: std.mem.Allocator, json: []const u8) !void {
    // Validate JSON first — refuse to write garbage
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return error.InvalidConfigFormat;
    };
    parsed.deinit();

    const config_path = getPath();

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
