const std = @import("std");

/// Records HTTP requests and responses to JSON files for test verification
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    output_dir: []const u8,

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
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.output_dir);
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

