const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration from ~/.config/zig-zag/config.json
    var cfg = try config.Config.load(allocator);
    defer cfg.deinit();

    // Start the HTTP server
    try server.start(allocator, &cfg);
}