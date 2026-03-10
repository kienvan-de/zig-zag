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
const config_mod = @import("config.zig");
const log = @import("log.zig");
const metrics = @import("metrics.zig");

/// Result of parsing a `"provider/model-name"` string via `parseModelString`.
///
/// Both fields are heap-allocated copies owned by the caller. Free them with
/// the same `std.mem.Allocator` that was passed to `parseModelString`:
///
/// ```zig
/// const info = try parseModelString("openai/gpt-4", allocator);
/// defer allocator.free(info.provider);
/// defer allocator.free(info.model);
/// ```
pub const ModelInfo = struct {
    /// The provider segment before the first `/` (e.g. `"anthropic"`, `"openai"`).
    /// Heap-allocated — caller must free.
    provider: []const u8,
    /// The model segment after the first `/`. May itself contain slashes
    /// (e.g. `"models/claude"` from `"anthropic/models/claude"`).
    /// Heap-allocated — caller must free.
    model: []const u8,
};

/// Error set for `parseModelString`. Re-exported from `errors.zig`.
///
/// | Variant              | Cause                                                    |
/// |----------------------|----------------------------------------------------------|
/// | `InvalidModelFormat` | Input is empty (after trimming) or contains no `/`       |
/// | `EmptyProvider`      | The segment before the first `/` is empty or whitespace  |
/// | `EmptyModel`         | The segment after the first `/` is empty or whitespace   |
/// | `OutOfMemory`        | Allocator failed to duplicate the provider or model name |
pub const ModelParseError = @import("errors.zig").ModelParseError;

/// Parse a model string in the format `"provider/model-name"` into a `ModelInfo`.
///
/// The input is split on the **first** `/` only, so the model segment may
/// itself contain slashes (e.g. `"anthropic/models/claude"`).
///
/// Leading and trailing whitespace on both the full string and each segment
/// is trimmed before validation.
///
/// ## Examples
///
/// ```
/// "anthropic/claude-3-5-sonnet-latest" → { .provider = "anthropic", .model = "claude-3-5-sonnet-latest" }
/// "openai/gpt-4"                       → { .provider = "openai",    .model = "gpt-4" }
/// "anthropic/models/claude"            → { .provider = "anthropic", .model = "models/claude" }
/// ```
///
/// ## Ownership
///
/// Both `provider` and `model` in the returned `ModelInfo` are freshly
/// allocated copies. The **caller** must free them with the same `allocator`:
///
/// ```zig
/// defer allocator.free(info.provider);
/// defer allocator.free(info.model);
/// ```
///
/// ## Errors
///
/// Returns `ModelParseError` — see that type for the full set.
pub fn parseModelString(model_str: []const u8, allocator: std.mem.Allocator) !ModelInfo {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, model_str, " \t\n\r");

    if (trimmed.len == 0) return error.InvalidModelFormat;

    // Find first slash
    const slash_idx = std.mem.indexOfScalar(u8, trimmed, '/') orelse return error.InvalidModelFormat;

    // Extract provider and model parts
    const provider_str = std.mem.trim(u8, trimmed[0..slash_idx], " \t\n\r");
    const model_part = std.mem.trim(u8, trimmed[slash_idx + 1 ..], " \t\n\r");

    if (provider_str.len == 0) return error.EmptyProvider;
    if (model_part.len == 0) return error.EmptyModel;

    // Allocate and copy provider name
    const provider_name = try allocator.dupe(u8, provider_str);

    // Allocate and copy model name
    const model_name = try allocator.dupe(u8, model_part);

    return ModelInfo{
        .provider = provider_name,
        .model = model_name,
    };
}

// ============================================================================
// Budget Enforcement
// ============================================================================

/// Check if the budget period has expired and reset costs + tokens if so.
/// Shared by both startup check and per-request enforcement.
/// No-op when cost_controls is disabled or days_duration == 0 (lifetime budget).
fn checkAndResetBudgetPeriod(config: *const config_mod.Config) void {
    if (!config.cost_controls.enabled) return;
    if (config.cost_controls.days_duration == 0) return; // lifetime budget, never resets

    const ps = metrics.getPeriodStart();
    const now = std.time.timestamp();
    if (ps == 0) {
        metrics.resetCosts();
        log.info("Budget period initialized (duration: {d} days)", .{config.cost_controls.days_duration});
    } else {
        const elapsed_seconds = now - ps;
        const duration_seconds: i64 = @as(i64, @intCast(config.cost_controls.days_duration)) * 86400;
        if (elapsed_seconds >= duration_seconds) {
            metrics.resetCosts();
            log.info("Budget period expired, costs and tokens reset (duration: {d} days)", .{config.cost_controls.days_duration});
        }
    }
}

/// Check whether the current budget period has expired and, if so, reset
/// accumulated costs **and** token counts so the new period starts fresh.
///
/// Call this **once**, right after `metrics.load()` and before the server
/// begins accepting requests. This covers the case where the proxy was
/// offline when the period rolled over — without this call the stale totals
/// from the previous period would carry over.
///
/// No-op when `cost_controls.enabled` is `false` or `days_duration` is `0`
/// (lifetime budget, which never resets).
///
/// The macOS menu-bar app reads metrics immediately on launch, so calling
/// this early ensures it displays correct (post-reset) statistics.
pub fn checkBudgetPeriodOnStartup(config: *const config_mod.Config) void {
    checkAndResetBudgetPeriod(config);
}

/// Error set returned by `enforceBudget`.  Re-exported from `errors.zig`
/// so callers can reference `utils.BudgetError` without a separate import.
pub const BudgetError = @import("errors.zig").BudgetError;

/// Enforce the configured spending budget on every incoming chat/messages request.
///
/// 1. If `cost_controls.enabled` is `false`, returns immediately (no-op).
/// 2. Checks whether the budget period has expired and resets costs/tokens
///    if necessary (delegates to `checkAndResetBudgetPeriod`).
/// 3. Compares total accumulated cost (`input_cost + output_cost`) against
///    `cost_controls.budget`. If the limit has been reached or exceeded,
///    returns `error.BudgetExceeded` — the caller should respond with
///    HTTP `429 Too Many Requests`.
///
/// This function is intended to be called at the **start** of every
/// `/v1/chat/completions` and `/v1/messages` handler invocation.
pub fn enforceBudget(config: *const config_mod.Config) BudgetError!void {
    if (!config.cost_controls.enabled) return;

    // Check if budget period has expired and reset if needed
    checkAndResetBudgetPeriod(config);

    const snap = metrics.snapshot();
    const total_cost = snap.input_cost + snap.output_cost;
    if (total_cost >= config.cost_controls.budget) {
        log.warn("Budget exceeded: ${d:.6} >= ${d:.6}, rejecting request", .{ total_cost, config.cost_controls.budget });
        return error.BudgetExceeded;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
