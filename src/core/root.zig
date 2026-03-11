//! zag-core — Transport-agnostic LLM proxy library.
//!
//! Public API surface for embedding zig-zag in any application.
//! The wrapper (HTTP server, CLI tool, etc.) injects dependencies
//! via `config.set()`, `worker_pool.setSubmitFn()`, and `log.setSink()`.
//!
//! ## Quick Start (Minimal Embedder)
//!
//! ```zig
//! const core = @import("zag-core");
//!
//! // Parse JSON, construct core Config (providers, log, cost_controls)
//! var cfg = try core.config.Config.parseFromJson(allocator, parsed);
//! core.config.set(&cfg, path);
//! core.cache.init(allocator);
//! core.metrics.load();
//! core.pricing.init(allocator, provider_names);
//!
//! try core.completion.chatComplete(writer, allocator, request);
//!
//! // Auth management
//! const status = core.config.checkAuthStatus(allocator, "copilot");
//! const result = core.config.initiateAuth(allocator, "copilot");
//! ```

// =========================================================================
// High-level completion API
// =========================================================================

/// Transport-agnostic LLM completion functions.
/// `chatComplete`, `messagesComplete`, `listModels`, `freeModels`.
pub const completion = @import("completion.zig");

// =========================================================================
// Core infrastructure
// =========================================================================

/// Configuration loader and global singleton (`set`/`get`).
pub const config = @import("config.zig");

/// Centralized error types and error response builder.
pub const errors = @import("errors.zig");

/// Logging facade — pluggable sink, stack-buffer formatting, stderr default.
pub const log = @import("log.zig");

/// CPU, memory, token, and cost tracking — persisted across restarts.
pub const metrics = @import("metrics.zig");

/// Per-token cost calculation with auto-updating price tables.
pub const pricing = @import("pricing.zig");

/// Utility functions: model parsing, budget enforcement.
pub const utils = @import("utils.zig");

/// Provider enum and helper functions.
pub const provider = @import("provider.zig");

/// Zig stdlib HTTP client for upstream provider calls.
pub const client = @import("client.zig");

/// System curl wrapper for TLS-constrained servers (SAP IAS).
pub const curl = @import("curl.zig");

/// Worker pool facade — pluggable task submission.
pub const worker_pool = @import("worker_pool.zig");

/// Authentication modules (OIDC, OAuth, PKCE, callback server).
pub const auth = @import("auth/mod.zig");

/// OAuth token caching.
pub const cache = @import("cache/token_cache.zig");

/// Application-level cache (e.g. server port for FFI).
pub const app_cache = @import("cache/app_cache.zig");

// =========================================================================
// Provider types — for callers building request/response structs
// =========================================================================

/// OpenAI request/response type definitions.
pub const openai_types = @import("providers/openai/types.zig");

/// Anthropic request/response type definitions.
pub const anthropic_types = @import("providers/anthropic/types.zig");

