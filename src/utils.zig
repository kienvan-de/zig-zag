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
const errors = @import("errors.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const metrics = @import("metrics.zig");

/// Parsed model information
pub const ModelInfo = struct {
    provider: []const u8,
    model: []const u8,
};

/// Model parsing errors — defined in errors.zig
pub const ModelParseError = @import("errors.zig").ModelParseError;

/// Parse model string in format "provider/model-name"
/// Examples:
///   "anthropic/claude-3-5-sonnet-latest" -> { .provider = .anthropic, .model = "claude-3-5-sonnet-latest" }
///   "openai/gpt-4" -> { .provider = .openai, .model = "gpt-4" }
///   "anthropic/models/claude" -> { .provider = .anthropic, .model = "models/claude" }
///
/// Caller is responsible for freeing model_info.model using the same allocator
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

/// Check if the budget period has expired at startup and reset if needed.
/// Called once after metrics are loaded, before the server accepts requests.
/// Ensures the macOS app displays correct (post-reset) stats immediately on launch.
pub fn checkBudgetPeriodOnStartup(config: *const config_mod.Config) void {
    checkAndResetBudgetPeriod(config);
}

/// Check cost controls and reject request if budget exceeded.
/// Returns true if the request was rejected (caller should return immediately).
/// Returns false if the request is allowed to proceed.
pub fn enforceBudget(
    config: *const config_mod.Config,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
) !bool {
    if (!config.cost_controls.enabled) return false;

    // Check if budget period has expired and reset if needed
    checkAndResetBudgetPeriod(config);

    const snap = metrics.snapshot();
    const total_cost = snap.input_cost + snap.output_cost;
    if (total_cost >= config.cost_controls.budget) {
        log.warn("Budget exceeded: ${d:.6} >= ${d:.6}, rejecting request", .{ total_cost, config.cost_controls.budget });
        const error_json = try errors.createErrorResponse(
            allocator,
            "Budget exceeded. Cost controls are enabled and the budget limit has been reached.",
            .rate_limit_error,
            "budget_exceeded",
        );
        defer allocator.free(error_json);
        try http.sendJsonResponse(connection, .too_many_requests, error_json);
        return true;
    }

    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
