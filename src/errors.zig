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

test "ErrorType.toString returns correct strings" {
    const testing = std.testing;

    try testing.expectEqualStrings("invalid_request_error", ErrorType.invalid_request_error.toString());
    try testing.expectEqualStrings("authentication_error", ErrorType.authentication_error.toString());
    try testing.expectEqualStrings("permission_error", ErrorType.permission_error.toString());
    try testing.expectEqualStrings("not_found_error", ErrorType.not_found_error.toString());
    try testing.expectEqualStrings("rate_limit_error", ErrorType.rate_limit_error.toString());
    try testing.expectEqualStrings("server_error", ErrorType.server_error.toString());
    try testing.expectEqualStrings("service_unavailable_error", ErrorType.service_unavailable_error.toString());
}

test "createErrorResponse generates valid JSON" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = try createErrorResponse(
        allocator,
        "Test error message",
        .invalid_request_error,
        null,
    );

    // Parse to verify valid JSON
    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("Test error message", parsed.value.@"error".message);
    try testing.expectEqualStrings("invalid_request_error", parsed.value.@"error".type);
}

test "createErrorResponse with error code" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = try createErrorResponse(
        allocator,
        "Invalid API key",
        .authentication_error,
        "invalid_api_key",
    );

    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("Invalid API key", parsed.value.@"error".message);
    try testing.expectEqualStrings("authentication_error", parsed.value.@"error".type);
    try testing.expectEqualStrings("invalid_api_key", parsed.value.@"error".code.?);
}

test "statusCodeToErrorType maps status codes correctly" {
    const testing = std.testing;

    try testing.expectEqual(ErrorType.invalid_request_error, statusCodeToErrorType(.bad_request));
    try testing.expectEqual(ErrorType.authentication_error, statusCodeToErrorType(.unauthorized));
    try testing.expectEqual(ErrorType.permission_error, statusCodeToErrorType(.forbidden));
    try testing.expectEqual(ErrorType.not_found_error, statusCodeToErrorType(.not_found));
    try testing.expectEqual(ErrorType.rate_limit_error, statusCodeToErrorType(.too_many_requests));
    try testing.expectEqual(ErrorType.server_error, statusCodeToErrorType(.internal_server_error));
    try testing.expectEqual(ErrorType.server_error, statusCodeToErrorType(.bad_gateway));
    try testing.expectEqual(ErrorType.server_error, statusCodeToErrorType(.gateway_timeout));
    try testing.expectEqual(ErrorType.service_unavailable_error, statusCodeToErrorType(.service_unavailable));
}

test "createErrorFromStatus with default messages" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = try createErrorFromStatus(allocator, .unauthorized, null);

    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("Authentication failed", parsed.value.@"error".message);
    try testing.expectEqualStrings("authentication_error", parsed.value.@"error".type);
}

test "createErrorFromStatus with custom message" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = try createErrorFromStatus(
        allocator,
        .too_many_requests,
        "You have exceeded your rate limit",
    );

    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("You have exceeded your rate limit", parsed.value.@"error".message);
    try testing.expectEqualStrings("rate_limit_error", parsed.value.@"error".type);
}

test "ErrorResponse structure has correct field" {
    const testing = std.testing;

    // Verify the field name is exactly "error" (with @"" syntax)
    const response = ErrorResponse{
        .@"error" = .{
            .message = "test",
            .type = "server_error",
            .code = null,
        },
    };

    try testing.expectEqualStrings("test", response.@"error".message);
    try testing.expectEqualStrings("server_error", response.@"error".type);
}

test "createErrorResponse handles long messages" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const long_message = "This is a very long error message that contains a lot of text to test if the error handling system can properly handle long error messages without any issues or truncation problems.";

    const json = try createErrorResponse(
        allocator,
        long_message,
        .server_error,
        null,
    );

    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings(long_message, parsed.value.@"error".message);
}

test "createErrorResponse handles special characters in message" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const message = "Error: \"Invalid JSON\" at line 5";

    const json = try createErrorResponse(
        allocator,
        message,
        .invalid_request_error,
        null,
    );

    // Verify it's valid JSON (should escape quotes properly)
    const parsed = try std.json.parseFromSlice(
        ErrorResponse,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    try testing.expectEqualStrings(message, parsed.value.@"error".message);
}

test "statusCodeToErrorType handles unknown status codes" {
    const testing = std.testing;

    // Unknown/uncommon status codes should default to server_error
    try testing.expectEqual(ErrorType.server_error, statusCodeToErrorType(.created));
    try testing.expectEqual(ErrorType.server_error, statusCodeToErrorType(.accepted));
}