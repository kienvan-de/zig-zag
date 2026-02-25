const std = @import("std");
const provider_mod = @import("provider.zig");
const log_mod = @import("log.zig");

/// Provider-specific configuration
/// Wraps a parsed JSON object and provides type-safe accessors
pub const ProviderConfig = struct {
    allocator: std.mem.Allocator,
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

/// Server configuration
pub const ServerConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "0.0.0.0",
    http_pool_size: ?i64 = null,
    io_pool_size: ?i64 = null,
};

/// Logging configuration
pub const LogConfig = struct {
    level: std.log.Level = .info,
    path: ?[]const u8 = null, // null = use OS default
    max_file_size_mb: i64 = 10, // rotate when file exceeds this size
    max_files: i64 = 5, // keep this many rotated files
    buffer_size: i64 = 100, // number of messages to buffer before flush
    flush_interval_ms: i64 = 1000, // auto-flush interval in milliseconds
};

/// Main application configuration
pub const Config = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(ProviderConfig),
    server: ServerConfig,
    log: LogConfig,
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
            std.debug.print("Failed to open config file: {s}\n", .{path});
            std.debug.print("Error: {}\n", .{err});
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
            std.debug.print("Config must be a JSON object\n", .{});
            return error.InvalidConfigFormat;
        }

        const root_obj = parsed.value.object;

        // Parse server config (optional, with defaults)
        var server_config = ServerConfig{};
        if (root_obj.get("server")) |server_value| {
            if (server_value != .object) {
                parsed.deinit();
                std.debug.print("Server config must be an object\n", .{});
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
            if (server_obj.get("http_pool_size")) |pool_value| {
                if (pool_value == .integer) {
                    server_config.http_pool_size = pool_value.integer;
                }
            }
            if (server_obj.get("io_pool_size")) |pool_value| {
                if (pool_value == .integer) {
                    server_config.io_pool_size = pool_value.integer;
                }
            }
        }

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
            }
        }

        // Get providers object
        const providers_value = root_obj.get("providers") orelse {
            parsed.deinit();
            std.debug.print("Config must contain 'providers' object\n", .{});
            return error.InvalidConfigFormat;
        };

        if (providers_value != .object) {
            parsed.deinit();
            std.debug.print("'providers' must be a JSON object\n", .{});
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
                std.debug.print("Provider config must be an object: {s}\n", .{provider_name});
                return error.InvalidProviderConfig;
            }

            // Create a wrapper that references the value in the root parsed object
            const provider_config = ProviderConfig{
                .allocator = allocator,
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

/// Configuration errors
pub const ConfigError = error{
    HomeNotFound,
    FileNotFound,
    InvalidConfigFormat,
    InvalidProvider,
    InvalidProviderConfig,
    MissingApiKey,
    OutOfMemory,
};

// ============================================================================
// Unit Tests
// ============================================================================
