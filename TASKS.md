# TASKS.md - Implementation Tasks

## Story 0: Configuration Design & Implementation

### Status: ✅ Complete

### Acceptance Criteria
- [x] Define HAI config structure (works with existing ProviderConfig)
- [x] Create `src/cache/app_cache.zig` for generic app-level caching
- [x] Replace `running` bool with `ServerStatus` enum in `CServerStats`
- [x] Add `error_code` field to `CServerStats` for UI error reporting

### Tasks

#### Task 0.1: Update `include/zig-zag.h` ✅
- [x] Add `ServerStatus` enum:
  - `ServerStatusStopped = 0`
  - `ServerStatusStarting = 1`
  - `ServerStatusRunning = 2`
  - `ServerStatusError = 3`
- [x] Add `ServerErrorCode` enum:
  - `ServerErrorNone = 0`
  - `ServerErrorConfigLoadFailed = 1`
  - `ServerErrorPortInUse = 2`
  - `ServerErrorWorkerPoolInitFailed = 3`
  - `ServerErrorLogInitFailed = 4`
  - `ServerErrorThreadSpawnFailed = 5`
  - `ServerErrorAuthFailed = 6`
- [x] Update `CServerStats`:
  - Replace `bool running` with `ServerStatus status`
  - Add `ServerErrorCode error_code`

#### Task 0.2: Update `src/lib.zig` ✅
- [x] Add `ServerStatus` enum matching C header
- [x] Add `ServerErrorCode` enum matching C header
- [x] Update `CServerStats` extern struct to match C header
- [x] Add global atomic `server_status` variable
- [x] Add global atomic `server_error_code` variable
- [x] Update `startServer()`:
  - Set status to `Starting` before spawn
  - Return true (actual status tracked by atomics)
- [x] Update `serverThreadFn()`:
  - Set status to `Running` after successful init
  - Set status to `Error` + error_code on failure
- [x] Update `stopServer()`:
  - Set status to `Stopped` after cleanup
- [x] Update `getServerStats()`:
  - Return status from atomic variable
  - Return error_code from atomic variable

#### Task 0.3: Create `src/cache/app_cache.zig` ✅
- [x] Create new file with module documentation
- [x] Implement global state:
  - `cache: ?std.StringHashMap([]const u8)`
  - `cache_allocator: ?std.mem.Allocator`
  - `mutex: std.Thread.Mutex`
- [x] Implement `init(allocator: std.mem.Allocator) void`
- [x] Implement `deinit() void`
- [x] Implement `get(allocator: std.mem.Allocator, key: []const u8) ?[]const u8`
  - Returns duplicated value (caller owns)
- [x] Implement `put(key: []const u8, value: []const u8) !void`
  - Duplicates both key and value
- [x] Implement `remove(key: []const u8) void`
- [x] Implement `contains(key: []const u8) bool` (bonus)

#### Task 0.4: Verification ✅
- [x] Run `zig build` - compilation succeeds
- [x] Run `zig build lib:dbg` - debug library builds
- [x] Run `zig build lib:rls` - release library builds
- [x] Added HAI config sample to `config.json.example`

### Notes
- HAI config uses existing `ProviderConfig` system - no changes to config.zig structure
- All HAI fields accessed via `getString()`, `getInt()` at runtime
- Config validation happens in Story 6 during provider init flow
- **Breaking change**: macOS Swift app must be updated (see Story 0.5)

### HAI Config Structure (for reference)
```json
{
  "providers": {
    "hai": {
      "api_url": "https://api.hyperspace.tools.sap",
      "client_id": "...",
      "auth_domain": "https://...",
      "oidc_config_path": "/.well-known/openid-configuration",
      "workspace_id": "...",
      "redirect_port": 8335,
      "redirect_path": "/auth-code",
      "models_path": "/models",
      "chat_completions_path": "/v1/chat/completions"
    }
  }
}
```

---

## Story 0.5: Update macOS Swift App for ServerStatus

### Status: 🔲 TODO

### Dependency
- Story 0 (must complete first)

### Tasks
- [ ] Update Swift code to use `ServerStatus` enum instead of `bool running`
- [ ] Handle `ServerErrorCode` and display appropriate error messages
- [ ] Update UI to show different states (Starting, Running, Error, Stopped)

---
