# TASKS.md - Implementation Tasks

## Story 0.5: Update macOS Swift App for ServerStatus

### Status: ✅ Complete

### Acceptance Criteria
- [ ] Update Swift code to use `ServerStatus` enum instead of `bool running`
- [ ] Handle `ServerErrorCode` and display appropriate error messages to user
- [ ] Update UI to show different states (Stopped/Starting/Running/Error)

### UI State Mapping

| Status | Globe Color | Text | Stats Shown | Buttons |
|--------|-------------|------|-------------|---------|
| **Stopped** | Red | "Stopped" | No | Start ✓, Stop ✗ |
| **Starting** | Yellow | "Starting..." | No | Start ✗, Stop ✗ |
| **Running** | Green | ":{port}" | Yes | Start ✗, Stop ✓ |
| **Error** | Red | Error message | No | Start ✓, Stop ✗ |

### Error Messages

| Error Code | Display Text |
|------------|--------------|
| `ConfigLoadFailed` | "Config load failed" |
| `PortInUse` | "Port in use" |
| `WorkerPoolInitFailed` | "Worker pool init failed" |
| `LogInitFailed` | "Log init failed" |
| `ThreadSpawnFailed` | "Thread spawn failed" |
| `AuthFailed` | "Auth failed" |

### Tasks

#### Task 0.5.1: Update `ServerStats` struct in `ContentView.swift` ✅
- [x] Replace `var running: Bool = false` with:
  - `var status: ServerStatus = ServerStatusStopped`
  - `var errorCode: ServerErrorCode = ServerErrorNone`
- [x] Update `init(_ cStats: CServerStats)` to read new fields
- [x] Add computed property `var isRunning: Bool` for convenience
- [x] Add computed property `var isStarting: Bool` for convenience
- [x] Add computed property `var isStopped: Bool` for convenience
- [x] Add computed property `var hasError: Bool` for convenience

#### Task 0.5.2: Add error message helper in `ContentView.swift` ✅
- [x] Add computed property `var errorMessage: String?` to `ServerStats`
- [x] Map each `ServerErrorCode` to user-friendly message

#### Task 0.5.3: Update status row in `ContentView.swift` ✅
- [x] Update globe color logic:
  - Stopped → Red
  - Starting → Yellow
  - Running → Green
  - Error → Red
- [x] Update status text logic:
  - Stopped → "Stopped"
  - Starting → "Starting..."
  - Running → ":{port}"
  - Error → error message

#### Task 0.5.4: Update stats visibility in `ContentView.swift` ✅
- [x] Change `if serverState.stats.running` to `if serverState.stats.isRunning`
- [x] Only show stats rows when Running

#### Task 0.5.5: Update action buttons in `ContentView.swift` ✅
- [x] Disable Start button when Starting or Running
- [x] Disable Stop button when Stopped, Starting, or Error
- [x] Keep button text as "Start"/"Stop" (no "Retry")
- [x] Add opacity feedback for disabled state

#### Task 0.5.6: Update `ServerState.swift` ✅
- [x] Update `stop()` to refresh stats from Zig (get stopped status)
- [x] Update `refresh()` to stop polling when server is not running/starting

#### Task 0.5.7: Update mock data for Preview ✅
- [x] Update `ServerStats.mock` to use new status field
- [x] Add `mockStopped` state
- [x] Add `mockStarting` state
- [x] Add `mockError` state

#### Task 0.5.8: Build and test
- [x] Run `zig build lib:dbg` to copy latest header
- [x] Build macOS app in Xcode
- [x] Test all states: Stopped → Starting → Running → Stop
- [x] Test error state (e.g., invalid config)

### Files Modified
- `ui/macos/zig-zag/zig-zag/ContentView.swift` ✅
- `ui/macos/zig-zag/zig-zag/ServerState.swift` ✅
- `ui/macos/zig-zag/zig-zag/zig_zagApp.swift` ✅ (menu bar icon)

### Dependencies
- Story 0 (Config Design) ✅ Complete

### Notes
- Header file `zig-zag.h` already updated from Story 0
- Future story: Add heartbeat animation for Starting state
