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

//! Transformer for the SAP AI Core provider (orchestration envelope wire).
//!
//! The SAP wire wraps chat-format payloads (`config.modules.prompt_templating`
//! on the way out, `final_result` on the way in); each flow converts its
//! inbound schema to/from that envelope. Conversion is written locally (P11).
//!
//! Four flows, named after the *inbound* schema (P2). Every `pub` symbol is
//! defined here (P5).

const std = @import("std");
const common = @import("../openai/types.zig"); // shared primitives

const Chat = @import("../openai/chat_types.zig"); // chat schema (envelope payload)
const Messages = @import("../anthropic/types.zig"); // Anthropic Messages wire types
const Responses = @import("../openai/responses_types.zig"); // inbound responses schema
const Sap = @import("types.zig"); // SAP AI Core wire types
const content = @import("content.zig"); // own mapping internals
const log = @import("../../log.zig");
const time = @import("../../time.zig");

// ============================================================================
// Contract
// ============================================================================

/// Result of transforming one upstream SSE line (P4): already-formatted bytes
/// the pipeline writes verbatim, or nothing. Owned by the caller when `.output`.
pub const StreamLineResult = union(enum) {
    output: []const u8,
    skip: void,
};

/// Chat and Messages pipelines append their own `[DONE]` sentinel; the
/// Responses pipeline does not (native Responses upstreams end silently).
pub const appendsDoneMarker = true;

/// A SAP model is usable through this provider only when it has a latest
/// non-deprecated version and supports the "orchestration" scenario.
fn isOrchestrationCapable(sap_model: Sap.SapModel) bool {
    var has_latest = false;
    for (sap_model.versions) |version| {
        if (version.isLatest and !version.deprecated) has_latest = true;
    }
    if (!has_latest) return false;

    for (sap_model.allowedScenarios) |scenario| {
        if (std.mem.eql(u8, scenario.scenarioId, "orchestration")) return true;
    }
    return false;
}

// ============================================================================
// Flow: /v1/models
// ============================================================================

/// Map the SAP models listing to inbound `Model` entries, prefixing ids with
/// the provider name. Only models with a latest non-deprecated version AND
/// the "orchestration" scenario are usable through this provider.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Sap.SapModelsResponse),
    provider_name: []const u8,
) ![]common.Model {
    var valid_count: usize = 0;
    for (response.value.resources) |sap_model| {
        if (isOrchestrationCapable(sap_model)) valid_count += 1;
    }

    var models = try allocator.alloc(common.Model, valid_count);
    errdefer allocator.free(models);

    var idx: usize = 0;
    for (response.value.resources) |sap_model| {
        if (!isOrchestrationCapable(sap_model)) continue;
        models[idx] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, sap_model.model }),
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, sap_model.provider),
        };
        idx += 1;
    }

    return models;
}

// ============================================================================
// Flow: /v1/chat/completions — chat wire in, SAP envelope out
// ============================================================================

/// Stream state for the chat flow. The SAP envelope carries chat chunks in
/// `final_result`; ids/usage arrive on those inner chunks.
pub const ChatStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ChatStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ChatStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
    }
};

/// Inbound chat request → SAP envelope, pinned to `model`. Sampling fields
/// map onto `model.params`; messages/tools/tool_choice/response_format ride
/// in the prompt_templating module (borrowed from the inbound parse).
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    // S1 — model params forwarding (max_completion_tokens wins over max_tokens)
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
                        .template = request.messages, // borrows the inbound parse
                        .tools = request.tools,
                        .tool_choice = request.tool_choice, // S2
                        .response_format = request.response_format, // S3
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                // S19 — SAP AI Core's stream.enabled drives token usage in the
                // final chunk; no include_usage workaround is applicable here.
                .enabled = request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what `transformChatRequest` allocated (the params object).
pub fn cleanupChatRequest(
    request: Sap.Request,
    allocator: std.mem.Allocator,
) void {
    if (request.config.modules.prompt_templating.model.params) |p| {
        content.freeParams(p, allocator);
    }
}

/// SAP response → inbound chat response (deep-copies the inner final_result
/// so the transformed value outlives the client response's parse arena).
pub fn transformChatResponse(
    upstream_response: Sap.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    const final_result = upstream_response.final_result;

    // Deep-copy the inner chat response: it lives in the client response's
    // parse arena, which dies when the pipeline deinits the upstream parse.
    const choices = try allocator.alloc(Chat.ResponseChoice, final_result.choices.len);
    errdefer {
        for (choices) |choice| {
            content.freeResponseMessage(allocator, choice.message);
            allocator.free(choice.finish_reason);
        }
        allocator.free(choices);
    }
    for (final_result.choices, 0..) |choice, i| {
        choices[i] = try content.dupeResponseChoice(allocator, choice);
    }

    return .{
        .id = try allocator.dupe(u8, final_result.id),
        .object = try allocator.dupe(u8, final_result.object),
        .created = final_result.created,
        .model = try allocator.dupe(u8, original_req.model),
        .choices = choices,
        .usage = final_result.usage orelse Chat.Usage{
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
        },
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Free what `transformChatResponse` allocated (the deep copies).
pub fn cleanupChatResponse(
    inbound_response: Chat.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.object);
    allocator.free(inbound_response.model);
    for (inbound_response.choices) |choice| {
        content.freeResponseMessage(allocator, choice.message);
        allocator.free(choice.finish_reason);
    }
    allocator.free(inbound_response.choices);
}

/// One SAP SSE line → zero or one chat-format SSE chunk as ready bytes (P4).
/// The `final_result` chat chunk is re-emitted with the model rewritten;
/// upstream errors render inline.
pub fn transformChatStreamLine(
    line: []const u8,
    state: *ChatStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        // Not a chunk — maybe an error payload; render it inline (P4).
        const bytes = content.formatSapErrorLine(json_part, allocator) orelse
            return .{ .skip = {} };
        return .{ .output = bytes };
    };
    defer parsed.deinit();

    const final_result = parsed.value.final_result;

    // Skip empty chunks (initial templating results).
    if (final_result.id.len == 0) return .{ .skip = {} };

    // Own the id: it borrows from `parsed`, which dies below (bug #18 class).
    if (state.response_id.len == 0) {
        state.response_id = allocator.dupe(u8, final_result.id) catch
            return .{ .skip = {} };
    }

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];
        if (choice.finish_reason) |reason| {
            if (reason.len > 0) {
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, reason) catch null;
            }
        }
    }
    if (final_result.usage) |usage| {
        state.input_tokens = @intCast(usage.prompt_tokens);
        state.output_tokens = @intCast(usage.completion_tokens);
    }

    const bytes = content.buildChatChunk(.{
        .id = state.response_id,
        .created = final_result.created,
        .original_model = state.original_model,
    }, if (final_result.choices.len > 0) final_result.choices[0].delta else .{}, if (final_result.choices.len > 0) final_result.choices[0].finish_reason else null, final_result.usage, allocator) orelse
        return .{ .skip = {} };
    return .{ .output = bytes };
}

// ============================================================================
// Flow: /v1/messages — messages wire in, SAP envelope out
// ============================================================================

/// Stream state for the messages flow: the SAP inner chat stream ends with
/// `[DONE]`, which triggers the closing triple of the synthesized protocol.
pub const MessagesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    // --- messages-flow specifics ---
    /// Whether the synthetic message_start was emitted.
    sent_message_start: bool = false,
    /// Whether the synthetic content_block_start was emitted.
    sent_content_block_start: bool = false,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) MessagesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *MessagesStreamState) void {
        // finish_reason is a dupe (mapped stop_reason captured from chunks).
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
    }
};

/// Inbound messages request → SAP envelope, pinned to `model`. Messages are
/// converted to chat messages (system-first, tool_use → tool_calls,
/// tool_result → tool messages); tools and tool_choice map to chat shapes.
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

    // System message first (borrows the inbound system string).
    if (request.system) |system_text| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = system_text },
        });
    }

    for (request.messages) |msg| {
        const role: common.Role = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
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
                    for (tool_use_blocks.items) |tc| {
                        allocator.free(tc.function.arguments);
                    }
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
                        .tool_result => |tr| try tool_results.append(allocator, .{
                            .id = tr.tool_use_id,
                            .content = tr.content,
                        }),
                        .image, .document, .thinking, .redacted_thinking,
                        .server_tool_use, .web_search_tool_result, .web_fetch_tool_result,
                        .code_execution_tool_result, .bash_code_execution_tool_result,
                        .text_editor_code_execution_tool_result, .tool_search_tool_result,
                        .search_result, .container_upload => {},
                    }
                }

                // Tool results first — one tool message per result.
                for (tool_results.items) |tr| {
                    try messages.append(allocator, .{
                        .role = .tool,
                        .content = if (tr.content) |c| .{ .text = try allocator.dupe(u8, c) } else null,
                        .tool_call_id = tr.id,
                    });
                }

                if (text_parts.items.len > 0 or tool_use_blocks.items.len > 0) {
                    const content_text: ?Chat.MessageContent = if (text_parts.items.len > 0) blk: {
                        break :blk .{ .text = try std.mem.join(allocator, "", text_parts.items) };
                    } else null;

                    try messages.append(allocator, .{
                        .role = role,
                        .content = content_text,
                        .tool_calls = if (tool_use_blocks.items.len > 0)
                            try tool_use_blocks.toOwnedSlice(allocator)
                        else
                            null,
                    });
                }
            },
        }
    }

    // Anthropic tools → chat function tools (schema borrows the inbound parse).
    const tools: ?[]Chat.Tool = if (request.tools) |anthro_tools| blk: {
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
                        .tool_choice = null, // Anthropic union not mapped (gap, as before)
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

/// Free what `transformMessagesRequest` allocated: the params object, the
/// tools slice, and the owned parts of the template messages.
pub fn cleanupMessagesRequest(
    request: Sap.Request,
    allocator: std.mem.Allocator,
) void {
    const prompt = request.config.modules.prompt_templating.prompt;
    for (prompt.template) |msg| content.freeMessageOwnedText(msg, allocator);
    allocator.free(prompt.template);
    if (prompt.tools) |tools| allocator.free(tools);
    if (request.config.modules.prompt_templating.model.params) |p| {
        content.freeParams(p, allocator);
    }
}

/// SAP response → inbound messages response (bug #17-pattern ownership:
/// leaky-parsed args freed via `content.freeMessageOwnedBlocks`).
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

        if (message.content) |text| {
            if (text.len > 0) {
                try content_blocks.append(allocator, .{ .text = .{
                    .type = "text",
                    .text = try allocator.dupe(u8, text),
                } });
            }
        }

        if (message.tool_calls) |tool_calls| for (tool_calls) |tc| {
            try content_blocks.append(allocator, .{ .tool_use = .{
                .type = "tool_use",
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.function.name),
                .input = try content.parseToolArguments(tc.function.arguments, allocator),
            } });
        };
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = "" } });
    }

    const stop_reason: ?[]const u8 = if (final_result.choices.len > 0)
        content.transformStopReasonToMessages(final_result.choices[0].finish_reason)
    else
        "end_turn";

    return .{
        .id = try allocator.dupe(u8, final_result.id),
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = try allocator.dupe(u8, original_req.model),
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = if (final_result.usage) |u| .{
            .input_tokens = @intCast(u.prompt_tokens),
            .output_tokens = @intCast(u.completion_tokens),
        } else .{ .input_tokens = 0, .output_tokens = 0 },
    };
}

/// Free what `transformMessagesResponse` allocated.
pub fn cleanupMessagesResponse(
    inbound_response: Messages.Response,
    allocator: std.mem.Allocator,
) void {
    content.freeMessageOwnedBlocks(inbound_response.content, allocator);
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    allocator.free(inbound_response.content);
}

/// One SAP SSE line → Anthropic-format SSE events as ready bytes: the first
/// text delta lazily emits the protocol opening; the `[DONE]` sentinel emits
/// the closing triple with the accumulated usage.
pub fn transformMessagesStreamLine(
    line: []const u8,
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    // [DONE] — the SAP chat stream's terminal sentinel: close the synthesized
    // message. States that never opened still close as a complete message.
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (!state.sent_message_start or !state.sent_content_block_start) {
            const open = content.messagesOpen(state.original_model, allocator) orelse
                return .{ .skip = {} };
            out.appendSlice(allocator, open) catch return .{ .skip = {} };
            allocator.free(open);
            state.sent_message_start = true;
            state.sent_content_block_start = true;
        }

        const close = content.messagesClose(
            state.finish_reason orelse "end_turn",
            state.output_tokens,
            allocator,
        ) orelse return .{ .skip = {} };
        out.appendSlice(allocator, close) catch return .{ .skip = {} };
        allocator.free(close);

        return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const final_result = parsed.value.final_result;
    if (final_result.id.len == 0) return .{ .skip = {} };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Lazy protocol opening, once per stream.
    if (!state.sent_message_start or !state.sent_content_block_start) {
        const open = content.messagesOpen(state.original_model, allocator) orelse
            return .{ .skip = {} };
        out.appendSlice(allocator, open) catch return .{ .skip = {} };
        allocator.free(open);
        state.sent_message_start = true;
        state.sent_content_block_start = true;
    }

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];

        // Usage from the final chunk.
        if (final_result.usage) |usage| {
            state.input_tokens = @intCast(usage.prompt_tokens);
            state.output_tokens = @intCast(usage.completion_tokens);
        }

        if (choice.finish_reason) |reason| {
            if (reason.len > 0) {
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(
                    u8,
                    content.transformStopReasonToMessages(reason),
                ) catch null;
            }
        }

        // Text deltas (chat wire tool_calls stream deltas are not forwarded,
        // matching the other bridged providers).
        if (choice.delta.content) |text| {
            if (text.len > 0) {
                out.print(
                    allocator,
                    "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}\n\n",
                    .{std.json.fmt(text, .{})},
                ) catch return .{ .skip = {} };
            }
        }
    }

    if (out.items.len == 0) return .{ .skip = {} };
    return .{ .output = out.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — responses wire in, SAP envelope out
// ============================================================================

/// Stream state for the responses flow: accumulates id / terminal reason /
/// usage so `flushResponsesStream` can synthesize the closing Responses
/// events. The SAP inner chat stream ends with `[DONE]`.
pub const ResponsesStreamState = struct {
    // --- uniform core (P3) ---
    allocator: std.mem.Allocator,
    original_model: []const u8,
    response_id: []const u8 = "",
    finish_reason: ?[]const u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) ResponsesStreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
        };
    }

    pub fn deinit(self: *ResponsesStreamState) void {
        if (self.response_id.len > 0) self.allocator.free(self.response_id);
        self.response_id = "";
        if (self.finish_reason) |reason| self.allocator.free(reason);
        self.finish_reason = null;
    }
};

/// Inbound responses request → SAP envelope, pinned to `model`. Messages are
/// derived from `instructions` + `input` (text-first, mirroring the rt bridge);
/// `max_output_tokens` maps to `max_tokens` in params.
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    // Messages from instructions + input (text-first mirror of the rt bridge).
    var messages: std.ArrayList(Chat.Message) = .empty;
    errdefer {
        for (messages.items) |msg| content.freeMessageOwnedText(msg, allocator);
        messages.deinit(allocator);
    }

    if (request.instructions) |inst| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = inst }, // borrows the inbound parse
        });
    }

    switch (request.input) {
        .text => |text| try messages.append(allocator, .{
            .role = .user,
            .content = .{ .text = text },
        }),
        .items => |items| for (items) |item| {
            if (item != .object) continue;
            const role_val = item.object.get("role") orelse continue;
            if (role_val != .string) continue;
            const role = std.meta.stringToEnum(common.Role, role_val.string) orelse continue;

            const content_val = item.object.get("content");
            const message_content: ?Chat.MessageContent = blk: {
                const cv = content_val orelse break :blk null;
                switch (cv) {
                    .string => |s| break :blk .{ .text = s },
                    .array => |arr| {
                        for (arr.items) |part| {
                            if (part != .object) continue;
                            const text_val = part.object.get("text") orelse continue;
                            if (text_val == .string and text_val.string.len > 0) {
                                break :blk .{ .text = text_val.string };
                            }
                        }
                        break :blk null;
                    },
                    else => break :blk null,
                }
            };

            try messages.append(allocator, .{
                .role = role,
                .content = message_content,
                .tool_call_id = if (item.object.get("tool_call_id")) |v|
                    if (v == .string) v.string else null
                else
                    null,
            });
        },
    }

    const params = try content.buildParams(.{
        .temperature = request.temperature,
        .max_tokens = request.max_output_tokens,
        .top_p = request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    const chat_tools: ?[]const Chat.Tool = if (request.tools) |rt| blk: {
        const tools = try allocator.alloc(Chat.Tool, rt.len);
        for (rt, 0..) |t, i| tools[i] = switch (t) {
            .function => |f| .{ .type = "function", .function = f.function },
            .other => .{ .type = "function", .function = .{ .name = "", .description = null, .parameters = null, .strict = null } },
        };
        break :blk tools;
    } else null;

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

/// Free what `transformResponsesRequest` allocated: the params object and
/// the template slice. All message text borrows the inbound parse (unlike
/// the messages face, which dupes and frees via freeMessageOwnedText).
pub fn cleanupResponsesRequest(
    request: Sap.Request,
    allocator: std.mem.Allocator,
) void {
    const prompt = request.config.modules.prompt_templating.prompt;
    allocator.free(prompt.template);
    if (prompt.tools) |t| allocator.free(t);
    if (request.config.modules.prompt_templating.model.params) |p| {
        content.freeParams(p, allocator);
    }
}

/// SAP response → inbound responses response (message + function_call items,
/// echo fields from `original_req`, status from finish_reason).
pub fn transformResponsesResponse(
    upstream_response: Sap.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    const final_result = upstream_response.final_result;

    var output_items: std.ArrayList(Responses.OutputItem) = .empty;
    errdefer output_items.deinit(allocator);

    var content_parts: std.ArrayList(Responses.OutputContent) = .empty;
    errdefer content_parts.deinit(allocator);

    var finish_reason: []const u8 = "stop";

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];
        finish_reason = choice.finish_reason;

        if (choice.message.content) |c| {
            if (c.len > 0) {
                try content_parts.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, c),
                } });
            }
        }
    }

    if (final_result.choices.len > 0) {
        if (final_result.choices[0].message.tool_calls) |tool_calls| for (tool_calls) |tc| {
            try output_items.append(allocator, .{ .function_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .type = "function_call",
                .name = try allocator.dupe(u8, tc.function.name),
                .arguments = try allocator.dupe(u8, tc.function.arguments),
                .status = "completed",
            } });
        };
    }

    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try allocator.dupe(u8, final_result.id),
        .type = "message",
        .role = "assistant",
        .content = try content_parts.toOwnedSlice(allocator),
        .status = "completed",
    } });

    return .{
        .id = try allocator.dupe(u8, final_result.id),
        .object = "response",
        .created_at = @floatFromInt(final_result.created),
        .model = try allocator.dupe(u8, original_req.model),
        .status = "completed",
        .output = try output_items.toOwnedSlice(allocator),
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

/// Free what `transformResponsesResponse` allocated.
pub fn cleanupResponsesResponse(
    inbound_response: Responses.Response,
    allocator: std.mem.Allocator,
) void {
    allocator.free(inbound_response.id);
    allocator.free(inbound_response.model);
    for (inbound_response.output) |item| {
        switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |txt| allocator.free(txt.text),
                    .refusal => {},
                    .other => {},
                };
                allocator.free(m.content);
            },
            .function_call => |f| {
                allocator.free(f.id);
                allocator.free(f.name);
                allocator.free(f.arguments);
            },
            .reasoning => {},
            .other => {},
        }
    }
    allocator.free(inbound_response.output);
}

/// One SAP SSE line → Responses SSE events as ready bytes: text deltas emit
/// `response.output_text.delta`, tool-argument deltas emit
/// `response.function_call_arguments.delta`, the terminal chunk captures
/// finish_reason + usage for the flush.
pub fn transformResponsesStreamLine(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };
    const json_part = line["data: ".len..];

    // [DONE] handled by the pipeline; SAP chunks carry the terminal state.
    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const final_result = parsed.value.final_result;
    if (final_result.id.len == 0) return .{ .skip = {} };

    // Own the id (bug #18 class: dupe before the parse dies).
    if (state.response_id.len == 0) {
        state.response_id = allocator.dupe(u8, final_result.id) catch
            return .{ .skip = {} };
    }

    if (final_result.choices.len > 0) {
        const choice = final_result.choices[0];

        // Terminal reason FIRST (bug #20: a chunk may carry both).
        if (choice.finish_reason) |reason| {
            if (reason.len > 0) {
                if (state.finish_reason) |prev| allocator.free(prev);
                state.finish_reason = allocator.dupe(u8, reason) catch null;
            }
        }

        if (final_result.usage) |usage| {
            state.input_tokens = @intCast(usage.prompt_tokens);
            state.output_tokens = @intCast(usage.completion_tokens);
        }

        // Text delta → response.output_text.delta
        if (choice.delta.content) |text| {
            if (text.len > 0) {
                var buf: std.ArrayList(u8) = .empty;
                buf.print(
                    allocator,
                    "event: response.output_text.delta\ndata: {{\"type\":\"response.output_text.delta\",\"item_id\":\"{s}\",\"output_index\":0,\"content_index\":0,\"delta\":{f}}}\n\n",
                    .{ state.response_id, std.json.fmt(text, .{}) },
                ) catch return .{ .skip = {} };
                return .{ .output = buf.toOwnedSlice(allocator) catch return .{ .skip = {} } };
            }
        }

        // Tool-args delta → response.function_call_arguments.delta
        if (choice.delta.tool_calls) |tcs| {
            if (tcs.len > 0) {
                const args = if (tcs[0].function) |f| (f.arguments orelse "") else "";
                if (args.len > 0) {
                    var buf: std.ArrayList(u8) = .empty;
                    buf.print(
                        allocator,
                        "event: response.function_call_arguments.delta\ndata: {{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"{s}\",\"output_index\":0,\"delta\":{f}}}\n\n",
                        .{ state.response_id, std.json.fmt(args, .{}) },
                    ) catch return .{ .skip = {} };
                    return .{ .output = buf.toOwnedSlice(allocator) catch return .{ .skip = {} } };
                }
            }
        }
    }

    return .{ .skip = {} };
}

/// Emit the terminal Responses events after the upstream stream ends
/// (`response.output_item.done` + `response.completed`, or
/// `response.incomplete` when the finish reason is `length`) with the usage
/// accumulated in `state`. Returns `null` when there is nothing to flush.
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const reason = state.finish_reason orelse return null;
    const status: []const u8 = if (std.mem.eql(u8, reason, "length")) "incomplete" else "completed";
    const input_tok = state.input_tokens;
    const output_tok = state.output_tokens;

    var buf: std.ArrayList(u8) = .empty;
    buf.print(
        allocator,
        \\event: response.output_item.done
        \\data: {{"type":"response.output_item.done","item":{{"id":"{s}","type":"message","role":"assistant","status":"{s}"}}}}
        \\
        \\event: response.completed
        \\data: {{"type":"response.completed","response":{{"id":"{s}","object":"response","model":"{s}","status":"{s}","usage":{{"input_tokens":{d},"output_tokens":{d},"total_tokens":{d}}}}}}}
        \\
        \\
    ,
        .{ state.response_id, status, state.response_id, state.original_model, status, input_tok, output_tok, input_tok + output_tok },
    ) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}
