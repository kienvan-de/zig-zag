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
        std.debug.print("[MockUpstream] Starting {s} server on port {d}\n", .{self.provider_name, self.port});
        self.thread = try std.Thread.spawn(.{}, runServer, .{self});
        // Give server time to bind
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    /// Stop the mock server
    pub fn stop(self: *MockUpstream) void {
        self.should_stop.store(true, .monotonic);
    }

    fn runServer(self: *MockUpstream) !void {
        std.debug.print("[MockUpstream] {s} binding to 127.0.0.1:{d}\n", .{self.provider_name, self.port});
        const addr = try std.net.Address.parseIp("127.0.0.1", self.port);
        var listener = addr.listen(.{
            .reuse_address = true,
        }) catch |err| {
            std.debug.print("[MockUpstream] {s} failed to bind: {}\n", .{self.provider_name, err});
            return err;
        };
        defer listener.deinit();

        std.debug.print("[MockUpstream] {s} listening on port {d}\n", .{self.provider_name, self.port});

        while (!self.should_stop.load(.monotonic)) {
            // Accept with timeout to allow checking should_stop
            const connection = listener.accept() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                std.debug.print("[MockUpstream] {s} accept error: {}\n", .{self.provider_name, err});
                return err;
            };

            std.debug.print("[MockUpstream] {s} accepted connection\n", .{self.provider_name});

            self.handleConnection(connection) catch |err| {
                std.debug.print("[MockUpstream] {s} error handling connection: {}\n", .{self.provider_name, err});
            };
        }
    }

    fn handleConnection(self: *MockUpstream, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        std.debug.print("[MockUpstream] {s} handling connection\n", .{self.provider_name});

        // Use arena for request handling
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const request_allocator = arena.allocator();

        var read_buffer: [16384]u8 = undefined;
        std.debug.print("[MockUpstream] {s} reading request...\n", .{self.provider_name});
        const bytes_read = try connection.stream.read(&read_buffer);
        std.debug.print("[MockUpstream] {s} read {d} bytes\n", .{self.provider_name, bytes_read});
        if (bytes_read == 0) return;

        const request_data = read_buffer[0..bytes_read];

        std.debug.print("[MockUpstream] {s} parsing request\n", .{self.provider_name});
        // Parse HTTP request
        const parsed = try parseHttpRequest(request_allocator, request_data);
        std.debug.print("[MockUpstream] {s} parsed: {s} {s}\n", .{self.provider_name, parsed.method, parsed.path});

        // Record the incoming request
        std.debug.print("[MockUpstream] {s} recording request\n", .{self.provider_name});
        try self.recorder.recordRequest(
            self.provider_name,
            parsed.method,
            parsed.path,
            parsed.body,
        );

        // Generate mock response based on provider
        std.debug.print("[MockUpstream] {s} generating mock response\n", .{self.provider_name});
        const response_body = try self.generateMockResponse(parsed.body);
        defer self.allocator.free(response_body);
        std.debug.print("[MockUpstream] {s} response body: {d} bytes\n", .{self.provider_name, response_body.len});

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

        std.debug.print("[MockUpstream] {s} sending response: {d} bytes\n", .{self.provider_name, response_buf.items.len});
        _ = try connection.stream.writeAll(response_buf.items);
        std.debug.print("[MockUpstream] {s} response sent successfully\n", .{self.provider_name});

        // Record the response
        try self.recorder.recordResponse(
            self.provider_name,
            200,
            response_body,
        );
        std.debug.print("[MockUpstream] {s} connection handled successfully\n", .{self.provider_name});
    }

    fn generateMockResponse(self: *MockUpstream, request_body: []const u8) ![]u8 {
        // Parse request to extract model if needed
        _ = request_body;

        if (std.mem.eql(u8, self.provider_name, "anthropic")) {
            return try self.generateAnthropicResponse();
        } else if (std.mem.eql(u8, self.provider_name, "openai") or
            std.mem.eql(u8, self.provider_name, "groq"))
        {
            return try self.generateOpenAIResponse();
        }

        return try self.allocator.dupe(u8, "{}");
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
    var rec = try recorder.Recorder.init(allocator, "test/fixtures/recorded");

    var upstream = try MockUpstream.init(allocator, 9001, "test", &rec);
    defer upstream.deinit();
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

    std.debug.print("[MockUpstream] Starting {s} server on port {d}\n", .{ provider_name, port });

    var rec = try recorder.Recorder.init(allocator, "test/fixtures/recorded");

    var upstream = try MockUpstream.init(allocator, port, provider_name, &rec);
    defer upstream.deinit();

    // Run server directly (not in a thread)
    try upstream.runServer();
}