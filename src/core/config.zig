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
const Allocator = std.mem.Allocator;
const provider_mod = @import("provider.zig");
const log_mod = @import("log.zig");
const worker_pool = @import("worker_pool.zig");
const LogOutput = log_mod.LogOutput;

// Provider clients — used by auth functions
const CopilotClient = @import("providers/copilot/client.zig").CopilotClient;
const SapAiCoreClient = @import("providers/sap_ai_core/client.zig").SapAiCoreClient;
const HaiClient = @import("providers/hai/client.zig").HaiClient;

// ============================================================================
// Global config singleton — set by wrapper, accessed by core
// ============================================================================

var global_config: ?*const Config = null;
var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var config_path_len: usize = 0;

/// Set the global config singleton reference and store the config file path.
///
/// Must be called **exactly once** by the wrapper (e.g. `main.zig` or `lib.zig`)
/// after `Config.parseFromJson()` completes successfully.
/// All core modules obtain configuration via `config.get()`, so the proxy will
/// panic on the first access if this function was never called.
///
/// The `path` is stored internally so that `readRaw()` and `writeRaw()` can
/// access the same file without the caller passing it again.
///
/// **Example (wrapper startup)**:
/// ```zig
/// const path = resolveConfigPath();   // wrapper decides the path
/// var cfg = try Config.parseFromJson(allocator, parsed);
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

/// Compile-time default values for core settings.
///
/// This namespace is the **single source of truth** for defaults used by
/// core modules.  Wrapper-specific defaults (server, statistics) live in
/// the wrapper's own config module.
pub const defaults = struct {
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

/// Cost / budget controls, parsed from the `"cost_controls"` section of `config.json`.
///
/// When `enabled` is `true` the proxy enforces a spending limit:
/// - Requests are rejected with **429 Too Many Requests** once the budget is exhausted.
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

/// Core configuration — providers, logging, and cost controls.
///
/// This struct contains only the settings needed by the core library.
/// Wrapper-specific settings (server, statistics) are managed by the
/// wrapper's own config type.
///
/// Owns the root `std.json.Parsed` tree and a hash-map of `ProviderConfig`
/// entries.  All string slices inside nested structs are **borrowed** from
/// the parsed tree, so they remain valid until `deinit()` is called.
///
/// Typical lifecycle:
/// ```
/// var cfg = try Config.parseFromJson(allocator, parsed);
/// defer cfg.deinit();
/// config.set(&cfg, path);
/// ```
pub const Config = struct {
    allocator: Allocator,
    /// Map of provider name → `ProviderConfig` (e.g. `"openai"` → config object).
    providers: std.StringHashMap(ProviderConfig),
    log: LogConfig,
    cost_controls: CostControlsConfig,
    /// The root parsed JSON tree.  Kept alive so that all borrowed slices
    /// in `ProviderConfig` and other structs remain valid.
    _parsed: std.json.Parsed(std.json.Value),

    /// Parse core configuration from an already-parsed JSON tree.
    ///
    /// The caller provides an `std.json.Parsed(std.json.Value)` obtained by
    /// parsing the config file.  **Ownership of `parsed` transfers to the
    /// returned `Config`** — the caller must NOT deinit it separately.
    ///
    /// The root value must be a JSON object with at least a `"providers"` key.
    /// Optional keys `"logging"` and `"cost_controls"` are merged with defaults.
    pub fn parseFromJson(allocator: Allocator, parsed: std.json.Parsed(std.json.Value)) !Config {
        // Validate it's an object
        if (parsed.value != .object) {
            log_mod.err("Config must be a JSON object", .{});
            return error.InvalidConfigFormat;
        }

        const root_obj = parsed.value.object;

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
                    if (v == .integer) log_config.max_file_size_mb = v.integer;
                }
                if (log_obj.get("max_files")) |v| {
                    if (v == .integer) log_config.max_files = v.integer;
                }
                if (log_obj.get("buffer_size")) |v| {
                    if (v == .integer) log_config.buffer_size = v.integer;
                }
                if (log_obj.get("flush_interval_ms")) |v| {
                    if (v == .integer) log_config.flush_interval_ms = v.integer;
                }
                if (log_obj.get("output")) |v| {
                    if (v == .string) {
                        log_config.output = if (std.mem.eql(u8, v.string, "stderr")) .stderr else .file;
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
                    if (v == .bool) cost_controls_config.enabled = v.bool;
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
            log_mod.err("Config must contain 'providers' object", .{});
            return error.InvalidConfigFormat;
        };

        if (providers_value != .object) {
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

            if (provider_value_ptr.* != .object) {
                log_mod.err("Provider config must be an object: {s}", .{provider_name});
                return error.InvalidProviderConfig;
            }

            const provider_config = ProviderConfig{
                .allocator = allocator,
                .name = provider_name,
                .raw = provider_value_ptr.*,
            };

            try providers.put(provider_name, provider_config);
        }

        return Config{
            .allocator = allocator,
            .providers = providers,
            .log = log_config,
            .cost_controls = cost_controls_config,
            ._parsed = parsed,
        };
    }

    /// Return a pointer to the `ProviderConfig` for the given `provider`, or
    /// `null` if that provider is not present in the config file.
    pub fn getProviderConfig(self: *const Config, provider: provider_mod.Provider) ?*const ProviderConfig {
        const provider_name = @tagName(provider);
        return self.providers.getPtr(provider_name);
    }

    /// Return `true` if the given `provider` has an entry in the `"providers"`
    /// section of the config file.
    pub fn hasProvider(self: *const Config, provider: provider_mod.Provider) bool {
        const provider_name = @tagName(provider);
        return self.providers.contains(provider_name);
    }

    /// Release all resources owned by this configuration.
    ///
    /// Deinitialises every `ProviderConfig`, the provider hash-map, and the
    /// root parsed JSON tree.  After this call **all** borrowed slices
    /// (provider names, string config values, etc.) become invalid.
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
// Provider Auth API
// ============================================================================

/// Unified auth status across all providers.
///
/// - `authenticated` — a valid cached token exists; the provider is ready.
/// - `configured`    — credentials exist on disk but no cached token yet
///                     (Copilot-specific: `apps.json` has an entry).
/// - `unauthenticated` — no credentials and no cached token.
pub const AuthStatus = enum {
    authenticated,
    configured,
    unauthenticated,
};

/// Result of `initiateAuth`.
///
/// - `authenticated` — the provider authenticated synchronously (SAP AI Core,
///   HAI).  The caller can report success immediately.
/// - `device_flow`  — a device-flow was started (Copilot).  The caller should
///   show `user_code` + `verification_uri` to the user.  A background poll
///   thread has already been spawned; subsequent calls to `checkAuthStatus`
///   will eventually return `.authenticated`.
/// - `err` — the auth attempt failed.  `message` describes what went wrong.
pub const AuthResult = union(enum) {
    authenticated,
    device_flow: struct {
        user_code: []const u8,
        verification_uri: []const u8,
    },
    err: struct {
        message: []const u8,
    },
};

/// Check authentication status for a provider.
///
/// Returns immediately without blocking or performing network I/O — it only
/// inspects cached tokens and local credential files.
///
/// Unknown or unconfigured provider names return `.unauthenticated`.
pub fn checkAuthStatus(allocator: Allocator, provider_name: []const u8) AuthStatus {
    const cfg = get();
    const eql = std.mem.eql;

    if (eql(u8, provider_name, "copilot")) {
        // Check device flow state first — if a poll is active or just succeeded
        const df_status = device_flow_state.status.load(.acquire);
        if (df_status == .authenticated) return .authenticated;
        if (df_status == .pending) return .configured;

        const provider_config = cfg.providers.getPtr(provider_name) orelse return .unauthenticated;
        var client = CopilotClient.init(allocator, provider_config) catch return .unauthenticated;
        defer client.deinit();
        return switch (client.authStatus()) {
            .authenticated => .authenticated,
            .configured => .configured,
            .unauthenticated => .unauthenticated,
        };
    }

    if (eql(u8, provider_name, "sap_ai_core")) {
        const provider_config = cfg.providers.getPtr(provider_name) orelse return .unauthenticated;
        var client = SapAiCoreClient.init(allocator, provider_config) catch return .unauthenticated;
        defer client.deinit();
        return switch (client.authStatus()) {
            .authenticated => .authenticated,
            .unauthenticated => .unauthenticated,
        };
    }

    if (eql(u8, provider_name, "hai")) {
        const provider_config = cfg.providers.getPtr(provider_name) orelse return .unauthenticated;
        var client = HaiClient.init(allocator, provider_config) catch return .unauthenticated;
        defer client.deinit();
        return switch (client.authStatus()) {
            .authenticated => .authenticated,
            .unauthenticated => .unauthenticated,
        };
    }

    return .unauthenticated;
}

/// Start authentication for a provider.
///
/// **Copilot:** Returns `.device_flow` with user code and verification URI.
/// A background thread polls GitHub until the user authorises the device;
/// subsequent `checkAuthStatus("copilot")` calls track progress.
/// If a device flow is already pending, returns the in-progress codes.
///
/// **SAP AI Core / HAI:** Blocks until the auth flow completes (client-
/// credentials grant or browser-based OIDC respectively).  Returns
/// `.authenticated` on success or `.err` on failure.
///
/// Unknown or unconfigured providers return `.err`.
pub fn initiateAuth(allocator: Allocator, provider_name: []const u8) AuthResult {
    const cfg = get();
    const eql = std.mem.eql;

    if (eql(u8, provider_name, "copilot")) {
        return initiateCopilotAuth(allocator, cfg, provider_name);
    }

    if (eql(u8, provider_name, "sap_ai_core")) {
        return initiateSapAiCoreAuth(allocator, cfg, provider_name);
    }

    if (eql(u8, provider_name, "hai")) {
        return initiateHaiAuth(allocator, cfg, provider_name);
    }

    return .{ .err = .{ .message = "Unknown provider" } };
}

/// Revoke cached tokens for a provider.
///
/// Clears the in-memory token cache (and, for Copilot, the `apps.json`
/// entry).  Resets any in-progress device flow state.
///
/// No-op for unknown or unconfigured providers.
pub fn revokeAuth(allocator: Allocator, provider_name: []const u8) void {
    const cfg = get();
    const eql = std.mem.eql;

    if (eql(u8, provider_name, "copilot")) {
        const provider_config = cfg.providers.getPtr(provider_name) orelse return;
        var client = CopilotClient.init(allocator, provider_config) catch return;
        defer client.deinit();
        client.revokeAuth();
        device_flow_state.status.store(.idle, .release);
        return;
    }

    if (eql(u8, provider_name, "sap_ai_core")) {
        const provider_config = cfg.providers.getPtr(provider_name) orelse return;
        var client = SapAiCoreClient.init(allocator, provider_config) catch return;
        defer client.deinit();
        client.revokeAuth();
        return;
    }

    if (eql(u8, provider_name, "hai")) {
        const provider_config = cfg.providers.getPtr(provider_name) orelse return;
        var client = HaiClient.init(allocator, provider_config) catch return;
        defer client.deinit();
        client.revokeAuth();
        return;
    }
}

// ============================================================================
// Auth internals — Copilot device flow
// ============================================================================

const DeviceFlowStatus = enum(u8) { idle, pending, authenticated, failed };

const DeviceFlowState = struct {
    status: std.atomic.Value(DeviceFlowStatus),
    user_code: [32]u8,
    user_code_len: usize,
    verification_uri: [256]u8,
    verification_uri_len: usize,
};

var device_flow_state: DeviceFlowState = .{
    .status = std.atomic.Value(DeviceFlowStatus).init(.idle),
    .user_code = [_]u8{0} ** 32,
    .user_code_len = 0,
    .verification_uri = [_]u8{0} ** 256,
    .verification_uri_len = 0,
};

/// Thread args for the background device-flow poll task.
/// Uses fixed-size buffers so it can be allocated with page_allocator
/// (survives after the request's arena allocator is freed).
const DeviceFlowThreadArgs = struct {
    provider_config: *const ProviderConfig,
    device_code: [256]u8,
    device_code_len: usize,
    interval: i64,
    expires_in: i64,
};

fn deviceFlowPollTask(ctx: *anyopaque) void {
    const args_ptr: *DeviceFlowThreadArgs = @ptrCast(@alignCast(ctx));
    const args = args_ptr.*;
    defer std.heap.page_allocator.destroy(args_ptr);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const thread_allocator = gpa.allocator();

    var client = CopilotClient.init(thread_allocator, args.provider_config) catch |err| {
        log_mod.err("[auth/copilot] poll thread: failed to init client: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return;
    };
    defer client.deinit();

    const device_code = args.device_code[0..args.device_code_len];
    client.completeDeviceFlow(device_code, args.interval, args.expires_in) catch |err| {
        log_mod.err("[auth/copilot] device flow poll failed: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return;
    };

    device_flow_state.status.store(.authenticated, .release);
    log_mod.info("[auth/copilot] device flow completed — authenticated", .{});
}

fn initiateCopilotAuth(allocator: Allocator, cfg: *const Config, provider_name: []const u8) AuthResult {
    // If a flow is already pending, return the in-progress codes
    const current = device_flow_state.status.load(.acquire);
    if (current == .pending) {
        return .{ .device_flow = .{
            .user_code = device_flow_state.user_code[0..device_flow_state.user_code_len],
            .verification_uri = device_flow_state.verification_uri[0..device_flow_state.verification_uri_len],
        } };
    }

    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        return .{ .err = .{ .message = "Provider not configured" } };
    };

    var client = CopilotClient.init(allocator, provider_config) catch {
        return .{ .err = .{ .message = "Failed to initialize client" } };
    };
    defer client.deinit();

    var result = client.startDeviceFlow() catch {
        return .{ .err = .{ .message = "Failed to start device flow" } };
    };
    defer result.deinit();

    // Store codes in module-level state for subsequent status polls
    const uc_len = @min(result.user_code.len, device_flow_state.user_code.len);
    @memcpy(device_flow_state.user_code[0..uc_len], result.user_code[0..uc_len]);
    device_flow_state.user_code_len = uc_len;

    const uri_len = @min(result.verification_uri.len, device_flow_state.verification_uri.len);
    @memcpy(device_flow_state.verification_uri[0..uri_len], result.verification_uri[0..uri_len]);
    device_flow_state.verification_uri_len = uri_len;

    device_flow_state.status.store(.pending, .release);

    // Spawn background poll thread
    const thread_args = std.heap.page_allocator.create(DeviceFlowThreadArgs) catch {
        device_flow_state.status.store(.failed, .release);
        return .{ .err = .{ .message = "Failed to allocate thread args" } };
    };

    const dc_len = @min(result.device_code.len, thread_args.device_code.len);
    @memcpy(thread_args.device_code[0..dc_len], result.device_code[0..dc_len]);
    thread_args.* = .{
        .provider_config = provider_config,
        .device_code = thread_args.device_code,
        .device_code_len = dc_len,
        .interval = result.interval,
        .expires_in = result.expires_in,
    };

    worker_pool.submit(&deviceFlowPollTask, @ptrCast(thread_args)) catch {
        std.heap.page_allocator.destroy(thread_args);
        device_flow_state.status.store(.failed, .release);
        return .{ .err = .{ .message = "Failed to submit poll task" } };
    };

    return .{ .device_flow = .{
        .user_code = device_flow_state.user_code[0..device_flow_state.user_code_len],
        .verification_uri = device_flow_state.verification_uri[0..device_flow_state.verification_uri_len],
    } };
}

// ============================================================================
// Auth internals — SAP AI Core (client-credentials, fully automated)
// ============================================================================

fn initiateSapAiCoreAuth(allocator: Allocator, cfg: *const Config, provider_name: []const u8) AuthResult {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        return .{ .err = .{ .message = "Provider not configured" } };
    };

    var client = SapAiCoreClient.init(allocator, provider_config) catch {
        return .{ .err = .{ .message = "Failed to initialize client" } };
    };
    defer client.deinit();

    // SAP AI Core uses client-credentials grant — fetch and cache token
    const access_token = client.fetchToken() catch {
        return .{ .err = .{ .message = "Authentication failed" } };
    };
    allocator.free(access_token);

    log_mod.info("[auth/sap_ai_core] auth successful", .{});
    return .authenticated;
}

// ============================================================================
// Auth internals — HAI (browser-based OIDC)
// ============================================================================

fn initiateHaiAuth(allocator: Allocator, cfg: *const Config, provider_name: []const u8) AuthResult {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        return .{ .err = .{ .message = "Provider not configured" } };
    };

    var client = HaiClient.init(allocator, provider_config) catch {
        return .{ .err = .{ .message = "Failed to initialize client" } };
    };
    defer client.deinit();

    // HAI requires browser-based OIDC login — this blocks until the user
    // completes authentication in their browser (up to 120s timeout).
    const access_token = client.browserAuthFlow() catch {
        return .{ .err = .{ .message = "Authentication failed" } };
    };
    allocator.free(access_token);

    log_mod.info("[auth/hai] auth successful", .{});
    return .authenticated;
}

// ============================================================================
// Unit Tests
// ============================================================================
