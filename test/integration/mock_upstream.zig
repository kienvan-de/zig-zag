const std = @import("std");
const recorder = @import("recorder.zig");

/// Mock upstream server that mimics provider APIs (Anthropic, OpenAI, etc.)
pub const MockUpstream = struct {
    allocator: std.mem.Allocator,
    port: u16,
    provider_name: []const u8,
    recorder: *recorder.Recorder,
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        provider_name: []const u8,
        rec: *recorder.Recorder,
    ) !MockUpstream {
        return MockUpstream{
            .allocator = allocator,
            .port = port,
            .provider_name = provider_name,
            .recorder = rec,
            .should_stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    pub fn deinit(self: *MockUpstream) void {
        self.should_stop.store(true, .monotonic);
        if (self.thread) |thread| {
            thread.join();
        }
    }

    /// Start the mock server in a background thread
    pub fn start(self: *MockUpstream) !void {
        self.thread = try std.Thread.spawn(.{}, runServer, .{self});
        // Give server time to bind
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    /// Stop the mock server
    pub fn stop(self: *MockUpstream) void {
        self.should_stop.store(true, .monotonic);
    }

    fn runServer(self: *MockUpstream) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", self.port);
        var listener = addr.listen(.{
            .reuse_address = true,
        }) catch |err| {
            return err;
        };
        defer listener.deinit();

        while (!self.should_stop.load(.monotonic)) {
            // Accept with timeout to allow checking should_stop
            const connection = listener.accept() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            self.handleConnection(connection) catch |err| {
                std.debug.print("[MockUpstream] {s} error handling connection: {}\n", .{self.provider_name, err});
            };
        }
    }

    fn handleConnection(self: *MockUpstream, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Use arena for request handling
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const request_allocator = arena.allocator();

        var read_buffer: [16384]u8 = undefined;
        const bytes_read = try connection.stream.read(&read_buffer);
        if (bytes_read == 0) return;

        const request_data = read_buffer[0..bytes_read];

        // Parse HTTP request
        const parsed = try parseHttpRequest(request_allocator, request_data);

        try recorder.writeCaseFile(
            self.allocator,
            "test/cases",
            "upstream_req.json",
            parsed.body,
        );

        // Generate mock response based on provider
        const response_body = try self.generateMockResponse(parsed.body);
        defer self.allocator.free(response_body);

        // Send HTTP response
        var response_buf = std.ArrayList(u8){};
        defer response_buf.deinit(request_allocator);

        const writer = response_buf.writer(request_allocator);
        try writer.writeAll("HTTP/1.1 200 OK\r\n");
        try writer.writeAll("Content-Type: application/json\r\n");
        try writer.print("Content-Length: {d}\r\n", .{response_body.len});
        try writer.writeAll("Connection: close\r\n");
        try writer.writeAll("\r\n");
        try writer.writeAll(response_body);

        _ = try connection.stream.writeAll(response_buf.items);
    }

    fn generateMockResponse(self: *MockUpstream, request_body: []const u8) ![]u8 {
        _ = request_body;

        return try recorder.readCaseFile(
            self.allocator,
            "test/cases",
            "upstream_res.json",
            1024 * 1024,
        );
    }

    fn generateAnthropicResponse(self: *MockUpstream) ![]u8 {
        const response =
            \\{
            \\  "id": "msg_test123",
            \\  "type": "message",
            \\  "role": "assistant",
            \\  "content": [
            \\    {
            \\      "type": "text",
            \\      "text": "This is a mock response from Anthropic API"
            \\    }
            \\  ],
            \\  "model": "claude-3-opus-20240229",
            \\  "stop_reason": "end_turn",
            \\  "stop_sequence": null,
            \\  "usage": {
            \\    "input_tokens": 10,
            \\    "output_tokens": 20
            \\  }
            \\}
        ;
        return try self.allocator.dupe(u8, response);
    }

    fn generateOpenAIResponse(self: *MockUpstream) ![]u8 {
        const response =
            \\{
            \\  "id": "chatcmpl-test123",
            \\  "object": "chat.completion",
            \\  "created": 1234567890,
            \\  "model": "gpt-4",
            \\  "choices": [
            \\    {
            \\      "index": 0,
            \\      "message": {
            \\        "role": "assistant",
            \\        "content": "This is a mock response from OpenAI API"
            \\      },
            \\      "finish_reason": "stop"
            \\    }
            \\  ],
            \\  "usage": {
            \\    "prompt_tokens": 10,
            \\    "completion_tokens": 20,
            \\    "total_tokens": 30
            \\  }
            \\}
        ;
        return try self.allocator.dupe(u8, response);
    }
};

const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

fn parseHttpRequest(allocator: std.mem.Allocator, data: []const u8) !ParsedRequest {
    // Find end of headers
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
        std.mem.indexOf(u8, data, "\n\n") orelse data.len;

    const header_section = data[0..header_end];
    const body = if (header_end + 4 <= data.len) data[header_end + 4 ..] else if (header_end + 2 <= data.len) data[header_end + 2 ..] else "";

    // Parse request line
    const first_line_end = std.mem.indexOf(u8, header_section, "\r\n") orelse
        std.mem.indexOf(u8, header_section, "\n") orelse header_section.len;
    const request_line = header_section[0..first_line_end];

    // Split request line: METHOD PATH HTTP/VERSION
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse "GET";
    const path = parts.next() orelse "/";

    // Parse headers (simplified - just collect them)
    var headers = std.ArrayList(Header){};
    var lines = std.mem.splitSequence(u8, header_section, "\r\n");
    _ = lines.next(); // Skip request line

    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
            try headers.append(allocator, .{ .name = name, .value = value });
        }
    }

    return ParsedRequest{
        .method = method,
        .path = path,
        .headers = try headers.toOwnedSlice(allocator),
        .body = body,
    };
}

test "MockUpstream initialization" {
    const allocator = std.testing.allocator;
    const case_dir = try recorder.resolveCaseDir(allocator, "test/cases");
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var upstream = try MockUpstream.init(allocator, 9001, "test", &rec);
    defer upstream.deinit();
}

test "MockUpstream loads case response" {
    const allocator = std.testing.allocator;

    const res_body = try recorder.readCaseFile(
        allocator,
        "test/cases",
        "upstream_res.json",
        1024 * 1024,
    );
    defer allocator.free(res_body);

    try std.testing.expect(std.mem.indexOf(u8, res_body, "\"choices\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_body, "\"message\"") != null);
}

/// Main entry point for standalone mock upstream server
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: mock-upstream <port> <provider_name>\n", .{});
        std.debug.print("  port: Port number to listen on\n", .{});
        std.debug.print("  provider_name: anthropic, openai, or groq\n", .{});
        return error.InvalidArguments;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const provider_name = args[2];



    const case_dir = try recorder.resolveCaseDir(allocator, "test/cases");
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var upstream = try MockUpstream.init(allocator, port, provider_name, &rec);
    defer upstream.deinit();

    // Run server directly (not in a thread)
    try upstream.runServer();
}