const std = @import("std");

pub const Config = struct {
    anthropic_api_key: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Config) void {
        self.allocator.free(self.anthropic_api_key);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    // Try to get ANTHROPIC_API_KEY from environment
    const api_key_opt = std.process.getEnvVarOwned(
        allocator,
        "ANTHROPIC_API_KEY",
    ) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            std.debug.print("ERROR: ANTHROPIC_API_KEY environment variable not set!\n", .{});
            std.debug.print("Please set it with: export ANTHROPIC_API_KEY=your_key_here\n", .{});
            return error.MissingApiKey;
        }
        return err;
    };

    // Validate the key is not empty
    if (api_key_opt.len == 0) {
        allocator.free(api_key_opt);
        std.debug.print("ERROR: ANTHROPIC_API_KEY is empty!\n", .{});
        return error.EmptyApiKey;
    }

    return Config{
        .anthropic_api_key = api_key_opt,
        .allocator = allocator,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Config.deinit frees allocated memory" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const api_key = try allocator.dupe(u8, "test-api-key-123");
    const config = Config{
        .anthropic_api_key = api_key,
        .allocator = allocator,
    };

    config.deinit();
    // If we reach here without crashes, deinit worked correctly
}

test "loadConfig succeeds with valid API key from environment" {
    const testing = std.testing;

    // This test requires ANTHROPIC_API_KEY to be set in the environment
    // Skip if not set, as we cannot set env vars in Zig tests
    const config = loadConfig(testing.allocator) catch |err| {
        if (err == error.MissingApiKey) {
            // Skip test if env var not set
            return error.SkipZigTest;
        }
        return err;
    };
    defer config.deinit();

    // If we got here, the key was loaded successfully
    try testing.expect(config.anthropic_api_key.len > 0);
}

test "Config struct stores correct allocator" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const api_key = try allocator.dupe(u8, "sk-test-allocator-check");
    const config = Config{
        .anthropic_api_key = api_key,
        .allocator = allocator,
    };
    defer config.deinit();

    // Verify the allocator is stored correctly
    try testing.expect(config.allocator.ptr == allocator.ptr);
    try testing.expect(config.allocator.vtable == allocator.vtable);
}

test "Config handles various API key formats" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with Anthropic-style key
    {
        const api_key = try allocator.dupe(u8, "sk-ant-api03-test123");
        const config = Config{
            .anthropic_api_key = api_key,
            .allocator = allocator,
        };
        defer config.deinit();
        try testing.expectEqualStrings("sk-ant-api03-test123", config.anthropic_api_key);
    }

    // Test with special characters
    {
        const api_key = try allocator.dupe(u8, "sk-ant-test_key-with-dashes_and_underscores.123");
        const config = Config{
            .anthropic_api_key = api_key,
            .allocator = allocator,
        };
        defer config.deinit();
        try testing.expectEqualStrings("sk-ant-test_key-with-dashes_and_underscores.123", config.anthropic_api_key);
    }
}

test "Config handles long API keys" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a long API key (256 characters)
    var long_key: [256]u8 = undefined;
    @memset(&long_key, 'a');
    @memcpy(long_key[0..7], "sk-ant-");

    const api_key = try allocator.dupe(u8, &long_key);
    const config = Config{
        .anthropic_api_key = api_key,
        .allocator = allocator,
    };
    defer config.deinit();

    try testing.expectEqual(256, config.anthropic_api_key.len);
    try testing.expect(std.mem.startsWith(u8, config.anthropic_api_key, "sk-ant-"));
}

test "Config key is properly copied not referenced" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var original = [_]u8{ 's', 'k', '-', 't', 'e', 's', 't' };
    const api_key = try allocator.dupe(u8, &original);
    const config = Config{
        .anthropic_api_key = api_key,
        .allocator = allocator,
    };
    defer config.deinit();

    // Modify original
    original[0] = 'X';

    // Config should still have original value
    try testing.expect(config.anthropic_api_key[0] == 's');
}

test "getEnvVarOwned error handling with missing variable" {
    const testing = std.testing;

    // Try to get a variable that definitely doesn't exist
    const result = std.process.getEnvVarOwned(
        testing.allocator,
        "ZIG_ZAG_NONEXISTENT_VAR_12345_TEST",
    );

    try testing.expectError(error.EnvironmentVariableNotFound, result);
}