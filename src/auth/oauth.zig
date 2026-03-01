//! OAuth 2.0 Token Exchange Module
//!
//! Provides OAuth 2.0 token exchange and refresh functionality.
//! Works with any OAuth 2.0 provider that supports:
//! - Authorization Code flow with PKCE (HAI)
//! - Client Credentials flow (SAP AI Core)
//! - Refresh token flow
//!
//! Components:
//! 1. `OAuth` struct - Member for provider clients, handles caching via global token_cache
//! 2. Standalone functions - `exchangeCode()`, `refreshToken()`, `fetchClientCredentials()`
//!
//! Token Flow Pattern (both providers use same pattern):
//! ```
//! 1. Check cache (fast path, no lock)
//! 2. Acquire fetch lock (prevent thundering herd)
//! 3. Check cache again (another thread may have fetched)
//! 4. Fetch token (refresh/browser/client_credentials)
//! 5. Cache and return
//! ```
//!
//! Usage - HAI (authorization_code + PKCE):
//! ```zig
//! fn getAccessToken(self: *HaiClient) ![]const u8 {
//!     if (self.oauth.getCachedToken()) |t| return t;
//!     const lock = try self.oauth.acquireFetchLock();
//!     defer self.oauth.releaseFetchLock(lock);
//!     if (self.oauth.getCachedToken()) |t| return t;
//!     if (try self.oauth.refreshAndCache(&self.client, endpoint)) |t| return t;
//!     return try self.browserAuthFlow(); // exchangeCodeAndCache inside
//! }
//! ```
//!
//! Usage - SAP AI Core (client_credentials):
//! ```zig
//! fn getAccessToken(self: *SapAiCoreClient) ![]const u8 {
//!     if (self.oauth.getCachedToken()) |t| return t;
//!     const lock = try self.oauth.acquireFetchLock();
//!     defer self.oauth.releaseFetchLock(lock);
//!     if (self.oauth.getCachedToken()) |t| return t;
//!     var tokens = try fetchClientCredentials(self.allocator, &self.client, params);
//!     defer tokens.deinit();
//!     try self.oauth.cacheTokens(tokens.access_token, null, tokens.expires_in);
//!     return self.allocator.dupe(u8, tokens.access_token);
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const token_cache = @import("../cache/token_cache.zig");
const log = @import("../log.zig");

// ============================================================================
// Types
// ============================================================================

/// Parameters for exchanging authorization code for tokens
pub const ExchangeCodeParams = struct {
    token_endpoint: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
    code_verifier: []const u8,
};

/// Parameters for refreshing access token
pub const RefreshTokenParams = struct {
    token_endpoint: []const u8,
    refresh_token: []const u8,
    client_id: []const u8,
};

/// Parameters for client credentials flow
pub const ClientCredentialsParams = struct {
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
};

/// Token response from OAuth server
pub const TokenResponse = struct {
    allocator: Allocator,
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8,
    id_token: ?[]const u8,

    pub fn deinit(self: *TokenResponse) void {
        self.allocator.free(self.access_token);
        self.allocator.free(self.token_type);
        if (self.refresh_token) |rt| self.allocator.free(rt);
        if (self.id_token) |it| self.allocator.free(it);
        self.* = undefined;
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const OAuthError = error{
    TokenExchangeFailed,
    TokenRefreshFailed,
    ClientCredentialsFailed,
    InvalidTokenResponse,
};

// ============================================================================
// OAuth Struct (for use as provider client member)
// ============================================================================

/// OAuth helper - manages token exchange, refresh, and caching
/// Designed to be a member of provider clients (like OIDC)
/// Uses global token_cache for thread-safe token storage
pub const OAuth = struct {
    allocator: Allocator,
    cache_key: []const u8,
    client_id: []const u8,

    const TOKEN_EXPIRY_BUFFER_SECONDS = 60;

    /// Initialize OAuth helper
    /// cache_key: unique key for token_cache (e.g., "hai")
    /// client_id: OAuth client ID for token requests
    pub fn init(allocator: Allocator, cache_key: []const u8, client_id: []const u8) OAuth {
        return .{
            .allocator = allocator,
            .cache_key = cache_key,
            .client_id = client_id,
        };
    }

    /// Get valid access token from cache
    /// Returns null if not found or expired
    /// Caller owns returned token and must free it
    pub fn getCachedToken(self: *OAuth) ?[]const u8 {
        if (token_cache.get(self.allocator, self.cache_key, TOKEN_EXPIRY_BUFFER_SECONDS)) |result| {
            // Free refresh_token copy since we only need access_token
            if (result.refresh_token) |rt| self.allocator.free(rt);
            return result.access_token;
        }
        return null;
    }

    /// Get refresh token from cache (even if access token expired)
    /// Returns null if not found
    /// Caller owns returned token and must free it
    pub fn getCachedRefreshToken(self: *OAuth) ?[]const u8 {
        return token_cache.getRefreshToken(self.allocator, self.cache_key);
    }

    /// Store tokens in cache
    pub fn cacheTokens(self: *OAuth, access_token: []const u8, refresh_token: ?[]const u8, expires_in: i64) !void {
        try token_cache.put(self.cache_key, access_token, refresh_token, expires_in);
    }

    /// Remove tokens from cache
    pub fn clearCache(self: *OAuth) void {
        token_cache.remove(self.cache_key);
    }

    /// Acquire fetch lock to prevent thundering herd
    /// Returns handle that MUST be passed to releaseFetchLock
    pub fn acquireFetchLock(self: *OAuth) !token_cache.FetchLockHandle {
        return token_cache.acquireFetchLock(self.cache_key);
    }

    /// Release fetch lock
    pub fn releaseFetchLock(_: *OAuth, handle: token_cache.FetchLockHandle) void {
        token_cache.releaseFetchLock(handle);
    }

    /// Exchange authorization code for tokens
    /// Stores tokens in cache on success
    /// Returns access_token (caller owns and must free)
    ///
    /// Parameters:
    /// - client: HttpClient or CurlClient instance (anytype)
    pub fn exchangeCodeAndCache(
        self: *OAuth,
        client: anytype,
        token_endpoint: []const u8,
        code: []const u8,
        redirect_uri: []const u8,
        code_verifier: []const u8,
    ) ![]const u8 {
        var tokens = try exchangeCode(self.allocator, client, .{
            .token_endpoint = token_endpoint,
            .code = code,
            .redirect_uri = redirect_uri,
            .client_id = self.client_id,
            .code_verifier = code_verifier,
        });
        defer tokens.deinit();

        // Cache tokens
        try self.cacheTokens(tokens.access_token, tokens.refresh_token, tokens.expires_in);

        return self.allocator.dupe(u8, tokens.access_token);
    }

    /// Refresh access token using cached refresh_token
    /// Stores new tokens in cache on success
    /// Returns new access_token (caller owns and must free) or null if refresh not possible
    ///
    /// Parameters:
    /// - client: HttpClient or CurlClient instance (anytype)
    pub fn refreshAndCache(
        self: *OAuth,
        client: anytype,
        token_endpoint: []const u8,
    ) !?[]const u8 {
        const refresh_tok = self.getCachedRefreshToken() orelse return null;
        defer self.allocator.free(refresh_tok);

        var tokens = refreshToken(self.allocator, client, .{
            .token_endpoint = token_endpoint,
            .refresh_token = refresh_tok,
            .client_id = self.client_id,
        }) catch |err| {
            log.warn("OAuth: Token refresh failed: {}, clearing cache", .{err});
            self.clearCache();
            return null;
        };
        defer tokens.deinit();

        // Cache new tokens
        try self.cacheTokens(tokens.access_token, tokens.refresh_token, tokens.expires_in);

        const duped = try self.allocator.dupe(u8, tokens.access_token);
        return duped;
    }
};

// ============================================================================
// Private Helpers
// ============================================================================

/// Build form-urlencoded body for token requests
fn buildFormBody(allocator: Allocator, params: anytype) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const fields = @typeInfo(@TypeOf(params)).@"struct".fields;
    var first = true;

    inline for (fields) |field| {
        const value = @field(params, field.name);
        if (value.len > 0) {
            if (!first) {
                try result.append(allocator, '&');
            }
            first = false;

            try result.appendSlice(allocator, field.name);
            try result.append(allocator, '=');
            try appendUrlEncoded(&result, allocator, value);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// URL-encode and append to result
fn appendUrlEncoded(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }
}

/// Parse token response JSON
fn parseTokenResponse(allocator: Allocator, json_body: []const u8) !TokenResponse {
    const parsed = std.json.parseFromSlice(
        struct {
            access_token: []const u8,
            token_type: []const u8 = "Bearer",
            expires_in: i64 = 3600,
            refresh_token: ?[]const u8 = null,
            id_token: ?[]const u8 = null,
        },
        allocator,
        json_body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("Failed to parse token response: {}", .{err});
        return error.InvalidTokenResponse;
    };
    defer parsed.deinit();

    // Duplicate strings so they outlive the parsed result
    const access_token = try allocator.dupe(u8, parsed.value.access_token);
    errdefer allocator.free(access_token);

    const token_type = try allocator.dupe(u8, parsed.value.token_type);
    errdefer allocator.free(token_type);

    const refresh_token = if (parsed.value.refresh_token) |rt|
        try allocator.dupe(u8, rt)
    else
        null;
    errdefer if (refresh_token) |rt| allocator.free(rt);

    const id_token = if (parsed.value.id_token) |it|
        try allocator.dupe(u8, it)
    else
        null;

    return TokenResponse{
        .allocator = allocator,
        .access_token = access_token,
        .token_type = token_type,
        .expires_in = parsed.value.expires_in,
        .refresh_token = refresh_token,
        .id_token = id_token,
    };
}

// ============================================================================
// Public Functions
// ============================================================================

/// Exchange authorization code for tokens
/// POST to token_endpoint with grant_type=authorization_code
///
/// Parameters:
/// - client: HttpClient or CurlClient instance (anytype)
pub fn exchangeCode(
    allocator: Allocator,
    client: anytype,
    params: ExchangeCodeParams,
) !TokenResponse {
    log.info("Exchanging authorization code for tokens at {s}", .{params.token_endpoint});

    // Build form body
    const body = try buildFormBody(allocator, .{
        .grant_type = "authorization_code",
        .code = params.code,
        .redirect_uri = params.redirect_uri,
        .client_id = params.client_id,
        .code_verifier = params.code_verifier,
    });
    defer allocator.free(body);

    // POST to token endpoint
    var response = try client.post(
        params.token_endpoint,
        &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        body,
    );
    defer response.deinit();

    if (response.status != .ok) {
        log.err("Token exchange failed: HTTP {} - {s}", .{ response.status, response.body });
        return error.TokenExchangeFailed;
    }

    log.info("Token exchange successful", .{});
    return parseTokenResponse(allocator, response.body);
}

/// Refresh access token using refresh token
/// POST to token_endpoint with grant_type=refresh_token
///
/// Parameters:
/// - client: HttpClient or CurlClient instance (anytype)
pub fn refreshToken(
    allocator: Allocator,
    client: anytype,
    params: RefreshTokenParams,
) !TokenResponse {
    log.info("Refreshing access token at {s}", .{params.token_endpoint});

    // Build form body
    const body = try buildFormBody(allocator, .{
        .grant_type = "refresh_token",
        .refresh_token = params.refresh_token,
        .client_id = params.client_id,
    });
    defer allocator.free(body);

    // POST to token endpoint
    var response = try client.post(
        params.token_endpoint,
        &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        body,
    );
    defer response.deinit();

    if (response.status != .ok) {
        log.err("Token refresh failed: HTTP {} - {s}", .{ response.status, response.body });
        return error.TokenRefreshFailed;
    }

    log.info("Token refresh successful", .{});
    return parseTokenResponse(allocator, response.body);
}

/// Fetch access token using client credentials grant
/// POST to token_endpoint with grant_type=client_credentials and Basic Auth header
///
/// Parameters:
/// - client: HttpClient or CurlClient instance (anytype)
pub fn fetchClientCredentials(
    allocator: Allocator,
    client: anytype,
    params: ClientCredentialsParams,
) !TokenResponse {
    log.info("Fetching token via client_credentials at {s}", .{params.token_endpoint});

    // Build Basic Auth header (client_id:client_secret base64 encoded)
    var credentials_buffer: [1024]u8 = undefined;
    const credentials = std.fmt.bufPrint(&credentials_buffer, "{s}:{s}", .{
        params.client_id,
        params.client_secret,
    }) catch return error.ClientCredentialsFailed;

    var base64_buffer: [2048]u8 = undefined;
    const base64_encoder = std.base64.standard;
    const encoded_len = base64_encoder.Encoder.calcSize(credentials.len);
    if (encoded_len > base64_buffer.len) return error.ClientCredentialsFailed;
    const encoded_credentials = base64_buffer[0..encoded_len];
    _ = base64_encoder.Encoder.encode(encoded_credentials, credentials);

    var auth_buffer: [2048]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_buffer, "Basic {s}", .{encoded_credentials}) catch return error.ClientCredentialsFailed;

    // Request body
    const request_body = "grant_type=client_credentials";

    // POST to token endpoint
    var response = try client.post(
        params.token_endpoint,
        &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        request_body,
    );
    defer response.deinit();

    if (response.status != .ok) {
        log.err("Client credentials token request failed: HTTP {} - {s}", .{ response.status, response.body });
        return error.ClientCredentialsFailed;
    }

    log.info("Client credentials token fetch successful", .{});
    return parseTokenResponse(allocator, response.body);
}

// ============================================================================
// Tests
// ============================================================================

test "buildFormBody creates correct form body" {
    const allocator = std.testing.allocator;

    const body = try buildFormBody(allocator, .{
        .grant_type = "authorization_code",
        .code = "test-code",
        .client_id = "my-client",
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings("grant_type=authorization_code&code=test-code&client_id=my-client", body);
}

test "buildFormBody URL-encodes special characters" {
    const allocator = std.testing.allocator;

    const body = try buildFormBody(allocator, .{
        .redirect_uri = "http://localhost:8335/callback",
        .scope = "openid profile",
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings("redirect_uri=http%3A%2F%2Flocalhost%3A8335%2Fcallback&scope=openid%20profile", body);
}

test "parseTokenResponse parses valid response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9",
        \\  "token_type": "Bearer",
        \\  "expires_in": 3600,
        \\  "refresh_token": "refresh-token-value",
        \\  "id_token": "id-token-value"
        \\}
    ;

    var tokens = try parseTokenResponse(allocator, json);
    defer tokens.deinit();

    try std.testing.expectEqualStrings("eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9", tokens.access_token);
    try std.testing.expectEqualStrings("Bearer", tokens.token_type);
    try std.testing.expectEqual(@as(i64, 3600), tokens.expires_in);
    try std.testing.expectEqualStrings("refresh-token-value", tokens.refresh_token.?);
    try std.testing.expectEqualStrings("id-token-value", tokens.id_token.?);
}

test "parseTokenResponse handles minimal response" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "access_token": "minimal-token"
        \\}
    ;

    var tokens = try parseTokenResponse(allocator, json);
    defer tokens.deinit();

    try std.testing.expectEqualStrings("minimal-token", tokens.access_token);
    try std.testing.expectEqualStrings("Bearer", tokens.token_type);
    try std.testing.expectEqual(@as(i64, 3600), tokens.expires_in);
    try std.testing.expect(tokens.refresh_token == null);
    try std.testing.expect(tokens.id_token == null);
}

test "parseTokenResponse returns error on invalid JSON" {
    const allocator = std.testing.allocator;

    const result = parseTokenResponse(allocator, "invalid json");
    try std.testing.expectError(error.InvalidTokenResponse, result);
}

test "parseTokenResponse returns error on missing access_token" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "token_type": "Bearer"
        \\}
    ;

    const result = parseTokenResponse(allocator, json);
    try std.testing.expectError(error.InvalidTokenResponse, result);
}

test "OAuth.init creates instance with correct fields" {
    const allocator = std.testing.allocator;
    const oauth = OAuth.init(allocator, "test-cache-key", "test-client-id");

    try std.testing.expectEqualStrings("test-cache-key", oauth.cache_key);
    try std.testing.expectEqualStrings("test-client-id", oauth.client_id);
}
