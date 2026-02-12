const std = @import("std");

/// Records HTTP requests and responses to JSON files for test verification
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    counter: usize,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, output_dir: []const u8) !Recorder {
        // Make a copy of output_dir that we own
        const output_dir_copy = try allocator.dupe(u8, output_dir);
        errdefer allocator.free(output_dir_copy);

        // Ensure output directory exists
        std.fs.cwd().makePath(output_dir_copy) catch |err| {
            if (err != error.PathAlreadyExists) {
                allocator.free(output_dir_copy);
                return err;
            }
        };

        return Recorder{
            .allocator = allocator,
            .output_dir = output_dir_copy,
            .counter = 0,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.output_dir);
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
        std.fs.cwd().makePath(self.output_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        var dir = try std.fs.cwd().openDir(self.output_dir, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                if (isFixtureFile(entry.name)) continue;
                try dir.deleteFile(entry.name);
            }
        }
    }
};

pub fn resolveCaseDirFor(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    case_name: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cases_root, case_name });
}

pub fn resolveCaseDir(allocator: std.mem.Allocator, cases_root: []const u8) ![]const u8 {
    const case_name = std.posix.getenv("CASE_FOLDER") orelse "case-1";
    return try resolveCaseDirFor(allocator, cases_root, case_name);
}

pub fn buildCasePath(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    filename: []const u8,
) ![]const u8 {
    const case_dir = try resolveCaseDir(allocator, cases_root);
    defer allocator.free(case_dir);

    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ case_dir, filename });
}

pub fn readCaseFile(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    filename: []const u8,
    max_bytes: usize,
) ![]u8 {
    const path = try buildCasePath(allocator, cases_root, filename);
    defer allocator.free(path);

    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

pub fn writeCaseFile(
    allocator: std.mem.Allocator,
    cases_root: []const u8,
    filename: []const u8,
    contents: []const u8,
) !void {
    const path = try buildCasePath(allocator, cases_root, filename);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    _ = try file.write(contents);
}

fn isFixtureFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "agent_req.json") or
        std.mem.eql(u8, name, "upstream_res.json") or
        std.mem.eql(u8, name, "expected_agent_res.json") or
        std.mem.eql(u8, name, "expected_upstream_req.json");
}

test "Recorder initialization" {
    const allocator = std.testing.allocator;
    const case_dir = try resolveCaseDirFor(allocator, "test/cases", "case-1");
    defer allocator.free(case_dir);
    
    var rec = try Recorder.init(allocator, case_dir);
    defer rec.deinit();
}

test "Recorder writes case files" {
    const allocator = std.testing.allocator;
    const case_dir = try resolveCaseDirFor(allocator, "test/cases", "case-1");
    defer allocator.free(case_dir);

    var rec = try Recorder.init(allocator, case_dir);
    defer rec.deinit();
    try rec.clean();

    try rec.recordRequest("upstream", "POST", "/v1/chat/completions", "{\\\"ok\\\":true}");
    try rec.recordResponse("upstream", 200, "{\\\"result\\\":true}");

    var dir = try std.fs.cwd().openDir(case_dir, .{ .iterate = true });
    defer dir.close();

    var found_request = false;
    var found_response = false;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            if (std.mem.startsWith(u8, entry.name, "upstream_request_")) found_request = true;
            if (std.mem.startsWith(u8, entry.name, "upstream_response_")) found_response = true;
        }
    }

    try std.testing.expect(found_request);
    try std.testing.expect(found_response);
}