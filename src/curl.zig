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

//! Curl-based HTTP Client
//!
//! Uses system curl binary for HTTPS requests to servers that require
//! TLS features not supported by Zig's stdlib (e.g., client certificate requests).
//!
//! This is used specifically for HAI provider authentication which connects to
//! SAP IAS servers that send CertificateRequest during TLS handshake.
//!
//! The interface mirrors HttpClient for comptime switching between clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("log.zig");

pub const CurlError = error{
    CurlNotFound,
    CurlFailed,
    OutOfMemory,
};

/// Response from curl requests - mirrors HttpResponse interface
pub const CurlResponse = struct {
    status: std.http.Status,
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *CurlResponse) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

/// HTTP client that shells out to curl
/// Used for servers with TLS configurations not supported by Zig's stdlib
/// Interface mirrors HttpClient for comptime switching
pub const CurlClient = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) CurlClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *CurlClient) void {
        // No resources to free
    }

    /// Perform a GET request using curl
    /// Interface mirrors HttpClient.get()
    pub fn get(
        self: *CurlClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) CurlError!CurlResponse {
        return self.request("GET", url, null, extra_headers);
    }

    /// Perform a POST request using curl with raw body
    /// Interface mirrors HttpClient.post()
    pub fn post(
        self: *CurlClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
        request_body: []const u8,
    ) CurlError!CurlResponse {
        return self.request("POST", url, request_body, extra_headers);
    }

    /// Generic request method
    fn request(
        self: *CurlClient,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) CurlError!CurlResponse {
        // Build curl command
        // -s: silent (no progress)
        // -S: show errors
        // -w '\n%{http_code}': append status code after body
        // -X: method
        var args = std.ArrayList([]const u8){};
        defer args.deinit(self.allocator);

        // Base arguments
        args.appendSlice(self.allocator, &[_][]const u8{
            "curl",
            "-s",
            "-S",
            "-w",
            "\n%{http_code}",
            "-X",
            method,
        }) catch return error.OutOfMemory;

        // Add headers from extra_headers
        var header_strings = std.ArrayList([]const u8){};
        defer {
            for (header_strings.items) |s| self.allocator.free(s);
            header_strings.deinit(self.allocator);
        }

        for (extra_headers) |header| {
            const header_str = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ header.name, header.value }) catch return error.OutOfMemory;
            header_strings.append(self.allocator, header_str) catch {
                self.allocator.free(header_str);
                return error.OutOfMemory;
            };
            args.appendSlice(self.allocator, &[_][]const u8{ "-H", header_str }) catch return error.OutOfMemory;
        }

        // Add body if present
        if (body) |b| {
            args.appendSlice(self.allocator, &[_][]const u8{ "-d", b }) catch return error.OutOfMemory;
        }

        // Add URL last
        args.append(self.allocator, url) catch return error.OutOfMemory;

        log.debug("curl: {s} {s}", .{ method, url });

        // Execute curl
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            log.err("Failed to spawn curl: {}", .{err});
            return error.CurlNotFound;
        };

        // Read output
        const output = child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            log.err("Failed to read curl output: {}", .{err});
            _ = child.wait() catch {};
            return error.CurlFailed;
        };
        errdefer self.allocator.free(output);

        const stderr_output = child.stderr.?.readToEndAlloc(self.allocator, 64 * 1024) catch null;
        defer if (stderr_output) |s| self.allocator.free(s);

        const result = child.wait() catch |err| {
            log.err("Failed to wait for curl: {}", .{err});
            return error.CurlFailed;
        };

        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("curl failed with exit code {}: {s}", .{ code, stderr_output orelse "(no stderr)" });
                    return error.CurlFailed;
                }
            },
            else => {
                log.err("curl terminated abnormally: {s}", .{stderr_output orelse "(no stderr)"});
                return error.CurlFailed;
            },
        }

        // Parse output: body + newline + status_code
        // Find last newline which separates body from status code
        const last_newline = std.mem.lastIndexOf(u8, output, "\n") orelse {
            log.err("Invalid curl output format (no newline)", .{});
            return error.CurlFailed;
        };

        const body_part = output[0..last_newline];
        const status_str = output[last_newline + 1 ..];

        const status_code = std.fmt.parseInt(u10, status_str, 10) catch {
            log.err("Invalid curl status code: {s}", .{status_str});
            return error.CurlFailed;
        };

        // Duplicate body since we need to free the full output
        const body_copy = self.allocator.dupe(u8, body_part) catch return error.OutOfMemory;
        self.allocator.free(output);

        return CurlResponse{
            .allocator = self.allocator,
            .status = @enumFromInt(status_code),
            .body = body_copy,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CurlClient GET request" {
    const allocator = std.testing.allocator;

    var client = CurlClient.init(allocator);
    defer client.deinit();

    var response = try client.get("https://httpbin.org/get", &[_]std.http.Header{});
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(response.body.len > 0);
}

test "CurlClient POST request" {
    const allocator = std.testing.allocator;

    var client = CurlClient.init(allocator);
    defer client.deinit();

    var response = try client.post(
        "https://httpbin.org/post",
        &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        },
        "key=value",
    );
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(response.body.len > 0);
}
