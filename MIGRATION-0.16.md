# Zig 0.15.2 → 0.16.0 Migration Plan

## Overview

This document lists all breaking changes found in the zig-zag codebase when upgrading from Zig 0.15.2 to Zig 0.16.0.

---

## Issue 1: `std.mem.trimRight` renamed to `std.mem.trimEnd`

**Affected files:**
- `build.zig:26`
- `src/core/pricing.zig:480`
- `test/integration/main.zig:163`
- `test/integration/mock_upstream.zig:308`

**Current 0.15.2 implementation:**
```zig
const version_trimmed = std.mem.trimRight(u8, version, "\n\r ");
const line = std.mem.trimRight(u8, raw_line, "\r ");
const trimmed = std.mem.trimRight(u8, line, "\r");
```

---

## Issue 2: `std.heap.GeneralPurposeAllocator` removed, replaced by `std.heap.DebugAllocator`

**Affected files:**
- `src/main.zig:44`
- `src/lib.zig:39, 235`
- `src/core/config.zig:586`
- `test/integration/main.zig:556`
- `test/integration/mock_upstream.zig:413`

**Current 0.15.2 implementation:**
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
```

In `src/lib.zig` (struct field):
```zig
gpa: std.heap.GeneralPurposeAllocator(.{}),
// ...
.gpa = std.heap.GeneralPurposeAllocator(.{}){},
```

---

## Issue 3: `std.process.args()` removed

**Affected files:**
- `src/main.zig:35`

**Current 0.15.2 implementation:**
```zig
var args = std.process.args();
_ = args.next(); // skip program name
if (args.next()) |arg| { ... }
```

---

## Issue 4: `std.process.argsAlloc` / `std.process.argsFree` removed

**Affected files:**
- `test/integration/mock_upstream.zig:418-419`

**Current 0.15.2 implementation:**
```zig
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);
```

---

## Issue 5: `std.posix.getenv` removed

**Affected files:**
- `src/main.zig:116, 123, 131`
- `src/lib.zig:381, 388, 396`
- `src/log.zig:355, 362, 369, 376`
- `src/core/pricing.zig:435`
- `src/core/metrics.zig:368`
- `src/core/providers/copilot/client.zig:204, 358, 786, 816`
- `test/integration/recorder.zig:101`
- `test/integration/main.zig:317, 565`

**Current 0.15.2 implementation:**
```zig
const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
if (std.posix.getenv("ZIG_ZAG_CONFIG")) |env_path| { ... }
```

---

## Issue 6: `std.posix.write` removed

**Affected files:**
- `src/main.zig:39`
- `src/core/log.zig:133`
- `src/log.zig:207, 214, 284, 306`

**Current 0.15.2 implementation:**
```zig
_ = std.posix.write(std.posix.STDOUT_FILENO, "zig-zag " ++ version ++ "\n") catch {};
_ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
```

---

## Issue 7: `std.net` namespace removed entirely

**Affected files:**
- `src/http.zig:34, 64, 84, 103, 116, 143, 177, 186, 216, 219`
- `src/server.zig:38, 48, 78, 173`
- `src/router.zig:28`
- `src/handlers/chat.zig:30, 105`
- `src/handlers/messages.zig:30, 103`
- `src/handlers/models.zig:30`
- `src/handlers/config.zig:40, 71, 80, 100`
- `src/handlers/template.zig:33, 71, 139`
- `src/core/auth/callback_server.zig:127, 204, 293, 307`
- `test/integration/mock_upstream.zig:66, 90, 149, 169, 225, 285`

**Current 0.15.2 implementation:**
```zig
// Types used throughout
std.net.Server
std.net.Server.Connection
std.net.Stream
std.net.Address

// Address creation
const address = try std.net.Address.parseIp(host, port);
const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, config.port);

// Server listening
var server = try address.listen(.{ .reuse_address = true });

// Connection handling
fn handleConnection(allocator: std.mem.Allocator, connection: std.net.Server.Connection, ...) !void { ... }

// Stream writing (used in HTTP response functions)
pub fn sendSseHeaders(connection: std.net.Server.Connection) !void { ... }
stream: std.net.Stream,
```

---

## Issue 8: `std.io` namespace removed (replaced by `std.Io`)

**Affected files:**
- `src/http.zig:245` — `std.io.GenericWriter`
- `src/core/auth/callback_server.zig:330` — `std.io.fixedBufferStream`
- `src/core/client.zig:271, 377, 460` — `std.io.Limit.limited`
- `src/core/metrics.zig:454` — `std.io.fixedBufferStream`
- `test/integration/mock_client.zig:101, 189, 209, 297` — `std.io.Limit.limited`

**Current 0.15.2 implementation:**
```zig
// GenericWriter
pub fn writer(self: *ChunkedWriter) std.io.GenericWriter(*ChunkedWriter, anyerror, write) { ... }

// fixedBufferStream
var fbs = std.io.fixedBufferStream(&html_buf);
const writer = fbs.writer();

// Limit
const body = try reader.allocRemaining(self.allocator, std.io.Limit.limited(self.max_response_size));
```

---

## Issue 9: `std.Thread.Mutex` moved to `std.Io.Mutex` (now requires `io: Io` parameter)

**Affected files:**
- `src/core/cache/token_cache.zig:42, 45, 46, 175`
- `src/core/cache/app_cache.zig:31`
- `src/core/pricing.zig:57`
- `src/core/worker_pool.zig:60`
- `src/core/completion.zig:730`
- `src/server.zig:49`
- `src/worker_pool.zig:35, 43, 44`

**Current 0.15.2 implementation:**
```zig
var rwlock: std.Thread.RwLock = .{};
var pool_mutex: std.Thread.Mutex = .{};
var queue_not_empty: std.Thread.Condition = .{};

// Usage
mutex.lock();
defer mutex.unlock();
```

---

## Issue 10: `std.Thread.sleep` removed

**Affected files:**
- `src/core/config.zig:714`
- `src/core/auth/oauth.zig:575`
- `src/core/auth/callback_server.zig:151`

**Current 0.15.2 implementation:**
```zig
std.Thread.sleep(100 * std.time.ns_per_ms);
std.Thread.sleep(interval * std.time.ns_per_s);
```

---

## Issue 11: `std.time.timestamp` / `std.time.milliTimestamp` / `std.time.nanoTimestamp` removed

**Affected files:**
- `src/core/cache/token_cache.zig:34, 206`
- `src/core/auth/oauth.zig:572, 574`
- `src/core/auth/callback_server.zig:134, 135, 142`

**Current 0.15.2 implementation:**
```zig
const now = @divTrunc(std.time.milliTimestamp(), 1000);
const deadline = std.time.timestamp() + expires_in;
while (std.time.timestamp() < deadline) { ... }
const timeout_ns: i128 = @as(i128, config.timeout_ms) * std.time.ns_per_ms;
const deadline = std.time.nanoTimestamp() + timeout_ns;
if (std.time.nanoTimestamp() > deadline) { ... }
```

---

## Issue 12: `std.fs.cwd()` and filesystem operations require `io: Io` parameter

**Affected files:**
- `src/config.zig:55`
- `src/core/config.zig:346, 378, 382, 388`
- `src/core/providers/copilot/client.zig:217, 375, 388, 423, 795, 825, 859`
- `src/core/pricing.zig:229, 373, 452, 460`
- `src/core/metrics.zig:249, 388`

**Current 0.15.2 implementation:**
```zig
// Opening files
const file = std.fs.cwd().openFile(path, .{}) catch |err| { ... };
const file = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| { ... };

// Directory operations
std.fs.cwd().makePath(pricing_dir) catch |err| { ... };
std.fs.cwd().deleteFile(tmp_path) catch {};
std.fs.cwd().rename(tmp_path, config_path) catch |err| { ... };

// Absolute path operations
if (std.fs.openFileAbsolute("/proc/self/statm", .{})) |file| { ... }
```

---

## Issue 13: `std.http.Client` now requires `io: Io` field

**Affected files:**
- `src/core/client.zig:187, 202`
- `test/integration/mock_client.zig:36`

**Current 0.15.2 implementation:**
```zig
.client = std.http.Client{ .allocator = allocator },
```

---

## Issue 14: `ArrayList.writer(allocator)` method removed

**Affected files (41 occurrences):**
- `src/core/auth/oauth.zig:281`
- `src/core/auth/oidc.zig:115`
- `src/core/providers/sap_ai_core/transformer.zig:351, 485`
- `src/core/providers/sap_ai_core/client.zig:261, 347`
- `src/core/providers/copilot/client.zig:417, 854`
- `src/core/providers/anthropic/transformer.zig:342, 770`
- `src/core/providers/openai/transformer.zig:223, 311, 640, 648, 673, 708, 716, 723`
- `src/core/errors.zig:188`
- `src/core/completion.zig:266, 351, 392, 401, 601`

**Current 0.15.2 implementation:**
```zig
buffer.writer(allocator).print("{f}", .{std.json.fmt(chunk, .{})}) catch return null;
try result.writer(allocator).print("%{X:0>2}", .{c});
try request_body.writer(self.allocator).print("{f}", .{std.json.fmt(request, .{})});
```

---

## Issue 15: `std.io.fixedBufferStream` removed

**Affected files:**
- `src/core/auth/callback_server.zig:330`
- `src/core/metrics.zig:454`

**Current 0.15.2 implementation:**
```zig
var fbs = std.io.fixedBufferStream(&html_buf);
const writer = fbs.writer();
writer.print(...);
```

---

## Summary Table

| # | Issue | Occurrences | Severity |
|---|-------|-------------|----------|
| 1 | `std.mem.trimRight` → `std.mem.trimEnd` | 4 | Low (rename) |
| 2 | `GeneralPurposeAllocator` → `DebugAllocator` | 6 | Medium |
| 3 | `std.process.args()` removed | 1 | Medium |
| 4 | `std.process.argsAlloc/argsFree` removed | 2 | Medium |
| 5 | `std.posix.getenv` removed | 18 | High |
| 6 | `std.posix.write` removed | 6 | Medium |
| 7 | `std.net` namespace removed | ~40 | **Critical** |
| 8 | `std.io` namespace removed | ~10 | High |
| 9 | `std.Thread.Mutex/RwLock/Condition` moved | ~15 | **Critical** |
| 10 | `std.Thread.sleep` removed | 3 | Medium |
| 11 | `std.time.timestamp/milliTimestamp/nanoTimestamp` removed | 8 | High |
| 12 | `std.fs` operations require `io: Io` | ~20 | **Critical** |
| 13 | `std.http.Client` requires `io: Io` | 3 | High |
| 14 | `ArrayList.writer(allocator)` removed | ~41 | **Critical** |
| 15 | `std.io.fixedBufferStream` removed | 2 | Medium |

**Total estimated occurrences: ~179**

---

## Architecture Impact

The most significant change in Zig 0.16 is the introduction of `std.Io` as a **pervasive parameter** required by most I/O operations (networking, filesystem, timers, mutexes). This fundamentally changes the architecture because:

1. **Every function that does I/O must receive an `io: std.Io` parameter** (or have access to one)
2. **Networking is entirely restructured** — `std.net.Server` → `std.Io.net.Server`, `std.net.Stream` → `std.Io.net.Stream`
3. **Synchronization primitives moved** — `std.Thread.Mutex.lock()` → requires `io` parameter
4. **Time/sleep** — Now uses `std.Io.Clock` and `std.Io.sleep()`

This means the server loop, all handlers, providers, and auth flows need to thread an `io` parameter throughout the call chain.
