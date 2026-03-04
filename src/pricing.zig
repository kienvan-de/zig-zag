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
const log = @import("log.zig");

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

var allocator: std.mem.Allocator = undefined;
var default_table: ?PricingTable = null;
var provider_tables: std.StringHashMap(PricingTable) = undefined;
var initialized: bool = false;

// ============================================================================
// Public API
// ============================================================================

/// Initialize the pricing engine. Loads default.csv and provider CSVs for configured providers.
pub fn init(alloc: std.mem.Allocator, provider_names: []const []const u8) void {
    allocator = alloc;
    provider_tables = std.StringHashMap(PricingTable).init(alloc);

    // Resolve pricing directory
    const pricing_dir = getPricingDir() orelse {
        log.warn("Could not resolve pricing directory, cost tracking disabled", .{});
        initialized = true;
        return;
    };
    defer allocator.free(pricing_dir);

    // Load default.csv (always)
    default_table = loadCsvFile(pricing_dir, "default.csv");
    if (default_table != null) {
        log.info("Loaded default pricing table", .{});
    }

    // Load provider-specific CSVs
    for (provider_names) |name| {
        var filename_buf: [128]u8 = undefined;
        const filename = std.fmt.bufPrint(&filename_buf, "{s}.csv", .{name}) catch continue;

        if (loadCsvFile(pricing_dir, filename)) |table| {
            // Dupe the name so the hashmap owns its key
            const duped_name = alloc.dupe(u8, name) catch continue;
            provider_tables.put(duped_name, table) catch {
                alloc.free(duped_name);
                continue;
            };
            log.info("Loaded pricing table for provider '{s}'", .{name});
        }
    }

    initialized = true;
}

/// Clean up all pricing data
pub fn deinit() void {
    if (!initialized) return;

    if (default_table) |*table| {
        freeTable(table);
        default_table = null;
    }

    var iter = provider_tables.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var table = entry.value_ptr.*;
        freeTable(&table);
    }
    provider_tables.deinit();

    initialized = false;
}

/// Look up cost entry for a provider/model combination.
/// Lookup order: provider CSV → default.csv → null
pub fn getCost(provider_name: []const u8, model_name: []const u8) ?CostEntry {
    if (!initialized) return null;

    // 1. Try provider-specific table
    if (provider_tables.get(provider_name)) |table| {
        if (table.get(model_name)) |entry| {
            return entry;
        }
    }

    // 2. Fall back to default table
    if (default_table) |table| {
        if (table.get(model_name)) |entry| {
            return entry;
        }
    }

    return null;
}

/// Calculate cost for a request given a cost entry and token counts.
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

// ============================================================================
// Internal
// ============================================================================

/// Get the pricing directory path
fn getPricingDir() ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/zig-zag/pricing", .{home}) catch return null;

    // Return a stable pointer by duping
    return allocator.dupe(u8, path) catch null;
}

/// Load and parse a single CSV file into a PricingTable
fn loadCsvFile(dir: []const u8, filename: []const u8) ?PricingTable {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, filename }) catch return null;

    const file = std.fs.cwd().openFile(path, .{}) catch {
        return null;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    return parseCsv(content);
}

/// Parse CSV content into a PricingTable
fn parseCsv(content: []const u8) ?PricingTable {
    var table = PricingTable.init(allocator);
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
        const duped_model = allocator.dupe(u8, model) catch continue;
        table.put(duped_model, entry) catch {
            allocator.free(duped_model);
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
        allocator.free(key_ptr.*);
    }
    table.deinit();
}
