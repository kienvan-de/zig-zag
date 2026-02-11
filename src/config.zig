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