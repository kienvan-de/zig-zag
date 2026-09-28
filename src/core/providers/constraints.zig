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

//! Provider request constraints
//!
//! Home for normalizing request fields to satisfy destination-provider schema
//! constraints before forwarding upstream. Today this covers tool-name
//! length/charset; new field constraints (argument caps, id formats, …) should
//! be added here as additional sections so callers have a single place to look.
//!
//! Validation (reject with 400) lives in the per-format `*_validator.zig`
//! modules; this module handles the cases where we *rewrite* rather than reject.
//!
//! ## Tool names
//!
//! Some OpenAI-family backends enforce a maximum tool-name length and a
//! `[a-zA-Z0-9_-]` character set. Anthropic imposes no such limit, so a tool
//! name that is legal in an Anthropic-format request (e.g. a 68+ char MCP name)
//! can exceed the destination cap after translation.
//!
//! `normalizeToolName` produces a compliant name that:
//!   - is a no-op when the input already complies (≤ max_len AND valid charset),
//!   - otherwise replaces invalid chars with `_`, truncates, and appends a short
//!     deterministic hash suffix derived from the *original* name so that two
//!     names sharing a truncated prefix do not collide.
//!
//! The transform is deterministic but NOT invertible from the normalized name
//! alone. Recovery is done by recomputing `normalizeToolName` over the known
//! original names (from the request's tool list / stream state) and matching —
//! see `recoverToolName`.

const std = @import("std");

// ============================================================================
// Tool names
// ============================================================================

/// OpenAI Chat Completions tool-name cap (doc-only, enforced by SAP AI Core et al.).
pub const CHAT_MAX_LEN: usize = 64;
/// OpenAI Responses tool-name cap (schema-enforced).
pub const RESPONSES_MAX_LEN: usize = 128;

/// Number of base36 hash chars appended after the `_` separator.
const HASH_WIDTH: usize = 6;

fn isValidChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

fn isCompliant(name: []const u8, max_len: usize) bool {
    if (name.len == 0 or name.len > max_len) return false;
    for (name) |c| if (!isValidChar(c)) return false;
    return true;
}

/// FNV-1a 32-bit hash of the original name.
fn fnv1a(name: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (name) |b| {
        h ^= b;
        h = h *% 0x01000193;
    }
    return h;
}

/// Write `HASH_WIDTH` base36 digits of `n` into `buf` (big-endian).
fn base36(n: u32, buf: []u8) void {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var v = n;
    var i: usize = HASH_WIDTH;
    while (i > 0) {
        i -= 1;
        buf[i] = digits[v % 36];
        v /= 36;
    }
}

/// Return a compliant tool name for `original`, capped at `max_len`.
///
/// No-op (returns a dupe of the input) when already compliant. Otherwise
/// allocates a new owned string. The caller owns the returned slice.
pub fn normalizeToolName(allocator: std.mem.Allocator, original: []const u8, max_len: usize) ![]u8 {
    if (isCompliant(original, max_len)) {
        return allocator.dupe(u8, original);
    }

    // budget = max_len - 1 (separator) - HASH_WIDTH
    std.debug.assert(max_len > 1 + HASH_WIDTH);
    const budget = max_len - 1 - HASH_WIDTH;

    var hash_buf: [HASH_WIDTH]u8 = undefined;
    base36(fnv1a(original), &hash_buf);

    var out = try allocator.alloc(u8, budget + 1 + HASH_WIDTH);
    var n: usize = 0;
    for (original) |c| {
        if (n >= budget) break;
        out[n] = if (isValidChar(c)) c else '_';
        n += 1;
    }
    out[n] = '_';
    n += 1;
    @memcpy(out[n .. n + HASH_WIDTH], &hash_buf);
    n += HASH_WIDTH;
    // `out` is sized exactly (budget may not be fully used if original shorter,
    // but original is > max_len here so budget is always fully consumed).
    return out[0..n];
}

/// True when `normalizeToolName` would change `original` (i.e. it is non-compliant).
pub fn toolNameNeedsNormalize(original: []const u8, max_len: usize) bool {
    return !isCompliant(original, max_len);
}

/// Reverse lookup: given a `normalized` name seen on the wire and the list of
/// `originals` from the request, return the matching original (or `normalized`
/// itself if no match — e.g. a name the model invented). Stateless: recomputes
/// `normalizeToolName` per candidate.
pub fn recoverToolName(
    allocator: std.mem.Allocator,
    normalized: []const u8,
    originals: []const []const u8,
    max_len: usize,
) []const u8 {
    for (originals) |orig| {
        const norm = normalizeToolName(allocator, orig, max_len) catch continue;
        defer allocator.free(norm);
        if (std.mem.eql(u8, norm, normalized)) return orig;
    }
    return normalized;
}

test "normalize no-op for compliant name" {
    const a = std.testing.allocator;
    const out = try normalizeToolName(a, "get_weather", CHAT_MAX_LEN);
    defer a.free(out);
    try std.testing.expectEqualStrings("get_weather", out);
}

test "normalize truncates over-length name" {
    const a = std.testing.allocator;
    const long = "mcp__github_enterprise__search_repositories_and_return_all_matching_results_verbose";
    const out = try normalizeToolName(a, long, CHAT_MAX_LEN);
    defer a.free(out);
    try std.testing.expect(out.len == CHAT_MAX_LEN);
    try std.testing.expectEqualStrings("mcp__github_enterprise__search_repositories_and_return_al_6tx6b2", out);
}

test "normalize cleans illegal chars" {
    const a = std.testing.allocator;
    const dirty = "mcp.github.enterprise:search repositories/and.return matching results verbose long";
    const out = try normalizeToolName(a, dirty, CHAT_MAX_LEN);
    defer a.free(out);
    try std.testing.expect(out.len == CHAT_MAX_LEN);
    try std.testing.expectEqualStrings("mcp_github_enterprise_search_repositories_and_return_matc_f8l3t4", out);
}

test "recoverOriginal round-trips" {
    const a = std.testing.allocator;
    const long = "mcp__github_enterprise__search_repositories_and_return_all_matching_results_verbose";
    const norm = try normalizeToolName(a, long, CHAT_MAX_LEN);
    defer a.free(norm);
    const originals = [_][]const u8{ "get_weather", long };
    const recovered = recoverToolName(a, norm, &originals, CHAT_MAX_LEN);
    try std.testing.expectEqualStrings(long, recovered);
}

test "recoverOriginal falls back to normalized when unknown" {
    const a = std.testing.allocator;
    const originals = [_][]const u8{"get_weather"};
    const recovered = recoverToolName(a, "invented_tool", &originals, CHAT_MAX_LEN);
    try std.testing.expectEqualStrings("invented_tool", recovered);
}
