//! OAuth 2.0 Token Exchange Module
//!
//! Provides OAuth 2.0 token exchange and refresh functionality.
//! Works with any OAuth 2.0 provider that supports:
//! - Authorization Code flow with PKCE
//! - Refresh token flow
//!
//! Usage:
//! ```zig
//! const oauth = @import("auth/oauth.zig");
//!
//! // Exchange authorization code for tokens
//! var tokens = try oauth.exchangeCode(allocator, &http_client, .{
//!     .token_endpoint = "https://auth.example.com/token",
//!     .code = "authorization_code",
//!     .redirect_uri = "http://localhost:8335/callback",
//!     .client_id = "my-client",
//!     .code_verifier = "pkce_verifier",
//! });
//! defer tokens.deinit();
//!
//! // Refresh access token
//! var new_tokens = try oauth.refreshToken(allocator, &http_client, .{
//!     .token_endpoint = "https://auth.example.com/token",
//!     .refresh_token = tokens.refresh_token.?,
//!     .client_id = "my-client",
//! });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const HttpClient = @import("../client.zig").HttpClient;
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
    InvalidTokenResponse,
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
pub fn exchangeCode(
    allocator: Allocator,
    http_client: *HttpClient,
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
    var response = try http_client.post(
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
pub fn refreshToken(
    allocator: Allocator,
    http_client: *HttpClient,
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
    var response = try http_client.post(
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
