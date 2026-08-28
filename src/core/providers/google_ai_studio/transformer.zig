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

//! Transformer for Google AI Studio (Gemini) provider.
//!
//! Implements the full transformer interface expected by completion.zig:
//!
//!   OpenAI Chat path  (/v1/chat/completions):
//!     transform / cleanupRequest / transformResponse / cleanupResponse
//!     StreamState / transformStreamLine
//!
//!   Anthropic path   (/v1/messages):
//!     transformFromAnthropic / cleanupFromAnthropicRequest
//!     transformToAnthropicResponse / cleanupAnthropicResponse
//!     AnthropicStreamState / transformStreamLineToAnthropic
//!
//!   OpenAI Responses path (/v1/responses):
//!     ResponsesStreamState
//!     transformFromResponses / cleanupFromRequest
//!     transformToResponse / cleanupResponsesResp
//!     transformStreamLineToResponses / flushResponsesStream
//!
//!   Models:
//!     transformModelsResponse

const std = @import("std");
const time = @import("../../time.zig");
const OpenAIChat = @import("../openai/chat_types.zig");
const OpenAIResponses = @import("../openai/responses_types.zig");
const Anthropic = @import("../anthropic/types.zig");
const Google = @import("types.zig");
const log = @import("../../log.zig");
const rt = @import("../openai/responses_transformer.zig");

// ============================================================================
// Helpers
// ============================================================================

/// Map Gemini finishReason to OpenAI finish_reason.
fn mapFinishReason(reason: ?[]const u8) []const u8 {
    if (reason == null) return "stop";
    const r = reason.?;
    if (std.mem.eql(u8, r, "STOP")) return "stop";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "length";
    if (std.mem.eql(u8, r, "SAFETY")) return "content_filter";
    if (std.mem.eql(u8, r, "RECITATION")) return "content_filter";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_calls";
    return "stop";
}

/// Map Gemini finishReason to Anthropic stop_reason.
fn mapFinishReasonToAnthropic(reason: ?[]const u8) ?[]const u8 {
    if (reason == null) return "end_turn";
    const r = reason.?;
    if (std.mem.eql(u8, r, "STOP")) return "end_turn";
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return "max_tokens";
    if (std.mem.eql(u8, r, "FUNCTION_CALL")) return "tool_use";
    return "end_turn";
}

/// Extract plain text from the first Gemini candidate.
fn extractTextFromResponse(response: Google.Response, allocator: std.mem.Allocator) ![]const u8 {
    if (response.candidates.len == 0) return try allocator.dupe(u8, "");

    const candidate = response.candidates[0];
    var parts_text = std.ArrayList([]const u8).empty;
    defer parts_text.deinit(allocator);

    for (candidate.content.parts) |part| {
        switch (part) {
            .text => |tp| {
                if (tp.text.len > 0) try parts_text.append(allocator, tp.text);
            },
            else => {},
        }
    }

    if (parts_text.items.len == 0) return try allocator.dupe(u8, "");
    return try std.mem.join(allocator, "", parts_text.items);
}

/// Extract OpenAI tool calls from Gemini function_call parts.
fn extractToolCallsFromResponse(
    response: Google.Response,
    allocator: std.mem.Allocator,
) !?[]OpenAIChat.ToolCall {
    if (response.candidates.len == 0) return null;

    var tool_calls = std.ArrayList(OpenAIChat.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    for (response.candidates[0].content.parts) |part| {
        switch (part) {
            .function_call => |fc| {
                var args_buf = std.ArrayList(u8).empty;
                defer args_buf.deinit(allocator);
                try args_buf.print(allocator, "{f}", .{std.json.fmt(fc.args, .{})});
                const args_str = try args_buf.toOwnedSlice(allocator);

                // Generate a synthetic id — Gemini does not provide call ids
                const call_id = try std.fmt.allocPrint(allocator, "call_{s}", .{fc.name});

                try tool_calls.append(allocator, .{ .function = .{
                    .id = call_id,
                    .type = "function",
                    .function = .{ .name = fc.name, .arguments = args_str },
                } });
            },
            else => {},
        }
    }

    if (tool_calls.items.len == 0) return null;
    return try tool_calls.toOwnedSlice(allocator);
}

// ============================================================================
// Models Response Transformation
// ============================================================================

/// Transform Google ModelsResponse to OpenAIChat.Model array.
/// Only includes models that support generateContent.
pub fn transformModelsResponse(
    allocator: std.mem.Allocator,
    response: std.json.Parsed(Google.ModelsResponse),
    provider_name: []const u8,
) ![]OpenAIChat.Model {
    const models_data = response.value.models;

    var result = std.ArrayList(OpenAIChat.Model).empty;
    errdefer result.deinit(allocator);

    for (models_data) |m| {
        // Filter: only models that support generateContent
        var supports_generate = false;
        for (m.supported_generation_methods) |method| {
            if (std.mem.eql(u8, method, "generateContent")) {
                supports_generate = true;
                break;
            }
        }
        if (!supports_generate) continue;

        // Strip the "models/" prefix from the name to get the bare model id
        const bare_name = if (std.mem.startsWith(u8, m.name, "models/"))
            m.name["models/".len..]
        else
            m.name;

        if (bare_name.len == 0) continue;

        const prefixed_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, bare_name });

        try result.append(allocator, OpenAIChat.Model{
            .id = prefixed_id,
            .object = "model",
            .created = 0,
            .owned_by = try allocator.dupe(u8, "google"),
        });
    }

    return try result.toOwnedSlice(allocator);
}

// ============================================================================
// Request Transformation: OpenAI Chat → Gemini
// ============================================================================

/// Convert OpenAI messages to Gemini Content array.
/// System messages are separated and returned as a SystemInstruction; other
/// messages are returned as the contents slice.
fn buildContents(
    messages: []const OpenAIChat.Message,
    allocator: std.mem.Allocator,
) !struct {
    contents: []Google.Content,
    system_text: ?[]const u8,
} {
    var system_parts = std.ArrayList([]const u8).empty;
    defer system_parts.deinit(allocator);

    var contents = std.ArrayList(Google.Content).empty;
    errdefer contents.deinit(allocator);

    for (messages) |msg| {
        switch (msg.role) {
            .system, .developer => {
                if (msg.content) |content| {
                    switch (content) {
                        .text => |t| try system_parts.append(allocator, t),
                        .parts => |ps| {
                            for (ps) |p| {
                                if (p == .text) try system_parts.append(allocator, p.text.text);
                            }
                        },
                    }
                }
            },
            .user => {
                const role = "user";
                var parts = std.ArrayList(Google.Part).empty;
                defer parts.deinit(allocator);

                if (msg.content) |content| {
                    switch (content) {
                        .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                        .parts => |ps| {
                            for (ps) |p| {
                                switch (p) {
                                    .text => |tp| try parts.append(allocator, .{ .text = .{ .text = tp.text } }),
                                    else => {}, // skip audio/file/refusal
                                }
                            }
                        },
                    }
                }

                if (parts.items.len == 0) {
                    try parts.append(allocator, .{ .text = .{ .text = "" } });
                }

                const owned_parts = try parts.toOwnedSlice(allocator);
                try contents.append(allocator, .{ .role = role, .parts = owned_parts });
            },
            .assistant => {
                const role = "model";
                var parts = std.ArrayList(Google.Part).empty;
                defer parts.deinit(allocator);

                if (msg.content) |content| {
                    switch (content) {
                        .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
                        .parts => |ps| {
                            for (ps) |p| {
                                if (p == .text) try parts.append(allocator, .{ .text = .{ .text = p.text.text } });
                            }
                        },
                    }
                }

                // Tool calls from assistant → function_call parts
                if (msg.tool_calls) |tool_calls| {
                    for (tool_calls) |tc| {
                        switch (tc) {
                            .function => |f| {
                                const args_json = std.json.parseFromSlice(std.json.Value, allocator, f.function.arguments, .{}) catch null;
                                const args_val: std.json.Value = if (args_json) |parsed| parsed.value else .null;
                                try parts.append(allocator, .{ .function_call = .{
                                    .name = f.function.name,
                                    .args = args_val,
                                } });
                            },
                            else => {},
                        }
                    }
                }

                if (parts.items.len == 0) {
                    try parts.append(allocator, .{ .text = .{ .text = "" } });
                }

                const owned_parts = try parts.toOwnedSlice(allocator);
                try contents.append(allocator, .{ .role = role, .parts = owned_parts });
            },
            .tool, .function => {
                // Tool results become user messages with function_response parts
                const role = "user";
                var parts = std.ArrayList(Google.Part).empty;
                defer parts.deinit(allocator);

                const func_name = msg.tool_call_id orelse "unknown_function";
                const content_text: []const u8 = if (msg.content) |c| switch (c) {
                    .text => |t| t,
                    .parts => |ps| if (ps.len > 0 and ps[0] == .text) ps[0].text.text else "",
                } else "";

                var resp_obj = std.json.ObjectMap{};
                defer resp_obj.deinit(allocator);
                try resp_obj.put(allocator, "output", .{ .string = content_text });

                try parts.append(allocator, .{ .function_response = .{
                    .name = func_name,
                    .response = .{ .object = resp_obj },
                } });

                const owned_parts = try parts.toOwnedSlice(allocator);
                try contents.append(allocator, .{ .role = role, .parts = owned_parts });
            },
        }
    }

    // Gemini requires at least one content item and the last must be from "user"
    if (contents.items.len == 0) {
        var fallback_parts = try allocator.alloc(Google.Part, 1);
        fallback_parts[0] = .{ .text = .{ .text = "" } };
        try contents.append(allocator, .{ .role = "user", .parts = fallback_parts });
    }

    const system_text: ?[]const u8 = if (system_parts.items.len > 0)
        try std.mem.join(allocator, "\n\n", system_parts.items)
    else
        null;

    return .{
        .contents = try contents.toOwnedSlice(allocator),
        .system_text = system_text,
    };
}

/// Build a Gemini tool array from OpenAI tools.
fn buildTools(
    tools: []const OpenAIChat.Tool,
    allocator: std.mem.Allocator,
) ![]Google.GeminiTool {
    var declarations = std.ArrayList(Google.FunctionDeclaration).empty;
    defer declarations.deinit(allocator);

    for (tools) |tool| {
        switch (tool) {
            .function => |f| {
                try declarations.append(allocator, .{
                    .name = f.function.name,
                    .description = f.function.description,
                    .parameters = f.function.parameters,
                });
            },
            else => {},
        }
    }

    if (declarations.items.len == 0) {
        return try allocator.alloc(Google.GeminiTool, 0);
    }

    const gemini_tools = try allocator.alloc(Google.GeminiTool, 1);
    gemini_tools[0] = .{ .function_declarations = try declarations.toOwnedSlice(allocator) };
    return gemini_tools;
}

/// Build Gemini ToolConfig from OpenAI tool_choice.
fn buildToolConfig(tool_choice: std.json.Value) ?Google.ToolConfig {
    switch (tool_choice) {
        .string => |s| {
            if (std.mem.eql(u8, s, "none")) {
                return .{ .function_calling_config = .{ .mode = "NONE" } };
            } else if (std.mem.eql(u8, s, "required")) {
                return .{ .function_calling_config = .{ .mode = "ANY" } };
            }
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        .object => |obj| {
            if (obj.get("type")) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "function")) {
                    return .{ .function_calling_config = .{ .mode = "ANY" } };
                }
            }
            return .{ .function_calling_config = .{ .mode = "AUTO" } };
        },
        else => return null,
    }
}

/// Transform OpenAI chat request → Google.Request.
pub fn transform(
    request: OpenAIChat.Request,
    target_model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    const built = try buildContents(request.messages, allocator);

    var system_instruction: ?Google.SystemInstruction = null;
    if (built.system_text) |sys| {
        var si_parts = try allocator.alloc(Google.Part, 1);
        si_parts[0] = .{ .text = .{ .text = sys } };
        system_instruction = .{ .parts = si_parts };
    }

    const tools: ?[]Google.GeminiTool = if (request.tools) |t|
        try buildTools(t, allocator)
    else
        null;

    const tool_config: ?Google.ToolConfig = if (request.tool_choice) |tc|
        buildToolConfig(tc)
    else
        null;

    const raw_max_tokens = request.max_tokens orelse request.max_completion_tokens;
    // Gemini models have a max output of 65536 tokens — clamp to avoid 400 errors
    const max_tokens: ?u32 = if (raw_max_tokens) |m| @min(m, 65536) else null;

    const generation_config = Google.GenerationConfig{
        .temperature = request.temperature,
        .top_p = request.top_p,
        .max_output_tokens = max_tokens,
        .stop_sequences = request.stop,
    };

    return Google.Request{
        .model = target_model,
        .payload = .{
            .contents = built.contents,
            .system_instruction = system_instruction,
            .tools = tools,
            .tool_config = tool_config,
            .generation_config = generation_config,
        },
    };
}

/// Cleanup allocated resources from transform().
pub fn cleanupRequest(request: Google.Request, allocator: std.mem.Allocator) void {
    for (request.payload.contents) |content| {
        allocator.free(content.parts);
    }
    allocator.free(request.payload.contents);

    if (request.payload.system_instruction) |si| {
        allocator.free(si.parts);
    }

    if (request.payload.tools) |tools| {
        for (tools) |tool| {
            if (tool.function_declarations) |fds| {
                allocator.free(fds);
            }
        }
        allocator.free(tools);
    }
}

// ============================================================================
// Response Transformation: Gemini → OpenAI Chat
// ============================================================================

/// Transform Google.Response → OpenAIChat.Response.
pub fn transformResponse(
    response: Google.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !OpenAIChat.Response {
    const content_text = try extractTextFromResponse(response, allocator);
    const tool_calls = try extractToolCallsFromResponse(response, allocator);

    const finish_reason = if (response.candidates.len > 0)
        mapFinishReason(response.candidates[0].finish_reason)
    else
        "stop";

    const message = OpenAIChat.ResponseMessage{
        .role = .assistant,
        .content = if (content_text.len > 0) content_text else null,
        .tool_calls = tool_calls,
        .function_call = null,
    };

    const choice = OpenAIChat.ResponseChoice{
        .index = 0,
        .message = message,
        .finish_reason = finish_reason,
        .logprobs = null,
    };

    var choices = try allocator.alloc(OpenAIChat.ResponseChoice, 1);
    choices[0] = choice;

    const usage = OpenAIChat.Usage{
        .prompt_tokens = response.usage_metadata.prompt_token_count,
        .completion_tokens = response.usage_metadata.candidates_token_count,
        .total_tokens = response.usage_metadata.total_token_count,
    };

    const model_str = try std.fmt.allocPrint(allocator, "google_ai_studio/{s}", .{original_model});
    const id_str = try std.fmt.allocPrint(allocator, "chatcmpl-{d}", .{time.timestamp()});

    return OpenAIChat.Response{
        .id = id_str,
        .object = "chat.completion",
        .created = time.timestamp(),
        .model = model_str,
        .choices = choices,
        .usage = usage,
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Cleanup resources from transformResponse().
pub fn cleanupResponse(response: OpenAIChat.Response, allocator: std.mem.Allocator) void {
    if (response.choices.len > 0) {
        if (response.choices[0].message.content) |c| allocator.free(c);
        if (response.choices[0].message.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                switch (tc) {
                    .function => |f| {
                        allocator.free(f.id);
                        allocator.free(f.function.arguments);
                    },
                    .custom => {},
                }
            }
            allocator.free(tool_calls);
        }
    }
    allocator.free(response.choices);
    allocator.free(response.id);
    allocator.free(response.model);
}

// ============================================================================
// Streaming State and Transformation: Gemini → OpenAI Chat
// ============================================================================

/// Streaming state for Gemini → OpenAI chat streaming.
pub const StreamState = struct {
    allocator: std.mem.Allocator,
    original_model: []const u8,
    created: i64,
    message_id: []const u8,
    input_tokens: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) StreamState {
        return .{
            .allocator = allocator,
            .original_model = original_model,
            .created = time.timestamp(),
            .message_id = "chatcmpl-google",
        };
    }

    pub fn deinit(self: *StreamState) void {
        _ = self;
    }
};

/// Transform a single Gemini SSE line to OpenAI StreamLineResult.
/// Gemini streams `data: {json}` lines where each chunk is a full Response.
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) OpenAIChat.StreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };

    const json_part = line["data: ".len..];

    const chunk = std.json.parseFromSlice(
        Google.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        log.debug("[Google] Failed to parse stream chunk: {}", .{err});
        return .{ .skip = {} };
    };
    defer chunk.deinit();

    if (chunk.value.candidates.len == 0) return .{ .skip = {} };

    const candidate = chunk.value.candidates[0];

    // Collect text from parts
    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);
    for (candidate.content.parts) |part| {
        switch (part) {
            .text => |tp| text_buf.appendSlice(allocator, tp.text) catch {},
            else => {},
        }
    }

    // Track usage from final chunk
    if (chunk.value.usage_metadata.total_token_count > 0) {
        state.input_tokens = chunk.value.usage_metadata.prompt_token_count;
    }

    const finish_reason = candidate.finish_reason;
    const is_final = finish_reason != null and !std.mem.eql(u8, finish_reason.?, "");

    const delta = OpenAIChat.Delta{
        .content = if (text_buf.items.len > 0) text_buf.items else null,
    };

    const usage: ?OpenAIChat.Usage = if (is_final and chunk.value.usage_metadata.total_token_count > 0)
        OpenAIChat.Usage{
            .prompt_tokens = chunk.value.usage_metadata.prompt_token_count,
            .completion_tokens = chunk.value.usage_metadata.candidates_token_count,
            .total_tokens = chunk.value.usage_metadata.total_token_count,
        }
    else
        null;

    const stream_choice = OpenAIChat.StreamChoice{
        .index = 0,
        .delta = delta,
        .finish_reason = if (is_final) mapFinishReason(finish_reason) else null,
    };

    var choices: [1]OpenAIChat.StreamChoice = .{stream_choice};

    const stream_chunk = OpenAIChat.StreamChunk{
        .id = state.message_id,
        .object = "chat.completion.chunk",
        .created = state.created,
        .model = state.original_model,
        .choices = &choices,
        .usage = usage,
    };

    // Serialise → re-parse to get owned Parsed(StreamChunk)
    var buf = std.ArrayList(u8).empty;
    buf.print(allocator, "{f}", .{std.json.fmt(stream_chunk, .{})}) catch return .{ .skip = {} };
    defer buf.deinit(allocator);

    const parsed = std.json.parseFromSlice(
        OpenAIChat.StreamChunk,
        allocator,
        buf.items,
        .{ .allocate = .alloc_always },
    ) catch return .{ .skip = {} };

    return .{ .chunk = parsed };
}

// ============================================================================
// Anthropic path (/v1/messages): Anthropic.Request → Google.Request
// ============================================================================

/// Transform Anthropic.Request → Google.Request (for /v1/messages endpoint).
pub fn transformFromAnthropic(
    request: Anthropic.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    // Build contents from Anthropic messages
    var contents = std.ArrayList(Google.Content).empty;
    errdefer contents.deinit(allocator);

    for (request.messages) |msg| {
        const role: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "model",
        };

        var parts = std.ArrayList(Google.Part).empty;
        defer parts.deinit(allocator);

        switch (msg.content) {
            .text => |t| try parts.append(allocator, .{ .text = .{ .text = t } }),
            .blocks => |blocks| {
                for (blocks) |block| {
                    switch (block) {
                        .text => |tb| try parts.append(allocator, .{ .text = .{ .text = tb.text } }),
                        .tool_use => |tu| {
                            try parts.append(allocator, .{ .function_call = .{
                                .name = tu.name,
                                .args = tu.input,
                            } });
                        },
                        .tool_result => |tr| {
                            const resp_text = tr.content orelse "";
                            var resp_obj = std.json.ObjectMap{};
                            defer resp_obj.deinit(allocator);
                            try resp_obj.put(allocator, "output", .{ .string = resp_text });
                            try parts.append(allocator, .{ .function_response = .{
                                .name = tr.tool_use_id,
                                .response = .{ .object = resp_obj },
                            } });
                        },
                        else => {},
                    }
                }
            },
        }

        if (parts.items.len == 0) {
            try parts.append(allocator, .{ .text = .{ .text = "" } });
        }

        const owned_parts = try parts.toOwnedSlice(allocator);
        try contents.append(allocator, .{ .role = role, .parts = owned_parts });
    }

    if (contents.items.len == 0) {
        var fallback_parts = try allocator.alloc(Google.Part, 1);
        fallback_parts[0] = .{ .text = .{ .text = "" } };
        try contents.append(allocator, .{ .role = "user", .parts = fallback_parts });
    }

    // System instruction
    var system_instruction: ?Google.SystemInstruction = null;
    if (request.system) |sys| {
        var si_parts = try allocator.alloc(Google.Part, 1);
        si_parts[0] = .{ .text = .{ .text = sys } };
        system_instruction = .{ .parts = si_parts };
    }

    const generation_config = Google.GenerationConfig{
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_k = request.top_k,
        .max_output_tokens = @min(request.max_tokens, 65536),
        .stop_sequences = request.stop_sequences,
    };

    return Google.Request{
        .model = model,
        .payload = .{
            .contents = try contents.toOwnedSlice(allocator),
            .system_instruction = system_instruction,
            .tools = null,
            .tool_config = null,
            .generation_config = generation_config,
        },
    };
}

/// Cleanup resources from transformFromAnthropic().
pub fn cleanupFromAnthropicRequest(request: Google.Request, allocator: std.mem.Allocator) void {
    cleanupRequest(request, allocator);
}

// ============================================================================
// Anthropic path (/v1/messages): Google.Response → Anthropic.Response
// ============================================================================

/// Transform Google.Response → Anthropic.Response.
pub fn transformToAnthropicResponse(
    response: Google.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !Anthropic.Response {
    _ = original_model;

    var content_blocks = std.ArrayList(Anthropic.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    if (response.candidates.len > 0) {
        for (response.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    try content_blocks.append(allocator, .{ .text = .{
                        .type = "text",
                        .text = tp.text,
                    } });
                },
                .function_call => |fc| {
                    try content_blocks.append(allocator, .{ .tool_use = .{
                        .type = "tool_use",
                        .id = fc.name, // Gemini has no call id — use name
                        .name = fc.name,
                        .input = fc.args,
                    } });
                },
                else => {},
            }
        }
    }

    if (content_blocks.items.len == 0) {
        try content_blocks.append(allocator, .{ .text = .{ .type = "text", .text = "" } });
    }

    const stop_reason = if (response.candidates.len > 0)
        mapFinishReasonToAnthropic(response.candidates[0].finish_reason)
    else
        "end_turn";

    const model_str = try std.fmt.allocPrint(allocator, "google_ai_studio/gemini", .{});
    const id_str = try std.fmt.allocPrint(allocator, "msg_{d}", .{time.timestamp()});

    return Anthropic.Response{
        .id = id_str,
        .type = "message",
        .role = "assistant",
        .content = try content_blocks.toOwnedSlice(allocator),
        .model = model_str,
        .stop_reason = stop_reason,
        .stop_sequence = null,
        .usage = .{
            .input_tokens = response.usage_metadata.prompt_token_count,
            .output_tokens = response.usage_metadata.candidates_token_count,
        },
    };
}

/// Cleanup resources from transformToAnthropicResponse().
pub fn cleanupAnthropicResponse(response: Anthropic.Response, allocator: std.mem.Allocator) void {
    allocator.free(response.content);
    allocator.free(response.id);
    allocator.free(response.model);
}

// ============================================================================
// Anthropic Streaming State (/v1/messages streaming path)
// ============================================================================

pub const AnthropicStreamLineResult = Anthropic.AnthropicStreamLineResult;

/// State for Gemini → Anthropic streaming.
pub const AnthropicStreamState = struct {
    allocator: std.mem.Allocator,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    message_id: []const u8 = "msg_google",
    model: []const u8 = "google_ai_studio/gemini",
    sent_start: bool = false,
    block_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) AnthropicStreamState {
        _ = original_model;
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AnthropicStreamState) void {
        _ = self;
    }

    pub fn getUsage(self: *const AnthropicStreamState) Anthropic.StreamUsage {
        return .{ .input_tokens = self.input_tokens, .output_tokens = self.output_tokens };
    }
};

/// Transform a Gemini SSE chunk line to Anthropic-format SSE output.
/// Returns AnthropicStreamLineResult (.output = owned []u8 or .skip).
pub fn transformStreamLineToAnthropic(
    line: []const u8,
    state: *AnthropicStreamState,
    allocator: std.mem.Allocator,
) AnthropicStreamLineResult {
    if (!std.mem.startsWith(u8, line, "data: ")) return .{ .skip = {} };

    const json_part = line["data: ".len..];

    const chunk = std.json.parseFromSlice(
        Google.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer chunk.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const alloc = allocator;

    // Emit message_start on the first chunk
    if (!state.sent_start) {
        state.sent_start = true;
        const start_json = std.fmt.allocPrint(alloc,
            \\event: message_start
            \\data: {{"type":"message_start","message":{{"id":"{s}","type":"message","role":"assistant","content":[],"model":"{s}","stop_reason":null,"stop_sequence":null,"usage":{{"input_tokens":0,"output_tokens":0}}}}}}
            \\
            \\event: content_block_start
            \\data: {{"type":"content_block_start","index":0,"content_block":{{"type":"text","text":""}}}}
            \\
            \\event: ping
            \\data: {{"type":"ping"}}
            \\
            \\
        , .{ state.message_id, state.model }) catch return .{ .skip = {} };
        defer alloc.free(start_json);
        out.appendSlice(alloc, start_json) catch return .{ .skip = {} };
    }

    // Emit text_delta for each text part
    if (chunk.value.candidates.len > 0) {
        for (chunk.value.candidates[0].content.parts) |part| {
            switch (part) {
                .text => |tp| {
                    if (tp.text.len == 0) continue;
                    // Escape the text for JSON embedding
                    var escaped = std.ArrayList(u8).empty;
                    defer escaped.deinit(alloc);
                    for (tp.text) |c| {
                        switch (c) {
                            '"' => escaped.appendSlice(alloc, "\\\"") catch {},
                            '\\' => escaped.appendSlice(alloc, "\\\\") catch {},
                            '\n' => escaped.appendSlice(alloc, "\\n") catch {},
                            '\r' => escaped.appendSlice(alloc, "\\r") catch {},
                            '\t' => escaped.appendSlice(alloc, "\\t") catch {},
                            else => escaped.append(alloc, c) catch {},
                        }
                    }
                    const delta_json = std.fmt.allocPrint(alloc,
                        "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n",
                        .{escaped.items},
                    ) catch continue;
                    defer alloc.free(delta_json);
                    out.appendSlice(alloc, delta_json) catch {};
                },
                else => {},
            }
        }

        // Emit stop events on final chunk
        const finish_reason = chunk.value.candidates[0].finish_reason;
        if (finish_reason != null) {
            const stop_reason = mapFinishReasonToAnthropic(finish_reason) orelse "end_turn";

            // Update usage
            state.input_tokens = chunk.value.usage_metadata.prompt_token_count;
            state.output_tokens = chunk.value.usage_metadata.candidates_token_count;

            const stop_json = std.fmt.allocPrint(alloc,
                \\event: content_block_stop
                \\data: {{"type":"content_block_stop","index":0}}
                \\
                \\event: message_delta
                \\data: {{"type":"message_delta","delta":{{"stop_reason":"{s}","stop_sequence":null}},"usage":{{"output_tokens":{d}}}}}
                \\
                \\event: message_stop
                \\data: {{"type":"message_stop"}}
                \\
                \\
            , .{ stop_reason, state.output_tokens }) catch return .{ .skip = {} };
            defer alloc.free(stop_json);
            out.appendSlice(alloc, stop_json) catch {};
        }
    }

    if (out.items.len == 0) return .{ .skip = {} };

    const owned = alloc.dupe(u8, out.items) catch return .{ .skip = {} };
    return .{ .output = owned };
}

// ============================================================================
// OpenAI Responses path (/v1/responses)
// Delegate to the shared responses_transformer helpers via the Anthropic bridge.
// ============================================================================

pub const ResponsesStreamState = rt.MessagesStreamState;

/// Transform OpenAI Responses.Request → Google.Request.
pub fn transformFromResponses(
    request: OpenAIResponses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Google.Request {
    // Convert Responses → Anthropic → Google
    const anthro_req = try rt.toMessages(request, model, allocator);
    defer rt.cleanupToMessages(anthro_req, allocator);
    return transformFromAnthropic(anthro_req, model, allocator);
}

/// Cleanup from transformFromResponses().
pub fn cleanupFromRequest(request: Google.Request, allocator: std.mem.Allocator) void {
    cleanupRequest(request, allocator);
}

/// Transform Google.Response → OpenAIResponses.Response.
pub fn transformToResponse(
    response: Google.Response,
    original_req: OpenAIResponses.Request,
    allocator: std.mem.Allocator,
) !OpenAIResponses.Response {
    // Convert Google → Anthropic → Responses
    const anthro_resp = try transformToAnthropicResponse(response, allocator, original_req.model);
    defer cleanupAnthropicResponse(anthro_resp, allocator);
    return rt.fromMessagesResponse(anthro_resp, original_req, allocator);
}

/// Cleanup from transformToResponse().
pub fn cleanupResponsesResp(resp: OpenAIResponses.Response, allocator: std.mem.Allocator) void {
    rt.cleanupFromMessagesResponse(resp, allocator);
}

/// Transform a Gemini SSE line to OpenAI Responses SSE output.
/// Routes through the Anthropic stream state.
pub fn transformStreamLineToResponses(
    line: []const u8,
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    // Convert the Gemini chunk line to an Anthropic SSE line, then feed
    // that into the responses_transformer Anthropic helpers.
    var tmp_state = AnthropicStreamState.init(allocator, "");
    defer tmp_state.deinit();

    const anthro_result = transformStreamLineToAnthropic(line, &tmp_state, allocator);
    switch (anthro_result) {
        .skip => return null,
        .output => |anthro_lines| {
            defer allocator.free(anthro_lines);
            // Feed each individual `event:...\ndata:...\n\n` block into the
            // MessagesStreamState processor.
            var remaining = anthro_lines;
            var last_out: ?[]const u8 = null;
            while (remaining.len > 0) {
                // Find next double-newline separator
                const sep = std.mem.indexOf(u8, remaining, "\n\n") orelse remaining.len - 1;
                const block = remaining[0 .. sep + 2];
                remaining = if (sep + 2 < remaining.len) remaining[sep + 2 ..] else &.{};

                // Extract data: line from the block
                var line_iter = std.mem.splitScalar(u8, block, '\n');
                while (line_iter.next()) |l| {
                    if (std.mem.startsWith(u8, l, "data: ")) {
                        if (rt.fromMessagesStreamLine(l, state, allocator)) |out| {
                            if (last_out) |prev| allocator.free(prev);
                            last_out = out;
                        }
                    }
                }
            }
            return last_out;
        },
    }
}

/// Flush any buffered state at end of stream.
pub fn flushResponsesStream(state: *ResponsesStreamState, allocator: std.mem.Allocator) ?[]const u8 {
    return rt.fromMessagesStreamFlush(state, allocator);
}

// ============================================================================
// Unit Tests
// ============================================================================
