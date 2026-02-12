const std = @import("std");

/// Records HTTP requests and responses to JSON files for test verification
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    counter: usize,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8) !Recorder {
        // Ensure output directory exists
        std.fs.cwd().makePath(output_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return Recorder{
            .allocator = allocator,
            .output_dir = output_dir,
            .counter = 0,
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Record a request to a JSON file
    pub fn recordRequest(
        self: *Recorder,
        prefix: []const u8,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !void {
        self.mutex.lock();
        const id = self.counter;
        self.counter += 1;
        self.mutex.unlock();
        
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const filepath = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}_request_{d:0>3}.json",
            .{ self.output_dir, prefix, id },
        );

        // Build JSON string
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(self.allocator);
        
        const writer = json_buf.writer(self.allocator);
        try writer.writeAll("{\n");
        try writer.print("  \"method\": \"{s}\",\n", .{method});
        try writer.print("  \"path\": \"{s}\",\n", .{path});
        try writer.writeAll("  \"body\": ");
        
        // Just write body as-is (assuming it's already JSON)
        try writer.writeAll(body);
        try writer.writeAll("\n}\n");

        // Write to file
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        
        _ = try file.write(json_buf.items);
    }

    /// Record a response to a JSON file
    pub fn recordResponse(
        self: *Recorder,
        prefix: []const u8,
        status: u16,
        body: []const u8,
    ) !void {
        self.mutex.lock();
        const id = self.counter - 1; // Use same ID as last request
        self.mutex.unlock();
        
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const filepath = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}_response_{d:0>3}.json",
            .{ self.output_dir, prefix, id },
        );

        // Build JSON string
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(self.allocator);
        
        const writer = json_buf.writer(self.allocator);
        try writer.writeAll("{\n");
        try writer.print("  \"status\": {d},\n", .{status});
        try writer.writeAll("  \"body\": ");
        
        // Just write body as-is (assuming it's already JSON)
        try writer.writeAll(body);
        try writer.writeAll("\n}\n");

        // Write to file
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        
        _ = try file.write(json_buf.items);
    }

    /// Clean up recorded files (useful before test runs)
    pub fn clean(self: *Recorder) !void {
        var dir = try std.fs.cwd().openDir(self.output_dir, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                try dir.deleteFile(entry.name);
            }
        }
    }
};

test "Recorder initialization" {
    const allocator = std.testing.allocator;
    const test_dir = "test/fixtures/recorded";
    
    const rec = try Recorder.init(allocator, test_dir);
    _ = rec;
}