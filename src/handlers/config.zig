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

//! Config REST Handler
//!
//! Handles all requests to /v1/config/* routes.
//! Dispatches internally by method + path:
//!
//!   GET    /v1/config/data                  → handleGet
//!   POST   /v1/config/data                  → handlePost
//!   GET    /v1/config/{provider}/auth        → provider auth status
//!   POST   /v1/config/{provider}/auth        → start provider auth flow
//!   DELETE /v1/config/{provider}/auth        → revoke provider auth

const std = @import("std");
const http = @import("../http.zig");
const errors = @import("../errors.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const token_cache = @import("../cache/token_cache.zig");
const http_client = @import("../client.zig");
const auth = @import("../auth/mod.zig");

const COPILOT_CACHE_KEY = "copilot";
const COPILOT_DEFAULT_CLIENT_ID = "Iv1.b507a08c87ecfe98";
const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code";
const GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token";

// ============================================================================
// Device Flow State — module-level, single Copilot instance
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

// ============================================================================
// Top-level dispatcher
// ============================================================================

pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const eql = std.mem.eql;

    if (eql(u8, path, "/v1/config/data")) {
        if (eql(u8, method, "GET")) return handleGet(allocator, connection);
        if (eql(u8, method, "POST")) return handlePost(allocator, connection, body);
    }

    // Match /v1/config/{provider}/auth
    const auth_prefix = "/v1/config/";
    const auth_suffix = "/auth";
    if (std.mem.startsWith(u8, path, auth_prefix) and std.mem.endsWith(u8, path, auth_suffix)) {
        const rest = path[auth_prefix.len..];
        const provider_name = rest[0 .. rest.len - auth_suffix.len];
        if (provider_name.len > 0 and std.mem.indexOfScalar(u8, provider_name, '/') == null) {
            return dispatchProviderAuth(allocator, connection, method, provider_name, cfg);
        }
    }

    log.warn("Config handler: no match for {s} {s}", .{ method, path });
    return http.sendNotFound(connection);
}

/// Dispatch GET/POST/DELETE /v1/config/{provider}/auth to provider-specific handlers
fn dispatchProviderAuth(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const eql = std.mem.eql;

    if (eql(u8, provider_name, "copilot")) {
        if (eql(u8, method, "GET")) return handleCopilotAuthStatus(allocator, connection);
        if (eql(u8, method, "POST")) return handleCopilotAuth(allocator, connection);
        if (eql(u8, method, "DELETE")) return handleCopilotAuthRevoke(allocator, connection);
    }

    _ = cfg; // Will be used by SAP AI Core + HAI handlers in TASK-12

    log.warn("Config auth: unsupported provider '{s}'", .{provider_name});
    return http.sendNotFound(connection);
}

// ============================================================================
// Config data — GET / POST
// ============================================================================

fn handleGet(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    const raw = config_mod.readRaw(allocator) catch |err| {
        log.err("Config read failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer allocator.free(raw);
    try http.sendJsonResponse(connection, .ok, raw);
}

fn handlePost(allocator: std.mem.Allocator, connection: std.net.Server.Connection, body: []const u8) !void {
    config_mod.writeRaw(allocator, body) catch |err| {
        log.err("Config write failed: {}", .{err});
        const msg = if (err == error.InvalidConfigFormat)
            "Invalid JSON"
        else
            "Failed to write config";
        const error_json = try errors.createErrorResponse(allocator, msg, .invalid_request_error, null);
        defer allocator.free(error_json);
        return http.sendJsonResponse(connection, .bad_request, error_json);
    };
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}

// ============================================================================
// Copilot auth — status
// ============================================================================

fn handleCopilotAuthStatus(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    // 1. In-memory token cache hit → "authenticated"
    if (token_cache.get(allocator, COPILOT_CACHE_KEY, 0)) |result| {
        allocator.free(result.access_token);
        if (result.refresh_token) |rt| allocator.free(rt);
        log.debug("[config/copilot] auth status: authenticated (token_cache hit)", .{});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"authenticated\"}");
    }

    // 2. apps.json exists with a valid entry → "configured"
    if (appsJsonHasEntry(allocator, COPILOT_DEFAULT_CLIENT_ID)) {
        log.debug("[config/copilot] auth status: configured (apps.json entry)", .{});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"configured\"}");
    }

    // 3. Neither → "unauthenticated"
    log.debug("[config/copilot] auth status: unauthenticated", .{});
    try http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
}

/// Returns true if ~/.config/github-copilot/apps.json exists and contains
/// an entry for "github.com:<client_id>".
fn appsJsonHasEntry(allocator: std.mem.Allocator, client_id: []const u8) bool {
    const home = std.posix.getenv("HOME") orelse return false;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const apps_path = std.fmt.bufPrint(
        &path_buf,
        "{s}/.config/github-copilot/apps.json",
        .{home},
    ) catch return false;

    const file = std.fs.cwd().openFile(apps_path, .{}) catch return false;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return false;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;

    var key_buf: [256]u8 = undefined;
    const lookup_key = std.fmt.bufPrint(&key_buf, "github.com:{s}", .{client_id}) catch return false;

    const entry = parsed.value.object.get(lookup_key) orelse return false;
    if (entry != .object) return false;
    return entry.object.get("oauth_token") != null;
}

// ============================================================================
// Copilot auth — start device flow (POST)
// ============================================================================

const DeviceFlowThreadArgs = struct {
    allocator: std.mem.Allocator,
    device_code: []const u8,
    interval: i64,
    expires_in: i64,
    client_id: []const u8,
};

fn deviceFlowPollThread(args_ptr: *DeviceFlowThreadArgs) void {
    const args = args_ptr.*;
    defer {
        args.allocator.free(args.device_code);
        args.allocator.free(args.client_id);
        args.allocator.destroy(args_ptr);
    }

    const params = auth.DeviceFlowParams{
        .device_code_url = GITHUB_DEVICE_CODE_URL,
        .token_url = GITHUB_ACCESS_TOKEN_URL,
        .client_id = args.client_id,
        .scope = "",
    };

    var client = http_client.HttpClient.initWithOptions(args.allocator, 60000, 10 * 1024 * 1024, null);
    defer client.deinit();

    var token = auth.oauth.pollDeviceToken(
        args.allocator,
        &client,
        params,
        args.device_code,
        args.interval,
        args.expires_in,
    ) catch |err| {
        log.err("[config/copilot] device flow poll failed: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return;
    };
    defer token.deinit();

    // Save token to apps.json (best-effort)
    saveTokenToAppsJson(args.allocator, token.access_token, args.client_id) catch |err| {
        log.warn("[config/copilot] failed to save token to apps.json: {}", .{err});
    };

    // Cache the token (expires_in from token response, default 8h for Copilot if zero)
    const expires_in_secs: i64 = if (token.expires_in > 0) token.expires_in else 28800;
    token_cache.put(COPILOT_CACHE_KEY, token.access_token, token.refresh_token, expires_in_secs) catch |err| {
        log.warn("[config/copilot] failed to cache token: {}", .{err});
    };

    device_flow_state.status.store(.authenticated, .release);
    log.info("[config/copilot] device flow completed — authenticated", .{});
}

fn handleCopilotAuth(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    // Only allow one flow at a time
    const current = device_flow_state.status.load(.acquire);
    if (current == .pending) {
        // Return the already-running flow's codes
        const user_code = device_flow_state.user_code[0..device_flow_state.user_code_len];
        const verification_uri = device_flow_state.verification_uri[0..device_flow_state.verification_uri_len];
        const resp = try std.fmt.allocPrint(allocator,
            "{{\"user_code\":\"{s}\",\"verification_uri\":\"{s}\"}}",
            .{ user_code, verification_uri },
        );
        defer allocator.free(resp);
        return http.sendJsonResponse(connection, .ok, resp);
    }

    const client_id = COPILOT_DEFAULT_CLIENT_ID;
    const params = auth.DeviceFlowParams{
        .device_code_url = GITHUB_DEVICE_CODE_URL,
        .token_url = GITHUB_ACCESS_TOKEN_URL,
        .client_id = client_id,
        .scope = "",
    };

    var client = http_client.HttpClient.initWithOptions(allocator, 30000, 1 * 1024 * 1024, null);
    defer client.deinit();

    var device_code = auth.oauth.requestDeviceCode(allocator, &client, params) catch |err| {
        log.err("[config/copilot] requestDeviceCode failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer device_code.deinit();

    // Store in module-level state for subsequent status polls
    const uc_len = @min(device_code.user_code.len, device_flow_state.user_code.len);
    @memcpy(device_flow_state.user_code[0..uc_len], device_code.user_code[0..uc_len]);
    device_flow_state.user_code_len = uc_len;

    const uri_len = @min(device_code.verification_uri.len, device_flow_state.verification_uri.len);
    @memcpy(device_flow_state.verification_uri[0..uri_len], device_code.verification_uri[0..uri_len]);
    device_flow_state.verification_uri_len = uri_len;

    device_flow_state.status.store(.pending, .release);

    // Spawn background thread to poll for token
    const thread_args = try allocator.create(DeviceFlowThreadArgs);
    thread_args.* = .{
        .allocator = allocator,
        .device_code = try allocator.dupe(u8, device_code.device_code),
        .interval = device_code.interval,
        .expires_in = device_code.expires_in,
        .client_id = try allocator.dupe(u8, client_id),
    };
    const thread = std.Thread.spawn(.{}, deviceFlowPollThread, .{thread_args}) catch |err| {
        log.err("[config/copilot] failed to spawn poll thread: {}", .{err});
        allocator.free(thread_args.device_code);
        allocator.free(thread_args.client_id);
        allocator.destroy(thread_args);
        device_flow_state.status.store(.failed, .release);
        return http.sendInternalError(connection);
    };
    thread.detach();

    // Respond immediately with the user code
    const resp = try std.fmt.allocPrint(allocator,
        "{{\"user_code\":\"{s}\",\"verification_uri\":\"{s}\"}}",
        .{ device_code.user_code, device_code.verification_uri },
    );
    defer allocator.free(resp);
    try http.sendJsonResponse(connection, .ok, resp);
}

// ============================================================================
// Copilot auth — revoke (DELETE)
// ============================================================================

fn handleCopilotAuthRevoke(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    // Clear in-memory token cache
    token_cache.remove(COPILOT_CACHE_KEY);
    log.info("[config/copilot] cleared token_cache for '{s}'", .{COPILOT_CACHE_KEY});

    // Remove apps.json entry (best-effort)
    removeAppsJsonEntry(allocator, COPILOT_DEFAULT_CLIENT_ID) catch |err| {
        log.warn("[config/copilot] failed to remove apps.json entry: {}", .{err});
    };

    // Reset device flow state
    device_flow_state.status.store(.idle, .release);

    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}

// ============================================================================
// Helpers — apps.json read / write
// ============================================================================

fn appsJsonPath(buf: []u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fmt.bufPrint(buf, "{s}/.config/github-copilot/apps.json", .{home});
}

fn saveTokenToAppsJson(allocator: std.mem.Allocator, access_token: []const u8, client_id: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/github-copilot", .{home}) catch return error.PathTooLong;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const apps_path = try appsJsonPath(&path_buf);

    std.fs.cwd().makePath(dir_path) catch {};

    // Read existing or start fresh
    var root_obj = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();
    var parsed_holder: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_holder) |*p| p.deinit();

    if (std.fs.cwd().openFile(apps_path, .{})) |file| {
        defer file.close();
        if (file.readToEndAlloc(allocator, 1024 * 1024)) |content| {
            defer allocator.free(content);
            if (std.json.parseFromSlice(std.json.Value, allocator, content, .{})) |p| {
                parsed_holder = p;
                if (p.value == .object) {
                    // Copy existing keys
                    var it = p.value.object.iterator();
                    while (it.next()) |kv| {
                        try root_obj.put(kv.key_ptr.*, kv.value_ptr.*);
                    }
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    var key_buf: [256]u8 = undefined;
    const lookup_key = std.fmt.bufPrint(&key_buf, "github.com:{s}", .{client_id}) catch return error.PathTooLong;
    const key_dupe = try allocator.dupe(u8, lookup_key);
    errdefer allocator.free(key_dupe);

    var entry_obj = std.json.ObjectMap.init(allocator);
    try entry_obj.put("oauth_token", .{ .string = access_token });
    try entry_obj.put("githubAppId", .{ .string = client_id });
    try root_obj.put(key_dupe, .{ .object = entry_obj });

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const root_val = std.json.Value{ .object = root_obj };
    buf.writer(allocator).print("{f}", .{std.json.fmt(root_val, .{ .whitespace = .indent_2 })}) catch |err| {
        log.err("[config/copilot] failed to serialize apps.json: {}", .{err});
        return error.FileWriteError;
    };

    const out = try std.fs.cwd().createFile(apps_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(buf.items);

    log.info("[config/copilot] saved OAuth token to {s}", .{apps_path});
}

fn removeAppsJsonEntry(allocator: std.mem.Allocator, client_id: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const apps_path = try appsJsonPath(&path_buf);

    const file = std.fs.cwd().openFile(apps_path, .{}) catch return; // not an error if missing
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch { file.close(); return; };
    file.close();
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    var key_buf: [256]u8 = undefined;
    const lookup_key = std.fmt.bufPrint(&key_buf, "github.com:{s}", .{client_id}) catch return;

    // Rebuild object without the entry
    var new_obj = std.json.ObjectMap.init(allocator);
    defer new_obj.deinit();
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, kv.key_ptr.*, lookup_key)) {
            try new_obj.put(kv.key_ptr.*, kv.value_ptr.*);
        }
    }

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const new_val = std.json.Value{ .object = new_obj };
    buf.writer(allocator).print("{f}", .{std.json.fmt(new_val, .{ .whitespace = .indent_2 })}) catch |err| {
        log.err("[config/copilot] failed to serialize apps.json: {}", .{err});
        return;
    };

    const out = try std.fs.cwd().createFile(apps_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(buf.items);

    log.info("[config/copilot] removed apps.json entry for '{s}'", .{lookup_key});
}
