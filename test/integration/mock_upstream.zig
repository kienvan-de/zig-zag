const std = @import("std");
const recorder = @import("recorder.zig");

/// Mock upstream server that mimics provider APIs (Anthropic, OpenAI, etc.)
pub const MockUpstream = struct {
    allocator: std.mem.Allocator,
    port: u16,
    provider_name: []const u8,
    case_name: []const u8,
    recorder: *recorder.Recorder,
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        provider_name: []const u8,
        case_name: []const u8,
        rec: *recorder.Recorder,
    ) !MockUpstream {
        return MockUpstream{
            .allocator = allocator,
            .port = port,
            .provider_name = provider_name,
            .case_name = case_name,
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
            self.case_name,
            "upstream_req.json",
            parsed.body,
        );

        // Check if this is a streaming request by looking for upstream_res.txt
        const is_streaming = self.isStreamingCase();

        if (is_streaming) {
            try self.sendStreamingResponse(connection);
        } else {
            try self.sendJsonResponse(connection, request_allocator);
        }
    }

    fn isStreamingCase(self: *MockUpstream) bool {
        // Check if upstream_res.txt exists for this case
        const txt_path = std.fmt.allocPrint(self.allocator, "test/cases/{s}/upstream_res.txt", .{self.case_name}) catch return false;
        defer self.allocator.free(txt_path);

        const file = std.fs.cwd().openFile(txt_path, .{}) catch return false;
        file.close();
        return true;
    }

    fn sendJsonResponse(self: *MockUpstream, connection: std.net.Server.Connection, request_allocator: std.mem.Allocator) !void {
        // Generate mock response based on provider
        const response_body = try self.generateMockResponse();
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

    fn sendStreamingResponse(self: *MockUpstream, connection: std.net.Server.Connection) !void {
        // Read SSE data from upstream_res.txt
        const sse_data = try recorder.readCaseFile(
            self.allocator,
            "test/cases",
            self.case_name,
            "upstream_res.txt",
            1024 * 1024,
        );
        defer self.allocator.free(sse_data);

        // Send SSE headers
        const headers =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";
        _ = try connection.stream.writeAll(headers);

        // Stream each line with a small delay to simulate real streaming
        var lines = std.mem.splitScalar(u8, sse_data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;

            _ = try connection.stream.writeAll(trimmed);
            _ = try connection.stream.writeAll("\n\n");

            // Small delay between chunks to simulate streaming
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn generateMockResponse(self: *MockUpstream) ![]u8 {
        return try recorder.readCaseFile(
            self.allocator,
            "test/cases",
            self.case_name,
            "upstream_res.json",
            1024 * 1024,
        );
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
    const case_dir = try recorder.resolveCaseDirFor(allocator, "test/cases", "case-1");
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var upstream = try MockUpstream.init(allocator, 9001, "test", "case-1", &rec);
    defer upstream.deinit();
}

test "MockUpstream loads case response" {
    const allocator = std.testing.allocator;

    const res_body = try recorder.readCaseFile(
        allocator,
        "test/cases",
        "case-1",
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

    if (args.len < 4) {
        std.debug.print("Usage: mock-upstream <port> <provider_name> <case_name>\n", .{});
        std.debug.print("  port: Port number to listen on\n", .{});
        std.debug.print("  provider_name: anthropic, openai, or groq\n", .{});
        std.debug.print("  case_name: test case folder name (e.g., case-1)\n", .{});
        return error.InvalidArguments;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const provider_name = args[2];
    const case_name = args[3];

    const case_dir = try recorder.resolveCaseDirFor(allocator, "test/cases", case_name);
    defer allocator.free(case_dir);
    var rec = try recorder.Recorder.init(allocator, case_dir);
    defer rec.deinit();

    var upstream = try MockUpstream.init(allocator, port, provider_name, case_name, &rec);
    defer upstream.deinit();

    // Run server directly (not in a thread)
    try upstream.runServer();
}