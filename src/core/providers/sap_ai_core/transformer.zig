// SPDX-License-Identifier: Apache-2.0
//! Transformer for the SAP AI Core provider (orchestration envelope wire).
//!
//! The SAP wire wraps chat-format payloads (`config.modules.prompt_templating`
//! on the way out, `final_result` on the way in). Each flow converts its
//! inbound schema to/from that envelope.
//!
//! Four flows, named after the *inbound* schema. Every pub symbol is defined
//! here. Conversion helpers live in content.zig only.
//! Stream functions return typed event slices — callers own serialization.

const std = @import("std");
const common = @import("../openai/types.zig");

const Chat = @import("../openai/chat_types.zig");
const Messages = @import("../anthropic/types.zig");
const Responses = @import("../openai/responses_types.zig");
const Sap = @import("types.zig");
const content = @import("content.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the SAP models listing to inbound Model entries, prefixing ids with
/// the provider name. Only models with a latest non-deprecated version AND
/// the "orchestration" scenario are included.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Sap.SapModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var valid_count: usize = 0;
    for (response.value.resources) |sap_model| {
        if (content.isOrchestrationCapable(sap_model)) valid_count += 1;
    }

    var models = try allocator.alloc(common.Model, valid_count);
    var filled: usize = 0;
    errdefer {
        for (models[0..filled]) |m| {
            allocator.free(m.id);
            allocator.free(m.owned_by);
        }
        allocator.free(models);
    }

    for (response.value.resources) |sap_model| {
        if (!content.isOrchestrationCapable(sap_model)) continue;
        models[filled] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, sap_model.model }),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, sap_model.provider),
        };
        filled += 1;
    }

    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — chat wire in, SAP envelope out
// ============================================================================

pub const ChatStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ChatStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *ChatStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Inbound chat request → SAP envelope, pinned to model.
///
/// Chat.Request fields mapped:
///   model (pinned), messages → template (borrowed), tools → tools (borrowed),
///   tool_choice → tool_choice (borrowed), response_format → response_format
///   (borrowed), stream → stream.enabled,
///   temperature / max_completion_tokens / max_tokens / top_p → model.params.
/// Skipped: stream_options, n, presence_penalty, frequency_penalty, stop,
///   logit_bias, logprobs, top_logprobs, parallel_tool_calls, user, seed,
///   reasoning_effort, modalities, audio, store, metadata, prediction,
///   service_tier,
///   web_search_options, moderation, verbosity
///   (SAP envelope has no equivalent fields).
///   Sap.Request.placeholder_values and messages_history are left null
///   (no inbound chat equivalent).
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    const max_tokens: ?u32 = request.max_completion_tokens orelse request.max_tokens;
    const params = try content.buildParams(.{
        .temperature = request.temperature,
        .max_tokens = max_tokens,
        .top_p = request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = request.messages,
                        .tools = request.tools,
                        .tool_choice = request.tool_choice,
                        .response_format = request.response_format,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                .enabled = request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformChatRequest allocated: the params object.
/// All other fields borrow from the inbound request.
pub fn cleanupChatRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    if (request.config.modules.prompt_templating) |pt|
        if (pt.model.params) |p|
            content.freeParams(p, allocator);
}

/// SAP response → inbound chat response.
///
/// Sap.Response.final_result (Chat.Response) fields mapped:
///   id → id (duped), object → object (duped), created → created,
///   choices → choices (deep-copied via dupeResponseChoice),
///   usage → usage (direct copy), original_req.model → model (duped).
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures (SAP envelope fields, not chat wire).
///   Chat.Response: system_fingerprint, service_tier, metadata, moderation
///   (set to null — no SAP equivalent).
pub fn transformChatResponse(
    upstream_response: Sap.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    const final_result = upstream_response.final_result;

    const choices = try allocator.alloc(Chat.ResponseChoice, final_result.choices.len);
    var filled: usize = 0;
    errdefer {
        for (choices[0..filled]) |choice| {
            content.freeResponseMessage(allocator, choice.message);
            allocator.free(choice.finish_reason);
        }
        allocator.free(choices);
    }
    for (final_result.choices, 0..) |choice, i| {
        choices[i] = try content.dupeResponseChoice(allocator, choice);
        filled += 1;
    }

    const owned_id = try allocator.dupe(u8, final_result.id);
    errdefer allocator.free(owned_id);
    const owned_object = try allocator.dupe(u8, final_result.object);
    errdefer allocator.free(owned_object);
    const owned_model = try allocator.dupe(u8, original_req.model);

    return .{
        .id = owned_id,
        .object = owned_object,
        .created = final_result.created,
        .model = owned_model,
        .choices = choices,
        .usage = final_result.usage orelse .{
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
        },
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Free what transformChatResponse allocated.
pub fn cleanupChatResponse(inbound_response: Chat.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.object);
    allocator.free(inbound_response.model);
    for (inbound_response.choices) |choice| {
        content.freeResponseMessage(allocator, choice.message);
        allocator.free(choice.finish_reason);
    }
    allocator.free(inbound_response.choices);
}

/// One SAP SSE line → Chat.ChatStreamLineResult (typed StreamChunk slice).
///
/// The SAP envelope wraps a chat StreamChunk in `final_result`. Empty chunks
/// (id.len == 0, initial templating results) are skipped. Unparseable lines
/// (error payloads) are skipped.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) Chat.ChatStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const final_result = switch (parsed.value) {
        .@"error" => |err| {
            const msg = allocator.dupe(u8, err.message orelse "Unknown error from SAP AI Core") catch return .{ .skip = {} };
            const typ = allocator.dupe(u8, content.sapErrorType(err)) catch { allocator.free(msg); return .{ .skip = {} }; };
            const code: ?[]const u8 = if (content.sapErrorCode(err)) |s| allocator.dupe(u8, s) catch {
                allocator.free(msg); allocator.free(typ); return .{ .skip = {} };
            } else null;
            return .{ .@"error" = .{ .@"error" = .{ .message = msg, .type = typ, .param = null, .code = code } } };
        },
        .result => |r| r.final_result,
    };
    if (final_result.id.len == 0) return .{ .skip = {} };

    if (state.response_id.len == 0) {
        state.response_id = allocator.dupe(u8, final_result.id) catch return .{ .skip = {} };
    }

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];
        if (choice.finish_reason) |reason| if (reason.len > 0) {
            if (state.finish_reason) |prev| allocator.free(prev);
            state.finish_reason = allocator.dupe(u8, reason) catch null;
        };
    }
    if (final_result.usage) |u| {
        state.input_tokens = @intCast(u.prompt_tokens);
        state.output_tokens = @intCast(u.completion_tokens);
    }

    const src_delta: Chat.Delta = if (final_result.choices.len > 0)
        final_result.choices[0].delta
    else
        .{};
    const src_finish: ?[]const u8 = if (final_result.choices.len > 0)
        final_result.choices[0].finish_reason
    else
        null;

    // Dupe owned strings from the parse arena before it dies.
    var owned_delta = src_delta;
    if (src_delta.content) |c| {
        owned_delta.content = allocator.dupe(u8, c) catch return .{ .skip = {} };
    }
    if (src_delta.tool_calls) |tcs| {
        const owned_tcs = allocator.alloc(Chat.DeltaToolCall, tcs.len) catch {
            if (owned_delta.content) |c| allocator.free(c);
            return .{ .skip = {} };
        };
        for (tcs, 0..) |tc, i| {
            owned_tcs[i] = tc;
            if (tc.id) |s| owned_tcs[i].id = allocator.dupe(u8, s) catch null;
            if (tc.function) |f| {
                var owned_f = f;
                if (f.name) |s| owned_f.name = allocator.dupe(u8, s) catch null;
                if (f.arguments) |s| owned_f.arguments = allocator.dupe(u8, s) catch null;
                owned_tcs[i].function = owned_f;
            }
        }
        owned_delta.tool_calls = owned_tcs;
    }
    owned_delta.audio = null;

    const owned_finish: ?[]const u8 = if (src_finish) |r|
        allocator.dupe(u8, r) catch null
    else
        null;

    const choices = allocator.alloc(Chat.StreamChoice, 1) catch {
        if (owned_delta.content) |c| allocator.free(c);
        if (owned_delta.tool_calls) |tcs| allocator.free(tcs);
        return .{ .skip = {} };
    };
    choices[0] = .{
        .index = if (final_result.choices.len > 0) final_result.choices[0].index else 0,
        .delta = owned_delta,
        .finish_reason = owned_finish,
        .logprobs = null,
    };

    const chunks = allocator.alloc(Chat.StreamChunk, 1) catch {
        if (owned_delta.content) |c| allocator.free(c);
        if (owned_delta.tool_calls) |tcs| allocator.free(tcs);
        allocator.free(choices);
        return .{ .skip = {} };
    };
    chunks[0] = .{
        .id = state.response_id,
        .object = "chat.completion.chunk",
        .created = final_result.created,
        .model = state.original_model,
        .choices = choices,
        .usage = final_result.usage,
    };
    return .{ .events = chunks };
}

// ============================================================================
// Flow: /v1/messages — messages wire in, SAP envelope out
// ============================================================================

pub const MessagesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    // finish_reason is a duped mapped stop_reason ("end_turn", "max_tokens", etc.)
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    sent_message_start: bool = false,
    sent_content_block_start: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Inbound messages request → SAP envelope, pinned to model.
///
/// Messages.Request fields mapped:
///   model (pinned), system → system chat message (borrows inbound string),
///   messages (user/assistant, text/tool_use/tool_result blocks) → template,
///   tools → chat function tools (schema borrows inbound parse),
///   stream → stream.enabled,
///   temperature / max_tokens / top_p → model.params.
/// Skipped: tool_choice (Anthropic union not mapped to chat shape), top_k,
///   thinking, betas, metadata, service_tier, output_config, container,
///   inference_geo, cache_control, fallbacks, stop_sequences
///   (SAP envelope has no equivalent fields).
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer {
        for (messages.items) |msg| content.freeMessageOwnedText(msg, allocator);
        messages.deinit(allocator);
    }

    if (request.system) |system_text| {
        const sys_str: []const u8 = switch (system_text) {
            .text => |t| t,
            .blocks => |blks| if (blks.len > 0) blks[0].text else "",
        };
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = sys_str },
        });
    }

    for (request.messages) |msg| {
        const role: Chat.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system => continue,
        };

        switch (msg.content) {
            .text => |text| try messages.append(allocator, .{
                .role = role,
                .content = .{ .text = try allocator.dupe(u8, text) },
            }),
            .blocks => |blocks| {
                var text_parts: std.ArrayList([]const u8) = .empty;
                defer text_parts.deinit(allocator);

                var tool_use_blocks: std.ArrayList(Chat.ToolCall) = .empty;
                errdefer {
                    for (tool_use_blocks.items) |tc| allocator.free(tc.function.arguments);
                    tool_use_blocks.deinit(allocator);
                }

                var tool_results: std.ArrayList(struct { id: []const u8, content: ?[]const u8 }) = .empty;
                defer tool_results.deinit(allocator);

                for (blocks) |block| {
                    switch (block) {
                        .text => |tb| try text_parts.append(allocator, tb.text),
                        .tool_use => |tu| {
                            var args_list: std.ArrayList(u8) = .empty;
                            defer args_list.deinit(allocator);
                            try args_list.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});
                            try tool_use_blocks.append(allocator, .{
                                .id = tu.id,
                                .type = "function",
                                .function = .{
                                    .name = tu.name,
                                    .arguments = try allocator.dupe(u8, args_list.items),
                                },
                            });
                        },
                        .tool_result => |tr| {
                            const c_text: ?[]const u8 = if (tr.content) |c| switch (c) {
                                .text => |s| s,
                                .blocks => null,
                            } else null;
                            try tool_results.append(allocator, .{
                                .id = tr.tool_use_id,
                                .content = c_text,
                            });
                        },
                        .image, .document, .thinking, .redacted_thinking,
                        .server_tool_use, .web_search_tool_result, .web_fetch_tool_result,
                        .code_execution_tool_result, .bash_code_execution_tool_result,
                        .text_editor_code_execution_tool_result, .tool_search_tool_result,
                        .search_result, .container_upload => {},
                    }
                }

                for (tool_results.items) |tr| {
                    try messages.append(allocator, .{
                        .role = .tool,
                        .content = if (tr.content) |c| .{ .text = try allocator.dupe(u8, c) } else null,
                        .tool_call_id = tr.id,
                    });
                }

                if (text_parts.items.len > 0 or tool_use_blocks.items.len > 0) {
                    try messages.append(allocator, .{
                        .role = role,
                        .content = if (text_parts.items.len > 0)
                            .{ .text = try std.mem.join(allocator, "", text_parts.items) }
                        else
                            null,
                        .tool_calls = if (tool_use_blocks.items.len > 0)
                            try tool_use_blocks.toOwnedSlice(allocator)
                        else
                            null,
                    });
                }
            },
        }
    }

    const tools: ?[]const Chat.Tool = if (request.tools) |anthro_tools| blk: {
        const oai_tools = try allocator.alloc(Chat.Tool, anthro_tools.len);
        for (anthro_tools, 0..) |at, i| {
            oai_tools[i] = .{
                .type = "function",
                .function = .{
                    .name = at.name orelse "",
                    .description = at.description,
                    .parameters = at.input_schema,
                    .strict = null,
                },
            };
        }
        break :blk oai_tools;
    } else null;
    errdefer if (tools) |ts| allocator.free(ts);

    const params = try content.buildParams(.{
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .top_p = request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = try messages.toOwnedSlice(allocator),
                        .tools = tools,
                        .tool_choice = null,
                        .response_format = null,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                .enabled = request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformMessagesRequest allocated: template messages, tools
/// slice, and params object.
pub fn cleanupMessagesRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    const pt = request.config.modules.prompt_templating.?;
    const prompt = pt.prompt;
    for (prompt.template) |msg| content.freeMessageOwnedText(msg, allocator);
    allocator.free(prompt.template);
    if (prompt.tools) |ts| allocator.free(ts);
    if (pt.model.params) |p|
        content.freeParams(p, allocator);
}

/// SAP response → inbound messages response.
///
/// Sap.Response.final_result (Chat.Response) fields mapped:
///   choices[0].message.content → content[].text (duped)
///   choices[0].message.tool_calls → content[].tool_use (id/name duped,
///     input leaky-parsed)
///   choices[0].finish_reason → stop_reason (mapped via transformStopReasonToMessages)
///   id → id (duped), original_req.model → model (duped)
///   usage.prompt_tokens → input_tokens, usage.completion_tokens → output_tokens
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures (SAP envelope fields, not Messages wire).
pub fn transformMessagesResponse(
    upstream_response: Sap.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    const final_result = upstream_response.final_result;

    var content_blocks: std.ArrayList(Messages.ContentBlock) = .empty;
    errdefer {
        content.freeMessageOwnedBlocks(content_blocks.items, allocator);
        content_blocks.deinit(allocator);
    }

    if (final_result.choices.len > 0) {
        const message = final_result.choices[0].message;
        if (message.content) |text| if (text.len > 0) {
            try content_blocks.append(allocator, .{ .text = .{
                .type = "text",
                .text = try allocator.dupe(u8, text),
            } });
        };
        if (message.tool_calls) |tcs| for (tcs) |tc| {
            try content_blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.function.name),
                .input = try content.parseToolArguments(tc.function.arguments, allocator),
            } });
        };
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{
            .type = "text",
            .text = try allocator.dupe(u8, ""),
        } });
    }

    const stop_reason: ?[]const u8 = if (final_result.choices.len > 0)
        content.transformStopReasonToMessages(final_result.choices[0].finish_reason)
    else
        "end_turn";

    const owned_content = try content_blocks.toOwnedSlice(allocator);
    errdefer {
        content.freeMessageOwnedBlocks(owned_content, allocator);
        allocator.free(owned_content);
    }
    const owned_id = try allocator.dupe(u8, final_result.id);
    errdefer allocator.free(owned_id);
    const owned_model = try allocator.dupe(u8, original_req.model);

    return .{
        .id = owned_id,
        .type = "message",
        .role = "assistant",
        .content = owned_content,
        .model = owned_model,
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = if (final_result.usage) |u| .{
            .input_tokens = @intCast(u.prompt_tokens),
            .output_tokens = @intCast(u.completion_tokens),
        } else .{ .input_tokens = 0, .output_tokens = 0 },
    };
}

/// Free what transformMessagesResponse allocated.
pub fn cleanupMessagesResponse(inbound_response: Messages.Response, allocator: std.mem.Allocator) void {
    content.freeMessageOwnedBlocks(inbound_response.content, allocator);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    allocator.free(inbound_response.content);
}

/// One SAP SSE line → Messages.MessagesStreamLineResult (typed SseEvent slice).
///
/// The SAP inner stream ends with `[DONE]`, which triggers the closing triple.
/// Text deltas lazily open the synthesized protocol on the first chunk.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) Messages.MessagesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    var events: std.ArrayList(Messages.SseEvent) = .empty;
    defer events.deinit(allocator);

    if (std.mem.eql(u8, json_part, "[DONE]")) {
        if (!state.sent_message_start or !state.sent_content_block_start) {
            events.append(allocator, .{ .message_start = .{
                .type = "message_start",
                .message = .{
                    .id = "msg_proxy",
                    .type = "message",
                    .role = "assistant",
                    .content = &.{},
                    .model = state.original_model,
                    .stop_reason = null,
                    .stop_sequence = null,
                    .usage = .{ .input_tokens = state.input_tokens, .output_tokens = 0 },
                },
            }}) catch return .{ .skip = {} };
            events.append(allocator, .{ .content_block_start = .{
                .type = "content_block_start",
                .index = 0,
                .content_block = .{ .type = "text", .text = "" },
            }}) catch return .{ .skip = {} };
            state.sent_message_start = true;
            state.sent_content_block_start = true;
        }

        const stop_reason = state.finish_reason orelse "end_turn";
        events.append(allocator, .{ .content_block_stop = .{
            .type = "content_block_stop", .index = 0,
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .message_delta = .{
            .type = "message_delta",
            .delta = .{ .stop_reason = stop_reason, .stop_sequence = null },
            .usage = .{ .output_tokens = state.output_tokens },
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .message_stop = .{ .type = "message_stop" } }) catch
            return .{ .skip = {} };
        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const final_result = switch (parsed.value) {
        .@"error" => |err| {
            const msg = allocator.dupe(u8, err.message orelse "Unknown error from SAP AI Core") catch return .{ .skip = {} };
            const ev = allocator.alloc(Messages.SseEvent, 1) catch { allocator.free(msg); return .{ .skip = {} }; };
            ev[0] = .{ .error_event = .{ .type = "error", .@"error" = .{
                .type = content.sapErrorType(err),
                .message = msg,
            }}};
            return .{ .events = ev };
        },
        .result => |r| r.final_result,
    };
    if (final_result.id.len == 0) return .{ .skip = {} };

    if (!state.sent_message_start or !state.sent_content_block_start) {
        events.append(allocator, .{ .message_start = .{
            .type = "message_start",
            .message = .{
                .id = "msg_proxy",
                .type = "message",
                .role = "assistant",
                .content = &.{},
                .model = state.original_model,
                .stop_reason = null,
                .stop_sequence = null,
                .usage = .{ .input_tokens = state.input_tokens, .output_tokens = 0 },
            },
        }}) catch return .{ .skip = {} };
        events.append(allocator, .{ .content_block_start = .{
            .type = "content_block_start",
            .index = 0,
            .content_block = .{ .type = "text", .text = "" },
        }}) catch return .{ .skip = {} };
        state.sent_message_start = true;
        state.sent_content_block_start = true;
    }

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];

        if (final_result.usage) |u| {
            state.input_tokens = @intCast(u.prompt_tokens);
            state.output_tokens = @intCast(u.completion_tokens);
        }

        if (choice.finish_reason) |reason| if (reason.len > 0) {
            if (state.finish_reason) |prev| allocator.free(prev);
            state.finish_reason = allocator.dupe(
                u8,
                content.transformStopReasonToMessages(reason),
            ) catch null;
        };

        if (choice.delta.content) |text| if (text.len > 0) {
            // Dupe — text borrows from parsed which dies after this function returns.
            const owned_text = allocator.dupe(u8, text) catch return .{ .skip = {} };
            events.append(allocator, .{ .content_block_delta = .{
                .type = "content_block_delta",
                .index = 0,
                .delta = .{ .type = "text_delta", .text = owned_text },
            }}) catch {
                allocator.free(owned_text);
                return .{ .skip = {} };
            };
        };
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — responses wire in, SAP envelope out
// ============================================================================

pub const ResponsesStreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_tokens: u32 = 0,
    cache_write_tokens: u32 = 0,
    sequence_number: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{ .allocator = allocator, .original_model = original_model };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |r| self.allocator.free(r);
        self.finish_reason = null;
    }
};

/// Inbound responses request → SAP envelope, pinned to model.
///
/// Responses.Request fields mapped:
///   model (pinned), instructions → system message (borrows),
///   input.text → user message (borrows),
///   input.items (message/function_call/function_call_output) → template,
///   tools (.function only → Chat.Tool; built-in types skipped),
///   tool_choice → tool_choice (borrowed),
///   text.format → response_format (borrowed),
///   stream → stream.enabled,
///   temperature / max_output_tokens / top_p → model.params.
/// Skipped: stream_options, previous_response_id, reasoning, reasoning_effort,
///   parallel_tool_calls, store, include, truncation, background, max_tool_calls,
///   conversation, context_management, metadata, top_logprobs, moderation,
///   safety_identifier, prompt_cache_key, prompt_cache_options, user, prompt,
///   verbosity, service_tier (SAP envelope has no equivalent fields).
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer {
        for (messages.items) |msg| content.freeMessageOwnedText(msg, allocator);
        messages.deinit(allocator);
    }

    if (request.instructions) |inst| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = inst },
        });
    }

    switch (request.input) {
        .text => |text| try messages.append(allocator, .{
            .role = .user,
            .content = .{ .text = text },
        }),
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const item_type_val = obj.get("type") orelse continue;
            if (item_type_val != .string) continue;
            const item_type = item_type_val.string;

            if (std.mem.eql(u8, item_type, "message")) {
                const role_val = obj.get("role") orelse continue;
                if (role_val != .string) continue;
                const role = std.meta.stringToEnum(Chat.Role, role_val.string) orelse continue;
                const message_content: ?Chat.MessageContent = blk: {
                    const cv = obj.get("content") orelse break :blk null;
                    switch (cv) {
                        .string => |s| break :blk .{ .text = s },
                        .array => |arr| {
                            for (arr.items) |part| {
                                if (part != .object) continue;
                                const tv = part.object.get("text") orelse continue;
                                if (tv == .string and tv.string.len > 0)
                                    break :blk .{ .text = tv.string };
                            }
                            break :blk null;
                        },
                        else => break :blk null,
                    }
                };
                try messages.append(allocator, .{
                    .role = role,
                    .content = message_content,
                    .tool_call_id = if (obj.get("tool_call_id")) |v|
                        if (v == .string) v.string else null
                    else
                        null,
                });
            } else if (std.mem.eql(u8, item_type, "function_call")) {
                const name_val = obj.get("name") orelse continue;
                if (name_val != .string) continue;
                const id_val = obj.get("call_id") orelse obj.get("id") orelse continue;
                if (id_val != .string) continue;
                const args_str: []const u8 = if (obj.get("arguments")) |a|
                    if (a == .string) a.string else "{}"
                else "{}";
                const tcs = try allocator.alloc(Chat.ToolCall, 1);
                tcs[0] = .{
                    .id = id_val.string,         // borrows inbound parse arena
                    .type = "function",
                    .function = .{
                        .name = name_val.string, // borrows inbound parse arena
                        .arguments = try allocator.dupe(u8, args_str),
                    },
                };
                try messages.append(allocator, .{
                    .role = .assistant,
                    .content = null,
                    .tool_calls = tcs,
                });
            } else if (std.mem.eql(u8, item_type, "function_call_output")) {
                const call_id_val = obj.get("call_id") orelse continue;
                if (call_id_val != .string) continue;
                const output_text: ?[]const u8 = if (obj.get("output")) |o|
                    if (o == .string) o.string else null
                else null;
                try messages.append(allocator, .{
                    .role = .tool,
                    .content = if (output_text) |t| .{ .text = t } else null,
                    .tool_call_id = call_id_val.string,
                });
            }
        },
    }

    const chat_tools: ?[]const Chat.Tool = if (request.tools) |rt| blk: {
        var list: std.ArrayList(Chat.Tool) = .empty;
        errdefer list.deinit(allocator);
        for (rt) |t| switch (t) {
            .function => |f| try list.append(allocator, .{ .type = "function", .function = f.function }),
            .web_search_preview, .file_search, .code_interpreter_tool, .mcp_tool, .other => {},
        };
        if (list.items.len == 0) {
            list.deinit(allocator);
            break :blk null;
        }
        break :blk try list.toOwnedSlice(allocator);
    } else null;
    errdefer if (chat_tools) |ts| allocator.free(ts);

    const params = try content.buildParams(.{
        .temperature = request.temperature,
        .max_tokens = request.max_output_tokens,
        .top_p = request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = try messages.toOwnedSlice(allocator),
                        .tools = chat_tools,
                        .tool_choice = request.tool_choice,
                        .response_format = if (request.text) |txt| txt.format else null,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                .enabled = request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformResponsesRequest allocated: function_call tool_calls
/// (arguments duped; id and name borrow inbound arena), template slice,
/// tools slice, params object.
/// Note: message content strings and tool_call_id borrow from the inbound
/// request arena (not freed here).
pub fn cleanupResponsesRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    const pt = request.config.modules.prompt_templating.?;
    const prompt = pt.prompt;
    for (prompt.template) |msg| content.freeMessageOwnedText(msg, allocator);
    allocator.free(prompt.template);
    if (prompt.tools) |ts| allocator.free(ts);
    if (pt.model.params) |p|
        content.freeParams(p, allocator);
}

/// SAP response → inbound responses response.
///
/// Sap.Response.final_result (Chat.Response) fields mapped:
///   choices[0].message.content → output[0].message.content[output_text] (duped)
///   choices[0].message.tool_calls → output[N].function_call (id/name/arguments duped)
///   choices[0].finish_reason="length" → status="incomplete"
///   id → id (duped), output[0].message.id (duped)
///   original_req.model → model (duped)
///   created → created_at, usage (prompt/completion/total_tokens)
/// Echo from original_req: temperature, top_p, parallel_tool_calls, store,
///   max_output_tokens, metadata.
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures, object, completed_at, output_text,
///   incomplete_details, error, reasoning, instructions, tool_choice, tools,
///   background, max_tool_calls, truncation, previous_response_id,
///   conversation, moderation, safety_identifier, prompt_cache_key,
///   prompt_cache_options, prompt_cache_diagnostics, prompt,
///   text, user, service_tier, top_logprobs (no Responses.Response equivalent
///   from the SAP wire, or echoed from original_req).
pub fn transformResponsesResponse(
    upstream_response: Sap.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    const final_result = upstream_response.final_result;

    var content_parts: std.ArrayList(Responses.OutputContent) = .empty;
    errdefer {
        for (content_parts.items) |c| switch (c) {
            .output_text => |t| allocator.free(t.text),
            .refusal, .other => {},
        };
        content_parts.deinit(allocator);
    }

    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer {
        for (output_items.items) |item| switch (item) {
            .function_call => |f| {
                allocator.free(f.id);
                allocator.free(f.name);
                allocator.free(f.arguments);
            },
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |t| allocator.free(t.text),
                    .refusal, .other => {},
                };
                allocator.free(m.content);
            },
            else => {},
        };
        output_items.deinit(allocator);
    }

    const finish_reason: []const u8 = if (final_result.choices.len > 0)
        final_result.choices[0].finish_reason
    else
        "stop";

    if (final_result.choices.len > 0) {
        const message = final_result.choices[0].message;
        if (message.content) |c| if (c.len > 0) {
            try content_parts.append(allocator, .{ .output_text = .{
                .type = "output_text",
                .text = try allocator.dupe(u8, c),
            } });
        };
        if (message.tool_calls) |tcs| for (tcs) |tc| {
            try output_items.append(allocator, .{ .function_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .type = "function_call",
                .name = try allocator.dupe(u8, tc.function.name),
                .arguments = try allocator.dupe(u8, tc.function.arguments),
                .status = "completed",
            } });
        };
    }

    const msg_status: []const u8 = if (std.mem.eql(u8, finish_reason, "length"))
        "incomplete"
    else
        "completed";

    const msg_id = try allocator.dupe(u8, final_result.id);
    var msg_transferred = false;
    errdefer if (!msg_transferred) allocator.free(msg_id);
    const msg_content = try content_parts.toOwnedSlice(allocator);
    errdefer if (!msg_transferred) {
        for (msg_content) |c| switch (c) {
            .output_text => |t| allocator.free(t.text),
            .refusal, .other => {},
        };
        allocator.free(msg_content);
    };

    try output_items.insert(allocator, 0, .{ .message = .{
        .id = msg_id,
        .type = "message",
        .role = "assistant",
        .content = msg_content,
        .status = msg_status,
    } });
    msg_transferred = true; // output_items errdefer now owns msg_id and msg_content

    const top_status: []const u8 = if (std.mem.eql(u8, finish_reason, "length"))
        "incomplete"
    else
        "completed";

    const owned_id = try allocator.dupe(u8, final_result.id);
    errdefer allocator.free(owned_id);
    const owned_output = try output_items.toOwnedSlice(allocator);
    errdefer {
        for (owned_output) |item| switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |t| allocator.free(t.text),
                    .refusal, .other => {},
                };
                allocator.free(m.content);
            },
            .function_call => |f| {
                allocator.free(f.id);
                allocator.free(f.name);
                allocator.free(f.arguments);
            },
            else => {},
        };
        allocator.free(owned_output);
    }
    const owned_model = try allocator.dupe(u8, original_req.model);

    return .{
        .id = owned_id,
        .object = "response",
        .created_at = @floatFromInt(final_result.created),
        .model = owned_model,
        .status = top_status,
        .output = owned_output,
        .usage = if (final_result.usage) |u| .{
            .input_tokens = u.prompt_tokens,
            .output_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
        } else .{ .input_tokens = 0, .output_tokens = 0, .total_tokens = 0 },
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
    };
}

/// Free what transformResponsesResponse allocated.
pub fn cleanupResponsesResponse(inbound_response: Responses.Response, allocator: std.mem.Allocator) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    for (inbound_response.output) |item| {
        switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |txt| allocator.free(txt.text),
                    .refusal, .other => {},
                };
                allocator.free(m.content);
            },
            .function_call => |f| {
                allocator.free(f.id);
                allocator.free(f.name);
                allocator.free(f.arguments);
            },
            .reasoning, .web_search_call, .file_search_call, .code_interpreter_call,
            .mcp_list_tools_item, .mcp_call_item, .image_generation_call,
            .local_shell_call, .other => {},
        }
    }
    allocator.free(inbound_response.output);
}

/// One SAP SSE line → Responses.ResponsesStreamLineResult (typed StreamEvent slice).
///
/// The SAP inner stream ends with `[DONE]`, handled by the pipeline
/// (appendsDoneMarker = true). Text deltas → output_text_delta events;
/// tool-argument deltas → function_call_arguments_delta events.
/// Terminal chunk (finish_reason present) captures state for flushResponsesStream.
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) Responses.ResponsesStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const final_result = switch (parsed.value) {
        .@"error" => |err| {
            const msg = allocator.dupe(u8, err.message orelse "Unknown error from SAP AI Core") catch return .{ .skip = {} };
            const ev = allocator.alloc(Responses.StreamEvent, 1) catch { allocator.free(msg); return .{ .skip = {} }; };
            ev[0] = .{ .stream_error = .{
                .sequence_number = state.sequence_number,
                .code = content.sapErrorCode(err),
                .message = msg,
            }};
            return .{ .events = ev };
        },
        .result => |r| r.final_result,
    };
    if (final_result.id.len == 0) return .{ .skip = {} };

    if (state.response_id.len == 0) {
        state.response_id = allocator.dupe(u8, final_result.id) catch return .{ .skip = {} };
    }

    if (final_result.choices.len == 0) return .{ .skip = {} };
    const choice = final_result.choices[0];

    if (choice.finish_reason) |reason| if (reason.len > 0) {
        if (state.finish_reason) |prev| allocator.free(prev);
        state.finish_reason = allocator.dupe(u8, reason) catch null;
    };

    if (final_result.usage) |u| {
        state.input_tokens = @intCast(u.prompt_tokens);
        state.output_tokens = @intCast(u.completion_tokens);
    }

    var events: std.ArrayList(Responses.StreamEvent) = .empty;
    defer events.deinit(allocator);

    if (choice.delta.content) |text| if (text.len > 0) {
        // Dupe — text borrows from parsed which dies after this function returns.
        const owned = allocator.dupe(u8, text) catch return .{ .skip = {} };
        events.append(allocator, .{ .output_text_delta = .{
            .sequence_number = state.sequence_number,
            .item_id = state.response_id,
            .delta = owned,
        }}) catch {
            allocator.free(owned);
            return .{ .skip = {} };
        };
        state.sequence_number += 1;
    };

    if (choice.delta.tool_calls) |tcs| if (tcs.len > 0) {
        const args = if (tcs[0].function) |f| (f.arguments orelse "") else "";
        if (args.len > 0) {
            const owned = allocator.dupe(u8, args) catch return .{ .skip = {} };
            events.append(allocator, .{ .function_call_arguments_delta = .{
                .sequence_number = state.sequence_number,
                .item_id = state.response_id,
                .delta = owned,
            }}) catch {
                allocator.free(owned);
                return .{ .skip = {} };
            };
            state.sequence_number += 1;
        }
    };

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

/// Emit the terminal Responses events after `[DONE]`: output_item_done +
/// response_completed (or response_incomplete when finish_reason="length").
/// Returns null when no finish_reason was captured.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "length")) "incomplete" else "completed";

    const events = allocator.alloc(Responses.StreamEvent, 2) catch return null;

    events[0] = .{ .output_item_done = .{
        .sequence_number = state.sequence_number,
        .output_index = 0,
        .item = .{ .message = .{
            .id = state.response_id,
            .type = "message",
            .role = "assistant",
            .content = &.{},
            .status = status,
        }},
    }};

    const terminal_response = Responses.Response{
        .id = state.response_id,
        .object = "response",
        .created_at = @floatFromInt(time.timestamp()),
        .model = state.original_model,
        .status = status,
        .output = &.{},
        .usage = .{
            .input_tokens = state.input_tokens,
            .output_tokens = state.output_tokens,
            .total_tokens = state.input_tokens + state.output_tokens,
        },
        .parallel_tool_calls = true,
    };

    events[1] = if (std.mem.eql(u8, status, "incomplete"))
        .{ .response_incomplete = .{
            .sequence_number = state.sequence_number + 1,
            .response = terminal_response,
        }}
    else
        .{ .response_completed = .{
            .sequence_number = state.sequence_number + 1,
            .response = terminal_response,
        }};

    return events;
}
