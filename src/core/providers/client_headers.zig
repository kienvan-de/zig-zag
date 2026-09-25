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

//! Shared helper for composing outbound request headers across provider clients.
//!
//! Each provider builds a small fixed set of base headers (Authorization,
//! Content-Type, provider-specific). This helper appends any per-provider
//! custom headers from the optional `"headers"` config object, returning a
//! single owned slice the caller frees with `free`.
//!
//! Custom headers are OPTIONAL: with no `"headers"` config the result is exactly
//! the base set (a fresh copy), so provider behavior is unchanged by absence.
//!
//! Header name/value strings are borrowed — base headers from the caller's
//! buffers, custom headers from the parsed config tree — so only the returned
//! slice's backing array is allocated; `free` releases just that.

const std = @import("std");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

/// Return `base` plus the provider's configured custom headers as one owned
/// slice (caller frees via `free`). A custom header whose name case-insensitively
/// matches a base header is skipped (base wins) and logged, so a misconfigured
/// `Authorization`/`Content-Type` can never clobber the built-in one.
pub fn compose(
    allocator: std.mem.Allocator,
    base: []const std.http.Header,
    provider_config: *const config_mod.ProviderConfig,
) ![]std.http.Header {
    var list = std.ArrayList(std.http.Header).empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, base);

    var it = provider_config.headerIterator();
    while (it.next()) |pair| {
        if (pair.name.len == 0) continue;
        if (hasNameIgnoreCase(base, pair.name)) {
            log.debug("[headers] custom header '{s}' ignored: conflicts with a built-in header", .{pair.name});
            continue;
        }
        try list.append(allocator, .{ .name = pair.name, .value = pair.value });
    }

    return list.toOwnedSlice(allocator);
}

/// Free a slice returned by `compose`. Only the backing array is freed — the
/// header name/value strings are borrowed (caller buffers / config tree).
pub fn free(allocator: std.mem.Allocator, headers: []std.http.Header) void {
    allocator.free(headers);
}

fn hasNameIgnoreCase(headers: []const std.http.Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}
