//! HAI (Hyperspace AI) Provider Client
//!
//! Client for Hyperspace AI API with OIDC authentication.
//! HAI is OpenAI-compatible, so this client follows the OpenAI client pattern
//! with OIDC auth flow on top.
//!
//! Features:
//! - OIDC discovery and authorization
//! - Token exchange and refresh
//! - OpenAI-compatible API (no transformation needed)
//! - Browser-based authentication flow
//!
//! Usage:
//! ```zig
//! var client = try HaiClient.init(allocator, &provider_config);
//! defer client.deinit();
//!
//! // Authenticate (opens browser if needed)
//! try client.authenticate();
//!
//! // Send request (same as OpenAI)
//! var response = try client.sendRequest(request);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const OpenAI = @import("../openai/types.zig");
const config_mod = @import("../../config.zig");
const http_client = @import("../../client.zig");
const log = @import("../../log.zig");
const auth = @import("../../auth/mod.zig");

/// Iterator for SSE streaming responses
pub const SSEIterator = http_client.SSEIterator;

/// Result of starting a streaming request
pub const StreamingResult = http_client.SSEResult;

// ============================================================================
// HAI Client
// ============================================================================

pub const HaiClient = struct {
    allocator: Allocator,
    config: *const config_mod.ProviderConfig,
    client: http_client.HttpClient,
    oidc: auth.OIDC,
    oauth: auth.OAuth,

    // Config values (extracted for convenience)
    api_url: []const u8,
    redirect_port: u16,
    redirect_path: []const u8,
    models_path: []const u8,
    chat_completions_path: []const u8,

    const DEFAULT_TIMEOUT_MS = 60000;
    const DEFAULT_MAX_RESPONSE_SIZE_MB = 10;

    pub fn init(allocator: Allocator, provider_config: *const config_mod.ProviderConfig) !HaiClient {
        // Extract ALL required config fields (no defaults for HAI-specific values)
        const api_url = provider_config.getString("api_url") orelse {
            log.err("HAI provider config missing 'api_url' field", .{});
            return error.MissingConfig;
        };

        const client_id = provider_config.getString("client_id") orelse {
            log.err("HAI provider config missing 'client_id' field", .{});
            return error.MissingConfig;
        };

        const auth_domain = provider_config.getString("auth_domain") orelse {
            log.err("HAI provider config missing 'auth_domain' field", .{});
            return error.MissingConfig;
        };

        const oidc_config_path = provider_config.getString("oidc_config_path") orelse {
            log.err("HAI provider config missing 'oidc_config_path' field", .{});
            return error.MissingConfig;
        };

        const redirect_port_int = provider_config.getInt("redirect_port") orelse {
            log.err("HAI provider config missing 'redirect_port' field", .{});
            return error.MissingConfig;
        };
        const redirect_port: u16 = @intCast(redirect_port_int);

        const redirect_path = provider_config.getString("redirect_path") orelse {
            log.err("HAI provider config missing 'redirect_path' field", .{});
            return error.MissingConfig;
        };

        const models_path = provider_config.getString("models_path") orelse {
            log.err("HAI provider config missing 'models_path' field", .{});
            return error.MissingConfig;
        };

        const chat_completions_path = provider_config.getString("chat_completions_path") orelse {
            log.err("HAI provider config missing 'chat_completions_path' field", .{});
            return error.MissingConfig;
        };

        // Optional timeout settings (these can have defaults as they're not HAI-specific)
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
            .oidc = auth.OIDC.init(allocator, auth_domain, oidc_config_path),
            .oauth = auth.OAuth.init(allocator, "hai", client_id),
            .api_url = api_url,
            .redirect_port = redirect_port,
            .redirect_path = redirect_path,
            .models_path = models_path,
            .chat_completions_path = chat_completions_path,
        };
    }

    pub fn deinit(self: *HaiClient) void {
        self.oidc.deinit();
        self.client.deinit();
    }

    // ========================================================================
    // Authentication
    // ========================================================================

    /// Get valid access token, refreshing or re-authenticating if needed
    /// Returns duplicated token that caller must free
    pub fn getAccessToken(self: *HaiClient) ![]const u8 {
        // 1. Check if we have a valid cached token
        if (self.oauth.getCachedToken()) |token| {
            log.debug("HAI: Using cached access token", .{});
            return token;
        }

        // 2. Acquire fetch lock to prevent multiple browser sessions
        const lock_handle = try self.oauth.acquireFetchLock();
        defer self.oauth.releaseFetchLock(lock_handle);

        // 3. Check cache again (another thread may have fetched while we waited)
        if (self.oauth.getCachedToken()) |token| {
            log.debug("HAI: Token found in cache after acquiring lock", .{});
            return token;
        }

        // 4. Try to refresh using cached refresh_token
        if (try self.tryRefreshToken()) |access_token| {
            log.info("HAI: Token refreshed successfully", .{});
            return access_token;
        }

        // 5. Need full browser auth flow
        log.info("HAI: Starting browser authentication flow", .{});
        return try self.browserAuthFlow();
    }

    /// Try to refresh token using cached refresh token
    /// Returns new access_token (caller owns) or null if refresh not possible
    fn tryRefreshToken(self: *HaiClient) !?[]const u8 {
        // Discover OIDC endpoints if not already done
        _ = try self.oidc.discover(&self.client);
        const oidc_config = self.oidc.config orelse return error.OIDCNotDiscovered;

        // Try to refresh using oauth member
        return self.oauth.refreshAndCache(&self.client, oidc_config.token_endpoint);
    }

    /// Full browser-based OIDC authentication flow
    /// Returns access_token (caller owns)
    fn browserAuthFlow(self: *HaiClient) ![]const u8 {
        // 1. Discover OIDC endpoints
        _ = try self.oidc.discover(&self.client);
        const oidc_config = self.oidc.config orelse return error.OIDCNotDiscovered;

        // 2. Generate PKCE
        var pkce = try auth.pkce.generate(self.allocator);
        defer pkce.deinit(self.allocator);

        // 3. Build redirect URI
        var redirect_uri_buf: [256]u8 = undefined;
        const redirect_uri = try std.fmt.bufPrint(
            &redirect_uri_buf,
            "http://localhost:{d}{s}",
            .{ self.redirect_port, self.redirect_path },
        );

        // 4. Build authorization URL
        var auth_url = try self.oidc.buildAuthorizationUrl(self.allocator, .{
            .client_id = self.oauth.client_id,
            .redirect_uri = redirect_uri,
            .scope = "openid",
            .code_challenge = pkce.code_challenge,
        });
        defer auth_url.deinit(self.allocator);

        // 5. Open browser
        try auth.callback_server.openBrowser(auth_url.url);

        // 6. Wait for callback
        var callback_result = try auth.callback_server.waitForCallback(self.allocator, .{
            .port = self.redirect_port,
            .path = self.redirect_path,
            .expected_state = auth_url.state,
            .timeout_ms = 120_000,
        });
        defer callback_result.deinit(self.allocator);

        // 7. Exchange code for tokens and cache
        const access_token = try self.oauth.exchangeCodeAndCache(
            &self.client,
            oidc_config.token_endpoint,
            callback_result.code,
            redirect_uri,
            pkce.code_verifier,
        );

        log.info("HAI: Authentication successful", .{});
        return access_token;
    }

    // ========================================================================
    // API Methods (OpenAI-compatible)
    // ========================================================================

    /// Build authorization headers for HAI API
    fn buildHeaders(_: *HaiClient, access_token: []const u8, auth_buffer: []u8, headers_buf: []std.http.Header) ![]std.http.Header {
        const auth_value = try std.fmt.bufPrint(auth_buffer, "Bearer {s}", .{access_token});

        headers_buf[0] = .{ .name = "Authorization", .value = auth_value };
        headers_buf[1] = .{ .name = "Content-Type", .value = "application/json" };

        return headers_buf[0..2];
    }

    /// Fetch list of available models from HAI API
    pub fn listModels(self: *HaiClient) !std.json.Parsed(OpenAI.ModelsResponse) {
        // Get valid access token
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.api_url, self.models_path });

        // Build headers
        var auth_buffer: [4096]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(access_token, &auth_buffer, &headers_buf);

        // Make GET request
        var response = try self.client.get(url, headers);
        defer response.deinit();

        // Check status code
        if (response.status != .ok) {
            log.err("HAI listModels failed: HTTP {}", .{response.status});
            return error.RequestFailed;
        }

        // Parse response
        return std.json.parseFromSlice(
            OpenAI.ModelsResponse,
            self.allocator,
            response.body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch |err| {
            log.err("Failed to parse HAI models response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Send a request to HAI Chat Completions API (non-streaming)
    pub fn sendRequest(self: *HaiClient, request: OpenAI.Request) !std.json.Parsed(OpenAI.Response) {
        // Get valid access token
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.api_url, self.chat_completions_path });

        // Build headers
        var auth_buffer: [4096]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(access_token, &auth_buffer, &headers_buf);

        // Make POST request with JSON body
        return self.client.postJson(OpenAI.Response, url, headers, request) catch |err| {
            log.err("Failed to send HAI request: {}", .{err});
            return err;
        };
    }

    /// Send a streaming request to HAI Chat Completions API
    pub fn sendStreamingRequest(self: *HaiClient, request: OpenAI.Request) !*StreamingResult {
        // Get valid access token
        const access_token = try self.getAccessToken();
        defer self.allocator.free(access_token);

        // Build URL
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.api_url, self.chat_completions_path });

        // Build headers
        var auth_buffer: [4096]u8 = undefined;
        var headers_buf: [2]std.http.Header = undefined;
        const headers = try self.buildHeaders(access_token, &auth_buffer, &headers_buf);

        // Make streaming POST request
        const result = try self.client.postStreaming(SSEIterator, url, headers, request);

        // Check status code
        if (result.response.head.status != .ok) {
            self.client.freeStreamingResult(SSEIterator, result);
            log.err("HAI streaming request failed: HTTP {}", .{result.response.head.status});
            return error.RequestFailed;
        }

        return result;
    }

    /// Free a streaming result allocated by sendStreamingRequest
    pub fn freeStreamingResult(self: *HaiClient, result: *StreamingResult) void {
        self.client.freeStreamingResult(SSEIterator, result);
    }
};


