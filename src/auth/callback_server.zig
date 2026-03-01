//! OAuth Callback Server
//!
//! A lightweight HTTP server that listens for OAuth authorization callbacks.
//! Used in browser-based OAuth flows to receive the authorization code.
//!
//! Features:
//! - Configurable port and path
//! - State validation (CSRF protection)
//! - Auto-timeout
//! - Success HTML response to browser
//! - Browser opener utility
//!
//! Usage:
//! ```zig
//! const callback_server = @import("auth/callback_server.zig");
//!
//! // Open browser for authorization
//! try callback_server.openBrowser(auth_url);
//!
//! // Wait for callback
//! var result = try callback_server.waitForCallback(allocator, .{
//!     .port = 8335,
//!     .path = "/auth-code",
//!     .expected_state = state,
//!     .timeout_ms = 120_000,
//! });
//! defer result.deinit(allocator);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("../log.zig");

// ============================================================================
// Types
// ============================================================================

/// Configuration for the callback server
pub const CallbackConfig = struct {
    port: u16,
    path: []const u8,
    expected_state: []const u8,
    timeout_ms: u64 = 120_000, // 2 minutes default
};

/// Result from OAuth callback
pub const CallbackResult = struct {
    code: []const u8,
    state: []const u8,

    pub fn deinit(self: *CallbackResult, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.state);
        self.* = undefined;
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const CallbackError = error{
    Timeout,
    StateMismatch,
    MissingCode,
    MissingState,
    ServerError,
    BrowserOpenFailed,
};

// ============================================================================
// Constants
// ============================================================================

const SUCCESS_HTML =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\  <title>Authentication Successful</title>
    \\  <style>
    \\    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
    \\    h1 { color: #4CAF50; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <h1>✓ Authentication Successful</h1>
    \\  <p>You can close this window and return to the application.</p>
    \\</body>
    \\</html>
;

const ERROR_HTML_TEMPLATE =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\  <title>Authentication Failed</title>
    \\  <style>
    \\    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
    \\    h1 { color: #f44336; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <h1>✗ Authentication Failed</h1>
    \\  <p>{s}</p>
    \\</body>
    \\</html>
;

// ============================================================================
// Public Functions
// ============================================================================

/// Wait for OAuth callback on the specified port/path
/// Blocks until callback received or timeout
pub fn waitForCallback(allocator: Allocator, config: CallbackConfig) !CallbackResult {
    log.info("Starting callback server on port {d}, path: {s}", .{ config.port, config.path });

    // Create server address
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, config.port);

    // Create and bind server
    var server = std.net.Server.init(address.stream, .{
        .reuse_address = true,
    });
    errdefer server.deinit();

    // Calculate timeout
    const timeout_ns: i128 = @as(i128, config.timeout_ms) * std.time.ns_per_ms;
    const deadline = std.time.nanoTimestamp() + timeout_ns;

    log.info("Waiting for OAuth callback (timeout: {d}ms)...", .{config.timeout_ms});

    // Accept loop with timeout
    while (true) {
        // Check timeout
        if (std.time.nanoTimestamp() > deadline) {
            log.err("Callback server timed out after {d}ms", .{config.timeout_ms});
            server.deinit();
            return error.Timeout;
        }

        // Try to accept connection (non-blocking would be better, but this works)
        const conn = server.accept() catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            log.err("Server accept error: {}", .{err});
            server.deinit();
            return error.ServerError;
        };

        // Handle the connection
        const result = handleConnection(allocator, conn.stream, config);
        conn.stream.close();

        if (result) |callback_result| {
            server.deinit();
            return callback_result;
        } else |err| {
            // If it's a path mismatch, continue waiting
            // Other errors should be returned
            if (err != error.MissingCode and err != error.MissingState) {
                continue; // Wrong path, keep waiting
            }
            server.deinit();
            return err;
        }
    }
}

/// Open URL in default browser
pub fn openBrowser(url: []const u8) !void {
    log.info("Opening browser: {s}", .{url});

    // Use platform-specific command
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "open", url },
    }) catch {
        log.err("Failed to open browser", .{});
        return error.BrowserOpenFailed;
    };

    if (result.term.Exited != 0) {
        log.err("Browser open command failed with code: {d}", .{result.term.Exited});
        return error.BrowserOpenFailed;
    }
}

// ============================================================================
// Private Helpers
// ============================================================================

/// Handle incoming HTTP connection
fn handleConnection(
    allocator: Allocator,
    stream: std.net.Stream,
    config: CallbackConfig,
) !CallbackResult {
    var buf: [4096]u8 = undefined;
    var server = std.http.Server.init(allocator, stream, &buf);

    var request = server.receiveHead() catch |err| {
        log.debug("Failed to receive HTTP head: {}", .{err});
        return error.ServerError;
    };

    // Check if this is the expected path
    const target = request.head.target;
    if (!std.mem.startsWith(u8, target, config.path)) {
        // Not our callback path, send 404
        try sendResponse(&request, .not_found, "Not Found");
        return error.ServerError; // Will continue waiting
    }

    // Parse query parameters
    const query_start = std.mem.indexOf(u8, target, "?") orelse {
        try sendErrorResponse(&request, "Missing query parameters");
        return error.MissingCode;
    };

    const query = target[query_start + 1 ..];
    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;

    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |param| {
        if (std.mem.startsWith(u8, param, "code=")) {
            code = param[5..];
        } else if (std.mem.startsWith(u8, param, "state=")) {
            state = param[6..];
        }
    }

    // Validate required parameters
    if (code == null) {
        try sendErrorResponse(&request, "Missing authorization code");
        return error.MissingCode;
    }

    if (state == null) {
        try sendErrorResponse(&request, "Missing state parameter");
        return error.MissingState;
    }

    // Validate state matches
    if (!std.mem.eql(u8, state.?, config.expected_state)) {
        log.err("State mismatch: expected {s}, got {s}", .{ config.expected_state, state.? });
        try sendErrorResponse(&request, "Invalid state parameter (possible CSRF attack)");
        return error.StateMismatch;
    }

    // Success! Send success page
    try sendResponse(&request, .ok, SUCCESS_HTML);

    log.info("OAuth callback received successfully", .{});

    // Return duplicated strings (caller owns them)
    return CallbackResult{
        .code = try allocator.dupe(u8, code.?),
        .state = try allocator.dupe(u8, state.?),
    };
}

/// Send HTTP response
fn sendResponse(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return error.ServerError;
    };
}

/// Send error response with HTML
fn sendErrorResponse(request: *std.http.Server.Request, message: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, ERROR_HTML_TEMPLATE, .{message}) catch {
        return sendResponse(request, .bad_request, "Error");
    };
    try sendResponse(request, .bad_request, html);
}

// ============================================================================
// Tests
// ============================================================================

test "CallbackResult deinit frees memory" {
    const allocator = std.testing.allocator;

    var result = CallbackResult{
        .code = try allocator.dupe(u8, "test-code"),
        .state = try allocator.dupe(u8, "test-state"),
    };

    result.deinit(allocator);
    // No memory leak = test passes
}
