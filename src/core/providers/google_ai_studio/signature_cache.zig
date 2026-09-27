/// Bounded cache for Gemini thought signatures.
/// Key: proxy tool id ("name~token").
/// Value: opaque thoughtSignature string.
/// Max 512 entries. Not FIFO despite the size cap: once full, new entries are
/// silently dropped (not inserted) until the process restarts — see put()'s
/// capacity check. A dropped entry just means that tool call's replay falls
/// back to the "skip_thought_signature_validator" bypass signature instead of
/// its real one; it does not fail the request.
///
/// This cache is process-lifetime, not request-lifetime: a tool call cached
/// during one request must still be found on a later, unrelated request.
/// It therefore MUST NOT be initialized with a caller-supplied allocator —
/// callers only ever have request-scoped allocators (e.g. the per-connection
/// arena in server.zig's handleConnection, freed as soon as that request
/// finishes). Backing the cache with page_allocator, owned internally, keeps
/// its storage valid for the life of the process regardless of which
/// request happens to trigger the first init() call.
const std = @import("std");
const log = @import("../../log.zig");
const sync = @import("../../sync.zig");

const MAX_ENTRIES: usize = 512;
const backing_allocator = std.heap.page_allocator;

var lookup: std.StringHashMap([]const u8) = undefined;
var initialized: bool = false;
var mutex: sync.Mutex = .{};
var token_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

/// Idempotent — safe to call on every request. Uses a fixed internal
/// allocator (see module doc) rather than one supplied by the caller.
pub fn init() void {
    mutex.lock();
    defer mutex.unlock();
    if (!initialized) {
        lookup = std.StringHashMap([]const u8).init(backing_allocator);
        initialized = true;
    }
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (initialized) {
        var it = lookup.iterator();
        while (it.next()) |entry| backing_allocator.free(entry.value_ptr.*);
        lookup.deinit();
        initialized = false;
    }
}

/// Store a signature for the proxy tool id.
pub fn put(key: []const u8, sig: []const u8) !void {
    mutex.lock();
    defer mutex.unlock();
    if (!initialized) return error.NotInitialized;
    if (lookup.contains(key)) return;
    // Bounded: skip new insertions once at capacity (simple cap, no FIFO tracking needed for fix).
    if (lookup.count() >= MAX_ENTRIES) return;
    const key_copy = try backing_allocator.dupe(u8, key);
    errdefer backing_allocator.free(key_copy);
    const sig_copy = try backing_allocator.dupe(u8, sig);
    errdefer backing_allocator.free(sig_copy);
    try lookup.put(key_copy, sig_copy);
}

/// Generate a new proxy tool id: "<name>~<token>".
pub fn generateId(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const token_val = token_counter.fetchAdd(1, .monotonic);
    var token_buf: [16]u8 = undefined;
    const token_str = std.fmt.bufPrint(&token_buf, "{x}", .{token_val}) catch "f";
    var result = try allocator.alloc(u8, name.len + 1 + token_str.len);
    std.mem.copyForwards(u8, result[0..name.len], name);
    result[name.len] = '~';
    std.mem.copyForwards(u8, result[name.len + 1 ..], token_str);
    return result;
}

/// Extract function name from proxy id.
pub fn splitNameFromId(id: []const u8) []const u8 {
    if (std.mem.indexOf(u8, id, "~")) |pos| return id[0..pos];
    return id;
}

/// Look up the thoughtSignature. Returns a duplicate owned by `allocator`
/// (the caller's own, typically request-scoped, allocator — safe since the
/// caller only uses it for the lifetime of its own request).
pub fn get(key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialized) return null;
    if (lookup.get(key)) |sig| return allocator.dupe(u8, sig) catch null;
    return null;
}
