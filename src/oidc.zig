//! OIDC (OpenID Connect) Discovery Module
//!
//! Provides OIDC discovery functionality for providers that use OIDC authentication.
//! Designed to be used as a member/component of provider clients.
//!
//! Features:
//! - Fetch OIDC configuration from discovery endpoint
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
const HttpClient = @import("client.zig").HttpClient;
const app_cache = @import("cache/app_cache.zig");
const log = @import("log.zig");

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

/// OIDC Helper - manages OIDC discovery and caching
/// Designed to be a member of provider clients
pub const OIDC = struct {
    allocator: Allocator,
    auth_domain: []const u8,
    config_path: []const u8,
    config: ?OIDCConfig,

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
    /// Uses two-level caching:
    /// 1. Instance cache (self.config) - fastest, no allocation
    /// 2. App cache - shared across instances, survives instance recreation
    /// 3. HTTP fetch - only on cache miss
    ///
    /// Returns pointer to cached config (valid until deinit)
    pub fn discover(self: *OIDC, http_client: *HttpClient) !*const OIDCConfig {
        // Level 1: Instance cache
        if (self.config) |*config| {
            log.debug("OIDC config found in instance cache for {s}", .{self.auth_domain});
            return config;
        }

        // Level 2: App cache
        const cache_key = try self.buildCacheKey();
        defer self.allocator.free(cache_key);

        if (app_cache.get(self.allocator, cache_key)) |cached_json| {
            defer self.allocator.free(cached_json);
            log.debug("OIDC config found in app cache for {s}", .{self.auth_domain});

            self.config = try parseOIDCConfig(self.allocator, cached_json);
            return &self.config.?;
        }

        // Level 3: HTTP fetch
        log.info("Fetching OIDC config from {s}{s}", .{ self.auth_domain, self.config_path });

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.auth_domain, self.config_path });
        defer self.allocator.free(url);

        var response = try http_client.get(url, &[_]std.http.Header{});
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

    /// Build cache key for app_cache
    fn buildCacheKey(self: *OIDC) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "oidc:{s}", .{self.auth_domain});
    }
};

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
// Errors
// ============================================================================

pub const OIDCError = error{
    OIDCDiscoveryFailed,
};
