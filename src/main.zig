const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const cfg = try config.loadConfig(allocator);
    defer cfg.deinit();

    // Start the HTTP server
    try server.start(allocator, cfg);
}