const std = @import("std");
const chat_handler = @import("handlers/chat.zig");

/// Route definition
pub const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: *const fn (
        allocator: std.mem.Allocator,
        connection: std.net.Server.Connection,
        body: []const u8,
        api_key: []const u8,
    ) anyerror!void,
};

/// Match incoming HTTP request to a route
/// Returns null if no route matches
pub fn match(request_data: []const u8) ?Route {
    if (request_data.len == 0) return null;

    // Extract method and path from request line
    const method = extractMethod(request_data) orelse return null;
    const path = extractPath(request_data) orelse return null;

    // Match routes
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/chat/completions")) {
        return Route{
            .method = "POST",
            .path = "/v1/chat/completions",
            .handler = chat_handler.handle,
        };
    }

    // Future routes:
    // if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/v1/models")) { ... }
    // if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/embeddings")) { ... }

    return null;
}

/// Extract HTTP method from request line
fn extractMethod(request_data: []const u8) ?[]const u8 {
    const space_pos = std.mem.indexOf(u8, request_data, " ") orelse return null;
    return request_data[0..space_pos];
}

/// Extract path from request line
fn extractPath(request_data: []const u8) ?[]const u8 {
    const first_space = std.mem.indexOf(u8, request_data, " ") orelse return null;
    const remaining = request_data[first_space + 1 ..];
    const second_space = std.mem.indexOf(u8, remaining, " ") orelse return null;

    const path_with_query = remaining[0..second_space];

    // Remove query string if present
    if (std.mem.indexOf(u8, path_with_query, "?")) |query_pos| {
        return path_with_query[0..query_pos];
    }

    return path_with_query;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "extractMethod returns correct method" {
    const testing = std.testing;

    try testing.expectEqualStrings("POST", extractMethod("POST /v1/chat/completions HTTP/1.1").?);
    try testing.expectEqualStrings("GET", extractMethod("GET /v1/models HTTP/1.1").?);
    try testing.expectEqualStrings("PUT", extractMethod("PUT /v1/data HTTP/1.1").?);
}

test "extractMethod returns null for invalid request" {
    const testing = std.testing;

    try testing.expect(extractMethod("") == null);
    try testing.expect(extractMethod("INVALID") == null);
}

test "extractPath returns correct path" {
    const testing = std.testing;

    try testing.expectEqualStrings("/v1/chat/completions", extractPath("POST /v1/chat/completions HTTP/1.1").?);
    try testing.expectEqualStrings("/v1/models", extractPath("GET /v1/models HTTP/1.1").?);
    try testing.expectEqualStrings("/", extractPath("GET / HTTP/1.1").?);
}

test "extractPath strips query string" {
    const testing = std.testing;

    try testing.expectEqualStrings("/v1/chat/completions", extractPath("POST /v1/chat/completions?stream=true HTTP/1.1").?);
    try testing.expectEqualStrings("/search", extractPath("GET /search?q=test&lang=en HTTP/1.1").?);
}

test "extractPath returns null for invalid request" {
    const testing = std.testing;

    try testing.expect(extractPath("") == null);
    try testing.expect(extractPath("GET") == null);
    try testing.expect(extractPath("GET /path") == null);
}

test "match returns chat handler for POST /v1/chat/completions" {
    const testing = std.testing;

    const request = "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const route = match(request);

    try testing.expect(route != null);
    try testing.expectEqualStrings("POST", route.?.method);
    try testing.expectEqualStrings("/v1/chat/completions", route.?.path);
}

test "match handles query parameters" {
    const testing = std.testing;

    const request = "POST /v1/chat/completions?stream=true HTTP/1.1\r\n";
    const route = match(request);

    try testing.expect(route != null);
    try testing.expectEqualStrings("/v1/chat/completions", route.?.path);
}

test "match returns null for unknown routes" {
    const testing = std.testing;

    try testing.expect(match("GET /v1/models HTTP/1.1") == null);
    try testing.expect(match("POST /unknown HTTP/1.1") == null);
    try testing.expect(match("DELETE /v1/chat/completions HTTP/1.1") == null);
}

test "match returns null for malformed requests" {
    const testing = std.testing;

    try testing.expect(match("") == null);
    try testing.expect(match("INVALID") == null);
    try testing.expect(match("GET") == null);
}

test "match is case-sensitive for methods" {
    const testing = std.testing;

    // HTTP methods must be uppercase
    try testing.expect(match("post /v1/chat/completions HTTP/1.1") == null);
    try testing.expect(match("Post /v1/chat/completions HTTP/1.1") == null);
}

test "match is case-sensitive for paths" {
    const testing = std.testing;

    // Paths are case-sensitive
    try testing.expect(match("POST /V1/CHAT/COMPLETIONS HTTP/1.1") == null);
    try testing.expect(match("POST /v1/Chat/Completions HTTP/1.1") == null);
}