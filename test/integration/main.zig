const std = @import("std");
const recorder = @import("recorder.zig");
const MockClient = @import("mock_client.zig").MockClient;
const MockUpstream = @import("mock_upstream.zig").MockUpstream;

/// Integration test configuration
const TestConfig = struct {
    proxy_host: []const u8 = "127.0.0.1",
    proxy_port: u16 = 8080,
    anthropic_port: u16 = 8001,
    openai_port: u16 = 8002,
    groq_port: u16 = 8003,
    recorded_dir: []const u8 = "test/fixtures/recorded",
};

/// Test context holding all test infrastructure
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    config: TestConfig,
    recorder: recorder.Recorder,
    client: MockClient,
    anthropic_upstream: MockUpstream,
    openai_upstream: MockUpstream,
    groq_upstream: MockUpstream,
    proxy_process: ?std.process.Child,

    pub fn init(allocator: std.mem.Allocator) !TestContext {
        const config = TestConfig{};
        
        var rec = try recorder.Recorder.init(allocator, config.recorded_dir);
        
        var proxy_url_buffer: [64]u8 = undefined;
        const proxy_url = try std.fmt.bufPrint(
            &proxy_url_buffer,
            "http://{s}:{d}",
            .{ config.proxy_host, config.proxy_port },
        );
        const proxy_url_owned = try allocator.dupe(u8, proxy_url);
        
        const client = MockClient.init(allocator, proxy_url_owned, &rec);
        
        const anthropic_upstream = try MockUpstream.init(
            allocator,
            config.anthropic_port,
            "anthropic",
            &rec,
        );
        
        const openai_upstream = try MockUpstream.init(
            allocator,
            config.openai_port,
            "openai",
            &rec,
        );
        
        const groq_upstream = try MockUpstream.init(
            allocator,
            config.groq_port,
            "groq",
            &rec,
        );

        return TestContext{
            .allocator = allocator,
            .config = config,
            .recorder = rec,
            .client = client,
            .anthropic_upstream = anthropic_upstream,
            .openai_upstream = openai_upstream,
            .groq_upstream = groq_upstream,
            .proxy_process = null,
        };
    }

    pub fn deinit(self: *TestContext) void {
        if (self.proxy_process) |*proc| {
            _ = proc.kill() catch {};
        }
        self.groq_upstream.deinit();
        self.openai_upstream.deinit();
        self.anthropic_upstream.deinit();
        self.client.deinit();
        self.allocator.free(self.client.proxy_url);
    }

    /// Start all mock upstream servers
    pub fn startUpstreams(self: *TestContext) !void {
        try self.anthropic_upstream.start();
        try self.openai_upstream.start();
        try self.groq_upstream.start();
        
        // Give servers time to start
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    /// Stop all mock upstream servers
    pub fn stopUpstreams(self: *TestContext) void {
        self.anthropic_upstream.stop();
        self.openai_upstream.stop();
        self.groq_upstream.stop();
    }

    /// Start the proxy server with test configuration
    pub fn startProxy(self: *TestContext) !void {
        // Copy test config to default location
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        var config_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(
            &config_dir_buf,
            "{s}/.config/zig-zag",
            .{home},
        );
        
        // Create config directory
        std.fs.cwd().makePath(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_path = try std.fmt.bufPrint(
            &config_path_buf,
            "{s}/config.json",
            .{config_dir},
        );
        
        // Read test config
        const test_config = try std.fs.cwd().readFileAlloc(
            self.allocator,
            "test/fixtures/test_config.json",
            1024 * 1024,
        );
        defer self.allocator.free(test_config);
        
        // Write to default location with explicit sync
        const config_file = try std.fs.cwd().createFile(config_path, .{});
        defer config_file.close();
        _ = try config_file.write(test_config);
        try config_file.sync();
        
        // Give filesystem time to flush
        std.Thread.sleep(100 * std.time.ns_per_ms);
        
        var child = std.process.Child.init(
            &[_][]const u8{
                "zig-out/bin/zig-zag",
            },
            self.allocator,
        );
        
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

test "OpenAI to Anthropic transformation" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams();
    
    // Note: In real tests, proxy should be started here
    // For now, we test individual components
    
    // Test will send OpenAI format request with anthropic model
    const messages =
        \\[
        \\  {"role": "user", "content": "Hello, world!"}
        \\]
    ;
    
    // This would be the actual test once proxy is integrated:
    // const response = try ctx.client.sendChatCompletion(
    //     "anthropic/claude-3-opus-20240229",
    //     messages,
    // );
    // defer allocator.free(response);
    
    _ = messages;
}

test "OpenAI passthrough" {
    const allocator = std.testing.allocator;
    
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams();
    
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
    
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    try ctx.startUpstreams();
    defer ctx.stopUpstreams();
    
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
    
    var ctx = try TestContext.init(allocator);
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
    
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.cleanRecordings();
    
    std.debug.print("Starting mock upstream servers...\n", .{});
    try ctx.startUpstreams();
    defer ctx.stopUpstreams();
    
    std.debug.print("Starting proxy server...\n", .{});
    try ctx.startProxy();
    defer ctx.stopProxy() catch {};
    
    std.debug.print("Running tests...\n", .{});
    
    // Test 1: OpenAI to Anthropic
    std.debug.print("\n[Test 1] OpenAI to Anthropic transformation\n", .{});
    {
        const messages =
            \\[
            \\  {"role": "user", "content": "Hello, Claude!"}
            \\]
        ;
        
        const response = try ctx.client.sendChatCompletion(
            "anthropic/claude-3-opus-20240229",
            messages,
        );
        defer allocator.free(response);
        
        std.debug.print("Response received: {s}\n", .{response});
    }
    
    // Test 2: OpenAI passthrough
    std.debug.print("\n[Test 2] OpenAI passthrough\n", .{});
    {
        const messages =
            \\[
            \\  {"role": "user", "content": "Hello, GPT!"}
            \\]
        ;
        
        const response = try ctx.client.sendChatCompletion(
            "openai/gpt-4",
            messages,
        );
        defer allocator.free(response);
        
        std.debug.print("Response received: {s}\n", .{response});
    }
    
    // Test 3: Groq (OpenAI-compatible)
    std.debug.print("\n[Test 3] Compatible provider - Groq\n", .{});
    {
        const messages =
            \\[
            \\  {"role": "user", "content": "Hello, Llama!"}
            \\]
        ;
        
        const response = try ctx.client.sendChatCompletion(
            "groq/llama-3-70b-8192",
            messages,
        );
        defer allocator.free(response);
        
        std.debug.print("Response received: {s}\n", .{response});
    }
    
    std.debug.print("\nAll tests completed!\n", .{});
    std.debug.print("Check test/fixtures/recorded/ for request/response recordings\n", .{});
}