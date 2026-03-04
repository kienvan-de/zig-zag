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

---

## Pricing Engine

### Overview

Per-token cost calculation using CSV pricing files, with tiered pricing support and auto-update from GitHub.

### Pricing File Structure

```
pricing/                              # In GitHub repo
├── default.csv                       # Known models (global fallback)
├── openai.csv                        # OpenAI-specific (if differs from default)
├── anthropic.csv                     # Anthropic-specific
├── sap_ai_core.csv                   # SAP AI Core pricing
└── ...

~/.config/zig-zag/pricing/            # Local cache (downloaded from GitHub)
├── default.csv                       # Always loaded
├── openai.csv                        # Loaded only if openai configured
└── ...
```

### CSV Format

```csv
model,threshold,input_t1,output_t1,input_t2,output_t2
gpt-4o,0,0.0000025,0.00001,,
text-embedding-3-small,0,0.00000002,0,,
gemini-2.5-pro,200000,0.00000125,0.000005,0.0000025,0.00001
```

- All costs are **per token** (not per 1K)
- `threshold = 0` → no tiered pricing
- `threshold > 0` → tier 2 rates apply after this many tokens
- `0` value → explicitly zero cost (e.g., output cost for embedding models)
- Empty value → field not set; at calculation time, null t2 falls back to t1

### Lookup Order

For a request to `sap_ai_core/gpt-4o`:
1. `sap_ai_core.csv` → look for `gpt-4o` (provider-specific)
2. `default.csv` → look for `gpt-4o` (global fallback)
3. Not found → cost = 0

### Cost Calculation

For `P` input tokens, `C` output tokens, threshold `T`:

**Non-tiered** (`T = 0` or t2 is null):
```
input_cost  = P × input_t1
output_cost = C × output_t1
```

**Tiered** (`T > 0` and t2 is set):
```
if P <= T: input_cost  = P × input_t1
else:      input_cost  = T × input_t1 + (P - T) × input_t2

if C <= T: output_cost = C × output_t1
else:      output_cost = T × output_t1 + (C - T) × output_t2
```

### Tasks

#### Task P1: Create pricing CSV files
- [ ] Create `pricing/` directory in repo
- [ ] Create `default.csv` with known model costs (OpenAI, Anthropic public pricing)
- [ ] Create `sap_ai_core.csv` from SAP AI Core models endpoint data
- [ ] All costs in per-token format

#### Task P2: Pricing parser
**File:** `src/pricing.zig`

- [ ] Define `CostEntry` struct:
  ```zig
  pub const CostEntry = struct {
      threshold: u64,        // 0 = no tiering
      input_t1: f64,
      output_t1: f64,
      input_t2: ?f64,        // null = use t1
      output_t2: ?f64,       // null = use t1
  };
  ```
- [ ] Parse CSV: skip empty lines, trim whitespace
- [ ] Value rules: number = use it (including 0), empty = null
- [ ] Build `HashMap([]const u8, CostEntry)` per file

#### Task P3: Pricing loader
**File:** `src/pricing.zig`

- [ ] Load from `~/.config/zig-zag/pricing/`
- [ ] Always load `default.csv`
- [ ] Load `{provider}.csv` only for providers in config
- [ ] Expose: `pub fn getCost(provider: []const u8, model: []const u8) ?CostEntry`
- [ ] Lookup: provider CSV → default.csv → null

#### Task P4: Cost calculation
**File:** `src/pricing.zig`

- [ ] `pub fn calculateCost(entry: CostEntry, input_tokens: u64, output_tokens: u64) struct { input_cost: f64, output_cost: f64 }`
- [ ] Tiered logic: split at threshold boundary
- [ ] Non-tiered: simple multiply
- [ ] Null t2 falls back to t1

#### Task P5: Integrate into chat handler
**File:** `src/handlers/chat.zig`

- [ ] After response with `usage.prompt_tokens` and `usage.completion_tokens`
- [ ] Look up cost entry: `pricing.getCost(provider_name, model_name)`
- [ ] Calculate cost
- [ ] Add to `metrics.zig` accumulators (`input_cost`, `output_cost`)

#### Task P6: Pricing auto-update from GitHub
- [ ] On startup, check `~/.config/zig-zag/pricing/` exists
- [ ] If not → download all CSVs from GitHub raw URL → save locally
- [ ] If exists → fetch checksums → compare with local
- [ ] Different → download updated files
- [ ] Network failure → use local files silently (offline-friendly)

#### Task P7: Build & verify
- [ ] Unit tests for CSV parsing
- [ ] Unit tests for cost calculation (tiered and non-tiered)
- [ ] Unit tests for lookup order (provider → default → null)
- [ ] Integration test with mock pricing CSV
- [ ] Verify costs accumulate in metrics and show in UI
