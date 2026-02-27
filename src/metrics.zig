//! Global metrics tracking for the zig-zag proxy server.
//!
//! This module provides thread-safe atomic counters for tracking:
//! - Network I/O bytes (rx/tx)
//! - Input/output tokens from LLM responses
//! - Input/output costs from LLM responses
//!
//! All counters are designed for high-frequency updates from multiple threads.
//! Cost values are stored as micro-dollars (millionths of a dollar) for precision
//! with atomic u64 operations.

const std = @import("std");

// ============================================================================
// Atomic Counters
// ============================================================================

/// Total bytes received from clients
var network_rx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total bytes sent to clients
var network_tx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total input/prompt tokens accumulated from LLM responses
var input_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total output/completion tokens accumulated from LLM responses
var output_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total input cost in micro-dollars (1/1,000,000 of a dollar)
var input_cost_micros: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total output cost in micro-dollars (1/1,000,000 of a dollar)
var output_cost_micros: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// ============================================================================
// Public API
// ============================================================================

/// Add to the network receive counter
pub fn addNetworkRx(bytes: u64) void {
    _ = network_rx_bytes.fetchAdd(bytes, .monotonic);
}

/// Add to the network transmit counter
pub fn addNetworkTx(bytes: u64) void {
    _ = network_tx_bytes.fetchAdd(bytes, .monotonic);
}

/// Add input tokens from an LLM response
pub fn addInputTokens(tokens: u64) void {
    _ = input_tokens.fetchAdd(tokens, .monotonic);
}

/// Add output tokens from an LLM response
pub fn addOutputTokens(tokens: u64) void {
    _ = output_tokens.fetchAdd(tokens, .monotonic);
}

/// Add input cost (in dollars, converted to micro-dollars internally)
pub fn addInputCost(dollars: f32) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = input_cost_micros.fetchAdd(micros, .monotonic);
}

/// Add output cost (in dollars, converted to micro-dollars internally)
pub fn addOutputCost(dollars: f32) void {
    const micros: u64 = @intFromFloat(dollars * 1_000_000.0);
    _ = output_cost_micros.fetchAdd(micros, .monotonic);
}

/// Get current network receive bytes
pub fn getNetworkRx() u64 {
    return network_rx_bytes.load(.monotonic);
}

/// Get current network transmit bytes
pub fn getNetworkTx() u64 {
    return network_tx_bytes.load(.monotonic);
}

/// Get total accumulated input tokens
pub fn getInputTokens() u64 {
    return input_tokens.load(.monotonic);
}

/// Get total accumulated output tokens
pub fn getOutputTokens() u64 {
    return output_tokens.load(.monotonic);
}

/// Get total accumulated input cost in dollars
pub fn getInputCost() f32 {
    const micros = input_cost_micros.load(.monotonic);
    return @as(f32, @floatFromInt(micros)) / 1_000_000.0;
}

/// Get total accumulated output cost in dollars
pub fn getOutputCost() f32 {
    const micros = output_cost_micros.load(.monotonic);
    return @as(f32, @floatFromInt(micros)) / 1_000_000.0;
}

/// Reset all counters to zero (useful for testing or server restart)
pub fn reset() void {
    network_rx_bytes.store(0, .monotonic);
    network_tx_bytes.store(0, .monotonic);
    input_tokens.store(0, .monotonic);
    output_tokens.store(0, .monotonic);
    input_cost_micros.store(0, .monotonic);
    output_cost_micros.store(0, .monotonic);
}

// ============================================================================
// Snapshot for stats reporting
// ============================================================================

pub const Snapshot = struct {
    network_rx_bytes: u64,
    network_tx_bytes: u64,
    input_tokens: u64,
    output_tokens: u64,
    input_cost: f32,
    output_cost: f32,
};

/// Get a consistent snapshot of all metrics
pub fn snapshot() Snapshot {
    return .{
        .network_rx_bytes = getNetworkRx(),
        .network_tx_bytes = getNetworkTx(),
        .input_tokens = getInputTokens(),
        .output_tokens = getOutputTokens(),
        .input_cost = getInputCost(),
        .output_cost = getOutputCost(),
    };
}
