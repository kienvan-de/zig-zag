// src/core/root.zig — public API surface for zig-zag-core
pub const config = @import("config.zig");
pub const errors = @import("errors.zig");
pub const log = @import("log.zig");
pub const metrics = @import("metrics.zig");
pub const pricing = @import("pricing.zig");
pub const utils = @import("utils.zig");
pub const provider = @import("provider.zig");
pub const client = @import("client.zig");
pub const curl = @import("curl.zig");
pub const worker_pool = @import("worker_pool.zig");
pub const auth = @import("auth/mod.zig");
pub const cache = @import("cache/token_cache.zig");
pub const app_cache = @import("cache/app_cache.zig");
pub const http = @import("http.zig");

// Provider types — for handler access (temporary, removed in STORY 4)
pub const openai_types = @import("providers/openai/types.zig");
pub const anthropic_types = @import("providers/anthropic/types.zig");

// Provider internals — temporary, needed by handlers until STORY 4 moves
// dispatch logic into completion.zig. Removed in STORY 5.
pub const providers = struct {
    pub const openai = struct {
        pub const client = @import("providers/openai/client.zig");
        pub const transformer = @import("providers/openai/transformer.zig");
        pub const types = @import("providers/openai/types.zig");
    };
    pub const anthropic = struct {
        pub const client = @import("providers/anthropic/client.zig");
        pub const transformer = @import("providers/anthropic/transformer.zig");
        pub const types = @import("providers/anthropic/types.zig");
    };
    pub const sap_ai_core = struct {
        pub const client = @import("providers/sap_ai_core/client.zig");
        pub const transformer = @import("providers/sap_ai_core/transformer.zig");
        pub const types = @import("providers/sap_ai_core/types.zig");
    };
    pub const hai = struct {
        pub const client = @import("providers/hai/client.zig");
    };
    pub const copilot = struct {
        pub const client = @import("providers/copilot/client.zig");
    };
};
