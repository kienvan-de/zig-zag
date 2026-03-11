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
//!   GET    /v1/config/data                  -> handleGet
//!   POST   /v1/config/data                  -> handlePost
//!   GET    /v1/config/{provider}/auth        -> provider auth status
//!   POST   /v1/config/{provider}/auth        -> start provider auth flow
//!   DELETE /v1/config/{provider}/auth        -> revoke provider auth

const std = @import("std");
const core = @import("zag-core");
const errors = core.errors;
const config_mod = core.config;
const log = core.log;
const worker_pool = core.worker_pool;
const copilot_mod = core.providers.copilot.client;
const CopilotClient = copilot_mod.CopilotClient;
const SapAiCoreClient = core.providers.sap_ai_core.client.SapAiCoreClient;
const HaiClient = core.providers.hai.client.HaiClient;

const http = @import("../http.zig");

// ============================================================================
// Device Flow State -- module-level, single Copilot instance
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
        if (eql(u8, method, "GET")) return handleCopilotAuthStatus(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "POST")) return handleCopilotAuth(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "DELETE")) return handleCopilotAuthRevoke(allocator, connection, provider_name, cfg);
    }

    if (eql(u8, provider_name, "sap_ai_core")) {
        if (eql(u8, method, "GET")) return handleSapAiCoreAuthStatus(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "POST")) return handleSapAiCoreAuth(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "DELETE")) return handleSapAiCoreAuthRevoke(allocator, connection, provider_name, cfg);
    }

    if (eql(u8, provider_name, "hai")) {
        if (eql(u8, method, "GET")) return handleHaiAuthStatus(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "POST")) return handleHaiAuth(allocator, connection, provider_name, cfg);
        if (eql(u8, method, "DELETE")) return handleHaiAuthRevoke(allocator, connection, provider_name, cfg);
    }

    log.warn("Config auth: unsupported provider '{s}'", .{provider_name});
    return http.sendNotFound(connection);
}

// ============================================================================
// Config data -- GET / POST
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
// Copilot auth -- GET / POST / DELETE
// ============================================================================

fn handleCopilotAuthStatus(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.debug("[config/copilot] provider not configured, reporting unauthenticated", .{});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };

    var client = CopilotClient.init(allocator, provider_config) catch |err| {
        log.err("[config/copilot] failed to init client: {}", .{err});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };
    defer client.deinit();

    const status = client.authStatus();
    const json = switch (status) {
        .authenticated => "{\"status\":\"authenticated\"}",
        .configured => "{\"status\":\"configured\"}",
        .unauthenticated => "{\"status\":\"unauthenticated\"}",
    };
    try http.sendJsonResponse(connection, .ok, json);
}

/// Thread args for background device flow polling.
/// Uses fixed-size buffers so it can be allocated with page_allocator
/// (survives after the request's arena allocator is freed).
const DeviceFlowThreadArgs = struct {
    provider_config: *const config_mod.ProviderConfig,
    device_code: [256]u8,
    device_code_len: usize,
    interval: i64,
    expires_in: i64,
};

fn deviceFlowPollTask(ctx: *anyopaque) void {
    const args_ptr: *DeviceFlowThreadArgs = @ptrCast(@alignCast(ctx));
    const args = args_ptr.*;
    defer std.heap.page_allocator.destroy(args_ptr);

    // Create a dedicated GPA for the poll thread (outlives the request)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const thread_allocator = gpa.allocator();

    var client = CopilotClient.init(thread_allocator, args.provider_config) catch |err| {
        log.err("[config/copilot] poll thread: failed to init client: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return;
    };
    defer client.deinit();

    const device_code = args.device_code[0..args.device_code_len];

    client.completeDeviceFlow(device_code, args.interval, args.expires_in) catch |err| {
        log.err("[config/copilot] device flow poll failed: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return;
    };

    device_flow_state.status.store(.authenticated, .release);
    log.info("[config/copilot] device flow completed — authenticated", .{});
}

fn handleCopilotAuth(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
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

    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.err("[config/copilot] provider '{s}' not found in config", .{provider_name});
        return http.sendJsonResponse(connection, .bad_request, "{\"status\":\"error\",\"message\":\"Provider not configured\"}");
    };

    var client = CopilotClient.init(allocator, provider_config) catch |err| {
        log.err("[config/copilot] failed to init client: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer client.deinit();

    var result = client.startDeviceFlow() catch |err| {
        log.err("[config/copilot] startDeviceFlow failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer result.deinit();

    // Store in module-level state for subsequent status polls
    const uc_len = @min(result.user_code.len, device_flow_state.user_code.len);
    @memcpy(device_flow_state.user_code[0..uc_len], result.user_code[0..uc_len]);
    device_flow_state.user_code_len = uc_len;

    const uri_len = @min(result.verification_uri.len, device_flow_state.verification_uri.len);
    @memcpy(device_flow_state.verification_uri[0..uri_len], result.verification_uri[0..uri_len]);
    device_flow_state.verification_uri_len = uri_len;

    device_flow_state.status.store(.pending, .release);

    // Spawn background thread to poll for token.
    // Allocate args with page_allocator so they survive after request arena is freed.
    const thread_args = std.heap.page_allocator.create(DeviceFlowThreadArgs) catch |err| {
        log.err("[config/copilot] failed to alloc thread args: {}", .{err});
        device_flow_state.status.store(.failed, .release);
        return http.sendInternalError(connection);
    };

    // Copy device_code into fixed-size buffer
    const dc_len = @min(result.device_code.len, thread_args.device_code.len);
    @memcpy(thread_args.device_code[0..dc_len], result.device_code[0..dc_len]);
    thread_args.* = .{
        .provider_config = provider_config,
        .device_code = thread_args.device_code,
        .device_code_len = dc_len,
        .interval = result.interval,
        .expires_in = result.expires_in,
    };

    worker_pool.submit(deviceFlowPollTask, @ptrCast(thread_args)) catch |err| {
        log.err("[config/copilot] failed to submit poll task to worker pool: {}", .{err});
        std.heap.page_allocator.destroy(thread_args);
        device_flow_state.status.store(.failed, .release);
        return http.sendInternalError(connection);
    };

    // Respond immediately with the user code
    const resp = try std.fmt.allocPrint(allocator,
        "{{\"user_code\":\"{s}\",\"verification_uri\":\"{s}\"}}",
        .{ result.user_code, result.verification_uri },
    );
    defer allocator.free(resp);
    try http.sendJsonResponse(connection, .ok, resp);
}

fn handleCopilotAuthRevoke(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.debug("[config/copilot] provider not configured, nothing to revoke", .{});
        return http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
    };

    var client = CopilotClient.init(allocator, provider_config) catch |err| {
        log.err("[config/copilot] failed to init client for revoke: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer client.deinit();

    client.revokeAuth();

    // Reset device flow state
    device_flow_state.status.store(.idle, .release);

    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}

// ============================================================================
// SAP AI Core auth — GET / POST / DELETE
// ============================================================================

fn handleSapAiCoreAuthStatus(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.warn("[config/sap_ai_core] provider '{s}' not found in config", .{provider_name});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };

    var client = SapAiCoreClient.init(allocator, provider_config) catch |err| {
        log.err("[config/sap_ai_core] failed to init client: {}", .{err});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };
    defer client.deinit();

    const status = client.authStatus();
    const json = switch (status) {
        .authenticated => "{\"status\":\"authenticated\"}",
        .unauthenticated => "{\"status\":\"unauthenticated\"}",
    };
    try http.sendJsonResponse(connection, .ok, json);
}

fn handleSapAiCoreAuth(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.err("[config/sap_ai_core] provider '{s}' not found in config", .{provider_name});
        return http.sendJsonResponse(connection, .bad_request, "{\"status\":\"error\",\"message\":\"Provider not configured\"}");
    };

    var client = SapAiCoreClient.init(allocator, provider_config) catch |err| {
        log.err("[config/sap_ai_core] failed to init client: {}", .{err});
        const resp = std.fmt.allocPrint(allocator,
            "{{\"status\":\"error\",\"message\":\"Failed to initialize client\"}}",
            .{},
        ) catch return http.sendInternalError(connection);
        defer allocator.free(resp);
        return http.sendJsonResponse(connection, .bad_request, resp);
    };
    defer client.deinit();

    const access_token = client.getAccessToken() catch |err| {
        log.err("[config/sap_ai_core] auth failed: {}", .{err});
        const resp = std.fmt.allocPrint(allocator,
            "{{\"status\":\"error\",\"message\":\"Authentication failed\"}}",
            .{},
        ) catch return http.sendInternalError(connection);
        defer allocator.free(resp);
        return http.sendJsonResponse(connection, .ok, resp);
    };
    allocator.free(access_token);

    log.info("[config/sap_ai_core] auth test successful", .{});
    try http.sendJsonResponse(connection, .ok, "{\"status\":\"authenticated\"}");
}

fn handleSapAiCoreAuthRevoke(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.debug("[config/sap_ai_core] provider not configured, nothing to revoke", .{});
        return http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
    };

    var client = SapAiCoreClient.init(allocator, provider_config) catch |err| {
        log.err("[config/sap_ai_core] failed to init client for revoke: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer client.deinit();

    client.revokeAuth();
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}

// ============================================================================
// HAI auth — GET / POST / DELETE
// ============================================================================

fn handleHaiAuthStatus(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.warn("[config/hai] provider '{s}' not found in config", .{provider_name});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };

    var client = HaiClient.init(allocator, provider_config) catch |err| {
        log.err("[config/hai] failed to init client: {}", .{err});
        return http.sendJsonResponse(connection, .ok, "{\"status\":\"unauthenticated\"}");
    };
    defer client.deinit();

    const status = client.authStatus();
    const json = switch (status) {
        .authenticated => "{\"status\":\"authenticated\"}",
        .unauthenticated => "{\"status\":\"unauthenticated\"}",
    };
    try http.sendJsonResponse(connection, .ok, json);
}

fn handleHaiAuth(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.err("[config/hai] provider '{s}' not found in config", .{provider_name});
        return http.sendJsonResponse(connection, .bad_request, "{\"status\":\"error\",\"message\":\"Provider not configured\"}");
    };

    var client = HaiClient.init(allocator, provider_config) catch |err| {
        log.err("[config/hai] failed to init client: {}", .{err});
        const resp = std.fmt.allocPrint(allocator,
            "{{\"status\":\"error\",\"message\":\"Failed to initialize client\"}}",
            .{},
        ) catch return http.sendInternalError(connection);
        defer allocator.free(resp);
        return http.sendJsonResponse(connection, .bad_request, resp);
    };
    defer client.deinit();

    // This blocks until browser auth completes (up to 120s timeout)
    const access_token = client.getAccessToken() catch |err| {
        log.err("[config/hai] auth failed: {}", .{err});
        const resp = std.fmt.allocPrint(allocator,
            "{{\"status\":\"error\",\"message\":\"Authentication failed\"}}",
            .{},
        ) catch return http.sendInternalError(connection);
        defer allocator.free(resp);
        return http.sendJsonResponse(connection, .ok, resp);
    };
    allocator.free(access_token);

    log.info("[config/hai] auth successful", .{});
    try http.sendJsonResponse(connection, .ok, "{\"status\":\"authenticated\"}");
}

fn handleHaiAuthRevoke(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    provider_name: []const u8,
    cfg: *const config_mod.Config,
) !void {
    const provider_config = cfg.providers.getPtr(provider_name) orelse {
        log.debug("[config/hai] provider not configured, nothing to revoke", .{});
        return http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
    };

    var client = HaiClient.init(allocator, provider_config) catch |err| {
        log.err("[config/hai] failed to init client for revoke: {}", .{err});
        return http.sendInternalError(connection);
    };
    defer client.deinit();

    client.revokeAuth();
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}
