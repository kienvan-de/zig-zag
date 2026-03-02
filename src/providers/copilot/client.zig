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

//! GitHub Copilot Provider Client
//!
//! Client for GitHub Copilot API with two-layer token management:
//! 1. GitHub OAuth token (long-lived, from ~/.config/github-copilot/apps.json or device flow)
//! 2. Copilot API token (short-lived ~30min, exchanged from OAuth token)
//!
//! Copilot API is OpenAI-compatible, so this client follows the HAI pattern:
//! only client.zig needed, reuses OpenAI types and transformer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const OpenAI = @import("../openai/types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");
const auth = @import("../../auth/mod.zig");
const app_cache = @import("../../cache/app_cache.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_CLIENT_ID = "Iv1.b507a08c87ecfe98";
const DEFAULT_EDITOR_VERSION = "vscode/1.95.0";
const DEFAULT_EDITOR_PLUGIN_VERSION = "copilot-chat/0.26.7";
const DEFAULT_USER_AGENT = "GitHubCopilotChat/0.26.7";
const DEFAULT_API_VERSION = "2025-04-01";

const TOKEN_ENDPOINT = "https://api.github.com/copilot_internal/v2/token";
const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code";
const GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token";

const TOKEN_EXPIRY_BUFFER_SECONDS = 60;
const DEFAULT_TIMEOUT_MS = 60000;
const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;

// ============================================================================
// Copilot Client
// ============================================================================

pub const CopilotClient = struct {
    allocator: Allocator,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,

    // Config values with defaults
    client_id: []const u8,
    editor_version: []const u8,
    editor_plugin_version: []const u8,
    user_agent: []const u8,
    api_version: []const u8,

    // Dynamic state (protected by token_mutex)
    api_base: ?[]const u8,
    api_token: ?[]const u8,
    token_expires_at: i64,
    token_mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, provider_config: *const config_mod.ProviderConfig) !CopilotClient {
        const timeout_ms = provider_config.getInt("timeout_ms") orelse DEFAULT_TIMEOUT_MS;
        const max_response_size_mb = provider_config.getInt("max_response_size_mb") orelse DEFAULT_MAX_RESPONSE_SIZE_MB;

        return .{
            .allocator = allocator,
            .config = provider_config,
            .client = http_client.HttpClient.initWithOptions(
                allocator,
                @intCast(timeout_ms),
                @intCast(max_response_size_mb * 1024 * 1024),
                null,
            ),
            .client_id = provider_config.getString("client_id") orelse DEFAULT_CLIENT_ID,
            .editor_version = provider_config.getString("editor_version") orelse DEFAULT_EDITOR_VERSION,
            .editor_plugin_version = provider_config.getString("editor_plugin_version") orelse DEFAULT_EDITOR_PLUGIN_VERSION,
            .user_agent = provider_config.getString("user_agent") orelse DEFAULT_USER_AGENT,
            .api_version = provider_config.getString("api_version") orelse DEFAULT_API_VERSION,
            .api_base = null,
            .api_token = null,
            .token_expires_at = 0,
            .token_mutex = .{},
        };
    }

    // ========================================================================
    // Task 1.3: Exchange OAuth Token for Copilot API Token
    // ========================================================================

    /// GET https://api.github.com/copilot_internal/v2/token
    /// Headers: Authorization: token <oauth_token>  (NOT Bearer!)
    /// Response: { token, expires_at, endpoints: { api: "..." } }
    /// Updates self.api_token, self.api_base, self.token_expires_at
    fn fetchCopilotToken(self: *CopilotClient, oauth_token: []const u8) !void {
        log.info("[Copilot] Exchanging OAuth token for Copilot API token...", .{});

        // Build "token <oauth_token>" auth header
        var auth_buf: [4096]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "token {s}", .{oauth_token}) catch return error.BufferTooSmall;

        // Use getUncompressed: GitHub's API returns gzip by default, but Zig's
        // response.reader() does not decompress — we must request identity encoding.
        var response = self.client.getUncompressed(TOKEN_ENDPOINT, &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Accept", .value = "application/json" },
        }) catch |err| {
            log.err("[Copilot] Token exchange request failed: {}", .{err});
            return error.TokenExchangeFailed;
        };
        defer response.deinit();

        if (response.status == .unauthorized) {
            log.err("[Copilot] OAuth token is invalid or expired (401)", .{});
            return error.InvalidOAuthToken;
        }
        if (response.status == .forbidden) {
            log.err("[Copilot] No Copilot subscription (403)", .{});
            return error.NoCopilotSubscription;
        }
        if (response.status != .ok) {
            log.err("[Copilot] Token exchange failed: HTTP {} | body: {s}", .{ response.status, response.body });
            return error.TokenExchangeFailed;
        }

        // Parse response
        const parsed = std.json.parseFromSlice(
            struct {
                token: []const u8,
                expires_at: i64,
                endpoints: struct {
                    api: []const u8,
                },
            },
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("[Copilot] Failed to parse token response: {} | body: {s}", .{ err, response.body });
            return error.InvalidTokenResponse;
        };
        defer parsed.deinit();

        // Free old values
        if (self.api_token) |old| self.allocator.free(old);
        if (self.api_base) |old| self.allocator.free(old);

        // Store new values
        self.api_token = try self.allocator.dupe(u8, parsed.value.token);
        self.api_base = try self.allocator.dupe(u8, parsed.value.endpoints.api);
        self.token_expires_at = parsed.value.expires_at;

        log.info("[Copilot] Got API token, expires_at={d}, api_base={s}", .{
            self.token_expires_at,
            self.api_base.?,
        });
    }

    // ========================================================================
    // Task 1.2: Read GitHub OAuth Token from apps.json
    // ========================================================================

    /// Read GitHub OAuth token from ~/.config/github-copilot/apps.json
    /// Looks for key "github.com:<client_id>" -> oauth_token
    /// Returns duplicated token string (caller must free)
    fn readGitHubToken(self: *CopilotClient) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse {
            log.err("[Copilot] HOME environment variable not set", .{});
            return error.HomeNotFound;
        };

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const apps_path = std.fmt.bufPrint(
            &path_buf,
            "{s}/.config/github-copilot/apps.json",
            .{home},
        ) catch return error.PathTooLong;

        // Read file
        const file = std.fs.cwd().openFile(apps_path, .{}) catch |err| {
            log.err("[Copilot] Failed to open {s}: {}", .{ apps_path, err });
            return error.TokenFileNotFound;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            log.err("[Copilot] Failed to read apps.json: {}", .{err});
            return error.TokenFileReadError;
        };
        defer self.allocator.free(content);

        // Parse JSON
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            content,
            .{},
        ) catch |err| {
            log.err("[Copilot] Failed to parse apps.json: {}", .{err});
            return error.InvalidTokenFile;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            log.err("[Copilot] apps.json is not a JSON object", .{});
            return error.InvalidTokenFile;
        }

        // Look up key "github.com:<client_id>"
        var key_buf: [256]u8 = undefined;
        const lookup_key = std.fmt.bufPrint(
            &key_buf,
            "github.com:{s}",
            .{self.client_id},
        ) catch return error.PathTooLong;

        const entry = parsed.value.object.get(lookup_key) orelse {
            log.err("[Copilot] No entry for '{s}' in apps.json", .{lookup_key});
            return error.TokenNotFound;
        };

        if (entry != .object) {
            log.err("[Copilot] Entry for '{s}' is not an object", .{lookup_key});
            return error.InvalidTokenFile;
        }

        const oauth_token_value = entry.object.get("oauth_token") orelse {
            log.err("[Copilot] No 'oauth_token' field in entry for '{s}'", .{lookup_key});
            return error.TokenNotFound;
        };

        if (oauth_token_value != .string) {
            log.err("[Copilot] 'oauth_token' is not a string", .{});
            return error.InvalidTokenFile;
        }

        log.debug("[Copilot] Read OAuth token from apps.json for '{s}'", .{lookup_key});
        return self.allocator.dupe(u8, oauth_token_value.string);
    }

    // ========================================================================
    // Task 1.5: Device Flow + Save Token
    // ========================================================================

    /// HTML template embedded at compile time — baked into the binary via @embedFile.
    /// Placeholders: {{USER_CODE}}, {{VERIFICATION_URI}}
    const device_flow_html = @embedFile("device_flow.html");

    /// Write the device flow HTML page to /tmp and open it in the default browser.
    /// The template is embedded in the binary at compile time (no runtime file dependency).
    fn showDeviceFlowPage(self: *CopilotClient, user_code: []const u8, verification_uri: []const u8) !void {
        const html_path = "/tmp/copilot-auth.html";

        // Replace {{USER_CODE}} with actual code (appears twice in template)
        const after_code = try std.mem.replaceOwned(u8, self.allocator, device_flow_html, "{{USER_CODE}}", user_code);
        defer self.allocator.free(after_code);

        // Replace {{VERIFICATION_URI}} with actual URI
        const html = try std.mem.replaceOwned(u8, self.allocator, after_code, "{{VERIFICATION_URI}}", verification_uri);
        defer self.allocator.free(html);

        // Write to temp file
        const file = std.fs.cwd().createFile(html_path, .{}) catch |err| {
            log.err("[Copilot] Failed to create {s}: {}", .{ html_path, err });
            return err;
        };
        defer file.close();
        try file.writeAll(html);

        log.info("[Copilot] Opening device flow page: {s}", .{html_path});

        // Open in default browser
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "open", html_path },
        }) catch |err| {
            log.err("[Copilot] Failed to open browser: {}", .{err});
            return err;
        };
        if (result.term.Exited != 0) {
            return error.BrowserOpenFailed;
        }
    }

    /// GitHub Device Flow — terminal-based authentication
    /// 1. Request device code
    /// 2. Print instructions to stderr
    /// 3. Poll for token
    /// 4. Save token to apps.json
    /// Returns duplicated access_token (caller must free)
    fn deviceFlow(self: *CopilotClient) ![]const u8 {
        log.info("[Copilot] Starting device flow authentication...", .{});

        const params = auth.DeviceFlowParams{
            .device_code_url = GITHUB_DEVICE_CODE_URL,
            .token_url = GITHUB_ACCESS_TOKEN_URL,
            .client_id = self.client_id,
            .scope = "",
        };

        // Step 1: Request device code
        var device_code = try auth.oauth.requestDeviceCode(self.allocator, &self.client, params);
        defer device_code.deinit();

        // Step 2: Write HTML page with the one-time code and open it in the browser
        self.showDeviceFlowPage(device_code.user_code, device_code.verification_uri) catch |err| {
            // Non-fatal: fall back to stderr output
            log.warn("[Copilot] Failed to open browser page: {}, falling back to stderr", .{err});
            var msg_buf: [1024]u8 = undefined;
            if (std.fmt.bufPrint(&msg_buf, "\n! First copy your one-time code: {s}\n- Open {s} in your browser\n- Paste the code and authorize\n\n", .{ device_code.user_code, device_code.verification_uri })) |msg| {
                _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
            } else |_| {}
        };

        // Step 3: Poll for token
        var token_response = try auth.oauth.pollDeviceToken(
            self.allocator,
            &self.client,
            params,
            device_code.device_code,
            device_code.interval,
            device_code.expires_in,
        );
        defer token_response.deinit();

        log.info("[Copilot] Device flow authentication successful", .{});

        // Step 4: Save to apps.json
        self.saveTokenToAppsJson(token_response.access_token) catch |err| {
            log.warn("[Copilot] Failed to save token to apps.json: {}", .{err});
            // Non-fatal: we still have the token in memory
        };

        return self.allocator.dupe(u8, token_response.access_token);
    }

    /// Save OAuth token to ~/.config/github-copilot/apps.json
    /// Read-modify-write: preserves other entries in the file
    fn saveTokenToAppsJson(self: *CopilotClient, access_token: []const u8) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = std.fmt.bufPrint(
            &dir_buf,
            "{s}/.config/github-copilot",
            .{home},
        ) catch return error.PathTooLong;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const apps_path = std.fmt.bufPrint(
            &path_buf,
            "{s}/apps.json",
            .{dir_path},
        ) catch return error.PathTooLong;

        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch |err| {
            log.err("[Copilot] Failed to create directory {s}: {}", .{ dir_path, err });
            return error.FileWriteError;
        };

        // Read existing file or start with empty object
        var root = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        var parsed_holder: ?std.json.Parsed(std.json.Value) = null;
        defer if (parsed_holder) |*p| p.deinit();

        if (std.fs.cwd().openFile(apps_path, .{})) |file| {
            defer file.close();
            if (file.readToEndAlloc(self.allocator, 1024 * 1024)) |content| {
                defer self.allocator.free(content);
                if (std.json.parseFromSlice(std.json.Value, self.allocator, content, .{})) |parsed| {
                    parsed_holder = parsed;
                    if (parsed.value == .object) {
                        root = parsed.value;
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}

        // Build lookup key
        var key_buf: [256]u8 = undefined;
        const lookup_key = std.fmt.bufPrint(
            &key_buf,
            "github.com:{s}",
            .{self.client_id},
        ) catch return error.PathTooLong;

        // Build the entry value as JSON
        const key_dupe = try self.allocator.dupe(u8, lookup_key);
        var entry_obj = std.json.ObjectMap.init(self.allocator);
        try entry_obj.put("oauth_token", std.json.Value{ .string = access_token });
        try entry_obj.put("githubAppId", std.json.Value{ .string = self.client_id });
        try root.object.put(key_dupe, std.json.Value{ .object = entry_obj });

        // Serialize to buffer
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(self.allocator);
        json_buf.writer(self.allocator).print("{f}", .{std.json.fmt(root, .{ .whitespace = .indent_2 })}) catch |err| {
            log.err("[Copilot] Failed to serialize apps.json: {}", .{err});
            return error.FileWriteError;
        };

        // Write back
        const out_file = std.fs.cwd().createFile(apps_path, .{}) catch |err| {
            log.err("[Copilot] Failed to write {s}: {}", .{ apps_path, err });
            return error.FileWriteError;
        };
        defer out_file.close();

        out_file.writeAll(json_buf.items) catch |err| {
            log.err("[Copilot] Failed to write apps.json content: {}", .{err});
            return error.FileWriteError;
        };

        log.info("[Copilot] Saved OAuth token to {s}", .{apps_path});
    }

    // ========================================================================
    // Task 1.6: getAccessToken with Caching
    // ========================================================================

    /// Check if cached Copilot API token is still valid
    fn isTokenValid(self: *CopilotClient) bool {
        if (self.api_token == null) return false;
        const now = std.time.timestamp();
        return now < self.token_expires_at - TOKEN_EXPIRY_BUFFER_SECONDS;
    }

    /// Get valid Copilot API token, refreshing if expired
    /// Flow:
    /// 1. Cached token valid? -> return it
    /// 2. Lock mutex (double-check pattern)
    /// 3. readGitHubToken() from apps.json; if not found -> deviceFlow()
    /// 4. fetchCopilotToken() to exchange for API token
    /// 5. Return api_token
    pub fn getAccessToken(self: *CopilotClient) ![]const u8 {
        // Fast path: check without lock
        if (self.isTokenValid()) {
            log.debug("[Copilot] Using cached API token", .{});
            return self.allocator.dupe(u8, self.api_token.?);
        }

        // Slow path: acquire mutex
        self.token_mutex.lock();
        defer self.token_mutex.unlock();

        // Double-check after acquiring lock
        if (self.isTokenValid()) {
            log.debug("[Copilot] Token valid after acquiring lock", .{});
            return self.allocator.dupe(u8, self.api_token.?);
        }

        // Get GitHub OAuth token
        const oauth_token = self.readGitHubToken() catch |err| {
            if (err == error.TokenFileNotFound or err == error.TokenNotFound) {
                log.info("[Copilot] No saved token found, starting device flow...", .{});
                const token = try self.deviceFlow();
                defer self.allocator.free(token);
                try self.fetchCopilotToken(token);
                return self.allocator.dupe(u8, self.api_token.?);
            }
            return err;
        };
        defer self.allocator.free(oauth_token);

        // Exchange for Copilot API token
        self.fetchCopilotToken(oauth_token) catch |err| {
            if (err == error.InvalidOAuthToken) {
                log.warn("[Copilot] Saved OAuth token expired, starting device flow...", .{});
                const new_token = try self.deviceFlow();
                defer self.allocator.free(new_token);
                try self.fetchCopilotToken(new_token);
                return self.allocator.dupe(u8, self.api_token.?);
            }
            return err;
        };

        return self.allocator.dupe(u8, self.api_token.?);
    }

    // ========================================================================
    // API Methods (OpenAI-compatible) — Stories 2, 3, 4
    // ========================================================================

    /// Build the required Copilot API headers into caller-provided buffers.
    /// - auth_buf: must be >= 512 bytes (holds "Bearer <token>")
    /// - uuid_buf: must be >= 37 bytes (holds "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
    /// - headers_buf: must hold at least 9 entries
    /// Returns slice of populated headers.
    fn buildHeaders(
        self: *CopilotClient,
        access_token: []const u8,
        auth_buf: []u8,
        uuid_buf: []u8,
        headers_buf: []std.http.Header,
    ) ![]std.http.Header {
        // Authorization: Bearer <copilot_api_token>
        const auth_value = try std.fmt.bufPrint(auth_buf, "Bearer {s}", .{access_token});

        // x-request-id: random UUIDv4
        var uuid_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);
        // Set version (4) and variant bits
        uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
        uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;
        const request_id = try std.fmt.bufPrint(uuid_buf,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                uuid_bytes[0],  uuid_bytes[1],  uuid_bytes[2],  uuid_bytes[3],
                uuid_bytes[4],  uuid_bytes[5],
                uuid_bytes[6],  uuid_bytes[7],
                uuid_bytes[8],  uuid_bytes[9],
                uuid_bytes[10], uuid_bytes[11], uuid_bytes[12],
                uuid_bytes[13], uuid_bytes[14], uuid_bytes[15],
            },
        );

        headers_buf[0] = .{ .name = "Authorization",           .value = auth_value };
        headers_buf[1] = .{ .name = "Content-Type",            .value = "application/json" };
        headers_buf[2] = .{ .name = "copilot-integration-id",  .value = "vscode-chat" };
        headers_buf[3] = .{ .name = "editor-version",          .value = self.editor_version };
        headers_buf[4] = .{ .name = "editor-plugin-version",   .value = self.editor_plugin_version };
        headers_buf[5] = .{ .name = "User-Agent",              .value = self.user_agent };
        headers_buf[6] = .{ .name = "openai-intent",           .value = "conversation-panel" };
        headers_buf[7] = .{ .name = "x-github-api-version",    .value = self.api_version };
        headers_buf[8] = .{ .name = "x-request-id",            .value = request_id };

        return headers_buf[0..9];
    }

    /// Build GET headers (8 headers — no Content-Type)
    fn buildGetHeaders(
        self: *CopilotClient,
        access_token: []const u8,
        auth_buf: []u8,
        uuid_buf: []u8,
        headers_buf: []std.http.Header,
    ) ![]std.http.Header {
        // Authorization: Bearer <copilot_api_token>
        const auth_value = try std.fmt.bufPrint(auth_buf, "Bearer {s}", .{access_token});

        // x-request-id: random UUIDv4
        var uuid_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);
        uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
        uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;
        const request_id = try std.fmt.bufPrint(uuid_buf,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                uuid_bytes[0],  uuid_bytes[1],  uuid_bytes[2],  uuid_bytes[3],
                uuid_bytes[4],  uuid_bytes[5],
                uuid_bytes[6],  uuid_bytes[7],
                uuid_bytes[8],  uuid_bytes[9],
                uuid_bytes[10], uuid_bytes[11], uuid_bytes[12],
                uuid_bytes[13], uuid_bytes[14], uuid_bytes[15],
            },
        );

        headers_buf[0] = .{ .name = "Authorization",           .value = auth_value };
        headers_buf[1] = .{ .name = "copilot-integration-id",  .value = "vscode-chat" };
        headers_buf[2] = .{ .name = "editor-version",          .value = self.editor_version };
        headers_buf[3] = .{ .name = "editor-plugin-version",   .value = self.editor_plugin_version };
        headers_buf[4] = .{ .name = "User-Agent",              .value = self.user_agent };
        headers_buf[5] = .{ .name = "openai-intent",           .value = "conversation-panel" };
        headers_buf[6] = .{ .name = "x-github-api-version",    .value = self.api_version };
        headers_buf[7] = .{ .name = "x-request-id",            .value = request_id };

        return headers_buf[0..8];
    }

    /// Send a non-streaming request to Copilot Chat Completions API
    pub fn sendRequest(self: *CopilotClient, request: OpenAI.Request) !std.json.Parsed(OpenAI.Response) {
        log.debug("[Copilot] [SYNC] sendRequest - getting access token...", .{});
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        const api_base = self.api_base orelse return error.ApiBaseNotSet;

        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{api_base});
        log.debug("[Copilot] [SYNC] sendRequest - URL: {s}", .{url});

        var auth_buf: [512]u8 = undefined;
        var uuid_buf: [37]u8 = undefined;
        var headers_buf: [9]std.http.Header = undefined;
        const headers = try self.buildHeaders(access_token, &auth_buf, &uuid_buf, &headers_buf);

        return self.client.postJson(OpenAI.Response, url, headers, request) catch |err| {
            log.err("[Copilot] [SYNC] sendRequest failed: {}", .{err});
            return err;
        };
    }

    /// Send a streaming request to Copilot Chat Completions API
    pub fn sendStreamingRequest(self: *CopilotClient, request: OpenAI.Request) !*StreamingResult {
        log.debug("[Copilot] [STREAM] sendStreamingRequest - getting access token...", .{});
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        const api_base = self.api_base orelse return error.ApiBaseNotSet;

        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{api_base});
        log.debug("[Copilot] [STREAM] sendStreamingRequest - URL: {s}", .{url});

        var auth_buf: [512]u8 = undefined;
        var uuid_buf: [37]u8 = undefined;
        var headers_buf: [9]std.http.Header = undefined;
        const headers = try self.buildHeaders(access_token, &auth_buf, &uuid_buf, &headers_buf);

        log.debug("[Copilot] [STREAM] sendStreamingRequest - sending POST request...", .{});
        const result = self.client.postStreaming(SSEIterator, url, headers, request) catch |err| {
            log.err("[Copilot] [STREAM] sendStreamingRequest - POST request failed: {}", .{err});
            return err;
        };
        log.debug("[Copilot] [STREAM] sendStreamingRequest - response status: {}", .{result.response.head.status});

        if (result.response.head.status != .ok) {
            self.client.freeStreamingResult(SSEIterator, result);
            log.err("[Copilot] [STREAM] sendStreamingRequest failed: HTTP {}", .{result.response.head.status});
            return error.RequestFailed;
        }

        log.debug("[Copilot] [STREAM] sendStreamingRequest - stream established successfully", .{});
        return result;
    }

    /// Free a streaming result allocated by sendStreamingRequest
    pub fn freeStreamingResult(self: *CopilotClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }

    /// Fetch list of available models from Copilot API.
    /// Results are cached via app_cache. Models are prefixed with "copilot/".
    pub fn listModels(self: *CopilotClient) !std.json.Parsed(OpenAI.ModelsResponse) {
        // Build cache key
        var cache_key_buf: [128]u8 = undefined;
        const cache_key = std.fmt.bufPrint(&cache_key_buf, "models:{s}", .{self.config.name}) catch "models:copilot";

        // Check cache
        if (app_cache.get(self.allocator, cache_key)) |cached_body| {
            defer self.allocator.free(cached_body);
            log.debug("[Copilot] Models cache hit for '{s}'", .{self.config.name});

            if (std.json.parseFromSlice(
                OpenAI.ModelsResponse,
                self.allocator,
                cached_body,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            )) |parsed| {
                return parsed;
            } else |_| {
                log.warn("[Copilot] Failed to parse cached models for '{s}', fetching fresh", .{self.config.name});
            }
        }

        log.debug("[Copilot] listModels - getting access token...", .{});
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);
        log.debug("[Copilot] listModels - access token obtained", .{});

        const api_base = self.api_base orelse return error.ApiBaseNotSet;

        // Build URL
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/models", .{api_base});
        log.debug("[Copilot] listModels - URL: {s}", .{url});

        // Build GET headers (8, no Content-Type)
        var auth_buf: [512]u8 = undefined;
        var uuid_buf: [37]u8 = undefined;
        var headers_buf: [8]std.http.Header = undefined;
        const headers = try self.buildGetHeaders(access_token, &auth_buf, &uuid_buf, &headers_buf);

        // GET request — use getUncompressed (same gzip concern as token endpoint)
        log.debug("[Copilot] listModels - sending GET request...", .{});
        var response = self.client.getUncompressed(url, headers) catch |err| {
            log.err("[Copilot] listModels - GET request failed: {}", .{err});
            return err;
        };
        defer response.deinit();
        log.debug("[Copilot] listModels - response status: {}, body length: {d}", .{ response.status, response.body.len });

        if (response.status != .ok) {
            log.err("[Copilot] listModels failed: HTTP {} | body: {s}", .{ response.status, response.body });
            return error.RequestFailed;
        }

        // Cache the response body (best-effort)
        app_cache.put(cache_key, response.body) catch |err| {
            log.warn("[Copilot] Failed to cache models for '{s}': {}", .{ self.config.name, err });
        };

        // Parse response
        const parsed = std.json.parseFromSlice(
            OpenAI.ModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("[Copilot] Failed to parse models response: {} | body: {s}", .{ err, response.body });
            return error.InvalidResponse;
        };

        return parsed;
    }

    pub fn deinit(self: *CopilotClient) void {
        if (self.api_token) |t| self.allocator.free(t);
        if (self.api_base) |b| self.allocator.free(b);
        self.client.deinit();
    }
};
