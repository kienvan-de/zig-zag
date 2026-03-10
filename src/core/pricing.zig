// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const worker_pool = @import("worker_pool.zig");

// ============================================================================
// Constants
// ============================================================================

const PRICING_ARCHIVE_URL = "https://github.com/kienvan-de/zig-zag/releases/latest/download/pricing.tar.gz";
const CHECKSUM_FILENAME = "checksum.sha256";

// ============================================================================
// Types
// ============================================================================

/// Cost entry for a single model
pub const CostEntry = struct {
    threshold: u64, // 0 = no tiering
    input_t1: f64,
    output_t1: f64,
    input_t2: ?f64, // null = use t1
    output_t2: ?f64, // null = use t1
};

/// Result of cost calculation
pub const CostResult = struct {
    input_cost: f64,
    output_cost: f64,
};

/// A pricing table for one CSV file (one provider or default)
const PricingTable = std.StringHashMap(CostEntry);

// ============================================================================
// Global State
// ============================================================================

var alloc: std.mem.Allocator = undefined;
var default_table: ?PricingTable = null;
var provider_tables: std.StringHashMap(PricingTable) = undefined;
var initialized: bool = false;
var rwlock: std.Thread.RwLock = .{};

/// Provider names stored for reload after auto-update
var stored_provider_names: std.ArrayList([]const u8) = undefined;

// ============================================================================
// Public API
// ============================================================================

/// Initialize the pricing engine. Loads default.csv and provider CSVs for configured providers.
pub fn init(allocator: std.mem.Allocator, provider_names: []const []const u8) void {
    alloc = allocator;
    provider_tables = std.StringHashMap(PricingTable).init(allocator);
    stored_provider_names = std.ArrayList([]const u8){};

    // Store provider names for reload after auto-update
    for (provider_names) |name| {
        const duped = allocator.dupe(u8, name) catch continue;
        stored_provider_names.append(allocator, duped) catch {
            allocator.free(duped);
            continue;
        };
    }

    // Load tables from local files
    loadAllTables();

    initialized = true;
}

/// Clean up all pricing data
pub fn deinit() void {
    if (!initialized) return;

    rwlock.lock();
    defer rwlock.unlock();

    freeTables();

    // Free stored provider names
    for (stored_provider_names.items) |name| {
        alloc.free(name);
    }
    stored_provider_names.deinit(alloc);

    initialized = false;
}

/// Look up cost entry for a provider/model combination.
/// Lookup order: provider CSV → default.csv → null
/// Each table is searched: exact match first, then contains-based fallback
/// (longest CSV key that is a substring of model_name wins).
/// Thread-safe: uses shared read lock.
pub fn getCost(provider_name: []const u8, model_name: []const u8) ?CostEntry {
    if (!initialized) return null;

    rwlock.lockShared();
    defer rwlock.unlockShared();

    // 1. Try provider-specific table
    if (provider_tables.get(provider_name)) |table| {
        if (tableLookup(table, model_name)) |entry| {
            return entry;
        }
    }

    // 2. Fall back to default table
    if (default_table) |table| {
        if (tableLookup(table, model_name)) |entry| {
            return entry;
        }
    }

    return null;
}

/// Look up a model in a pricing table.
/// 1. Exact match (fast HashMap lookup)
/// 2. Contains fallback: find the longest key that is a substring of model_name
///    e.g. key "gpt-4o" matches model "gpt-4o-2024-11-20",
///         key "gpt-4o-mini" matches model "gpt-4o-mini-2024-07-18" (longer wins)
fn tableLookup(table: PricingTable, model_name: []const u8) ?CostEntry {
    // Fast path: exact match
    if (table.get(model_name)) |entry| return entry;

    // Slow path: contains-based fallback (longest match wins)
    var best_entry: ?CostEntry = null;
    var best_len: usize = 0;

    var it = table.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (key.len > best_len and std.mem.indexOf(u8, model_name, key) != null) {
            best_len = key.len;
            best_entry = kv.value_ptr.*;
        }
    }

    return best_entry;
}

/// Calculate cost for a request given a cost entry and token counts.
/// Pure function, no lock needed.
pub fn calculateCost(entry: CostEntry, input_tokens: u64, output_tokens: u64) CostResult {
    const input_f: f64 = @floatFromInt(input_tokens);
    const output_f: f64 = @floatFromInt(output_tokens);

    var input_cost: f64 = 0.0;
    var output_cost: f64 = 0.0;

    if (entry.threshold > 0 and input_tokens > entry.threshold) {
        // Tiered input
        const threshold_f: f64 = @floatFromInt(entry.threshold);
        const overflow_f: f64 = input_f - threshold_f;
        const t2_rate = entry.input_t2 orelse entry.input_t1;
        input_cost = threshold_f * entry.input_t1 + overflow_f * t2_rate;
    } else {
        input_cost = input_f * entry.input_t1;
    }

    if (entry.threshold > 0 and output_tokens > entry.threshold) {
        // Tiered output
        const threshold_f: f64 = @floatFromInt(entry.threshold);
        const overflow_f: f64 = output_f - threshold_f;
        const t2_rate = entry.output_t2 orelse entry.output_t1;
        output_cost = threshold_f * entry.output_t1 + overflow_f * t2_rate;
    } else {
        output_cost = output_f * entry.output_t1;
    }

    return .{
        .input_cost = input_cost,
        .output_cost = output_cost,
    };
}

/// Schedule a background auto-update via the worker pool.
/// Only supported on macOS and Linux (requires curl + tar).
pub fn scheduleAutoUpdate() void {
    if (!initialized) return;

    // Only macOS and Linux have curl + tar
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
        log.debug("Pricing auto-update not supported on this platform", .{});
        return;
    }

    worker_pool.submit(autoUpdateTask, undefined) catch |err| {
        log.warn("Failed to schedule pricing auto-update: {}", .{err});
    };
}

// ============================================================================
// Auto-Update
// ============================================================================

/// Worker pool task wrapper
fn autoUpdateTask(_: *anyopaque) void {
    autoUpdate();
}

/// Download pricing archive from GitHub, compare checksum, and reload if changed.
fn autoUpdate() void {
    log.info("Checking for pricing updates...", .{});

    const pricing_dir = getPricingDir() orelse {
        log.warn("Could not resolve pricing directory for auto-update", .{});
        return;
    };
    defer alloc.free(pricing_dir);

    // Ensure pricing directory exists
    std.fs.cwd().makePath(pricing_dir) catch |err| {
        log.warn("Failed to create pricing directory: {}", .{err});
        return;
    };

    // Step 1: Download archive to temp file
    const tmp_path = getTempPath("pricing.tar.gz") orelse return;
    defer alloc.free(tmp_path);
    defer deleteFile(tmp_path); // cleanup temp file

    if (!downloadFile(PRICING_ARCHIVE_URL, tmp_path)) {
        log.warn("Failed to download pricing archive", .{});
        return;
    }

    // Step 2: Extract checksum from archive (without extracting all files)
    const remote_checksum = extractFileFromArchive(tmp_path, CHECKSUM_FILENAME) orelse {
        log.warn("Pricing archive has no checksum file", .{});
        return;
    };
    defer alloc.free(remote_checksum);

    // Step 3: Compare with local checksum
    const local_checksum = readLocalChecksum(pricing_dir);
    defer if (local_checksum) |cs| alloc.free(cs);

    if (local_checksum) |local| {
        if (std.mem.eql(u8, std.mem.trim(u8, local, " \t\n\r"), std.mem.trim(u8, remote_checksum, " \t\n\r"))) {
            log.info("Pricing data is up to date", .{});
            return;
        }
    }

    // Step 4: Checksums differ (or no local) — extract all files
    log.info("Pricing update available, extracting...", .{});
    if (!extractArchive(tmp_path, pricing_dir)) {
        log.warn("Failed to extract pricing archive", .{});
        return;
    }

    // Step 5: Reload pricing tables under write lock
    log.info("Reloading pricing tables...", .{});
    rwlock.lock();
    freeTables();
    loadAllTables();
    rwlock.unlock();

    log.info("Pricing tables updated successfully", .{});
}

/// Download a URL to a local file path using curl
fn downloadFile(url: []const u8, dest: []const u8) bool {
    var child = std.process.Child.init(
        &[_][]const u8{ "curl", "-sL", "--max-time", "30", "-o", dest, url },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("Failed to spawn curl: {}", .{err});
        return false;
    };

    const stderr = child.stderr.?.readToEndAlloc(alloc, 64 * 1024) catch null;
    defer if (stderr) |s| alloc.free(s);

    const result = child.wait() catch |err| {
        log.warn("Failed to wait for curl: {}", .{err});
        return false;
    };

    return switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Extract a single file from a tar.gz archive using tar -xzf <archive> -O <filename>
fn extractFileFromArchive(archive_path: []const u8, filename: []const u8) ?[]const u8 {
    var child = std.process.Child.init(
        &[_][]const u8{ "tar", "xzf", archive_path, "-O", filename },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const output = child.stdout.?.readToEndAlloc(alloc, 64 * 1024) catch {
        _ = child.wait() catch {};
        return null;
    };

    const result = child.wait() catch {
        alloc.free(output);
        return null;
    };

    return switch (result) {
        .Exited => |code| if (code == 0) output else {
            alloc.free(output);
            return null;
        },
        else => {
            alloc.free(output);
            return null;
        },
    };
}

/// Extract all files from a tar.gz archive to a directory
fn extractArchive(archive_path: []const u8, dest_dir: []const u8) bool {
    var child = std.process.Child.init(
        &[_][]const u8{ "tar", "xzf", archive_path, "-C", dest_dir },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("Failed to spawn tar: {}", .{err});
        return false;
    };

    const stderr = child.stderr.?.readToEndAlloc(alloc, 64 * 1024) catch null;
    defer if (stderr) |s| alloc.free(s);

    const result = child.wait() catch |err| {
        log.warn("Failed to wait for tar: {}", .{err});
        return false;
    };

    return switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Read the local checksum file
fn readLocalChecksum(pricing_dir: []const u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ pricing_dir, CHECKSUM_FILENAME }) catch return null;

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    return file.readToEndAlloc(alloc, 64 * 1024) catch null;
}

// ============================================================================
// Table Management
// ============================================================================

/// Load all pricing tables from local CSV files (called at init and after update)
fn loadAllTables() void {
    const pricing_dir = getPricingDir() orelse {
        log.warn("Could not resolve pricing directory", .{});
        return;
    };
    defer alloc.free(pricing_dir);

    // Load default.csv (always)
    default_table = loadCsvFile(pricing_dir, "default.csv");
    if (default_table != null) {
        log.info("Loaded default pricing table", .{});
    }

    // Load provider-specific CSVs
    for (stored_provider_names.items) |name| {
        var filename_buf: [128]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{s}.csv", .{name}) catch continue;

        if (loadCsvFile(pricing_dir, filename)) |table| {
            const duped_name = alloc.dupe(u8, name) catch continue;
            provider_tables.put(duped_name, table) catch {
                alloc.free(duped_name);
                continue;
            };
            log.info("Loaded pricing table for provider '{s}'", .{name});
        }
    }
}

/// Free all pricing tables (caller must hold write lock or be in init/deinit)
fn freeTables() void {
    if (default_table) |*table| {
        freeTable(table);
        default_table = null;
    }

    var iter = provider_tables.iterator();
    while (iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        var table = entry.value_ptr.*;
        freeTable(&table);
    }
    provider_tables.clearAndFree();
}

// ============================================================================
// CSV Parsing
// ============================================================================

/// Get the pricing directory path
fn getPricingDir() ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/zig-zag/pricing", .{home}) catch return null;

    // Return a stable pointer by duping
    return alloc.dupe(u8, path) catch null;
}

/// Get a temp file path
fn getTempPath(filename: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/tmp/zig-zag-{s}", .{filename}) catch return null;
    return alloc.dupe(u8, path) catch null;
}

/// Delete a file, ignoring errors
fn deleteFile(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

/// Load and parse a single CSV file into a PricingTable
fn loadCsvFile(dir: []const u8, filename: []const u8) ?PricingTable {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, filename }) catch return null;

    const file = std.fs.cwd().openFile(path, .{}) catch {
        return null;
    };
    defer file.close();

    const content = file.readToEndAlloc(alloc, 1024 * 1024) catch return null;
    defer alloc.free(content);

    return parseCsv(content);
}

/// Parse CSV content into a PricingTable
fn parseCsv(content: []const u8) ?PricingTable {
    var table = PricingTable.init(alloc);
    errdefer freeTable(&table);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r ");

        // Skip empty lines
        if (line.len == 0) continue;

        // Skip header row
        if (first_line) {
            first_line = false;
            if (std.mem.startsWith(u8, line, "model")) continue;
        }

        // Parse columns
        var col_iter = std.mem.splitScalar(u8, line, ',');

        const model_raw = col_iter.next() orelse continue;
        const model = std.mem.trim(u8, model_raw, " ");
        if (model.len == 0) continue;

        const threshold_str = col_iter.next() orelse continue;
        const input_t1_str = col_iter.next() orelse continue;
        const output_t1_str = col_iter.next() orelse continue;
        const input_t2_str = col_iter.next(); // optional
        const output_t2_str = col_iter.next(); // optional

        const threshold = parseU64(threshold_str) orelse continue;
        const input_t1 = parseF64(input_t1_str) orelse continue;
        const output_t1 = parseF64(output_t1_str) orelse continue;
        const input_t2 = if (input_t2_str) |s| parseOptionalF64(s) else null;
        const output_t2 = if (output_t2_str) |s| parseOptionalF64(s) else null;

        const entry = CostEntry{
            .threshold = threshold,
            .input_t1 = input_t1,
            .output_t1 = output_t1,
            .input_t2 = input_t2,
            .output_t2 = output_t2,
        };

        // Dupe model name so hashmap owns the key
        const duped_model = alloc.dupe(u8, model) catch continue;
        table.put(duped_model, entry) catch {
            alloc.free(duped_model);
            continue;
        };
    }

    if (table.count() == 0) {
        table.deinit();
        return null;
    }

    return table;
}

/// Parse a trimmed string as u64, return null on failure
fn parseU64(raw: []const u8) ?u64 {
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// Parse a trimmed string as f64, return null on failure
fn parseF64(raw: []const u8) ?f64 {
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Parse an optional f64: empty string → null, "0" → 0.0, valid number → value
fn parseOptionalF64(raw: []const u8) ?f64 {
    const s = std.mem.trim(u8, raw, " ");
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Free all keys in a pricing table and deinit it
fn freeTable(table: *PricingTable) void {
    var iter = table.keyIterator();
    while (iter.next()) |key_ptr| {
        alloc.free(key_ptr.*);
    }
    table.deinit();
}
