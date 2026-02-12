const std = @import("std");
const recorder = @import("recorder.zig");
const MockClient = @import("mock_client.zig").MockClient;

/// Integration test configuration
const TestConfig = struct {
    proxy_host: []const u8 = "127.0.0.1",
    proxy_port: u16 = 8080,
    anthropic_port: u16 = 8001,
    openai_port: u16 = 8002,
    groq_port: u16 = 8003,
    recorded_dir: []const u8 = "test/cases",
    cases_dir: []const u8 = "test/cases",
};

/// Case file paths for a single test case folder
const CaseFiles = struct {
    allocator: std.mem.Allocator,
    case_dir: []const u8,
    agent_req_path: []const u8,
    upstream_req_path: []const u8,
    upstream_res_path: []const u8,
    agent_res_path: []const u8,
    expected_agent_res_path: []const u8,
    expected_upstream_req_path: []const u8,

    pub fn deinit(self: *CaseFiles) void {
        const allocator = self.allocator;
        allocator.free(self.case_dir);
        allocator.free(self.agent_req_path);
        allocator.free(self.upstream_req_path);
        allocator.free(self.upstream_res_path);
        allocator.free(self.agent_res_path);
        allocator.free(self.expected_agent_res_path);
        allocator.free(self.expected_upstream_req_path);
    }
};

fn buildCaseFiles(allocator: std.mem.Allocator, cases_dir: []const u8) !CaseFiles {
    const case_name = std.posix.getenv("CASE_FOLDER") orelse "case-1";
    const case_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cases_dir, case_name });
    const agent_req_path = try std.fmt.allocPrint(allocator, "{s}/agent_req.json", .{case_dir});
    const upstream_req_path = try std.fmt.allocPrint(allocator, "{s}/upstream_req.json", .{case_dir});
    const upstream_res_path = try std.fmt.allocPrint(allocator, "{s}/upstream_res.json", .{case_dir});
    const agent_res_path = try std.fmt.allocPrint(allocator, "{s}/agent_res.json", .{case_dir});
    const expected_agent_res_path = try std.fmt.allocPrint(allocator, "{s}/expected_agent_res.json", .{case_dir});
    const expected_upstream_req_path = try std.fmt.allocPrint(allocator, "{s}/expected_upstream_req.json", .{case_dir});

    return CaseFiles{
        .allocator = allocator,
        .case_dir = case_dir,
        .agent_req_path = agent_req_path,
        .upstream_req_path = upstream_req_path,
        .upstream_res_path = upstream_res_path,
        .agent_res_path = agent_res_path,
        .expected_agent_res_path = expected_agent_res_path,
        .expected_upstream_req_path = expected_upstream_req_path,
    };
}

fn valueEqual(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |av| return b == .bool and b.bool == av,
        .integer => |av| return b == .integer and b.integer == av,
        .float => |av| return b == .float and b.float == av,
        .number_string => |av| return b == .number_string and std.mem.eql(u8, b.number_string, av),
        .string => |av| return b == .string and std.mem.eql(u8, b.string, av),
        .array => |av| {
            if (b != .array) return false;
            if (av.items.len != b.array.items.len) return false;
            var i: usize = 0;
            while (i < av.items.len) : (i += 1) {
                if (!valueEqual(av.items[i], b.array.items[i])) return false;
            }
            return true;
        },
        .object => |av| {
            if (b != .object) return false;
            if (av.count() != b.object.count()) return false;
            var it = av.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const other = b.object.get(key) orelse return false;
                if (!valueEqual(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

fn jsonEqual(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    var left_parsed = try std.json.parseFromSlice(std.json.Value, allocator, left, .{});
    defer left_parsed.deinit();
    var right_parsed = try std.json.parseFromSlice(std.json.Value, allocator, right, .{});
    defer right_parsed.deinit();

    return valueEqual(left_parsed.value, right_parsed.value);
}

fn assertCaseFileEqual(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    actual_filename: []const u8,
    expected_filename: []const u8,
) !void {
    const actual = try recorder.readCaseFile(allocator, cases_root, actual_filename, 1024 * 1024);
    defer allocator.free(actual);
    const expected = try recorder.readCaseFile(allocator, cases_root, expected_filename, 1024 * 1024);
    defer allocator.free(expected);

    const equal = try jsonEqual(allocator, actual, expected);
    if (!equal) {
        return error.CaseAssertionFailed;
    }
}

/// Test context holding all test infrastructure
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    config: TestConfig,
    recorder: recorder.Recorder,
    client: MockClient,
    anthropic_upstream_process: ?std.process.Child,
    openai_upstream_process: ?std.process.Child,
    groq_upstream_process: ?std.process.Child,
    proxy_process: ?std.process.Child,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) !*TestContext {
        const config = TestConfig{};
        
        const case_dir = try recorder.resolveCaseDir(allocator, config.cases_dir);
        defer allocator.free(case_dir);
        var rec = try recorder.Recorder.init(allocator, case_dir);
        errdefer rec.deinit();
        
        var proxy_url_buffer: [64]u8 = undefined;
        const proxy_url = try std.fmt.bufPrint(
            &proxy_url_buffer,
            "http://{s}:{d}",
            .{ config.proxy_host, config.proxy_port },
        );
        const proxy_url_owned = try allocator.dupe(u8, proxy_url);
        
        // Allocate on heap to avoid dangling pointer when returned
        const ctx = try allocator.create(TestContext);
        ctx.* = TestContext{
            .allocator = allocator,
            .config = config,
            .recorder = rec,
            .client = undefined,
            .anthropic_upstream_process = null,
            .openai_upstream_process = null,
            .groq_upstream_process = null,
            .proxy_process = null,
            .env_map = null,
        };
        
        // Now set the client with stable recorder pointer
        ctx.client = MockClient.init(allocator, proxy_url_owned, &ctx.recorder);
        
        return ctx;
    }

    pub fn deinit(self: *TestContext) void {
        const allocator = self.allocator;
        if (self.proxy_process) |*proc| {
            _ = proc.kill() catch {};
        }
        if (self.groq_upstream_process) |*proc| {
            _ = proc.kill() catch {};
        }
        if (self.openai_upstream_process) |*proc| {
            _ = proc.kill() catch {};
        }
        if (self.anthropic_upstream_process) |*proc| {
            _ = proc.kill() catch {};
        }
        if (self.env_map) |*em| {
            em.deinit();
        }
        self.client.deinit();
        self.recorder.deinit();
        allocator.free(self.client.proxy_url);
        allocator.destroy(self);
    }

    /// Start all mock upstream servers as separate processes
    pub fn startUpstreams(self: *TestContext) !void {
        // Start Anthropic mock upstream
        var anthropic_port_buf: [8]u8 = undefined;
        const anthropic_port_str = try std.fmt.bufPrint(&anthropic_port_buf, "{d}", .{self.config.anthropic_port});
        var anthropic_child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/mock-upstream",
                anthropic_port_str,
                "anthropic",
            },
            self.allocator,
        );
        try anthropic_child.spawn();
        self.anthropic_upstream_process = anthropic_child;

        // Start OpenAI mock upstream
        var openai_port_buf: [8]u8 = undefined;
        const openai_port_str = try std.fmt.bufPrint(&openai_port_buf, "{d}", .{self.config.openai_port});
        var openai_child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/mock-upstream",
                openai_port_str,
                "openai",
            },
            self.allocator,
        );
        try openai_child.spawn();
        self.openai_upstream_process = openai_child;

        // Start Groq mock upstream
        var groq_port_buf: [8]u8 = undefined;
        const groq_port_str = try std.fmt.bufPrint(&groq_port_buf, "{d}", .{self.config.groq_port});
        var groq_child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/mock-upstream",
                groq_port_str,
                "groq",
            },
            self.allocator,
        );
        try groq_child.spawn();
        self.groq_upstream_process = groq_child;
        
        // Give servers time to start and bind to ports
        std.Thread.sleep(1000 * std.time.ns_per_ms);
    }

    /// Stop all mock upstream servers
    pub fn stopUpstreams(self: *TestContext) !void {
        if (self.anthropic_upstream_process) |*proc| {
            _ = try proc.kill();
            _ = try proc.wait();
            self.anthropic_upstream_process = null;
        }
        if (self.openai_upstream_process) |*proc| {
            _ = try proc.kill();
            _ = try proc.wait();
            self.openai_upstream_process = null;
        }
        if (self.groq_upstream_process) |*proc| {
            _ = try proc.kill();
            _ = try proc.wait();
            self.groq_upstream_process = null;
        }
    }

    /// Start the proxy server with test configuration
    pub fn startProxy(self: *TestContext) !void {
        // Build case-specific config path
        const case_dir = try recorder.resolveCaseDir(self.allocator, self.config.cases_dir);
        defer self.allocator.free(case_dir);
        
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config.json", .{case_dir});
        defer self.allocator.free(config_path);
        
        // Get absolute path for the config
        const cwd = try std.fs.cwd().realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd);
        
        const abs_config_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ cwd, config_path });
        defer self.allocator.free(abs_config_path);
        
        self.env_map = std.process.EnvMap.init(self.allocator);
        try self.env_map.?.put("ZIG_ZAG_CONFIG", abs_config_path);
        // Inherit PATH for finding zig-out/bin
        if (std.posix.getenv("PATH")) |path| {
            try self.env_map.?.put("PATH", path);
        }
        
        var child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/zig-zag",
            },
            self.allocator,
        );
        child.env_map = &self.env_map.?;
        
        try child.spawn();
        self.proxy_process = child;
        
        // Give proxy time to start and bind to port
        std.Thread.sleep(3000 * std.time.ns_per_ms);
    }

    /// Stop the proxy server
    pub fn stopProxy(self: *TestContext) !void {
        if (self.proxy_process) |*proc| {
            _ = try proc.kill();
            _ = try proc.wait();
            self.proxy_process = null;
        }
    }

    /// Clean recorded files before test
    pub fn cleanRecordings(self: *TestContext) !void {
        try self.recorder.clean();
    }
};

test "Case files - case-1 paths" {
    const allocator = std.testing.allocator;

    var files = try buildCaseFiles(allocator, "test/cases");
    defer files.deinit();

    try std.testing.expect(std.mem.endsWith(u8, files.agent_req_path, "/case-1/agent_req.json"));
    try std.testing.expect(std.mem.endsWith(u8, files.upstream_req_path, "/case-1/upstream_req.json"));
    try std.testing.expect(std.mem.endsWith(u8, files.upstream_res_path, "/case-1/upstream_res.json"));
    try std.testing.expect(std.mem.endsWith(u8, files.agent_res_path, "/case-1/agent_res.json"));
    try std.testing.expect(std.mem.endsWith(u8, files.expected_agent_res_path, "/case-1/expected_agent_res.json"));
    try std.testing.expect(std.mem.endsWith(u8, files.expected_upstream_req_path, "/case-1/expected_upstream_req.json"));
}

test "Normalize JSON comparison" {
    const allocator = std.testing.allocator;

    const left = "{ \"a\": 2, \"b\": 1 }";
    const right = "{\n  \"b\": 1,\n  \"a\": 2\n}\n";

    const equal = try jsonEqual(allocator, left, right);
    try std.testing.expect(equal);
}

test "OpenAI passthrough" {
    const allocator = std.testing.allocator;
    
    const ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams() catch {};
    
    const messages =
        \\[
        \\  {"role": "user", "content": "Hello, world!"}
        \\]
    ;
    
    // This would be the actual test once proxy is integrated:
    // const response = try ctx.client.sendChatCompletion(
    //     "openai/gpt-4",
    //     messages,
    // );
    // defer allocator.free(response);
    
    _ = messages;
}

test "Compatible provider - Groq" {
    const allocator = std.testing.allocator;
    
    const ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams() catch {};
    
    const messages =
        \\[
        \\  {"role": "user", "content": "Hello, world!"}
        \\]
    ;
    
    // This would be the actual test once proxy is integrated:
    // const response = try ctx.client.sendChatCompletion(
    //     "groq/llama-3-70b-8192",
    //     messages,
    // );
    // defer allocator.free(response);
    
    _ = messages;
}

test "Error handling - invalid model" {
    const allocator = std.testing.allocator;
    
    const ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    const messages =
        \\[
        \\  {"role": "user", "content": "Hello, world!"}
        \\]
    ;
    
    // This would test error response:
    // const response = try ctx.client.sendChatCompletion(
    //     "invalid/model-name",
    //     messages,
    // );
    // defer allocator.free(response);
    // // Expect error response
    
    _ = messages;
}

/// Main entry point for integration tests
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Starting integration tests...\n", .{});
    
    const ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    
    std.debug.print("Starting mock upstream servers...\n", .{});
    try ctx.startUpstreams();
    defer ctx.stopUpstreams() catch {};
    
    std.debug.print("Starting proxy server...\n", .{});
    try ctx.startProxy();
    defer ctx.stopProxy() catch {};
    
    std.debug.print("Running tests...\n", .{});
    
    // Test: Case-based request
    std.debug.print("\n[Test] Case-based request\n", .{});
    {
        const response = try ctx.client.sendCaseRequest("test/cases");
        defer allocator.free(response);

        try assertCaseFileEqual(allocator, "test/cases", "upstream_req.json", "expected_upstream_req.json");
        try assertCaseFileEqual(allocator, "test/cases", "agent_res.json", "expected_agent_res.json");
    }
    
    std.debug.print("\nAll tests completed!\n", .{});
    std.debug.print("Check test/cases/<case>/ for request/response recordings\n", .{});
}