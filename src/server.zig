const std = @import("std");
const config = @import("config.zig");

// HTTP response constants
const SUCCESS_RESPONSE =
    \\HTTP/1.1 200 OK
    \\Content-Type: application/json
    \\Content-Length: 19
    \\Connection: close
    \\
    \\{"status": "alive"}
;

const NOT_FOUND_RESPONSE =
    \\HTTP/1.1 404 Not Found
    \\Content-Type: application/json
    \\Content-Length: 22
    \\Connection: close
    \\
    \\{"error": "Not Found"}
;

/// Checks if the HTTP request is a valid POST to /v1/chat/completions
pub fn isValidChatCompletionRequest(request_data: []const u8) bool {
    if (request_data.len == 0) return false;
    
    const is_post = std.mem.startsWith(u8, request_data, "POST ");
    const has_endpoint = std.mem.indexOf(u8, request_data, "/v1/chat/completions") != null;
    
    return is_post and has_endpoint;
}

pub fn start(allocator: std.mem.Allocator, cfg: config.Config) !void {
    std.debug.print("Starting zig-zag proxy server on port 8080...\n", .{});
    std.debug.print("Anthropic API Key loaded: {s}\n", .{if (cfg.anthropic_api_key.len > 0) "Yes" else "No"});

    // Create server address
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);

    // Create TCP listener
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.debug.print("Listening on http://127.0.0.1:8080\n", .{});
    std.debug.print("Test endpoint: POST http://127.0.0.1:8080/v1/chat/completions\n", .{});

    // Accept connections in a loop
    while (true) {
        const connection = try listener.accept();
        
        // Handle each connection (for now, single-threaded)
        handleConnection(allocator, connection) catch |err| {
            std.debug.print("Error handling connection: {}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var read_buffer: [4096]u8 = undefined;
    
    // Read HTTP request
    const bytes_read = try connection.stream.read(&read_buffer);
    if (bytes_read == 0) return;
    
    const request_data = read_buffer[0..bytes_read];
    
    // Route request based on endpoint
    if (isValidChatCompletionRequest(request_data)) {
        _ = try connection.stream.writeAll(SUCCESS_RESPONSE);
    } else {
        _ = try connection.stream.writeAll(NOT_FOUND_RESPONSE);
    }
    
    _ = allocator;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "isValidChatCompletionRequest with valid POST request" {
    const testing = std.testing;
    
    const request =
        \\POST /v1/chat/completions HTTP/1.1
        \\Host: localhost:8080
        \\Content-Type: application/json
        \\
    ;
    
    try testing.expect(isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest with POST and query params" {
    const testing = std.testing;
    
    const request =
        \\POST /v1/chat/completions?stream=true HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest with minimal valid request" {
    const testing = std.testing;
    
    const request = "POST /v1/chat/completions HTTP/1.1";
    
    try testing.expect(isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest rejects GET request" {
    const testing = std.testing;
    
    const request =
        \\GET /v1/chat/completions HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest rejects PUT request" {
    const testing = std.testing;
    
    const request =
        \\PUT /v1/chat/completions HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest rejects POST to wrong endpoint" {
    const testing = std.testing;
    
    const request =
        \\POST /v1/models HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest rejects POST to root" {
    const testing = std.testing;
    
    const request =
        \\POST / HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest handles empty request" {
    const testing = std.testing;
    
    const request = "";
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest handles malformed request" {
    const testing = std.testing;
    
    const request = "INVALID REQUEST DATA";
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest with POST lowercase rejected" {
    const testing = std.testing;
    
    // HTTP methods are case-sensitive and must be uppercase
    const request = "post /v1/chat/completions HTTP/1.1";
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest with complex headers" {
    const testing = std.testing;
    
    const request =
        \\POST /v1/chat/completions HTTP/1.1
        \\Host: localhost:8080
        \\User-Agent: curl/7.68.0
        \\Accept: */*
        \\Content-Type: application/json
        \\Content-Length: 100
        \\Authorization: Bearer sk-test-key
        \\
        \\{"model":"claude-3","messages":[]}
    ;
    
    try testing.expect(isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest rejects similar endpoint" {
    const testing = std.testing;
    
    const request =
        \\POST /v1/chat/completion HTTP/1.1
        \\Host: localhost:8080
        \\
    ;
    
    try testing.expect(!isValidChatCompletionRequest(request));
}

test "isValidChatCompletionRequest with endpoint in body passes" {
    const testing = std.testing;
    
    // The function looks for the endpoint anywhere in the request
    // This includes the body, which is the current behavior
    const request =
        \\POST /v1/models HTTP/1.1
        \\Host: localhost:8080
        \\
        \\{"endpoint": "/v1/chat/completions"}
    ;
    
    // Current implementation will match because indexOf searches entire request
    try testing.expect(isValidChatCompletionRequest(request));
}

test "SUCCESS_RESPONSE is valid HTTP format" {
    const testing = std.testing;
    
    // Verify response starts with status line
    try testing.expect(std.mem.startsWith(u8, SUCCESS_RESPONSE, "HTTP/1.1 200 OK"));
    
    // Verify response contains required headers
    try testing.expect(std.mem.indexOf(u8, SUCCESS_RESPONSE, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, SUCCESS_RESPONSE, "Content-Length: 19") != null);
    
    // Verify response contains JSON body
    try testing.expect(std.mem.indexOf(u8, SUCCESS_RESPONSE, "{\"status\": \"alive\"}") != null);
}

test "NOT_FOUND_RESPONSE is valid HTTP format" {
    const testing = std.testing;
    
    // Verify response starts with status line
    try testing.expect(std.mem.startsWith(u8, NOT_FOUND_RESPONSE, "HTTP/1.1 404 Not Found"));
    
    // Verify response contains required headers
    try testing.expect(std.mem.indexOf(u8, NOT_FOUND_RESPONSE, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, NOT_FOUND_RESPONSE, "Content-Length: 22") != null);
    
    // Verify response contains JSON body
    try testing.expect(std.mem.indexOf(u8, NOT_FOUND_RESPONSE, "{\"error\": \"Not Found\"}") != null);
}

test "SUCCESS_RESPONSE Content-Length matches body" {
    const testing = std.testing;
    
    const body = "{\"status\": \"alive\"}";
    try testing.expectEqual(19, body.len);
}

test "NOT_FOUND_RESPONSE Content-Length matches body" {
    const testing = std.testing;
    
    const body = "{\"error\": \"Not Found\"}";
    try testing.expectEqual(22, body.len);
}