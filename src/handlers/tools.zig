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

//! Agent Tools REST Handler
//!
//! Handles requests to /v1/config/tools/* routes. These expose the on-disk
//! settings files of external agent tools (Claude Code, Pi Agent) so the
//! config UI can visualize and update them.
//!
//!   GET  /v1/config/tools/{tool}   -> load tool settings file + derived values
//!   POST /v1/config/tools/{tool}   -> merge posted values into tool settings file
//!
//! Supported tools:
//!   - claude-code  (~/.claude/settings.json)
//!   - pi-agent     (~/.pi/agent/models.json)

const std = @import("std");
const core = @import("zag-core");
const net = core.net;
const fs = core.fs;
const env = core.env;
const log = core.log;
const config_mod = core.config;

const http = @import("../http.zig");

// ============================================================================
// Fake credentials — the proxy does not require real tokens from the agent,
// it authenticates upstream itself. These placeholders keep the agent tools
// happy (they insist on *some* value being present).
// ============================================================================

const FAKE_TOKEN = "zig-zag-proxy";
const FAKE_API_KEY = "zig-zag-proxy";

// ============================================================================
// Tool registry
// ============================================================================

const Tool = enum {
    claude_code,
    pi_agent,

    fn fromSlug(slug: []const u8) ?Tool {
        if (std.mem.eql(u8, slug, "claude-code")) return .claude_code;
        if (std.mem.eql(u8, slug, "pi-agent")) return .pi_agent;
        return null;
    }

    /// Environment variable that overrides the tool's config *directory*.
    /// When set, the settings file is resolved as `$<dir_env>/<fileRelPath>`.
    ///   - Claude Code honours `CLAUDE_CONFIG_DIR` natively.
    ///   - Pi mirrors that convention with `PI_CONFIG_DIR` (pi home is ~/.pi).
    fn dirEnv(self: Tool) [*:0]const u8 {
        return switch (self) {
            .claude_code => "CLAUDE_CONFIG_DIR",
            .pi_agent => "PI_CONFIG_DIR",
        };
    }

    /// Path of the settings file relative to the tool's config directory.
    fn fileRelPath(self: Tool) []const u8 {
        return switch (self) {
            .claude_code => "settings.json",
            .pi_agent => "agent/models.json",
        };
    }

    /// Default config directory relative to $HOME, used when `dirEnv` is unset.
    fn defaultDirRelPath(self: Tool) []const u8 {
        return switch (self) {
            .claude_code => ".claude",
            .pi_agent => ".pi",
        };
    }
};

// ============================================================================
// Dispatcher
// ============================================================================

/// Handle /v1/config/tools/{tool}. Called by the config handler for any path
/// starting with the tools prefix. Returns `false` if the path did not match a
/// tools route (so the caller can continue its own matching); otherwise handles
/// the request and returns `true`.
pub fn handle(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    method: []const u8,
    path: []const u8,
) !bool {
    const prefix = "/v1/config/tools/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;

    const slug = path[prefix.len..];
    if (slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) {
        try http.sendNotFound(connection);
        return true;
    }

    const tool = Tool.fromSlug(slug) orelse {
        try http.sendJsonResponse(connection, .not_found, "{\"error\":\"unknown tool\"}");
        return true;
    };

    if (std.mem.eql(u8, method, "GET")) {
        try handleGet(allocator, connection, tool);
        return true;
    }

    try http.sendJsonResponse(connection, .not_found, "{\"error\":\"method not allowed\"}");
    return true;
}

/// POST variant — kept separate because it needs the request body.
pub fn handlePost(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    path: []const u8,
    body: []const u8,
) !bool {
    const prefix = "/v1/config/tools/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;

    const slug = path[prefix.len..];
    if (slug.len == 0 or std.mem.indexOfScalar(u8, slug, '/') != null) {
        try http.sendNotFound(connection);
        return true;
    }

    const tool = Tool.fromSlug(slug) orelse {
        try http.sendJsonResponse(connection, .not_found, "{\"error\":\"unknown tool\"}");
        return true;
    };

    switch (tool) {
        .claude_code => try saveClaudeCode(allocator, connection, body),
        .pi_agent => try savePiAgent(allocator, connection, body),
    }
    return true;
}

// ============================================================================
// Helpers
// ============================================================================

/// Build the absolute path of a tool's settings file.
///
/// Resolution order for the config directory:
///   1. The tool's directory env var (e.g. `CLAUDE_CONFIG_DIR`), if set & non-empty.
///   2. `$HOME/<default dir>` (e.g. `~/.claude`).
/// The settings file is then `<dir>/<fileRelPath>` (e.g. `settings.json`).
/// Caller owns the returned slice.
fn absPath(allocator: std.mem.Allocator, tool: Tool) ![]u8 {
    if (env.get(tool.dirEnv())) |dir| {
        if (dir.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, tool.fileRelPath() });
        }
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, tool.defaultDirRelPath(), tool.fileRelPath() });
}

/// Read a tool's settings file and parse it as a JSON object.
/// Returns null if the file does not exist or is not a JSON object.
/// Caller owns the returned `Parsed` and must call `.deinit()`.
fn loadToolJson(allocator: std.mem.Allocator, tool: Tool) !?std.json.Parsed(std.json.Value) {
    const path = try absPath(allocator, tool);
    defer allocator.free(path);

    const file = fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return null;
    };
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

/// Load + parse a tool's settings file using the given (arena) allocator,
/// returning the parsed `Value` directly (lives as long as the arena).
/// Returns null when the file is missing or not valid JSON.
fn loadToolValue(allocator: std.mem.Allocator, tool: Tool) !?std.json.Value {
    const path = try absPath(allocator, tool);

    const file = fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    return parsed.value;
}

/// Atomically write JSON text to a tool's settings file, creating parent
/// directories as needed.
fn writeToolFile(allocator: std.mem.Allocator, tool: Tool, json: []const u8) !void {
    const path = try absPath(allocator, tool);
    defer allocator.free(path);

    // Ensure the parent directory exists (e.g. ~/.pi/agent).
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try fs.cwd().makePath(path[0..slash]);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const tmp = try fs.cwd().createFile(tmp_path, .{ .truncate = true });
    errdefer fs.cwd().deleteFile(tmp_path) catch {};
    try tmp.writeAll(json);
    tmp.close();

    try fs.cwd().rename(tmp_path, path);
    log.info("Tool settings written to {s} ({d} bytes)", .{ path, json.len });
}

/// Derive the proxy base URL (`http://host:port`) from the server config
/// section in config.json. Falls back to defaults when absent. Localhost-ish
/// hosts (0.0.0.0) are reported as 127.0.0.1 so agents can actually connect.
/// Caller owns the returned slice.
fn proxyBaseUrl(allocator: std.mem.Allocator) ![]u8 {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;

    const raw = config_mod.readRaw(allocator) catch null;
    if (raw) |r| {
        defer allocator.free(r);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("server")) |sv| {
                    if (sv == .object) {
                        if (sv.object.get("host")) |hv| {
                            if (hv == .string and hv.string.len > 0) host = hv.string;
                        }
                        if (sv.object.get("port")) |pv| {
                            if (pv == .integer) port = @intCast(pv.integer);
                        }
                    }
                }
            }
        }
    }

    if (std.mem.eql(u8, host, "0.0.0.0") or std.mem.eql(u8, host, "::")) {
        host = "127.0.0.1";
    }

    return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
}

/// Look up a string field in a JSON object, returning "" when missing.
fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

// ============================================================================
// GET — load + derive form values
// ============================================================================

fn handleGet(allocator: std.mem.Allocator, connection: net.Connection, tool: Tool) !void {
    switch (tool) {
        .claude_code => try getClaudeCode(allocator, connection),
        .pi_agent => try getPiAgent(allocator, connection),
    }
}

fn getClaudeCode(allocator: std.mem.Allocator, connection: net.Connection) !void {
    const base_url = try proxyBaseUrl(allocator);
    defer allocator.free(base_url);

    // Pull existing model selections from the file's "env" object, if present.
    var haiku: []const u8 = "";
    var opus: []const u8 = "";
    var sonnet: []const u8 = "";
    var model: []const u8 = "";

    const parsed = try loadToolJson(allocator, .claude_code);
    defer if (parsed) |p| p.deinit();
    if (parsed) |p| {
        if (p.value.object.get("env")) |ev| {
            if (ev == .object) {
                haiku = getStr(ev.object, "ANTHROPIC_DEFAULT_HAIKU_MODEL");
                opus = getStr(ev.object, "ANTHROPIC_DEFAULT_OPUS_MODEL");
                sonnet = getStr(ev.object, "ANTHROPIC_DEFAULT_SONNET_MODEL");
                model = getStr(ev.object, "ANTHROPIC_MODEL");
            }
        }
    }

    const Resp = struct {
        configured: bool,
        auth_token: []const u8,
        base_url: []const u8,
        haiku_model: []const u8,
        opus_model: []const u8,
        sonnet_model: []const u8,
        model: []const u8,
    };

    try sendJsonStruct(allocator, connection, Resp{
        .configured = parsed != null,
        .auth_token = FAKE_TOKEN,
        .base_url = base_url,
        .haiku_model = haiku,
        .opus_model = opus,
        .sonnet_model = sonnet,
        .model = model,
    });
}

/// The provider key the proxy manages inside pi's `models.json`. Other
/// provider entries in the file are preserved untouched.
const PI_PROVIDER_KEY = "zig-zag";

/// A single pi model entry as surfaced to / accepted from the UI.
const PiModel = struct {
    id: []const u8 = "",
    reasoning: bool = false,
    input: []const []const u8 = &.{},
    contextWindow: ?i64 = null,
    maxTokens: ?i64 = null,
};

fn getPiAgent(allocator: std.mem.Allocator, connection: net.Connection) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base_url = try proxyBaseUrl(alloc);

    // Collect the model entries already configured under providers.zig-zag.
    var models = std.ArrayList(PiModel).empty;

    var configured = false;
    if (try loadToolValue(alloc, .pi_agent)) |root| {
        if (root == .object) {
            if (root.object.get("providers")) |pv| {
                if (pv == .object) {
                    if (pv.object.get(PI_PROVIDER_KEY)) |prov| {
                        if (prov == .object) {
                            configured = true;
                            if (prov.object.get("models")) |mv| {
                                if (mv == .array) {
                                    for (mv.array.items) |item| {
                                        if (item != .object) continue;
                                        try models.append(alloc, parsePiModel(alloc, item.object));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    const Resp = struct {
        configured: bool,
        base_url: []const u8,
        api_key: []const u8,
        api: []const u8,
        models: []const PiModel,
    };

    try sendJsonStruct(alloc, connection, Resp{
        .configured = configured,
        .base_url = base_url,
        .api_key = FAKE_API_KEY,
        .api = "anthropic-messages",
        .models = models.items,
    });
}

/// Read one model object from the parsed file into a `PiModel` (arena-backed).
fn parsePiModel(allocator: std.mem.Allocator, obj: std.json.ObjectMap) PiModel {
    var m = PiModel{ .id = getStr(obj, "id") };
    if (obj.get("reasoning")) |v| {
        if (v == .bool) m.reasoning = v.bool;
    }
    if (obj.get("input")) |v| {
        if (v == .array) {
            var list = std.ArrayList([]const u8).empty;
            for (v.array.items) |it| {
                if (it == .string) list.append(allocator, it.string) catch {};
            }
            m.input = list.items;
        }
    }
    if (obj.get("contextWindow")) |v| {
        if (v == .integer) m.contextWindow = v.integer;
    }
    if (obj.get("maxTokens")) |v| {
        if (v == .integer) m.maxTokens = v.integer;
    }
    return m;
}

// ============================================================================
// POST — merge posted values into the tool settings file
// ============================================================================

fn saveClaudeCode(allocator: std.mem.Allocator, connection: net.Connection, body: []const u8) !void {
    const Req = struct {
        haiku_model: []const u8 = "",
        opus_model: []const u8 = "",
        sonnet_model: []const u8 = "",
        model: []const u8 = "",
    };

    // One arena for all temporary JSON work (parse tree + new maps + output).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = std.json.parseFromSlice(Req, alloc, body, .{ .ignore_unknown_fields = true }) catch {
        return http.sendJsonResponse(connection, .bad_request, "{\"error\":\"invalid request body\"}");
    };

    const base_url = try proxyBaseUrl(alloc);

    // Start from the existing settings so unrelated keys are preserved.
    var root = std.json.Value{ .object = std.json.ObjectMap{} };
    if (try loadToolValue(alloc, .claude_code)) |existing| {
        if (existing == .object) root = existing;
    }

    // Rebuild the "env" object, preserving any pre-existing env entries.
    var env_obj = std.json.ObjectMap{};
    if (root.object.get("env")) |ev| {
        if (ev == .object) {
            var it = ev.object.iterator();
            while (it.next()) |e| try env_obj.put(alloc, e.key_ptr.*, e.value_ptr.*);
        }
    }

    // Append/replace our managed env keys.
    try env_obj.put(alloc, "ANTHROPIC_AUTH_TOKEN", .{ .string = FAKE_TOKEN });
    try env_obj.put(alloc, "ANTHROPIC_BASE_URL", .{ .string = base_url });
    try putStrIfSet(alloc, &env_obj, "ANTHROPIC_DEFAULT_HAIKU_MODEL", req.value.haiku_model);
    try putStrIfSet(alloc, &env_obj, "ANTHROPIC_DEFAULT_OPUS_MODEL", req.value.opus_model);
    try putStrIfSet(alloc, &env_obj, "ANTHROPIC_DEFAULT_SONNET_MODEL", req.value.sonnet_model);
    try putStrIfSet(alloc, &env_obj, "ANTHROPIC_MODEL", req.value.model);

    try root.object.put(alloc, "env", .{ .object = env_obj });

    try writeJsonValue(alloc, connection, .claude_code, root);
}

fn savePiAgent(allocator: std.mem.Allocator, connection: net.Connection, body: []const u8) !void {
    const Req = struct {
        models: []const PiModel = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = std.json.parseFromSlice(Req, alloc, body, .{ .ignore_unknown_fields = true }) catch {
        return http.sendJsonResponse(connection, .bad_request, "{\"error\":\"invalid request body\"}");
    };

    const base_url = try proxyBaseUrl(alloc);

    // Build the models array — one object per configured model.
    var models_arr = std.json.Array.init(alloc);
    for (req.value.models) |m| {
        if (m.id.len == 0) continue;
        var entry = std.json.ObjectMap{};
        try entry.put(alloc, "id", .{ .string = m.id });
        try entry.put(alloc, "reasoning", .{ .bool = m.reasoning });
        var inputs = std.json.Array.init(alloc);
        for (m.input) |cap| try inputs.append(.{ .string = cap });
        try entry.put(alloc, "input", .{ .array = inputs });
        if (m.contextWindow) |cw| try entry.put(alloc, "contextWindow", .{ .integer = cw });
        if (m.maxTokens) |mt| try entry.put(alloc, "maxTokens", .{ .integer = mt });
        try models_arr.append(.{ .object = entry });
    }

    // Load the existing file; preserve all unrelated providers and keys.
    var root = std.json.Value{ .object = std.json.ObjectMap{} };
    if (try loadToolValue(alloc, .pi_agent)) |existing| {
        if (existing == .object) root = existing;
    }

    // Fetch-or-create the top-level "providers" object.
    var providers = std.json.ObjectMap{};
    if (root.object.get("providers")) |pv| {
        if (pv == .object) providers = pv.object;
    }

    // Rebuild the managed provider entry, preserving any extra keys it had
    // (e.g. "compat") while refreshing the connection fields + models.
    var prov = std.json.ObjectMap{};
    if (providers.get(PI_PROVIDER_KEY)) |existing_prov| {
        if (existing_prov == .object) {
            var it = existing_prov.object.iterator();
            while (it.next()) |e| try prov.put(alloc, e.key_ptr.*, e.value_ptr.*);
        }
    }
    try prov.put(alloc, "baseUrl", .{ .string = base_url });
    try prov.put(alloc, "apiKey", .{ .string = FAKE_API_KEY });
    try prov.put(alloc, "api", .{ .string = "anthropic-messages" });
    try prov.put(alloc, "models", .{ .array = models_arr });

    try providers.put(alloc, PI_PROVIDER_KEY, .{ .object = prov });
    try root.object.put(alloc, "providers", .{ .object = providers });

    try writeJsonValue(alloc, connection, .pi_agent, root);
}

// ============================================================================
// Small JSON utilities
// ============================================================================

fn putStrIfSet(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    if (value.len == 0) {
        _ = obj.orderedRemove(key);
        return;
    }
    try obj.put(allocator, key, .{ .string = value });
}

/// Serialize a struct to JSON and send it as a 200 response.
fn sendJsonStruct(allocator: std.mem.Allocator, connection: net.Connection, value: anytype) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    try http.sendJsonResponse(connection, .ok, buf.items);
}

/// Serialize a JSON value (pretty-printed), write it to the tool file, and
/// reply with `{"ok":true}`. `allocator` is expected to be an arena.
fn writeJsonValue(
    allocator: std.mem.Allocator,
    connection: net.Connection,
    tool: Tool,
    root: std.json.Value,
) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "{f}", .{std.json.fmt(root, .{ .whitespace = .indent_2 })});

    writeToolFile(allocator, tool, buf.items) catch |err| {
        log.err("Tool save failed: {}", .{err});
        return http.sendInternalError(connection);
    };
    try http.sendJsonResponse(connection, .ok, "{\"ok\":true}");
}
