//! Global metrics tracking for the zig-zag proxy server.
//!
//! This module provides thread-safe atomic counters for tracking:
//! - Network I/O bytes (rx/tx)
//! - Total tokens from LLM responses
//!
//! All counters are designed for high-frequency updates from multiple threads.

const std = @import("std");

// ============================================================================
// Atomic Counters
// ============================================================================

/// Total bytes received from clients
var network_rx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total bytes sent to clients
var network_tx_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Total tokens accumulated from LLM responses
var total_tokens: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

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

/// Add tokens from an LLM response
pub fn addTokens(tokens: u64) void {
    _ = total_tokens.fetchAdd(tokens, .monotonic);
}

/// Get current network receive bytes
pub fn getNetworkRx() u64 {
    return network_rx_bytes.load(.monotonic);
}

/// Get current network transmit bytes
pub fn getNetworkTx() u64 {
    return network_tx_bytes.load(.monotonic);
}

/// Get total accumulated tokens
pub fn getTotalTokens() u64 {
    return total_tokens.load(.monotonic);
}

/// Reset all counters to zero (useful for testing or server restart)
pub fn reset() void {
    network_rx_bytes.store(0, .monotonic);
    network_tx_bytes.store(0, .monotonic);
    total_tokens.store(0, .monotonic);
}

// ============================================================================
// Snapshot for stats reporting
// ============================================================================

pub const Snapshot = struct {
    network_rx_bytes: u64,
    network_tx_bytes: u64,
    total_tokens: u64,
};

/// Get a consistent snapshot of all metrics
pub fn snapshot() Snapshot {
    return .{
        .network_rx_bytes = getNetworkRx(),
        .network_tx_bytes = getNetworkTx(),
        .total_tokens = getTotalTokens(),
    };
}
