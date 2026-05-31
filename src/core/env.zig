// SPDX-License-Identifier: Apache-2.0
//! Process environment variable access.
//! Drop-in replacement for the removed std.posix.getenv in Zig 0.16.
//! Uses libc getenv which is available on all target platforms (macOS, Linux).

const std = @import("std");

/// Look up an environment variable by name.
/// Returns the value as a null-terminated slice, or null if not found.
/// Equivalent to the old std.posix.getenv API.
pub fn get(key: [*:0]const u8) ?[:0]const u8 {
    const ptr = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}
