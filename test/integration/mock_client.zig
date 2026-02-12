const std = @import("std");
const recorder = @import("recorder.zig");

/// Mock client that simulates an agent/tool sending OpenAI format requests to the proxy
pub const MockClient = struct {
    allocator: std.mem.Allocator,
    proxy_url: []const u8,
    recorder: *recorder.Recorder,
    http_client: std.http.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        proxy_url: []const u8,
        rec: *recorder.Recorder,
    ) MockClient {
        return MockClient{
            .allocator = allocator,
            .proxy_url = proxy_url,
            .recorder = rec,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *MockClient) void {
        self.http_client.deinit();
    }

    /// Send a chat completion request to the proxy
    pub fn sendChatCompletion(
        self: *MockClient,
        model: []const u8,
        messages: []const u8, // JSON string of messages array
    ) ![]u8 {
        // Build request body
        var body_buffer = std.ArrayList(u8){};
        defer body_buffer.deinit(self.allocator);

        const writer = body_buffer.writer(self.allocator);
        try writer.writeAll("{\"model\":\"");
        try writer.writeAll(model);
        try writer.writeAll("\",\"messages\":");
        try writer.writeAll(messages);
        try writer.writeAll("}");

        const request_body = try body_buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(request_body);

        // Construct full URL
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buffer,
            "{s}/v1/chat/completions",
            .{self.proxy_url},
        );

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request
        var req = try self.http_client.request(.POST, uri, .{
            .headers = headers,
        });
        defer req.deinit();

        // Set content length and send
        req.transfer_encoding = .{ .content_length = request_body.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(request_body);
        try body_writer.end();
        try req.connection.?.flush();

        // Record the request
        try self.recorder.recordRequest(
            "client",
            "POST",
            "/v1/chat/completions",
            request_body,
        );

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(1024 * 1024));

        // Record the response
        try self.recorder.recordResponse(
            "client",
            @intFromEnum(response.head.status),
            response_body,
        );

        return response_body;
    }

    /// Send a case-based request using agent_req.json and write agent_res.json
    pub fn sendCaseRequest(
        self: *MockClient,
        cases_root: []const u8,
    ) ![]u8 {
        const request_body = try recorder.readCaseFile(
            self.allocator,
            cases_root,
            "agent_req.json",
            1024 * 1024,
        );
        defer self.allocator.free(request_body);

        const response_body = try self.sendRaw(.POST, "/v1/chat/completions", request_body);

        try recorder.writeCaseFile(
            self.allocator,
            cases_root,
            "agent_res.json",
            response_body,
        );

        return response_body;
    }

    /// Send a raw request with custom body
    pub fn sendRaw(
        self: *MockClient,
        method: std.http.Method,
        path: []const u8,
        body: []const u8,
    ) ![]u8 {
        // Construct full URL
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buffer,
            "{s}{s}",
            .{ self.proxy_url, path },
        );

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Standard headers
        var headers = std.http.Client.Request.Headers{};
        headers.content_type = .{ .override = "application/json" };

        // Make request
        var req = try self.http_client.request(method, uri, .{
            .headers = headers,
        });
        defer req.deinit();

        // Set content length and send
        req.transfer_encoding = .{ .content_length = body.len };
        var buf: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&buf);
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        // Record the request
        try self.recorder.recordRequest(
            "client",
            @tagName(method),
            path,
            body,
        );

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(1024 * 1024));

        // Record the response
        try self.recorder.recordResponse(
            "client",
            @intFromEnum(response.head.status),
            response_body,
        );

        return response_body;
    }
};

test "MockClient initialization" {
    const allocator = std.testing.allocator;
    const case_dir = try recorder.resolveCaseDir(allocator, "test/cases");
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var client = MockClient.init(allocator, "http://localhost:8080", &rec);
    defer client.deinit();
}

test "MockClient loads case request" {
    const allocator = std.testing.allocator;

    const req_body = try recorder.readCaseFile(
        allocator,
        "test/cases",
        "agent_req.json",
        1024 * 1024,
    );
    defer allocator.free(req_body);

    try std.testing.expect(std.mem.indexOf(u8, req_body, "\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_body, "\"messages\"") != null);
}