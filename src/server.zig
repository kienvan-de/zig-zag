const std = @import("std");
const config = @import("config.zig");

pub fn start(allocator: std.mem.Allocator, cfg: config.Config) !void {
    std.debug.print("Starting zig-zag proxy server on port 8080...\n", .{});
    std.debug.print("Anthropic API Key loaded: {s}\n", .{if (cfg.anthropic_api_key.len > 0) "Yes" else "No"});

    // Create server address
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);

    // Create TCP listener
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.debug.print("Listening on http://127.0.0.1:8080\n", .{});
    std.debug.print("Test endpoint: POST http://127.0.0.1:8080/v1/chat/completions\n", .{});

    // Accept connections in a loop
    while (true) {
        const connection = try listener.accept();
        
        // Handle each connection (for now, single-threaded)
        handleConnection(allocator, connection) catch |err| {
            std.debug.print("Error handling connection: {}\n", .{err});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    defer connection.stream.close();

    var read_buffer: [4096]u8 = undefined;
    
    // Read HTTP request
    const bytes_read = try connection.stream.read(&read_buffer);
    if (bytes_read == 0) return;
    
    const request_data = read_buffer[0..bytes_read];
    
    // Simple HTTP parsing - look for POST /v1/chat/completions
    const is_post = std.mem.startsWith(u8, request_data, "POST ");
    const has_endpoint = std.mem.indexOf(u8, request_data, "/v1/chat/completions") != null;
    
    if (is_post and has_endpoint) {
        // Return static JSON response
        const response = 
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Content-Length: 19
            \\Connection: close
            \\
            \\{"status": "alive"}
        ;
        
        _ = try connection.stream.writeAll(response);
    } else {
        // Return 404 for other paths
        const response = 
            \\HTTP/1.1 404 Not Found
            \\Content-Type: application/json
            \\Content-Length: 23
            \\Connection: close
            \\
            \\{"error": "Not Found"}
        ;
        
        _ = try connection.stream.writeAll(response);
    }
    
    _ = allocator;
}