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
const recorder = @import("recorder.zig");

/// Mock client that simulates an agent/tool sending OpenAI format requests to the proxy
pub const MockClient = struct {
    allocator: std.mem.Allocator,
    proxy_url: []const u8,
    recorder: *recorder.Recorder,
    http_client: std.http.Client,
    case_name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        proxy_url: []const u8,
        rec: *recorder.Recorder,
        case_name: []const u8,
    ) MockClient {
        return MockClient{
            .allocator = allocator,
            .proxy_url = proxy_url,
            .recorder = rec,
            .http_client = std.http.Client{ .allocator = allocator },
            .case_name = case_name,
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

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(1024 * 1024));

        return response_body;
    }

    /// Send a case-based request using agent_req.json and write agent_res.json or agent_res.txt
    pub fn sendCaseRequest(
        self: *MockClient,
        cases_root: []const u8,
    ) ![]u8 {
        const request_body = try recorder.readCaseFile(
            self.allocator,
            cases_root,
            self.case_name,
            "agent_req.json",
            1024 * 1024,
        );
        defer self.allocator.free(request_body);

        // Check if this is a streaming request by parsing the JSON
        const is_streaming = self.isStreamingRequest(request_body);

        // Detect custom endpoint path from _path field in request JSON
        const endpoint_path = self.detectEndpointPath(request_body);

        const response_body = try self.sendRaw(.POST, endpoint_path, request_body);

        // Write to .txt for streaming, .json for non-streaming
        const res_filename = if (is_streaming) "agent_res.txt" else "agent_res.json";
        try recorder.writeCaseFile(
            self.allocator,
            cases_root,
            self.case_name,
            res_filename,
            response_body,
        );

        return response_body;
    }

    /// Detect custom endpoint path from x_path field, defaulting to /v1/chat/completions.
    /// Uses simple string search to avoid JSON parser lifetime issues.
    fn detectEndpointPath(self: *MockClient, request_body: []const u8) []const u8 {
        _ = self;
        // Look for "x_path":"/v1/messages" in the raw JSON text
        if (std.mem.indexOf(u8, request_body, "\"x_path\":\"/v1/messages\"") != null or
            std.mem.indexOf(u8, request_body, "\"x_path\": \"/v1/messages\"") != null)
        {
            return "/v1/messages";
        }
        return "/v1/chat/completions";
    }

    /// Check if request has stream: true
    fn isStreamingRequest(self: *MockClient, request_body: []const u8) bool {
        _ = self;
        // Simple check for "stream":true or "stream": true in JSON
        return std.mem.indexOf(u8, request_body, "\"stream\":true") != null or
            std.mem.indexOf(u8, request_body, "\"stream\": true") != null;
    }

    /// Send a GET request to /v1/models and return the response
    pub fn sendModelsRequest(self: *MockClient) ![]u8 {
        // Construct full URL
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buffer,
            "{s}/v1/models",
            .{self.proxy_url},
        );

        // Parse URI
        const uri = try std.Uri.parse(url);

        // Make GET request
        var req = try self.http_client.request(.GET, uri, .{});
        defer req.deinit();

        // Send request without body
        try req.sendBodiless();

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(1024 * 1024));

        return response_body;
    }

    /// Send a raw GET request to any path, returning the response body
    pub fn sendGetRequest(self: *MockClient, path: []const u8) ![]u8 {
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.proxy_url, path });
        const uri = try std.Uri.parse(url);

        var req = try self.http_client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();

        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        return reader.allocRemaining(self.allocator, std.io.Limit.limited(10 * 1024 * 1024));
    }

    /// Send an HTTP endpoint test case:
    /// Reads agent_req.json as {"method":"GET"|"POST","path":"...","body":"..."(opt)}
    /// Returns the raw response body (may be JSON or HTML).
    pub fn sendEndpointRequest(self: *MockClient, cases_root: []const u8) ![]u8 {
        const req_data = try recorder.readCaseFile(
            self.allocator,
            cases_root,
            self.case_name,
            "agent_req.json",
            1024 * 1024,
        );
        defer self.allocator.free(req_data);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, req_data, .{});
        defer parsed.deinit();

        const method_str = if (parsed.value.object.get("method")) |m|
            if (m == .string) m.string else "GET"
        else
            "GET";

        const path_str = if (parsed.value.object.get("path")) |p|
            if (p == .string) p.string else "/v1/config/data"
        else
            "/v1/config/data";

        const body_str: []const u8 = if (parsed.value.object.get("body")) |b|
            if (b == .string) b.string else ""
        else
            "";

        const method: std.http.Method = if (std.mem.eql(u8, method_str, "POST")) .POST
        else if (std.mem.eql(u8, method_str, "DELETE")) .DELETE
        else .GET;

        if (method == .GET) {
            return self.sendGetRequest(path_str);
        } else {
            return self.sendRaw(method, path_str, body_str);
        }
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

        // Wait for response
        const redirect_buffer: [0]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(1024 * 1024));

        return response_body;
    }
};

test "MockClient initialization" {
    const allocator = std.testing.allocator;
    const case_dir = try recorder.resolveCaseDirFor(allocator, "test/cases", "case-1");
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var client = MockClient.init(allocator, "http://localhost:8080", &rec, "case-1");
    defer client.deinit();
}

test "MockClient loads case request" {
    const allocator = std.testing.allocator;

    const req_body = try recorder.readCaseFile(
        allocator,
        "test/cases",
        "case-1",
        "agent_req.json",
        1024 * 1024,
    );
    defer allocator.free(req_body);

    try std.testing.expect(std.mem.indexOf(u8, req_body, "\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_body, "\"messages\"") != null);
}
