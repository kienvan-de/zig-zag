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

const std = @import("std");

// ============================================================================
// Error Sets
// ============================================================================

/// Configuration errors (config.zig)
pub const ConfigError = error{
    HomeNotFound,
    FileNotFound,
    InvalidConfigFormat,
    InvalidProvider,
    InvalidProviderConfig,
    MissingApiKey,
    OutOfMemory,
};

/// Curl client errors (curl.zig)
pub const CurlError = error{
    CurlNotFound,
    CurlFailed,
    OutOfMemory,
};

/// OIDC discovery errors (auth/oidc.zig)
pub const OIDCError = error{
    OIDCDiscoveryFailed,
    OIDCNotDiscovered,
};

/// OAuth token exchange/refresh errors (auth/oauth.zig)
pub const OAuthError = error{
    TokenExchangeFailed,
    TokenRefreshFailed,
    ClientCredentialsFailed,
    InvalidTokenResponse,
};

/// Device flow authentication errors (auth/oauth.zig)
pub const DeviceFlowError = error{
    DeviceCodeRequestFailed,
    DeviceCodeExpired,
    DeviceFlowDenied,
    InvalidDeviceCodeResponse,
};

/// Callback server errors for browser auth (auth/callback_server.zig)
pub const CallbackError = error{
    Timeout,
    StateMismatch,
    MissingCode,
    MissingState,
    ServerError,
    BrowserOpenFailed,
};

/// Provider resolution errors (provider.zig)
pub const ProviderError = error{
    UnsupportedProvider,
    InvalidProvider,
};

/// Model string parsing errors (utils.zig)
pub const ModelParseError = error{
    InvalidModelFormat,
    EmptyProvider,
    EmptyModel,
    OutOfMemory,
};

/// Budget enforcement error (utils.zig).
/// Total cost (input + output) has reached or exceeded the configured budget.
pub const BudgetError = error{
    BudgetExceeded,
};

/// Completion lifecycle errors (completion.zig).
/// Superset that includes model parsing and budget errors for convenience.
/// Callers should `switch (err)` to map these to HTTP status codes or other
/// transport-specific responses.
pub const CompletionError = error{
    /// Cost budget exceeded — caller should respond with 429.
    BudgetExceeded,
    /// Model string could not be parsed (`"provider/model-name"` expected).
    InvalidModelFormat,
    /// Provider portion of the model string is empty (e.g. `"/gpt-4o"`).
    EmptyProvider,
    /// Model portion of the model string is empty (e.g. `"openai/"`).
    EmptyModel,
    /// No matching provider entry in `config.json`.
    ProviderNotConfigured,
    /// Non-native provider without a `"compatible"` field in its config.
    CompatibleFieldMissing,
    /// `"compatible"` field value is not `"openai"` or `"anthropic"`.
    UnknownCompatibleType,
    /// Transformer failed to convert the request to provider-native format.
    TransformFailed,
    /// Provider client init failed (auth, credentials, network).
    ClientInitFailed,
    /// Upstream provider returned an error or the connection failed.
    UpstreamError,
    /// Transformer failed to convert the upstream response back.
    TransformResponseFailed,
    /// Provider requires authentication before use (e.g. Copilot device flow).
    /// Caller should prompt the user to authenticate via the config auth API.
    AuthRequired,
};

/// HTTP upstream errors — shared by all provider clients
pub const HttpError = error{
    AuthenticationError,
    RateLimitError,
    ServerError,
    InvalidStatusCode,
    MissingApiKey,
};

// ============================================================================
// OpenAI-compatible Error Response
// ============================================================================

/// OpenAI-compatible error response structure
pub const ErrorResponse = struct {
    @"error": ErrorDetail,

    pub const ErrorDetail = struct {
        message: []const u8,
        type: []const u8,
        code: ?[]const u8 = null,
    };
};

/// Error types following OpenAI conventions
pub const ErrorType = enum {
    invalid_request_error,
    authentication_error,
    permission_error,
    not_found_error,
    rate_limit_error,
    server_error,
    service_unavailable_error,

    pub fn toString(self: ErrorType) []const u8 {
        return switch (self) {
            .invalid_request_error => "invalid_request_error",
            .authentication_error => "authentication_error",
            .permission_error => "permission_error",
            .not_found_error => "not_found_error",
            .rate_limit_error => "rate_limit_error",
            .server_error => "server_error",
            .service_unavailable_error => "service_unavailable_error",
        };
    }
};

/// Create an OpenAI-compatible error response
pub fn createErrorResponse(
    allocator: std.mem.Allocator,
    message: []const u8,
    error_type: ErrorType,
    code: ?[]const u8,
) ![]const u8 {
    const response = ErrorResponse{
        .@"error" = .{
            .message = message,
            .type = error_type.toString(),
            .code = code,
        },
    };

    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    try buffer.writer(allocator).print("{f}", .{std.json.fmt(response, .{})});
    return try buffer.toOwnedSlice(allocator);
}

/// Map HTTP status codes to OpenAI error types
pub fn statusCodeToErrorType(status: std.http.Status) ErrorType {
    return switch (status) {
        .bad_request => .invalid_request_error,
        .unauthorized => .authentication_error,
        .forbidden => .permission_error,
        .not_found => .not_found_error,
        .too_many_requests => .rate_limit_error,
        .internal_server_error, .bad_gateway, .gateway_timeout => .server_error,
        .service_unavailable => .service_unavailable_error,
        else => .server_error,
    };
}

/// Create error response from HTTP status code
pub fn createErrorFromStatus(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    message: ?[]const u8,
) ![]const u8 {
    const error_type = statusCodeToErrorType(status);
    const default_message = switch (error_type) {
        .invalid_request_error => "Invalid request",
        .authentication_error => "Authentication failed",
        .permission_error => "Permission denied",
        .not_found_error => "Resource not found",
        .rate_limit_error => "Rate limit exceeded",
        .server_error => "Internal server error",
        .service_unavailable_error => "Service temporarily unavailable",
    };

    return try createErrorResponse(
        allocator,
        message orelse default_message,
        error_type,
        null,
    );
}

// ============================================================================
// Unit Tests
// ============================================================================
