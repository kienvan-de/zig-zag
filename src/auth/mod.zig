//! Authentication Module
//!
//! Provides reusable authentication helpers for OAuth 2.0 and OIDC flows.
//!
//! Components:
//! - `pkce` - PKCE (Proof Key for Code Exchange) generation
//! - `oidc` - OIDC discovery and authorization URL building
//! - `oauth` - OAuth 2.0 token exchange and refresh
//!
//! Usage:
//! ```zig
//! const auth = @import("auth/mod.zig");
//!
//! // Generate PKCE
//! var pkce = try auth.pkce.generate(allocator);
//! defer pkce.deinit(allocator);
//!
//! // OIDC discovery
//! var oidc = auth.oidc.OIDC.init(allocator, auth_domain, config_path);
//! const config = try oidc.discover(&http_client);
//!
//! // Build authorization URL
//! var auth_url = try oidc.buildAuthorizationUrl(allocator, params);
//!
//! // Token exchange
//! var tokens = try auth.oauth.exchangeCode(allocator, &http_client, exchange_params);
//! ```

pub const pkce = @import("pkce.zig");
pub const oidc = @import("oidc.zig");
pub const oauth = @import("oauth.zig");
pub const callback_server = @import("callback_server.zig");

// Re-export commonly used types
pub const PKCE = pkce.PKCE;
pub const OIDC = oidc.OIDC;
pub const OIDCConfig = oidc.OIDCConfig;
pub const AuthorizationParams = oidc.AuthorizationParams;
pub const AuthorizationUrl = oidc.AuthorizationUrl;
pub const TokenResponse = oauth.TokenResponse;
pub const ExchangeCodeParams = oauth.ExchangeCodeParams;
pub const RefreshTokenParams = oauth.RefreshTokenParams;
pub const CallbackConfig = callback_server.CallbackConfig;
pub const CallbackResult = callback_server.CallbackResult;
