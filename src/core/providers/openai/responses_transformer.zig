// SPDX-License-Identifier: Apache-2.0
//! Responses API transformer — bridges between all inbound schemas and the
//! canonical ResponsesRequest/ResponsesResponse format, and between the
//! canonical format and each upstream provider's wire format.

const std = @import("std");
const Completion = @import("chat_types.zig");
const Responses = @import("responses_types.zig");
const Anthropic = @import("../anthropic/types.zig");
const SapAiCore = @import("../sap_ai_core/types.zig");
const log = @import("../../log.zig");

// ============================================================================
// Inbound bridge: legacy schemas → canonical ResponsesRequest
// ============================================================================

/// Convert a /v1/chat/completions request into a ResponsesRequest.
/// Called by chatComplete before delegating to responsesComplete.
pub fn fromChat(req: Completion.Request, allocator: std.mem.Allocator) !Responses.ResponsesRequest {
    // Build input[] from messages — system messages become instructions
    var instructions_parts = std.ArrayList([]const u8).empty;
    defer instructions_parts.deinit(allocator);
    var input_items = std.ArrayList(std.json.Value).empty;
    defer input_items.deinit(allocator);

    for (req.messages) |msg| {
        if (msg.role == .system or msg.role == .developer) {
            if (msg.content) |c| switch (c) {
                .text => |t| if (t.len > 0) try instructions_parts.append(allocator, t),
                .parts => {},
            };
            continue;
        }
        // Serialize each non-system message as a JSON object for input[]
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(msg, .{ .emit_null_optional_fields = false })});
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try input_items.append(allocator, parsed.value);
    }

    const instructions: ?[]const u8 = if (instructions_parts.items.len > 0)
        try std.mem.join(allocator, "\n\n", instructions_parts.items)
    else
        null;

    const input: Responses.InputParam = if (input_items.items.len > 0)
        .{ .items = try input_items.toOwnedSlice(allocator) }
    else
        .{ .text = "" };

    return Responses.ResponsesRequest{
        .model = req.model,
        .input = input,
        .instructions = instructions,
        .stream = req.stream,
        .tools = req.tools,
        .tool_choice = req.tool_choice,
        .parallel_tool_calls = req.parallel_tool_calls,
        .temperature = req.temperature,
        .top_p = req.top_p,
        .top_logprobs = req.top_logprobs,
        .store = req.store,
        .metadata = req.metadata,
        .moderation = req.moderation,
        .safety_identifier = req.safety_identifier,
        .prompt_cache_key = req.prompt_cache_key,
        .prompt_cache_options = req.prompt_cache_options,
        .user = req.user,
        .service_tier = req.service_tier,
        .max_output_tokens = req.max_completion_tokens orelse req.max_tokens,
        .text = if (req.response_format) |rf| .{ .format = rf } else null,
        .reasoning = if (req.reasoning_effort) |re| blk: {
            var obj: std.json.ObjectMap = .{};
            try obj.put(allocator, "effort", .{ .string = re });
            break :blk std.json.Value{ .object = try obj.clone(allocator) };
        } else null,
        .truncation = null,
        .background = null,
        .max_tool_calls = null,
        .conversation = null,
        .context_management = null,
        .include = null,
        .previous_response_id = null,
    };
}

pub fn cleanupFromChat(req: Responses.ResponsesRequest, allocator: std.mem.Allocator) void {
    if (req.instructions) |s| allocator.free(s);
    switch (req.input) {
        .items => |items| allocator.free(items),
        .text => {},
    }
    if (req.reasoning) |r| {
        var obj = r.object;
        obj.deinit(allocator);
    }
}

/// Convert an Anthropic /v1/messages request into a ResponsesRequest.
pub fn fromMessages(req: Anthropic.Request, allocator: std.mem.Allocator) !Responses.ResponsesRequest {
    // Build input[] from Anthropic messages
    var input_items = std.ArrayList(std.json.Value).empty;
    defer input_items.deinit(allocator);

    for (req.messages) |msg| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "{f}", .{std.json.fmt(msg, .{ .emit_null_optional_fields = false })});
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try input_items.append(allocator, parsed.value);
    }

    const input: Responses.InputParam = if (input_items.items.len > 0)
        .{ .items = try input_items.toOwnedSlice(allocator) }
    else
        .{ .text = "" };

    return Responses.ResponsesRequest{
        .model = req.model,
        .input = input,
        .instructions = req.system,
        .stream = req.stream,
        .temperature = req.temperature,
        .top_p = req.top_p,
        .max_output_tokens = req.max_tokens,
        .metadata = if (req.metadata) |m| blk: {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);
            try buf.print(allocator, "{f}", .{std.json.fmt(m, .{})});
            const p = try std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{ .allocate = .alloc_always });
            defer p.deinit();
            break :blk p.value;
        } else null,
        .thinking = req.thinking,
        .betas = req.betas,
    };
}

pub fn cleanupFromMessages(req: Responses.ResponsesRequest, allocator: std.mem.Allocator) void {
    switch (req.input) {
        .items => |items| allocator.free(items),
        .text => {},
    }
}

// ============================================================================
// Outbound: ResponsesRequest → upstream wire formats
// ============================================================================

/// ResponsesRequest → completion_types.Request (for legacy /v1/chat/completions upstream)
pub fn toChat(req: Responses.ResponsesRequest, model: []const u8, allocator: std.mem.Allocator) !Completion.Request {
    // Build messages[] from input + instructions
    var messages = std.ArrayList(Completion.Message).empty;
    errdefer messages.deinit(allocator);

    // System message from instructions
    if (req.instructions) |inst| {
        try messages.append(allocator, .{
            .role = .system,
            .content = .{ .text = inst },
        });
    }

    switch (req.input) {
        .text => |t| {
            try messages.append(allocator, .{
                .role = .user,
                .content = .{ .text = t },
            });
        },
        .items => |items| {
            for (items) |item| {
                if (item != .object) continue;
                const role_val = item.object.get("role") orelse continue;
                if (role_val != .string) continue;
                const role = std.meta.stringToEnum(Completion.Role, role_val.string) orelse continue;
                const content: ?Completion.MessageContent = if (item.object.get("content")) |cv| switch (cv) {
                    .string => |s| .{ .text = s },
                    .null => null,
                    else => null,
                } else null;
                try messages.append(allocator, .{
                    .role = role,
                    .content = content,
                    .tool_call_id = if (item.object.get("tool_call_id")) |v| if (v == .string) v.string else null else null,
                });
            }
        },
    }

    const msgs = try messages.toOwnedSlice(allocator);

    return Completion.Request{
        .model = model,
        .messages = msgs,
        .stream = req.stream,
        .temperature = req.temperature,
        .top_p = req.top_p,
        .top_logprobs = req.top_logprobs,
        .max_completion_tokens = req.max_output_tokens,
        .tools = req.tools,
        .tool_choice = req.tool_choice,
        .parallel_tool_calls = req.parallel_tool_calls,
        .store = req.store,
        .metadata = req.metadata,
        .moderation = req.moderation,
        .safety_identifier = req.safety_identifier,
        .prompt_cache_key = req.prompt_cache_key,
        .prompt_cache_options = req.prompt_cache_options,
        .user = req.user,
        .service_tier = req.service_tier,
        .response_format = if (req.text) |t| t.format else null,
        .reasoning_effort = if (req.reasoning) |r| blk: {
            if (r == .object) break :blk if (r.object.get("effort")) |e| (if (e == .string) e.string else null) else null;
            break :blk null;
        } else null,
    };
}

pub fn cleanupToChat(req: Completion.Request, allocator: std.mem.Allocator) void {
    allocator.free(req.messages);
}

/// completion_types.Response → ResponsesResponse
pub fn fromChatResponse(
    resp: Completion.Response,
    original_req: Responses.ResponsesRequest,
    allocator: std.mem.Allocator,
) !Responses.ResponsesResponse {
    var output_items = std.ArrayList(Responses.OutputItem).empty;
    errdefer output_items.deinit(allocator);

    if (resp.choices.len > 0) {
        const choice = resp.choices[0];
        const msg = choice.message;

        // Build content array
        var content = std.ArrayList(Responses.OutputContent).empty;
        errdefer content.deinit(allocator);

        if (msg.content) |c| {
            if (c.len > 0) {
                try content.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, c),
                } });
            }
        }

        const content_slice = try content.toOwnedSlice(allocator);

        // Message output item
        try output_items.append(allocator, .{ .message = .{
            .id = try allocator.dupe(u8, resp.id),
            .type = "message",
            .role = "assistant",
            .content = content_slice,
            .status = "completed",
        } });

        // Tool call output items
        if (msg.tool_calls) |tcs| {
            for (tcs) |tc| {
                switch (tc) {
                    .function => |f| try output_items.append(allocator, .{ .function_call = .{
                        .id = try allocator.dupe(u8, f.id),
                        .type = "function_call",
                        .name = try allocator.dupe(u8, f.function.name),
                        .arguments = try allocator.dupe(u8, f.function.arguments),
                        .status = "completed",
                    } }),
                    .custom => {},
                }
            }
        }

        // Map finish_reason to status
        const status: []const u8 = if (std.mem.eql(u8, choice.finish_reason, "length"))
            "incomplete"
        else
            "completed";

        const usage = Responses.ResponsesUsage{
            .input_tokens = if (resp.usage) |u| u.prompt_tokens else 0,
            .output_tokens = if (resp.usage) |u| u.completion_tokens else 0,
            .total_tokens = if (resp.usage) |u| u.total_tokens else 0,
        };

        return Responses.ResponsesResponse{
            .id = try allocator.dupe(u8, resp.id),
            .object = "response",
            .created_at = @floatFromInt(resp.created),
            .model = try allocator.dupe(u8, original_req.model),
            .status = status,
            .output = try output_items.toOwnedSlice(allocator),
            .usage = usage,
            .temperature = original_req.temperature,
            .top_p = original_req.top_p,
            .tools = null,
            .tool_choice = original_req.tool_choice,
            .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
            .store = original_req.store,
            .max_output_tokens = original_req.max_output_tokens,
            .metadata = original_req.metadata,
            .service_tier = resp.service_tier,
        };
    }

    // Empty response fallback
    return Responses.ResponsesResponse{
        .id = try allocator.dupe(u8, resp.id),
        .object = "response",
        .created_at = @floatFromInt(resp.created),
        .model = try allocator.dupe(u8, original_req.model),
        .status = "completed",
        .output = &.{},
        .usage = .{},
    };
}

pub fn cleanupFromChatResponse(resp: Responses.ResponsesResponse, allocator: std.mem.Allocator) void {
    allocator.free(resp.id);
    allocator.free(resp.model);
    for (resp.output) |item| {
        switch (item) {
            .message => |m| {
                allocator.free(m.id);
                for (m.content) |c| switch (c) {
                    .output_text => |t| allocator.free(t.text),
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
    allocator.free(resp.output);
}

/// ResponsesRequest → Anthropic.Request (for anthropic upstream)
pub fn toMessages(req: Responses.ResponsesRequest, model: []const u8, allocator: std.mem.Allocator) !Anthropic.Request {
    var messages = std.ArrayList(Anthropic.Message).empty;
    errdefer messages.deinit(allocator);

    switch (req.input) {
        .text => |t| {
            try messages.append(allocator, .{
                .role = .user,
                .content = .{ .text = t },
            });
        },
        .items => |items| {
            for (items) |item| {
                if (item != .object) continue;
                const role_val = item.object.get("role") orelse continue;
                if (role_val != .string) continue;
                const anthro_role: Anthropic.Role = if (std.mem.eql(u8, role_val.string, "assistant"))
                    .assistant
                else
                    .user;
                const content_val = item.object.get("content") orelse continue;
                const content_text: []const u8 = switch (content_val) {
                    .string => |s| s,
                    else => continue,
                };
                try messages.append(allocator, .{
                    .role = anthro_role,
                    .content = .{ .text = content_text },
                });
            }
        },
    }

    const msgs = try messages.toOwnedSlice(allocator);

    return Anthropic.Request{
        .model = model,
        .messages = msgs,
        .system = req.instructions,
        .max_tokens = req.max_output_tokens orelse 4096,
        .temperature = req.temperature,
        .top_p = req.top_p,
        .stream = req.stream,
        .thinking = req.thinking,
        .betas = req.betas,
        .service_tier = req.service_tier,
    };
}

pub fn cleanupToMessages(req: Anthropic.Request, allocator: std.mem.Allocator) void {
    allocator.free(req.messages);
}

/// Anthropic.Response → ResponsesResponse
pub fn fromMessagesResponse(
    resp: Anthropic.Response,
    original_req: Responses.ResponsesRequest,
    allocator: std.mem.Allocator,
) !Responses.ResponsesResponse {
    var output_items = std.ArrayList(Responses.OutputItem).empty;
    errdefer output_items.deinit(allocator);

    var content = std.ArrayList(Responses.OutputContent).empty;
    errdefer content.deinit(allocator);

    for (resp.content) |block| {
        switch (block) {
            .text => |t| {
                if (t.text.len > 0) try content.append(allocator, .{ .output_text = .{
                    .type = "output_text",
                    .text = try allocator.dupe(u8, t.text),
                } });
            },
            .tool_use => |tu| {
                var args_buf = std.ArrayList(u8).empty;
                defer args_buf.deinit(allocator);
                try args_buf.print(allocator, "{f}", .{std.json.fmt(tu.input, .{})});
                try output_items.append(allocator, .{ .function_call = .{
                    .id = try allocator.dupe(u8, tu.id),
                    .type = "function_call",
                    .name = try allocator.dupe(u8, tu.name),
                    .arguments = try args_buf.toOwnedSlice(allocator),
                    .status = "completed",
                } });
            },
            .thinking, .redacted_thinking => {},
        }
    }

    const content_slice = try content.toOwnedSlice(allocator);
    try output_items.insert(allocator, 0, .{ .message = .{
        .id = try allocator.dupe(u8, resp.id),
        .type = "message",
        .role = "assistant",
        .content = content_slice,
        .status = "completed",
    } });

    const status: []const u8 = if (resp.stop_reason) |sr|
        if (std.mem.eql(u8, sr, "max_tokens")) "incomplete" else "completed"
    else
        "completed";

    return Responses.ResponsesResponse{
        .id = try allocator.dupe(u8, resp.id),
        .object = "response",
        .created_at = 0,
        .model = try allocator.dupe(u8, original_req.model),
        .status = status,
        .output = try output_items.toOwnedSlice(allocator),
        .usage = .{
            .input_tokens = resp.usage.input_tokens,
            .output_tokens = resp.usage.output_tokens,
            .total_tokens = resp.usage.input_tokens + resp.usage.output_tokens,
        },
        .temperature = original_req.temperature,
        .top_p = original_req.top_p,
        .parallel_tool_calls = original_req.parallel_tool_calls orelse true,
        .store = original_req.store,
        .max_output_tokens = original_req.max_output_tokens,
        .metadata = original_req.metadata,
    };
}

pub fn cleanupFromMessagesResponse(resp: Responses.ResponsesResponse, allocator: std.mem.Allocator) void {
    cleanupFromChatResponse(resp, allocator);
}

/// ResponsesRequest → SapAiCore.Request
pub fn toSap(req: Responses.ResponsesRequest, model: []const u8, allocator: std.mem.Allocator) !SapAiCore.Request {
    // Bridge through Chat then into SAP format
    const chat_req = try toChat(req, model, allocator);
    defer cleanupToChat(chat_req, allocator);

    // Reuse sap transformer's transform logic by building params from chat request
    var params_obj: std.json.ObjectMap = .{};
    defer params_obj.deinit(allocator);
    if (chat_req.temperature) |v| try params_obj.put(allocator, "temperature", .{ .float = v });
    if (chat_req.max_completion_tokens) |v| try params_obj.put(allocator, "max_tokens", .{ .integer = v });
    if (chat_req.top_p) |v| try params_obj.put(allocator, "top_p", .{ .float = v });

    const params: ?std.json.Value = if (params_obj.count() > 0)
        .{ .object = try params_obj.clone(allocator) }
    else
        null;

    // Need to dupe messages since chat_req is about to be freed
    const duped_messages = try allocator.dupe(SapAiCore.OpenAI.Message, chat_req.messages);

    return SapAiCore.Request{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = duped_messages,
                        .tools = req.tools,
                        .tool_choice = req.tool_choice,
                        .response_format = if (req.text) |t| t.format else null,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{ .enabled = req.stream orelse false },
        },
    };
}

pub fn cleanupToSap(req: SapAiCore.Request, allocator: std.mem.Allocator) void {
    allocator.free(req.config.modules.prompt_templating.prompt.template);
    if (req.config.modules.prompt_templating.model.params) |p| {
        var obj = p.object;
        obj.deinit(allocator);
    }
}

/// SapAiCore.Response → ResponsesResponse
pub fn fromSapResponse(
    resp: SapAiCore.Response,
    original_req: Responses.ResponsesRequest,
    allocator: std.mem.Allocator,
) !Responses.ResponsesResponse {
    return fromChatResponse(resp.final_result, original_req, allocator);
}

pub fn cleanupFromSapResponse(resp: Responses.ResponsesResponse, allocator: std.mem.Allocator) void {
    cleanupFromChatResponse(resp, allocator);
}

// ============================================================================
// Response → Chat (for chatComplete response path when upstream is responses)
// ============================================================================

/// ResponsesResponse → completion_types.Response
pub fn toChatResponse(
    resp: Responses.ResponsesResponse,
    allocator: std.mem.Allocator,
) !Completion.Response {
    // Collect text and tool calls from output items
    var text_parts = std.ArrayList([]const u8).empty;
    defer text_parts.deinit(allocator);
    var tool_calls = std.ArrayList(Completion.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    for (resp.output) |item| {
        switch (item) {
            .message => |m| {
                for (m.content) |c| {
                    switch (c) {
                        .output_text => |t| try text_parts.append(allocator, t.text),
                        .refusal, .other => {},
                    }
                }
            },
            .function_call => |f| {
                try tool_calls.append(allocator, .{ .function = .{
                    .id = try allocator.dupe(u8, f.id),
                    .type = "function",
                    .function = .{
                        .name = try allocator.dupe(u8, f.name),
                        .arguments = try allocator.dupe(u8, f.arguments),
                    },
                } });
            },
            .reasoning, .other => {},
        }
    }

    const content = if (text_parts.items.len > 0)
        try std.mem.join(allocator, "", text_parts.items)
    else
        null;

    const tc_slice: ?[]const Completion.ToolCall = if (tool_calls.items.len > 0)
        try tool_calls.toOwnedSlice(allocator)
    else
        null;

    const finish_reason: []const u8 = if (std.mem.eql(u8, resp.status, "incomplete"))
        "length"
    else if (tc_slice != null)
        "tool_calls"
    else
        "stop";

    const msg = Completion.ResponseMessage{
        .role = .assistant,
        .content = content,
        .tool_calls = tc_slice,
    };

    const choices = try allocator.alloc(Completion.ResponseChoice, 1);
    choices[0] = .{
        .index = 0,
        .message = msg,
        .finish_reason = try allocator.dupe(u8, finish_reason),
    };

    return Completion.Response{
        .id = try allocator.dupe(u8, resp.id),
        .object = "chat.completion",
        .created = @intFromFloat(resp.created_at),
        .model = try allocator.dupe(u8, resp.model),
        .choices = choices,
        .usage = Completion.Usage{
            .prompt_tokens = resp.usage.input_tokens,
            .completion_tokens = resp.usage.output_tokens,
            .total_tokens = resp.usage.total_tokens,
        },
        .service_tier = resp.service_tier,
    };
}

pub fn cleanupToChatResponse(resp: Completion.Response, allocator: std.mem.Allocator) void {
    allocator.free(resp.id);
    allocator.free(resp.model);
    for (resp.choices) |choice| {
        if (choice.message.content) |c| allocator.free(c);
        if (choice.message.tool_calls) |tcs| {
            for (tcs) |tc| switch (tc) {
                .function => |f| {
                    allocator.free(f.id);
                    allocator.free(f.function.name);
                    allocator.free(f.function.arguments);
                },
                .custom => {},
            };
            allocator.free(tcs);
        }
        allocator.free(choice.finish_reason);
    }
    allocator.free(resp.choices);
}

// ============================================================================
// Streaming state
// ============================================================================

pub const StreamState = struct {
    original_model: []const u8,
    response_id: []const u8 = "",
    input_tokens: u32 = 0,

    pub fn init(_: std.mem.Allocator, original_model: []const u8) StreamState {
        return .{ .original_model = original_model };
    }
    pub fn deinit(_: *StreamState) void {}
};
