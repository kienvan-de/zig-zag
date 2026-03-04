# TASKS.md — Statistics Display & Cost Controls

## Overview

Add configurable display options for statistics rows in the macOS menu bar app, and lay the groundwork for cost budget controls. Also fix button clickable area issue.

### Config Shape

```json
{
  "statistics": {
    "show_performance": true,
    "show_llm": true,
    "show_cost": true
  },
  "cost_controls": {
    "enabled": false,
    "budget": 10.00,
    "days_duration": 30
  }
}
```

### Row Visibility Rules

| Row | Content | Controlled by |
|-----|---------|---------------|
| 1. Status | Port, Uptime, Version | Always visible |
| 2. Performance | RAM, CPU, Network | `statistics.show_performance` (default: `true`) |
| 3. LLM | Providers, Input/Output tokens | `statistics.show_llm` (default: `true`) |
| 4. Cost | Total cost, Input/Output cost | See cost logic below |
| 5. Actions | Start/Stop, Quit buttons | Always visible |

### Cost Row Logic

| `show_cost` | `cost_controls.enabled` | Row visible? | Total cost label |
|-------------|------------------------|--------------|------------------|
| `false` | `false` | ❌ Hidden | — |
| `true` | `false` | ✅ Shown | `$1.23` (total spent) |
| _any_ | `true` | ✅ Always shown | `$8.77 left` (remaining = budget - total) |

When `cost_controls.enabled = true`, it **overrides** `show_cost` — the row is always visible.

---

## Tasks

### Task 1: Add config structs in Zig

**File:** `src/config.zig`

- [ ] Add `StatisticsConfig` struct:
  ```zig
  pub const StatisticsConfig = struct {
      show_performance: bool = true,
      show_llm: bool = true,
      show_cost: bool = true,
  };
  ```
- [ ] Add `CostControlsConfig` struct:
  ```zig
  pub const CostControlsConfig = struct {
      enabled: bool = false,
      budget: f32 = 0.0,
      days_duration: u32 = 0, // 0 = no reset (lifetime budget)
  };
  ```
- [ ] Add both to `Config` struct:
  ```zig
  statistics: StatisticsConfig,
  cost_controls: CostControlsConfig,
  ```
- [ ] Parse `"statistics"` section in `loadFromFile()` (optional, with defaults)
- [ ] Parse `"cost_controls"` section in `loadFromFile()` (optional, with defaults)

---

### Task 2: Expose config via C API

**Files:** `src/lib.zig`, `include/zig-zag.h`

- [ ] Add fields to `CServerStats`:
  ```c
  // Statistics display options
  bool show_performance;
  bool show_llm;
  bool show_cost;

  // Cost controls
  bool cost_controls_enabled;
  float cost_budget;
  ```
- [ ] Populate new fields in `getServerStats()` from config
- [ ] Update zeroed return (server not running) with defaults
- [ ] Update C header `CServerStats` typedef to match

**Why in `CServerStats`?** The config is loaded by the server thread. Exposing it through the existing stats struct avoids a separate C API call and keeps the polling model simple — one call gets everything.

---

### Task 3: Update Swift model

**File:** `ui/macos/zig-zag/zig-zag/ContentView.swift`

- [ ] Add fields to `ServerStats`:
  ```swift
  // Statistics display options
  var showPerformance: Bool = true
  var showLLM: Bool = true
  var showCost: Bool = true

  // Cost controls
  var costControlsEnabled: Bool = false
  var costBudget: Float = 0.0
  ```
- [ ] Map from `CServerStats` in `init(_ cStats:)`
- [ ] Add computed property:
  ```swift
  var formattedTotalCostDisplay: String {
      if costControlsEnabled {
          let remaining = costBudget - totalCost
          return formatCost(remaining) + " left"
      }
      return formattedTotalCost
  }
  ```
- [ ] Add computed property for cost color:
  ```swift
  var costColor: Color {
      guard costControlsEnabled else { return .primary }
      let remaining = costBudget - totalCost
      let ratio = remaining / costBudget
      if ratio <= 0 { return .red }
      if ratio <= 0.2 { return .orange }
      return .primary
  }
  ```
- [ ] Update mock data

---

### Task 4: Update UI — conditional row visibility

**File:** `ui/macos/zig-zag/zig-zag/ContentView.swift`

- [ ] Wrap `statsRow` (row 2) with:
  ```swift
  if serverState.stats.showPerformance { ... }
  ```
- [ ] Wrap `llmRow` (row 3) with:
  ```swift
  if serverState.stats.showLLM { ... }
  ```
- [ ] Wrap `costRow` (row 4) with:
  ```swift
  if serverState.stats.showCost || serverState.stats.costControlsEnabled { ... }
  ```
- [ ] Update `costRow` to use `formattedTotalCostDisplay` and `costColor`
- [ ] Change cost icon based on mode:
  - Normal mode (`cost_controls.enabled = false`): `dollarsign.circle` (current)
  - Budget mode (`cost_controls.enabled = true`): `gauge.with.needle` (remaining budget gauge)
- [ ] Cost icon color in budget mode:
  - Budget remaining > 20%: default (`.secondary`)
  - Budget remaining ≤ 20%: `.orange` (warning)
  - Budget remaining ≤ 0: `.red` (drained)
- [ ] Handle dividers — only show divider between visible rows (avoid double dividers)

---

### Task 5: Fix button clickable area

**File:** `ui/macos/zig-zag/zig-zag/ContentView.swift`

- [ ] Investigate why icon clicks don't register despite `.contentShape(Rectangle())`
- [ ] Fix: likely needs `.frame(maxWidth: .infinity, maxHeight: .infinity)` on the `HStack` inside the button, or move `.contentShape(Rectangle())` after `.frame()`
- [ ] Verify both icon and text are clickable for Start/Stop and Quit buttons

---

### Task 6: Add tooltips

**File:** `ui/macos/zig-zag/zig-zag/ContentView.swift`

Using SwiftUI's `.help("text")` modifier for native macOS tooltips.

- [ ] Row 1 — Status:
  | Element | Tooltip |
  |---------|---------|
  | Port | `"Server port"` |
  | Uptime | `"Server uptime"` |
  | Version | `"Core version"` |
- [ ] Row 2 — Performance:
  | Element | Tooltip |
  |---------|---------|
  | Memory | `"Memory usage"` |
  | CPU | `"CPU usage"` |
  | Network | `"Network I/O"` |
- [ ] Row 3 — LLM:
  | Element | Tooltip |
  |---------|---------|
  | Providers | `"Active / configured"` |
  | Input tokens | `"Input tokens"` |
  | Output tokens | `"Output tokens"` |
- [ ] Row 4 — Cost:
  | Element | Tooltip (normal mode) | Tooltip (budget mode) |
  |---------|----------------------|----------------------|
  | Total/Remaining | `"Total cost"` | `"Budget remaining"` |
  | Input cost | `"Input cost"` | `"Input cost"` |
  | Output cost | `"Output cost"` | `"Output cost"` |

Apply `.help()` on each `StatItem` or its wrapper. May need to add a `tooltip` parameter to `StatItem` component.

---

### Task 7: Build & verify

- [ ] `zig build exec:dbg` — CLI builds
- [ ] `zig build lib:dbg` — shared library builds
- [ ] Xcode build succeeds
- [ ] Test with default config (no `statistics`/`cost_controls` sections) — all rows visible, cost shows total
- [ ] Test with `"show_performance": false` — row 2 hidden
- [ ] Test with `"show_llm": false` — row 3 hidden
- [ ] Test with `"show_cost": false` — row 4 hidden
- [ ] Test with `"cost_controls": { "enabled": true, "budget": 10.0 }` — row 4 shows remaining budget

---

### Future (not in this PR)

- [ ] Server-side budget enforcement: reject requests in `handlers/chat.zig` when `total_cost >= budget`
- [ ] HTTP 429 response with budget exceeded message
- [ ] Budget reset duration (daily, weekly, monthly)
- [ ] Per-provider budget limits
- [ ] Cost alerts/notifications
