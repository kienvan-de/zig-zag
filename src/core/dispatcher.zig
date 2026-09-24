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

//! Core Dispatcher
//!
//! Two public entry points:
//!
//!   complete   — smart-routing loop + budget enforcement for any completion
//!                protocol (chat / messages / responses). Calls a per-protocol
//!                `run` function supplied as a comptime parameter.
//!
//!   listModels — fetch the model catalogue from all configured providers
//!   freeModels — free the slice returned by listModels

const std = @import("std");
const time = @import("time.zig");
const sync = @import("sync.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const smart_routing = @import("smart_routing.zig");
const worker_pool = @import("worker_pool.zig");
const provider_mod = @import("provider.zig");
const openai_common = @import("providers/openai/types.zig");
const errors_mod = @import("errors.zig");

const openai = struct {
    const client = @import("providers/openai/client.zig");
    const chat_transformer = @import("providers/openai/chat_transformer.zig");
};
const anthropic = struct {
    const client = @import("providers/anthropic/client.zig");
    const transformer = @import("providers/anthropic/transformer.zig");
};
const sap_ai_core = struct {
    const client = @import("providers/sap_ai_core/client.zig");
    const transformer = @import("providers/sap_ai_core/transformer.zig");
};
const hai = struct {
    const client = @import("providers/hai/client.zig");
};
const copilot = struct {
    const client = @import("providers/copilot/client.zig");
};
const google_ai_studio = struct {
    const client = @import("providers/google_ai_studio/client.zig");
    const transformer = @import("providers/google_ai_studio/transformer.zig");
};

// ============================================================================
// complete — smart-routing loop for completion protocols
// ============================================================================

/// Enforce budget, acquire smart-routing, and run `inner` with automatic model
/// rollover on retryable errors. `inner` must have the signature:
///
///   fn(writer: anytype, err_writer: anytype, allocator, cfg, request: anytype, model: []const u8) anyerror!void
///
/// `writer` receives the success response body; `err_writer` receives the
/// upstream error body. It is cleared before every attempt, so after the loop
/// it holds the final attempt's error body — or is empty when the final attempt
/// failed without producing a parsed upstream body.
///
/// `request` must have a `.model: []const u8` field used for smart-routing lookup.
pub fn complete(
    comptime inner: anytype,
    writer: anytype,
    err_writer: anytype,
    allocator: std.mem.Allocator,
    request: anytype,
) !void {
    const cfg = config_mod.get();
    try utils.enforceBudget(cfg);

    const sr_handle = smart_routing.acquire();
    defer if (sr_handle) |h| h.release();
    const sr = if (sr_handle) |h| h.sr else null;
    const sr_group = if (sr) |s| s.lookup(request.model) else null;
    var current_model_buf: ?[]u8 = if (sr_group) |g| try sr.?.getCurrentModel(g, allocator) else null;
    defer if (current_model_buf) |buf| allocator.free(buf);
    var did_rollover = false;
    var rollover_count: usize = 0;
    const rollover_limit: usize = if (sr_group) |g| g.alternatives.len else 0;

    while (true) {
        const effective_model = if (current_model_buf) |buf| buf else request.model;

        // Reset the upstream-error buffer before each attempt. Only the pipeline's
        // .err branch writes into it; an attempt that fails via a plain Zig error
        // (e.g. HttpRequestFailed) leaves it untouched, so without this reset a
        // later attempt could surface a PREVIOUS attempt's error body with a
        // mismatched status.
        err_writer.clearRetainingCapacity();

        const dispatch_err = inner(writer, err_writer, allocator, cfg, request, effective_model);
        if (dispatch_err) |_| {
            if (did_rollover and sr != null) {
                sr.?.writeBack(allocator) catch |e| {
                    log.warn("[smart_routing] writeBack failed: {}", .{e});
                };
            }
            return;
        } else |err| {
            // Retryable = transient/server upstream statuses (and 404/408) per
            // errors.isRetryableUpstream, plus the legacy catch-all UpstreamError
            // and HttpRequestFailed (non-2xx whose error body failed to parse —
            // the upstream still failed, we just lost the structured body).
            const retryable = errors_mod.isRetryableUpstream(err) or
                err == error.UpstreamError or
                err == error.HttpRequestFailed;
            if (retryable and sr_group != null and rollover_count < rollover_limit) {
                log.warn("[smart_routing] Model '{s}' failed ({s}), attempting rollover ({d}/{d})...", .{ effective_model, @errorName(err), rollover_count + 1, rollover_limit });
                const next = sr.?.rollover(sr_group.?, allocator) catch null;
                if (next) |n| {
                    if (current_model_buf) |old| allocator.free(old);
                    current_model_buf = n;
                    did_rollover = true;
                    rollover_count += 1;
                    log.info("[smart_routing] Rolling over to '{s}'", .{n});
                    continue;
                } else {
                    log.err("[smart_routing] All alternatives exhausted for '{s}'", .{request.model});
                }
            } else if (retryable and sr_group != null and rollover_count >= rollover_limit) {
                log.err("[smart_routing] Rollover limit reached ({d}) for '{s}'", .{ rollover_limit, request.model });
            }
            return err;
        }
    }
    unreachable;
}

// ============================================================================
// listModels / freeModels
// ============================================================================

const ThreadSafeAllocator = struct {
    backing_allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

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

const FetchResult = struct {
    provider_name: []const u8,
    models: ?[]openai_common.Model,
    err: ?anyerror,
    elapsed_ms: i64,
};

const FetchContext = struct {
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
    result: *FetchResult,
    wg: *worker_pool.WaitGroup,
};

/// Fetch the model catalogue from all configured providers.
///
/// When a worker pool is available, providers are queried **in parallel**;
/// otherwise the function falls back to sequential fetching. Individual
/// provider failures are logged and skipped — the returned slice contains
/// models from all providers that responded successfully, sorted
/// alphabetically by model `id`.
///
/// The returned slice is **caller-owned**. Free it with `freeModels()`.
pub fn listModels(allocator: std.mem.Allocator) ![]openai_common.Model {
    const cfg = config_mod.get();
    const provider_count = cfg.providers.count();

    log.info("GET /v1/models - starting fetch from {d} providers", .{provider_count});

    if (provider_count == 0) {
        return try allocator.alloc(openai_common.Model, 0);
    }

    if (!worker_pool.isAvailable()) {
        log.warn("Worker pool not initialized, falling back to sequential fetch", .{});
        return try listModelsSequential(allocator, cfg);
    }

    var ts_alloc = ThreadSafeAllocator{ .backing_allocator = allocator };
    const safe_allocator = ts_alloc.allocator();

    var contexts = try safe_allocator.alloc(FetchContext, provider_count);
    defer safe_allocator.free(contexts);

    var results = try safe_allocator.alloc(FetchResult, provider_count);
    defer safe_allocator.free(results);

    for (results) |*result| {
        result.* = .{ .provider_name = "", .models = null, .err = null, .elapsed_ms = 0 };
    }

    var wg = worker_pool.WaitGroup.init();

    var i: usize = 0;
    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const pname = entry.key_ptr.*;
        const pconfig = entry.value_ptr;
        contexts[i] = .{
            .allocator = safe_allocator,
            .provider_name = pname,
            .provider_config = pconfig,
            .result = &results[i],
            .wg = &wg,
        };
        wg.add(1);
        worker_pool.submit(&fetchTask, @ptrCast(&contexts[i])) catch |err| {
            log.warn("Failed to submit task for provider '{s}': {}", .{ pname, err });
            results[i].err = err;
            results[i].provider_name = pname;
            wg.done();
        };
        i += 1;
    }

    wg.wait();

    var all_models = std.ArrayList(openai_common.Model).empty;
    defer all_models.deinit(safe_allocator);

    for (results[0..provider_count]) |result| {
        if (result.err) |err| {
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ result.provider_name, result.elapsed_ms, err });
            continue;
        }
        if (result.models) |model_list| {
            log.info("Provider '{s}' returned {d} models in {d}ms", .{ result.provider_name, model_list.len, result.elapsed_ms });
            for (model_list) |m| try all_models.append(safe_allocator, m);
            safe_allocator.free(model_list);
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ result.provider_name, result.elapsed_ms });
        }
    }

    log.info("GET /v1/models - total models: {d}", .{all_models.items.len});

    appendGroupModels(safe_allocator, &all_models) catch |err| {
        log.warn("Failed to append smart routing models: {}", .{err});
    };

    const sorted = try allocator.alloc(openai_common.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_common.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_common.Model, b: openai_common.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return sorted;
}

/// Free a model slice previously returned by `listModels`.
pub fn freeModels(allocator: std.mem.Allocator, models: []openai_common.Model) void {
    for (models) |m| {
        allocator.free(m.id);
        allocator.free(m.owned_by);
    }
    allocator.free(models);
}

fn fetchTask(ctx_ptr: *anyopaque) void {
    const ctx: *FetchContext = @ptrCast(@alignCast(ctx_ptr));
    defer ctx.wg.done();
    const start_time = time.milliTimestamp();
    ctx.result.provider_name = ctx.provider_name;
    ctx.result.models = fetchModelsForProvider(ctx.allocator, ctx.provider_name, ctx.provider_config) catch |err| {
        ctx.result.err = err;
        ctx.result.elapsed_ms = time.milliTimestamp() - start_time;
        return;
    };
    ctx.result.elapsed_ms = time.milliTimestamp() - start_time;
}

fn appendGroupModels(allocator: std.mem.Allocator, list: *std.ArrayList(openai_common.Model)) !void {
    const handle = smart_routing.acquire() orelse return;
    defer handle.release();
    for (handle.sr.groups) |*g| {
        if (g.api_key.len == 0) continue;
        try list.append(allocator, openai_common.Model{
            .id = try allocator.dupe(u8, g.api_key),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, "zig-zag"),
        });
    }
}

fn listModelsSequential(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ![]openai_common.Model {
    var all_models = std.ArrayList(openai_common.Model).empty;
    defer all_models.deinit(allocator);

    var provider_iter = cfg.providers.iterator();
    while (provider_iter.next()) |entry| {
        const pname = entry.key_ptr.*;
        const pconfig = entry.value_ptr;
        const provider_start = time.milliTimestamp();
        const models = fetchModelsForProvider(allocator, pname, pconfig) catch |err| {
            const elapsed = time.milliTimestamp() - provider_start;
            log.warn("Provider '{s}' failed after {d}ms: {}", .{ pname, elapsed, err });
            continue;
        };
        const elapsed = time.milliTimestamp() - provider_start;
        if (models) |model_list| {
            log.info("Provider '{s}' returned {d} models in {d}ms", .{ pname, model_list.len, elapsed });
            for (model_list) |m| try all_models.append(allocator, m);
            allocator.free(model_list);
        } else {
            log.debug("Provider '{s}' returned no models in {d}ms", .{ pname, elapsed });
        }
    }

    appendGroupModels(allocator, &all_models) catch |err| {
        log.warn("Failed to append smart routing models: {}", .{err});
    };

    const sorted = try allocator.alloc(openai_common.Model, all_models.items.len);
    @memcpy(sorted, all_models.items);
    std.mem.sort(openai_common.Model, sorted, {}, struct {
        fn lessThan(_: void, a: openai_common.Model, b: openai_common.Model) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return sorted;
}

fn fetchModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_common.Model {
    return fetchModelsForProviderInner(allocator, provider_name, provider_config) catch |err| {
        if (err == error.AuthRequired and utils.tryAutoReauth(allocator, provider_name)) {
            return fetchModelsForProviderInner(allocator, provider_name, provider_config);
        }
        return err;
    };
}

fn fetchModelsForProviderInner(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_common.Model {
    if (provider_config.getString("compatible")) |compatible| {
        const resolved = provider_mod.resolveCompatible(compatible) catch return null;
        return switch (resolved) {
            .openai    => try fetchModels(openai.client.OpenAIClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .anthropic => try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config),
            else       => null,
        };
    }

    if (provider_mod.Provider.fromString(provider_name)) |native_provider| {
        return switch (native_provider) {
            .openai => try fetchModels(openai.client.OpenAIClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .anthropic => try fetchModels(anthropic.client.AnthropicClient, anthropic.transformer, allocator, provider_name, provider_config),
            .sap_ai_core => try fetchModels(sap_ai_core.client.SapAiCoreClient, sap_ai_core.transformer, allocator, provider_name, provider_config),
            .hai => try fetchModels(hai.client.HaiClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .copilot => try fetchModels(copilot.client.CopilotClient, openai.chat_transformer, allocator, provider_name, provider_config),
            .google_ai_studio => try fetchModels(google_ai_studio.client.GoogleAiStudioClient, google_ai_studio.transformer, allocator, provider_name, provider_config),
        };
    } else |_| {
        return null;
    }
}

fn fetchModels(
    comptime ClientType: type,
    comptime transformer: type,
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: *const config_mod.ProviderConfig,
) !?[]openai_common.Model {
    var client = try ClientType.init(allocator, provider_config);
    defer client.deinit();

    const response = try client.listModels();

    if (@TypeOf(response) == ?void) return null;
    if (@typeInfo(@TypeOf(response)) == .optional) {
        if (response == null) return null;
    }

    const models = try transformer.transformModelsResponse(allocator, response, provider_name);
    var r = response;
    r.deinit();
    return models;
}
