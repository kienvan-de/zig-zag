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
    ToolNotFound,
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
    ListenerError,
    BrowserOpenFailed,
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

/// Upstream HTTP status errors — one per meaningful HTTP status code.
/// Used to carry the upstream status through the pipeline and back to the handler.
pub const UpstreamHttpError = error{
    BadRequest,
    Unauthorized,
    PaymentRequired,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    RequestTimeout,
    Conflict,
    PayloadTooLarge,
    UnsupportedMediaType,
    UnprocessableEntity,
    TooManyRequests,
    InternalServerError,
    NotImplemented,
    BadGateway,
    ServiceUnavailable,
    GatewayTimeout,
};

/// Single source of truth for the status <-> error <-> reason-phrase <-> type
/// mapping. Every function below is derived from this table so the views can
/// never silently diverge. `retryable` marks statuses that should trigger
/// smart-routing rollover to the next configured model (transient/server
/// failures, plus 404 model-not-found and 408 request-timeout). `error_type`
/// is the OpenAI-style ErrorType that best describes the status.
const StatusEntry = struct {
    status: std.http.Status,
    err: UpstreamHttpError,
    reason: []const u8,
    retryable: bool,
    error_type: ErrorType,
};

const status_table = [_]StatusEntry{
    .{ .status = .bad_request,            .err = error.BadRequest,           .reason = "Bad Request",            .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .unauthorized,           .err = error.Unauthorized,         .reason = "Unauthorized",           .retryable = true,  .error_type = .authentication_error },
    .{ .status = .payment_required,       .err = error.PaymentRequired,      .reason = "Payment Required",       .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .forbidden,              .err = error.Forbidden,            .reason = "Forbidden",              .retryable = true,  .error_type = .permission_error },
    .{ .status = .not_found,              .err = error.NotFound,             .reason = "Not Found",              .retryable = true,  .error_type = .not_found_error },
    .{ .status = .method_not_allowed,     .err = error.MethodNotAllowed,     .reason = "Method Not Allowed",     .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .request_timeout,        .err = error.RequestTimeout,       .reason = "Request Timeout",        .retryable = true,  .error_type = .invalid_request_error },
    .{ .status = .conflict,               .err = error.Conflict,             .reason = "Conflict",               .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .payload_too_large,      .err = error.PayloadTooLarge,      .reason = "Payload Too Large",      .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .unsupported_media_type, .err = error.UnsupportedMediaType, .reason = "Unsupported Media Type", .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .unprocessable_entity,   .err = error.UnprocessableEntity,  .reason = "Unprocessable Entity",   .retryable = false, .error_type = .invalid_request_error },
    .{ .status = .too_many_requests,      .err = error.TooManyRequests,      .reason = "Too Many Requests",      .retryable = true,  .error_type = .rate_limit_error },
    .{ .status = .internal_server_error,  .err = error.InternalServerError,  .reason = "Internal Server Error",  .retryable = true,  .error_type = .server_error },
    .{ .status = .not_implemented,        .err = error.NotImplemented,       .reason = "Not Implemented",        .retryable = false, .error_type = .server_error },
    .{ .status = .bad_gateway,            .err = error.BadGateway,           .reason = "Bad Gateway",            .retryable = true,  .error_type = .service_unavailable_error },
    .{ .status = .service_unavailable,    .err = error.ServiceUnavailable,   .reason = "Service Unavailable",    .retryable = true,  .error_type = .service_unavailable_error },
    .{ .status = .gateway_timeout,        .err = error.GatewayTimeout,       .reason = "Gateway Timeout",        .retryable = true,  .error_type = .service_unavailable_error },
};

/// Map a std.http.Status to an UpstreamHttpError.
/// Unknown/unmapped statuses fall back to BadGateway.
pub fn statusToError(status: std.http.Status) UpstreamHttpError {
    inline for (status_table) |e| {
        if (status == e.status) return e.err;
    }
    return error.BadGateway;
}

/// Map any error to an HTTP status if it is an UpstreamHttpError member,
/// otherwise null. Safe to call with arbitrary `anyerror`.
pub fn upstreamErrorToStatus(err: anyerror) ?std.http.Status {
    inline for (status_table) |e| {
        if (err == e.err) return e.status;
    }
    return null;
}

/// Whether an error should trigger smart-routing rollover to the next model.
/// True for transient/server upstream failures (and 404/408); false otherwise.
/// Non-UpstreamHttpError values return false.
pub fn isRetryableUpstream(err: anyerror) bool {
    inline for (status_table) |e| {
        if (err == e.err) return e.retryable;
    }
    return false;
}

/// The HTTP reason phrase for a status code (e.g. "Service Unavailable").
/// Falls back to "Internal Server Error" for statuses outside the table and
/// the non-upstream statuses (200/404-for-routing) handled by callers.
pub fn reasonPhrase(status: std.http.Status) []const u8 {
    switch (status) {
        .ok => return "OK",
        else => {},
    }
    inline for (status_table) |e| {
        if (status == e.status) return e.reason;
    }
    return "Internal Server Error";
}

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

/// Map an HTTP status to the OpenAI-style ErrorType that best describes it.
/// Derived from `status_table` so it never diverges from the other views.
/// Used to build a fallback error body whose `type` agrees with the status
/// when no upstream body is available. Non-table statuses fall back to
/// `.server_error`.
pub fn errorTypeForStatus(status: std.http.Status) ErrorType {
    inline for (status_table) |e| {
        if (status == e.status) return e.error_type;
    }
    return .server_error;
}

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

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    try buffer.print(allocator, "{f}", .{std.json.fmt(response, .{})});
    return try buffer.toOwnedSlice(allocator);
}

// ============================================================================
// Error classification — one place mapping any proxy error to a client reply
// ============================================================================

/// The fields needed to build a client-facing error response: the HTTP status,
/// the OpenAI-style `type`, a human message, and an optional machine `code`.
/// `classifyError` produces one of these for any error the proxy can surface.
pub const ClientError = struct {
    status: std.http.Status,
    error_type: ErrorType,
    message: []const u8,
    code: ?[]const u8 = null,
};

/// The proxy's own (non-upstream) errors, mapped to their client reply. Single
/// source of truth: add a domain error here and `classifyError` handles it, with
/// status/type/message/code guaranteed consistent because they share a row.
/// Upstream HTTP errors are handled separately via `status_table`.
///
/// `uses_model_message = true` marks the model-parsing rows whose message is the
/// caller-supplied "invalid model format" text (it embeds a protocol-appropriate
/// example, so it can't be a literal here); `classifyError` substitutes it.
const DomainEntry = struct {
    err: anyerror,
    status: std.http.Status,
    error_type: ErrorType,
    message: []const u8,
    code: ?[]const u8 = null,
    uses_model_message: bool = false,
};

const domain_table = [_]DomainEntry{
    .{ .err = error.BudgetExceeded,          .status = .too_many_requests,    .error_type = .rate_limit_error,      .message = "Budget exceeded. Cost controls are enabled and the budget limit has been reached.", .code = "budget_exceeded" },
    .{ .err = error.AuthRequired,            .status = .unauthorized,         .error_type = .invalid_request_error, .message = "Authentication required. Please authenticate this provider via POST /v1/config/{provider}/auth", .code = "auth_required" },
    .{ .err = error.InvalidModelFormat,      .status = .bad_request,          .error_type = .invalid_request_error, .message = "", .uses_model_message = true },
    .{ .err = error.EmptyProvider,           .status = .bad_request,          .error_type = .invalid_request_error, .message = "", .uses_model_message = true },
    .{ .err = error.EmptyModel,              .status = .bad_request,          .error_type = .invalid_request_error, .message = "", .uses_model_message = true },
    .{ .err = error.ProviderNotConfigured,   .status = .bad_request,          .error_type = .invalid_request_error, .message = "Provider not configured" },
    .{ .err = error.CompatibleFieldMissing,  .status = .bad_request,          .error_type = .invalid_request_error, .message = "Provider not supported and no 'compatible' field specified" },
    .{ .err = error.UnknownCompatibleType,   .status = .bad_request,          .error_type = .invalid_request_error, .message = "Unknown compatible provider type. Must be 'openai' or 'anthropic'" },
    .{ .err = error.TransformFailed,         .status = .bad_request,          .error_type = .invalid_request_error, .message = "Failed to transform request" },
    .{ .err = error.ClientInitFailed,        .status = .bad_request,          .error_type = .invalid_request_error, .message = "Failed to initialize provider client" },
    .{ .err = error.TransformResponseFailed, .status = .internal_server_error, .error_type = .server_error,         .message = "Failed to transform response" },
    // UpstreamError / HttpRequestFailed: upstream failed but no parsed body to
    // forward — surface as a Bad Gateway.
    .{ .err = error.UpstreamError,           .status = .bad_gateway,          .error_type = .server_error,          .message = "Failed to communicate with upstream API" },
    .{ .err = error.HttpRequestFailed,       .status = .bad_gateway,          .error_type = .server_error,          .message = "Failed to communicate with upstream API" },
};

/// Classify any error the proxy can return into a client-facing reply.
///
/// Resolution order:
///   1. `domain_table` — the proxy's own errors (budget, auth, model parsing, …).
///   2. `status_table` (via `upstreamErrorToStatus`/`errorTypeForStatus`) — a
///      raw upstream HTTP status error whose body was not captured.
///   3. Anything else — an unexpected internal error → 500.
///
/// `invalid_model_message` is the full "invalid model format" text for this
/// endpoint (it embeds a protocol-appropriate example); it is substituted for
/// the model-parsing rows.
pub fn classifyError(err: anyerror, invalid_model_message: []const u8) ClientError {
    inline for (domain_table) |e| {
        if (err == e.err) return .{
            .status = e.status,
            .error_type = e.error_type,
            .message = if (e.uses_model_message) invalid_model_message else e.message,
            .code = e.code,
        };
    }
    if (upstreamErrorToStatus(err)) |status| return .{
        .status = status,
        .error_type = errorTypeForStatus(status),
        .message = "Upstream API returned an error",
        .code = null,
    };
    return .{
        .status = .internal_server_error,
        .error_type = .server_error,
        .message = "Internal server error",
        .code = null,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================
