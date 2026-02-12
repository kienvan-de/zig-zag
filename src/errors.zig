const std = @import("std");

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
