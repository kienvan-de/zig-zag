const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");
const log = @import("log.zig");
const token_cache = @import("cache/token_cache.zig");
const worker_pool = @import("worker_pool.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from ~/.config/zig-zag/config.json
    var cfg = try config.Config.load(allocator);
    defer cfg.deinit();

    // Initialize token cache
    token_cache.init(allocator);
    defer token_cache.deinit();

    // Initialize IO worker pool (before logging so async writes work)
    const io_pool_size: usize = if (cfg.server.io_pool_size) |size|
        @intCast(size)
    else
        4;
    try worker_pool.init(allocator, io_pool_size);
    defer worker_pool.deinit();

    // Initialize logging (after worker pool for async writes)
    try log.init(.{
        .level = cfg.log.level,
        .path = cfg.log.path,
        .output = cfg.log.output,
    }, allocator);
    defer log.deinit();

    // Start the HTTP server
    try server.start(allocator, &cfg);
}