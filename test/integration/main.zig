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
const MockClient = @import("mock_client.zig").MockClient;

/// Integration test configuration
const TestConfig = struct {
    proxy_host: []const u8 = "127.0.0.1",
    proxy_port: u16 = 8080,
    upstream_port: u16 = 8001,
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

fn buildCaseFiles(allocator: std.mem.Allocator, cases_dir: []const u8, case_name: []const u8) !CaseFiles {
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
            // Count non-ignored fields
            var a_count: usize = 0;
            var b_count: usize = 0;
            var a_it = av.iterator();
            while (a_it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "created")) {
                    a_count += 1;
                }
            }
            var b_it = b.object.iterator();
            while (b_it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "created")) {
                    b_count += 1;
                }
            }
            if (a_count != b_count) return false;
            var it = av.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                // Skip dynamic fields
                if (std.mem.eql(u8, key, "created")) continue;
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

/// Compare SSE streaming responses line by line
/// Each "data: {...}" line is parsed as JSON and compared
fn sseEqual(allocator: std.mem.Allocator, left: []const u8, right: []const u8) !bool {
    var left_lines = std.mem.splitScalar(u8, left, '\n');
    var right_lines = std.mem.splitScalar(u8, right, '\n');

    while (true) {
        const left_line = nextDataLine(&left_lines);
        const right_line = nextDataLine(&right_lines);

        // Both exhausted - equal
        if (left_line == null and right_line == null) return true;
        // One exhausted but not the other - not equal
        if (left_line == null or right_line == null) return false;

        const left_data = left_line.?;
        const right_data = right_line.?;

        // Handle [DONE] marker
        if (std.mem.eql(u8, left_data, "[DONE]") and std.mem.eql(u8, right_data, "[DONE]")) {
            continue;
        }
        if (std.mem.eql(u8, left_data, "[DONE]") or std.mem.eql(u8, right_data, "[DONE]")) {
            return false;
        }

        // Compare JSON content
        const equal = jsonEqual(allocator, left_data, right_data) catch return false;
        if (!equal) return false;
    }
}

fn nextDataLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "data: ")) {
            return trimmed["data: ".len..];
        }
    }
    return null;
}

fn assertCaseFileEqual(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    case_name: []const u8,
    actual_filename: []const u8,
    expected_filename: []const u8,
) !void {
    const actual = try recorder.readCaseFile(allocator, cases_root, case_name, actual_filename, 1024 * 1024);
    defer allocator.free(actual);
    const expected = try recorder.readCaseFile(allocator, cases_root, case_name, expected_filename, 1024 * 1024);
    defer allocator.free(expected);

    // Determine if this is SSE streaming content (check for "data: " prefix)
    const is_sse = std.mem.indexOf(u8, expected, "data: ") != null;

    const equal = if (is_sse)
        try sseEqual(allocator, actual, expected)
    else
        try jsonEqual(allocator, actual, expected);

    if (!equal) {
        return error.CaseAssertionFailed;
    }
}

/// Check if a case file exists
fn caseFileExists(allocator: std.mem.Allocator, cases_root: []const u8, case_name: []const u8, filename: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ cases_root, case_name, filename }) catch return false;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Test context holding all test infrastructure
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    config: TestConfig,
    recorder: recorder.Recorder,
    client: MockClient,
    upstream_process: ?std.process.Child,
    proxy_process: ?std.process.Child,
    env_map: ?std.process.EnvMap,
    case_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, case_name: []const u8) !*TestContext {
        const config = TestConfig{};
        
        const case_dir = try recorder.resolveCaseDirFor(allocator, config.cases_dir, case_name);
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
            .upstream_process = null,
            .proxy_process = null,
            .env_map = null,
            .case_name = case_name,
        };
        
        // Now set the client with stable recorder pointer
        ctx.client = MockClient.init(allocator, proxy_url_owned, &ctx.recorder, case_name);
        
        return ctx;
    }

    pub fn deinit(self: *TestContext) void {
        const allocator = self.allocator;
        if (self.proxy_process) |*proc| {
            _ = proc.kill() catch {};
        }
        if (self.upstream_process) |*proc| {
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

    /// Start mock upstream server
    pub fn startUpstreams(self: *TestContext) !void {
        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{self.config.upstream_port});
        var child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/mock-upstream",
                port_str,
                "upstream",
                self.case_name,
            },
            self.allocator,
        );
        try child.spawn();
        self.upstream_process = child;
        
        // Give server time to start and bind to port
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    /// Stop mock upstream server
    pub fn stopUpstreams(self: *TestContext) !void {
        if (self.upstream_process) |*proc| {
            _ = try proc.kill();
            _ = try proc.wait();
        }
    }

    /// Start the proxy server with test configuration
    pub fn startProxy(self: *TestContext) !void {
        // Build case-specific config path
        const case_dir = try recorder.resolveCaseDirFor(self.allocator, self.config.cases_dir, self.case_name);
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

    var files = try buildCaseFiles(allocator, "test/cases", "case-1");
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
    
    const ctx = try TestContext.init(allocator, "case-1");
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
    
    const ctx = try TestContext.init(allocator, "case-1");
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
    
    const ctx = try TestContext.init(allocator, "case-1");
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

/// Run a single test case
fn runCase(allocator: std.mem.Allocator, cases_root: []const u8, case_name: []const u8) !void {
    std.log.info("[Test] {s}", .{case_name});

    // Initialize context for this case
    const ctx = try TestContext.init(allocator, case_name);
    defer ctx.deinit();

    try ctx.cleanRecordings();

    // Start servers
    try ctx.startUpstreams();
    defer ctx.stopUpstreams() catch {};

    try ctx.startProxy();
    defer ctx.stopProxy() catch {};

    // Detect test type: models test (no agent_req.json) vs chat completion test
    const is_models_test = !caseFileExists(allocator, cases_root, case_name, "agent_req.json") and
        caseFileExists(allocator, cases_root, case_name, "expected_agent_res.json");

    if (is_models_test) {
        // Models test - use sendModelsRequest
        const response = try ctx.client.sendModelsRequest();
        defer allocator.free(response);

        // Write response to agent_res.json for comparison
        try recorder.writeCaseFile(
            allocator,
            cases_root,
            case_name,
            "agent_res.json",
            response,
        );

        try assertCaseFileEqual(allocator, cases_root, case_name, "agent_res.json", "expected_agent_res.json");
    } else {
        // Chat completion test - use sendCaseRequest
        const response = try ctx.client.sendCaseRequest(cases_root);
        defer allocator.free(response);

        // Only assert upstream request if expected file exists
        // (proxy-rejected requests like budget exceeded never reach upstream)
        if (caseFileExists(allocator, cases_root, case_name, "expected_upstream_req.json")) {
            try assertCaseFileEqual(allocator, cases_root, case_name, "upstream_req.json", "expected_upstream_req.json");
        }

        // Check if this is a streaming case (expected_agent_res.txt vs .json)
        if (caseFileExists(allocator, cases_root, case_name, "expected_agent_res.txt")) {
            try assertCaseFileEqual(allocator, cases_root, case_name, "agent_res.txt", "expected_agent_res.txt");
        } else {
            try assertCaseFileEqual(allocator, cases_root, case_name, "agent_res.json", "expected_agent_res.json");
        }
    }

    std.log.info("  ✓ {s} passed", .{case_name});
}

/// Main entry point for integration tests
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting integration tests...", .{});

    const cases_root = "test/cases";

    // Check if specific case is requested via env var
    if (std.posix.getenv("CASE_FOLDER")) |case_name| {
        try runCase(allocator, cases_root, case_name);
        std.log.info("Test completed!", .{});
        return;
    }

    // Discover and run all cases
    const case_dirs = try recorder.listCaseDirs(allocator, cases_root);
    defer {
        for (case_dirs) |dir| {
            allocator.free(dir);
        }
        allocator.free(case_dirs);
    }

    if (case_dirs.len == 0) {
        std.log.warn("No test cases found in {s}", .{cases_root});
        return;
    }

    std.log.info("Found {d} test case(s)", .{case_dirs.len});

    var passed: usize = 0;
    var failed: usize = 0;

    for (case_dirs) |case_name| {
        runCase(allocator, cases_root, case_name) catch |err| {
            std.log.err("  ✗ {s} failed: {}", .{ case_name, err });
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.log.info("========================================", .{});
    std.log.info("Results: {d} passed, {d} failed", .{ passed, failed });
    std.log.info("========================================", .{});

    if (failed > 0) {
        return error.TestsFailed;
    }
}
