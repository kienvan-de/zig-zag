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

//! OIDC (OpenID Connect) Module
//!
//! Provides OIDC functionality for providers that use OIDC authentication.
//! Designed to be used as a member/component of provider clients.
//!
//! Features:
//! - Fetch OIDC configuration from discovery endpoint
//! - Build authorization URLs with PKCE support
//! - Two-level caching: instance cache + app_cache
//! - Thread-safe via app_cache
//!
//! Usage:
//! ```zig
//! const HaiClient = struct {
//!     http_client: HttpClient,
//!     oidc: OIDC,
//!
//!     pub fn init(allocator: Allocator, auth_domain: []const u8) HaiClient {
//!         return .{
//!             .http_client = HttpClient.init(allocator),
//!             .oidc = OIDC.init(allocator, auth_domain, "/.well-known/openid-configuration"),
//!         };
//!     }
//! };
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_cache = @import("../cache/app_cache.zig");
const log = @import("../log.zig");

// ============================================================================
// Types
// ============================================================================

/// OIDC Discovery Configuration
/// Contains endpoints discovered from the OIDC provider
pub const OIDCConfig = struct {
    allocator: Allocator,
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
    end_session_endpoint: ?[]const u8,

    /// Free all allocated strings
    pub fn deinit(self: *OIDCConfig) void {
        self.allocator.free(self.issuer);
        self.allocator.free(self.authorization_endpoint);
        self.allocator.free(self.token_endpoint);
        self.allocator.free(self.jwks_uri);
        if (self.end_session_endpoint) |endpoint| {
            self.allocator.free(endpoint);
        }
        self.* = undefined;
    }
};

/// Parameters for building authorization URL
pub const AuthorizationParams = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    code_challenge: []const u8,
};

/// Authorization URL result
/// Caller owns both url and state, must free with deinit()
pub const AuthorizationUrl = struct {
    url: []const u8,
    state: []const u8, // Caller needs this to verify callback

    pub fn deinit(self: *AuthorizationUrl, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.state);
        self.* = undefined;
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const OIDCError = error{
    OIDCDiscoveryFailed,
    OIDCNotDiscovered,
};

// ============================================================================
// Private Helpers
// ============================================================================

/// URL-encode a string per RFC 3986
/// Encodes all characters except unreserved: A-Z a-z 0-9 - _ . ~
fn urlEncode(allocator: Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse OIDC configuration from JSON response
fn parseOIDCConfig(allocator: Allocator, json_body: []const u8) !OIDCConfig {
    const parsed = try std.json.parseFromSlice(
        struct {
            issuer: []const u8,
            authorization_endpoint: []const u8,
            token_endpoint: []const u8,
            jwks_uri: []const u8,
            end_session_endpoint: ?[]const u8 = null,
        },
        allocator,
        json_body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Duplicate strings so they outlive the parsed result
    const issuer = try allocator.dupe(u8, parsed.value.issuer);
    errdefer allocator.free(issuer);

    const authorization_endpoint = try allocator.dupe(u8, parsed.value.authorization_endpoint);
    errdefer allocator.free(authorization_endpoint);

    const token_endpoint = try allocator.dupe(u8, parsed.value.token_endpoint);
    errdefer allocator.free(token_endpoint);

    const jwks_uri = try allocator.dupe(u8, parsed.value.jwks_uri);
    errdefer allocator.free(jwks_uri);

    const end_session_endpoint = if (parsed.value.end_session_endpoint) |endpoint|
        try allocator.dupe(u8, endpoint)
    else
        null;

    return OIDCConfig{
        .allocator = allocator,
        .issuer = issuer,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .jwks_uri = jwks_uri,
        .end_session_endpoint = end_session_endpoint,
    };
}

// ============================================================================
// OIDC Struct
// ============================================================================

/// OIDC Helper - manages OIDC discovery and caching
/// Designed to be a member of provider clients
/// Uses global app_cache for thread-safe config storage
pub const OIDC = struct {
    allocator: Allocator,
    auth_domain: []const u8,
    config_path: []const u8,
    config: ?OIDCConfig, // Parsed config for current request lifetime

    /// Initialize OIDC helper
    /// auth_domain: e.g., "https://accounts.example.com"
    /// config_path: e.g., "/.well-known/openid-configuration"
    pub fn init(allocator: Allocator, auth_domain: []const u8, config_path: []const u8) OIDC {
        return .{
            .allocator = allocator,
            .auth_domain = auth_domain,
            .config_path = config_path,
            .config = null,
        };
    }

    /// Cleanup OIDC helper
    pub fn deinit(self: *OIDC) void {
        if (self.config) |*config| {
            config.deinit();
        }
        self.* = undefined;
    }

    /// Discover OIDC configuration
    /// Uses global app_cache for thread-safe caching
    /// Parses and stores config in self.config for current request lifetime
    ///
    /// Parameters:
    /// - client: HttpClient or CurlClient instance (anytype)
    ///
    /// Returns pointer to config (valid until deinit)
    pub fn discover(
        self: *OIDC,
        client: anytype,
    ) !*const OIDCConfig {
        // If already discovered in this request, return cached
        if (self.config) |*config| {
            return config;
        }

        // Check app_cache (global, thread-safe)
        const cache_key = try self.buildCacheKey();
        defer self.allocator.free(cache_key);

        if (app_cache.get(self.allocator, cache_key)) |cached_json| {
            defer self.allocator.free(cached_json);
            log.debug("OIDC config found in app_cache for {s}", .{self.auth_domain});

            self.config = try parseOIDCConfig(self.allocator, cached_json);
            return &self.config.?;
        }

        // Fetch from HTTP
        log.info("Fetching OIDC config from {s}{s}", .{ self.auth_domain, self.config_path });

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.auth_domain, self.config_path });
        defer self.allocator.free(url);

        var response = try client.getJson(url, &[_]std.http.Header{});
        defer response.deinit();

        if (response.status != .ok) {
            log.err("OIDC discovery failed: HTTP {}", .{response.status});
            return error.OIDCDiscoveryFailed;
        }

        // Parse and cache
        self.config = try parseOIDCConfig(self.allocator, response.body);

        // Store in app cache for future instances
        app_cache.put(cache_key, response.body) catch |err| {
            log.warn("Failed to cache OIDC config: {}", .{err});
            // Continue even if caching fails
        };

        log.info("OIDC discovery successful for {s}", .{self.auth_domain});
        return &self.config.?;
    }

    /// Build authorization URL for OIDC Authorization Code Flow with PKCE
    /// Requires discover() to be called first to get authorization_endpoint
    pub fn buildAuthorizationUrl(
        self: *OIDC,
        allocator: Allocator,
        params: AuthorizationParams,
    ) !AuthorizationUrl {
        const config = self.config orelse return error.OIDCNotDiscovered;

        // Generate random state for CSRF protection (32 bytes -> 43 chars base64url)
        var state_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&state_bytes);
        const state = try allocator.alloc(u8, 43);
        errdefer allocator.free(state);
        _ = std.base64.url_safe_no_pad.Encoder.encode(state, &state_bytes);

        // URL-encode parameters that may contain special characters
        const encoded_redirect_uri = try urlEncode(allocator, params.redirect_uri);
        defer allocator.free(encoded_redirect_uri);

        const encoded_scope = try urlEncode(allocator, params.scope);
        defer allocator.free(encoded_scope);

        // Build URL with query parameters
        // Note: client_id, state, code_challenge are already URL-safe (alphanumeric/base64url)
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&state={s}&code_challenge={s}&code_challenge_method=S256",
            .{
                config.authorization_endpoint,
                params.client_id,
                encoded_redirect_uri,
                encoded_scope,
                state,
                params.code_challenge,
            },
        );

        return AuthorizationUrl{
            .url = url,
            .state = state,
        };
    }

    // ------------------------------------------------------------------------
    // Private methods
    // ------------------------------------------------------------------------

    /// Build cache key for app_cache
    fn buildCacheKey(self: *OIDC) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "oidc:{s}", .{self.auth_domain});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "urlEncode encodes special characters" {
    const allocator = std.testing.allocator;

    const encoded = try urlEncode(allocator, "http://localhost:8335/auth-code");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("http%3A%2F%2Flocalhost%3A8335%2Fauth-code", encoded);
}

test "urlEncode preserves unreserved characters" {
    const allocator = std.testing.allocator;

    const encoded = try urlEncode(allocator, "hello-world_test.value~123");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("hello-world_test.value~123", encoded);
}

test "urlEncode handles spaces and ampersands" {
    const allocator = std.testing.allocator;

    const encoded = try urlEncode(allocator, "openid profile email");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("openid%20profile%20email", encoded);
}

test "buildAuthorizationUrl returns error when not discovered" {
    const allocator = std.testing.allocator;

    var oidc = OIDC.init(allocator, "https://auth.example.com", "/.well-known/openid-configuration");
    defer oidc.deinit();

    const result = oidc.buildAuthorizationUrl(allocator, .{
        .client_id = "test-client",
        .redirect_uri = "http://localhost:8335/callback",
        .scope = "openid",
        .code_challenge = "test-challenge",
    });

    try std.testing.expectError(error.OIDCNotDiscovered, result);
}

test "buildAuthorizationUrl generates valid URL with state" {
    const allocator = std.testing.allocator;

    var oidc = OIDC.init(allocator, "https://auth.example.com", "/.well-known/openid-configuration");
    defer oidc.deinit();

    // Manually set config to simulate discovered state
    oidc.config = OIDCConfig{
        .allocator = allocator,
        .issuer = try allocator.dupe(u8, "https://auth.example.com"),
        .authorization_endpoint = try allocator.dupe(u8, "https://auth.example.com/authorize"),
        .token_endpoint = try allocator.dupe(u8, "https://auth.example.com/token"),
        .jwks_uri = try allocator.dupe(u8, "https://auth.example.com/.well-known/jwks.json"),
        .end_session_endpoint = null,
    };

    var auth_url = try oidc.buildAuthorizationUrl(allocator, .{
        .client_id = "test-client",
        .redirect_uri = "http://localhost:8335/callback",
        .scope = "openid",
        .code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    });
    defer auth_url.deinit(allocator);

    // Verify URL contains expected parts
    try std.testing.expect(std.mem.startsWith(u8, auth_url.url, "https://auth.example.com/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "client_id=test-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "redirect_uri=http%3A%2F%2Flocalhost%3A8335%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "scope=openid") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, "code_challenge_method=S256") != null);

    // Verify state is 43 chars (32 bytes base64url encoded)
    try std.testing.expectEqual(@as(usize, 43), auth_url.state.len);

    // Verify state is in URL
    try std.testing.expect(std.mem.indexOf(u8, auth_url.url, auth_url.state) != null);
}

test "buildAuthorizationUrl generates unique state each time" {
    const allocator = std.testing.allocator;

    var oidc = OIDC.init(allocator, "https://auth.example.com", "/.well-known/openid-configuration");
    defer oidc.deinit();

    // Manually set config
    oidc.config = OIDCConfig{
        .allocator = allocator,
        .issuer = try allocator.dupe(u8, "https://auth.example.com"),
        .authorization_endpoint = try allocator.dupe(u8, "https://auth.example.com/authorize"),
        .token_endpoint = try allocator.dupe(u8, "https://auth.example.com/token"),
        .jwks_uri = try allocator.dupe(u8, "https://auth.example.com/.well-known/jwks.json"),
        .end_session_endpoint = null,
    };

    const params = AuthorizationParams{
        .client_id = "test-client",
        .redirect_uri = "http://localhost:8335/callback",
        .scope = "openid",
        .code_challenge = "test-challenge",
    };

    var auth_url1 = try oidc.buildAuthorizationUrl(allocator, params);
    defer auth_url1.deinit(allocator);

    var auth_url2 = try oidc.buildAuthorizationUrl(allocator, params);
    defer auth_url2.deinit(allocator);

    // States should be different (random)
    try std.testing.expect(!std.mem.eql(u8, auth_url1.state, auth_url2.state));
}
