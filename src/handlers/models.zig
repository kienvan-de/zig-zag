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

//! Models Handler
//!
//! This module handles GET /v1/models requests and aggregates models from all
//! configured providers using comptime generics.
//! Fetches from providers in parallel using the IO worker pool.

const std = @import("std");

const http = @import("../http.zig");
const errors = @import("../errors.zig");
const config_mod = @import("../config.zig");
const OpenAI = @import("../providers/openai/types.zig");
const SapAiCore = @import("../providers/sap_ai_core/types.zig");
const provider_mod = @import("../provider.zig");
const log = @import("../log.zig");
const worker_pool = @import("../worker_pool.zig");

// Provider modules
const openai = struct {
    const client = @import("../providers/openai/client.zig");
    const transformer = @import("../providers/openai/transformer.zig");
};

const anthropic = struct {
    const client = @import("../providers/anthropic/client.zig");
    const transformer = @import("../providers/anthropic/transformer.zig");
};

const sap_ai_core = struct {
    const client = @import("../providers/sap_ai_core/client.zig");
    const transformer = @import("../providers/sap_ai_core/transformer.zig");
};

const hai = struct {
    const client = @import("../providers/hai/client.zig");
    const transformer = @import("../providers/openai/transformer.zig"); // HAI is OpenAI-compatible
};

const copilot = struct {
    const client = @import("../providers/copilot/client.zig");
    const transformer = @import("../providers/openai/transformer.zig"); // Copilot is OpenAI-compatible
};

/// Thread-safe allocator wrapper
const ThreadSafeAllocator = struct {
    backing_allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.alloc(self.backing_allocator.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.resize(self.backing_allocator.ptr, buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.backing_allocator.vtable.remap(self.backing_allocator.ptr, buf, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.backing_allocator.vtable.free(self.backing_allocator.ptr, buf, alignment, ret_addr);
    }
};

/// Result from a provider fetch task
const FetchResult = struct {
    provider_name: []const u8,
    models: ?[]OpenAI.Model,
    err: ?anyerror,
    elapsed_ms: i64,
};

/// Context passed to each fetch task
const FetchContext = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
    result: *FetchResult,
    wg: *worker_pool.WaitGroup,
};

/// Handle GET /v1/models request
pub fn handle(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    cfg: *const config_mod.Config,
) !void {
    _ = method;
    _ = path;
    _ = body; // GET request, no body needed

    const start_time = std.time.milliTimestamp();

    const provider_count = cfg.providers.count();
    log.info("GET /v1/models - starting parallel fetch from {d} providers", .{provider_count});

    if (provider_count == 0) {
        // No providers configured, return empty list
        try sendModelsResponse(allocator, connection, &[_]OpenAI.Model{});
        return;
    }

    // Get worker pool
    const pool = worker_pool.getPool() orelse {
        log.warn("Worker pool not initialized, falling back to sequential fetch", .{});
        try handleSequential(allocator, connection, cfg, start_time);
        return;
    };

    // Wrap allocator with thread-safe wrapper
    var ts_alloc = ThreadSafeAllocator{ .backing_allocator = allocator };
    const safe_allocator = ts_alloc.allocator();

    // Allocate arrays for contexts and results
    var contexts = try safe_allocator.alloc(FetchContext, provider_count);
    defer safe_allocator.free(contexts);

    var results = try safe_allocator.alloc(FetchResult, provider_count);
    defer safe_allocator.free(results);

    // Initialize results
    for (results) |*result| {
        result.* = .{
            .provider_name = "",
            .models = null,
            .err = null,
            .elapsed_ms = 0,
        };
    }

    // Create wait group
    var wg = worker_pool.WaitGroup.init();

    // Submit tasks for each provider
    var i: usize = 0;
    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const provider_config = entry.value_ptr;

        contexts[i] = .{
            .allocator = safe_allocator,
            .provider_name = provider_name,
            .provider_config = provider_config,
            .result = &results[i],
            .wg = &wg,
        };

        wg.add(1);
        pool.submit(fetchTask, @ptrCast(&contexts[i])) catch |err| {
            log.warn("Failed to submit task for provider '{s}': {}", .{ provider_name, err });
            results[i].err = err;
            results[i].provider_name = provider_name;
            wg.done();
        };

        i += 1;
    }

    // Wait for all tasks to complete
    wg.wait();

    // Aggregate results
    var all_models = std.ArrayList(OpenAI.Model){};
    defer all_models.deinit(safe_allocator);

    for (results[0..provider_count]) |result| {
        if (result.err) |err| {
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ result.provider_name, result.elapsed_ms, err });
            continue;
        }

        if (result.models) |model_list| {
            log.info("Provider '{s}' returned {d} models in {d}ms", .{ result.provider_name, model_list.len, result.elapsed_ms });

            for (model_list) |model| {
                try all_models.append(safe_allocator, model);
            }

            // Free the model list slice only - strings are moved to all_models
            safe_allocator.free(model_list);
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ result.provider_name, result.elapsed_ms });
        }
    }

    const total_elapsed = std.time.milliTimestamp() - start_time;
    log.info("GET /v1/models - completed in {d}ms, total models: {d}", .{ total_elapsed, all_models.items.len });

    // Send response then free model strings
    defer freeModelStrings(safe_allocator, all_models.items);
    try sendModelsResponse(allocator, connection, all_models.items);
}

/// Free allocated strings in model array
fn freeModelStrings(allocator: std.mem.Allocator, models: []const OpenAI.Model) void {
    for (models) |model| {
        allocator.free(model.id);
        // owned_by may be a static string ("anthropic", "model") or allocated
        // Check if it's one of the known static strings before freeing
        if (!isStaticOwnedBy(model.owned_by)) {
            allocator.free(model.owned_by);
        }
    }
}

/// Check if owned_by is a static string that shouldn't be freed
fn isStaticOwnedBy(owned_by: []const u8) bool {
    const static_values = [_][]const u8{ "anthropic", "model", "openai", "system" };
    for (static_values) |static_val| {
        if (std.mem.eql(u8, owned_by, static_val)) {
            return true;
        }
    }
    return false;
}

/// Task function for worker pool
fn fetchTask(ctx_ptr: *anyopaque) void {
    const ctx: *FetchContext = @ptrCast(@alignCast(ctx_ptr));
    defer ctx.wg.done();

    const start_time = std.time.milliTimestamp();
    ctx.result.provider_name = ctx.provider_name;

    ctx.result.models = fetchModelsForProvider(
        ctx.allocator,
        ctx.provider_name,
        ctx.provider_config,
    ) catch |err| {
        ctx.result.err = err;
        ctx.result.elapsed_ms = std.time.milliTimestamp() - start_time;
        return;
    };

    ctx.result.elapsed_ms = std.time.milliTimestamp() - start_time;
}

/// Fallback sequential fetch when worker pool is not available
fn handleSequential(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    cfg: *const config_mod.Config,
    start_time: i64,
) !void {
    var all_models = std.ArrayList(OpenAI.Model){};
    defer all_models.deinit(allocator);

    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const provider_name = entry.key_ptr.*;
        const provider_config = entry.value_ptr;

        const provider_start = std.time.milliTimestamp();

        const models = fetchModelsForProvider(allocator, provider_name, provider_config) catch |err| {
            const provider_elapsed = std.time.milliTimestamp() - provider_start;
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ provider_name, provider_elapsed, err });
            continue;
        };

        const provider_elapsed = std.time.milliTimestamp() - provider_start;

        if (models) |model_list| {
            defer {
                // Free model strings then the list
                freeModelStrings(allocator, model_list);
                allocator.free(model_list);
            }

            log.info("Provider '{s}' returned {d} models in {d}ms", .{ provider_name, model_list.len, provider_elapsed });

            for (model_list) |model| {
                try all_models.append(allocator, model);
            }
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ provider_name, provider_elapsed });
        }
    }

    const total_elapsed = std.time.milliTimestamp() - start_time;
    log.info("GET /v1/models - completed in {d}ms, total models: {d}", .{ total_elapsed, all_models.items.len });

    try sendModelsResponse(allocator, connection, all_models.items);
}

/// Send models response to client
fn sendModelsResponse(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    models: []const OpenAI.Model,
) !void {
    // Sort models by id alphabetically
    const sorted_models = try allocator.alloc(OpenAI.Model, models.len);
    defer allocator.free(sorted_models);
    @memcpy(sorted_models, models);

    std.mem.sort(OpenAI.Model, sorted_models, {}, struct {
        fn lessThan(_: void, a: OpenAI.Model, b: OpenAI.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    const response = OpenAI.ModelsResponse{
        .data = sorted_models,
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);

    try json_buf.writer(allocator).print("{f}", .{std.json.fmt(response, .{})});

    try http.sendJsonResponse(connection, .ok, json_buf.items);
}

/// Fetch models for a provider based on its type or compatibility
fn fetchModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]OpenAI.Model {
    // First check for "compatible" field (takes precedence for compatible providers)
    if (provider_config.getString("compatible")) |compatible| {
        if (std.mem.eql(u8, compatible, "openai")) {
            return try fetchModels(
                openai.client.OpenAIClient,
                openai.transformer,
                allocator,
                provider_name,
                provider_config,
            );
        } else if (std.mem.eql(u8, compatible, "anthropic")) {
            return try fetchModels(
                anthropic.client.AnthropicClient,
                anthropic.transformer,
                allocator,
                provider_name,
                provider_config,
            );
        }
        return null;
    }

    // Use provider_name as the provider type for native providers
    if (provider_mod.Provider.fromString(provider_name)) |native_provider| {
        return switch (native_provider) {
            .openai => try fetchModels(
                openai.client.OpenAIClient,
                openai.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .anthropic => try fetchModels(
                anthropic.client.AnthropicClient,
                anthropic.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .sap_ai_core => try fetchModels(
                sap_ai_core.client.SapAiCoreClient,
                sap_ai_core.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .hai => try fetchModels(
                hai.client.HaiClient,
                hai.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
            .copilot => try fetchModels(
                copilot.client.CopilotClient,
                copilot.transformer,
                allocator,
                provider_name,
                provider_config,
            ),
        };
    } else |_| {
        // Not a native provider and no compatible field
        return null;
    }
}

/// Generic function to fetch models using comptime client and transformer
fn fetchModels(
    comptime ClientType: type,
    comptime transformer: type,
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]OpenAI.Model {
    var client = try ClientType.init(allocator, provider_config);
    defer client.deinit();

    // Call listModels on the client
    const response = try client.listModels();

    // Handle null response (provider doesn't support models listing)
    if (@TypeOf(response) == ?void) {
        return null;
    }

    // For optional responses that are null
    if (@typeInfo(@TypeOf(response)) == .optional) {
        if (response == null) {
            return null;
        }
    }

    // Transform to OpenAI models with provider prefix
    const models = try transformer.transformModelsResponse(allocator, response, provider_name);

    // Deinit parsed response
    var r = response;
    r.deinit();

    return models;
}
