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
const log = @import("../../log.zig");
const chat_transformer = @import("../openai/chat_transformer.zig");

// ============================================================================
// Contract
// ============================================================================

pub const appendsDoneMarker = true;

// ============================================================================
// Flow: /v1/models
// ============================================================================


/// Convert a SAP AI Core error response to OpenAI error format (for /v1/chat/completions and /v1/responses).
pub fn transformToOpenAIError(err: Sap.ErrorResponse) common.ErrorResponse {
    return .{ .@"error" = .{
        .message = err.@"error".message orelse "Upstream error",
        .type = "server_error",
        .param = null,
        .code = null,
    } };
}

/// Convert a SAP AI Core error response to Anthropic error format (for /v1/messages).
pub fn transformToMessagesError(err: Sap.ErrorResponse) Messages.ErrorResponse {
    return .{ .@"error" = .{
        .type = "server_error",
        .message = err.@"error".message orelse "Upstream error",
    } };
}

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

/// Stream state is shared with `chat_transformer` — the two were field-identical
/// duplicates, so SAP aliases rather than re-declaring it.
pub const ChatStreamState = chat_transformer.ChatStreamState;

/// Inbound chat request → SAP envelope, pinned to model.
///
/// The chat wire IS the SAP inner schema, so the request is already in the right
/// shape: `chat_transformer.transformChatRequest` pins the model and injects
/// `stream_options`, and the messages/tools/tool_choice/response_format are
/// carried straight into `prompt.template`. Only the sampling fields move into
/// `model.params` (the SAP envelope's slot for them).
///
/// Because a chat client may send `content: null` (e.g. an assistant turn that
/// is only a tool call) and the SAP envelope rejects null, the borrowed message
/// list is shallow-copied and normalized via `content.normalizeNonNullContent`.
///
/// Dropped at the envelope boundary (no SAP slot): stop, user, parallel_tool_calls,
/// reasoning_effort, seed, logprobs/top_logprobs, n, presence_penalty,
/// frequency_penalty, logit_bias, modalities, audio, store, metadata,
/// prediction, service_tier, web_search_options, moderation, verbosity.
pub fn transformChatRequest(
    request: Chat.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    const pinned = try chat_transformer.transformChatRequest(request, model, allocator);
    errdefer chat_transformer.cleanupChatRequest(pinned, allocator);

    // SAP orchestration rejects content: null — it requires an empty string.
    // The inbound list is borrowed, so normalize an owned shallow copy.
    const template = try allocator.dupe(Chat.Message, pinned.messages);
    errdefer {
        for (template) |msg| content.freeNormalizedContent(msg, allocator);
        allocator.free(template);
    }
    try content.normalizeNonNullContent(template, allocator);

    const max_tokens: ?u32 = pinned.max_completion_tokens orelse pinned.max_tokens;
    const params = try content.buildParams(.{
        .temperature = pinned.temperature,
        .max_tokens = max_tokens,
        .top_p = pinned.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = template,
                        .tools = pinned.tools,
                        .tool_choice = pinned.tool_choice,
                        .response_format = pinned.response_format,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                .enabled = pinned.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformChatRequest allocated: the normalized template copy
/// (its empty-string replacements plus the slice) and the params object.
/// Message payloads and tools/tool_choice borrow from the inbound request.
pub fn cleanupChatRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    if (request.config.modules.prompt_templating) |pt| {
        for (pt.prompt.template) |msg| content.freeNormalizedContent(msg, allocator);
        allocator.free(pt.prompt.template);
        if (pt.model.params) |p| content.freeParams(p, allocator);
    }
}

/// SAP response → inbound chat response.
///
/// Unwraps the envelope's `final_result` (a `Chat.Response`) and delegates to
/// `chat_transformer.transformChatResponse`, which pins the model to the name the
/// client sent. The rest of the response is passed through from SAP's envelope,
/// which owns the inner tree — so only the model string is freshly allocated.
///
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures (SAP envelope fields, not chat wire).
pub fn transformChatResponse(
    upstream_response: Sap.Response,
    original_req: Chat.Request,
    allocator: std.mem.Allocator,
) !Chat.Response {
    return chat_transformer.transformChatResponse(
        upstream_response.final_result,
        original_req,
        allocator,
    );
}

/// Free what transformChatResponse allocated (delegated to chat_transformer).
pub fn cleanupChatResponse(inbound_response: Chat.Response, allocator: std.mem.Allocator) void {
    chat_transformer.cleanupChatResponse(inbound_response, allocator);
}

/// One SAP SSE line → Chat.ChatStreamLineResult (typed StreamChunk slice).
///
/// SAP wraps the chat chunk in an envelope, so this only unwraps `final_result`
/// (or an `error` payload) and hands the parsed `Chat.StreamChunk` to
/// `chat_transformer.transformChatStreamChunk` — the shared chunk-level mapping
/// used by the native chat path. Empty chunks (templating-only) are skipped.
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

    const chunk = switch (parsed.value) {
        // SAP error payload → OpenAI error chunk (SAP-specific: the code/type
        // classification comes from SAP, not from the chat wire).
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
    if (chunk.id.len == 0) return .{ .skip = {} };

    return chat_transformer.transformChatStreamChunk(chunk, state, allocator);
}


// ============================================================================
// Flow: /v1/messages — messages wire in, SAP envelope out
// ============================================================================

/// SAP's streaming `delta` is an OpenAIChat.StreamChunk, identical to the chat
/// flow, so we reuse the chat transformer's lazy block-machine state and its
/// `appendMessagesDeltaEvents` (reasoning → thinking, content → text, streamed
/// tool calls → tool_use). Aliasing keeps a single implementation.
pub const MessagesStreamState = chat_transformer.MessagesStreamState;

/// Inbound messages request → SAP envelope, pinned to model.
///
/// Delegates the whole Messages↔Chat mapping to `chat_transformer`, then wraps
/// the resulting `Chat.Request` in the SAP orchestration envelope:
///   messages → prompt.template, tools → prompt.tools,
///   tool_choice → prompt.tool_choice, stream → stream.enabled,
///   temperature / max_tokens / top_p → model.params.
///
/// The Messages→Chat mapping itself (system block joining, tool_result/image/
/// tool_use block handling, tool_choice, metadata.user_id) is owned and
/// maintained by `chat_transformer` — SAP does not re-implement it. Because
/// `chat_transformer` produces nullable `content` while the SAP envelope
/// rejects null, messages are normalized via `content.normalizeNonNullContent`.
///
/// Dropped at the envelope boundary (no SAP slot): stream_options, stop,
/// user, top_k, thinking, betas, service_tier, output_config, container,
/// inference_geo, cache_control, fallbacks. Unmappable fields are logged
/// by `chat_transformer` at debug level.
pub fn transformMessagesRequest(
    request: Messages.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    const chat_request = try chat_transformer.transformMessagesRequest(request, model, allocator);
    errdefer chat_transformer.cleanupMessagesRequest(chat_request, allocator);

    // SAP orchestration rejects content: null — it requires an empty string.
    // Normalize the very slice chat_transformer allocated, in place, so there
    // remains a single owner: the delegated Chat.Request, freed in cleanup.
    try content.normalizeNonNullContent(@constCast(chat_request.messages), allocator);

    if (chat_request.stop) |_| log.debug("[sap_ai_core] dropping Messages stop_sequences: no envelope field", .{});
    if (chat_request.user) |u| log.debug("[sap_ai_core] dropping Messages metadata.user_id '{s}': no envelope field", .{u});

    const params = try content.buildParams(.{
        .temperature = chat_request.temperature,
        .max_tokens = chat_request.max_tokens,
        .top_p = chat_request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = chat_request.messages,
                        .tools = chat_request.tools,
                        .tool_choice = chat_request.tool_choice,
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
                .enabled = chat_request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformMessagesRequest allocated: the delegated `Chat.Request`
/// (template messages, tools, tool_choice, plus the null-content replacements)
/// and the params object.
///
/// `chat_transformer.cleanupMessagesRequest` owns the Messages<->Chat allocations,
/// so the envelope is unpacked back into a `Chat.Request` and handed to it — the
/// same code that frees a native OpenAI request frees the SAP one.
pub fn cleanupMessagesRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    const pt = request.config.modules.prompt_templating.?;
    const prompt = pt.prompt;

    // Hand the original messages/tools/tool_choice back to the delegated cleanup,
    // which owns every allocation — including the empty-string content
    // replacements made by `normalizeNonNullContent`.
    chat_transformer.cleanupMessagesRequest(.{
        .model = pt.model.name,
        .messages = prompt.template,
        .tools = prompt.tools,
        .tool_choice = prompt.tool_choice,
    }, allocator);

    if (pt.model.params) |p| content.freeParams(p, allocator);
}

/// SAP response → inbound messages response.
///
/// Unwraps the envelope's `final_result` (a `Chat.Response`) and delegates the
/// whole Chat→Messages mapping to `chat_transformer.transformMessagesResponse`
/// — content blocks, reasoning→thinking, tool_use blocks, stop_reason mapping and
/// usage (including cache token detail) are owned and maintained there.
///
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures (SAP envelope fields, not Messages wire).
pub fn transformMessagesResponse(
    upstream_response: Sap.Response,
    original_req: Messages.Request,
    allocator: std.mem.Allocator,
) !Messages.Response {
    return chat_transformer.transformMessagesResponse(
        upstream_response.final_result,
        original_req,
        allocator,
    );
}

/// Free what transformMessagesResponse allocated (delegated to chat_transformer).
pub fn cleanupMessagesResponse(inbound_response: Messages.Response, allocator: std.mem.Allocator) void {
    chat_transformer.cleanupMessagesResponse(inbound_response, allocator);
}

/// Terminal flush when the stream ends without a finish_reason/[DONE].
/// Delegates to the shared chat transformer (SAP reuses its stream state).
pub fn finalizeMessagesStream(
    state: *MessagesStreamState,
    allocator: std.mem.Allocator,
) ?[]Messages.SseEvent {
    return chat_transformer.finalizeMessagesStream(state, allocator);
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

    // [DONE] — synthesize the terminal (close open block + message_delta + stop).
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        chat_transformer.finishMessagesStream(state, &events, allocator);
        return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
    }

    const parsed = std.json.parseFromSlice(
        Sap.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return .{ .skip = {} };
    defer parsed.deinit();

    const chunk = switch (parsed.value) {
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
    if (chunk.id.len == 0) return .{ .skip = {} };

    // Whether this chunk carries a terminal finish_reason (SAP has no [DONE]).
    const has_finish = chunk.choices.len > 0 and
        if (chunk.choices[0].finish_reason) |r| r.len > 0 else false;

    // Delegate the delta body to the shared chat transformer (reasoning →
    // thinking, content → text, streamed tool calls → tool_use). This also
    // records usage and the raw finish_reason into `state`.
    chat_transformer.appendMessagesDeltaEvents(chunk, state, &events, allocator);

    // SAP signals completion via a chunk's finish_reason (not a separate [DONE]),
    // so synthesize the terminal here once we've seen it.
    if (has_finish) {
        chat_transformer.finishMessagesStream(state, &events, allocator);
    }

    if (events.items.len == 0) return .{ .skip = {} };
    return .{ .events = events.toOwnedSlice(allocator) catch return .{ .skip = {} } };
}

// ============================================================================
// Flow: /v1/responses — responses wire in, SAP envelope out
// ============================================================================

/// Stream state is shared with `chat_transformer` — the two were field-identical
/// duplicates, so SAP aliases rather than re-declaring it.
pub const ResponsesStreamState = chat_transformer.ResponsesStreamState;

/// Inbound responses request → SAP envelope, pinned to model.
///
/// Delegates the whole Responses↔Chat mapping to `chat_transformer`, then wraps the
/// resulting `Chat.Request`: messages → prompt.template, tools → prompt.tools,
/// tool_choice → prompt.tool_choice, response_format (text.format) →
/// prompt.response_format, stream → stream.enabled, temperature /
/// max_output_tokens / top_p → model.params.
///
/// Because `chat_transformer` produces nullable `content` while the SAP envelope
/// rejects null, messages are normalized via `content.normalizeNonNullContent`.
///
/// Dropped at the envelope boundary (no SAP slot): stream_options, user, stop,
/// parallel_tool_calls, reasoning, reasoning_effort, and the remaining
/// store/include/truncation/background/max_tool_calls/conversation/moderation/
/// safety_identifier/prompt_cache_* /prompt/verbosity/service_tier fields.
pub fn transformResponsesRequest(
    request: Responses.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !Sap.Request {
    const chat_request = try chat_transformer.transformResponsesRequest(request, model, allocator);
    errdefer chat_transformer.cleanupResponsesRequest(chat_request, allocator);

    // SAP orchestration rejects content: null — it requires an empty string.
    // Normalize the very slice chat_transformer allocated, in place, so there
    // remains a single owner: the delegated Chat.Request, freed in cleanup.
    try content.normalizeNonNullContent(@constCast(chat_request.messages), allocator);

    if (chat_request.user) |u| log.debug("[sap_ai_core] dropping Responses user '{s}': no envelope field", .{u});
    if (chat_request.stop) |_| log.debug("[sap_ai_core] dropping Responses stop: no envelope field", .{});

    const params = try content.buildParams(.{
        .temperature = chat_request.temperature,
        .max_tokens = chat_request.max_completion_tokens orelse chat_request.max_tokens,
        .top_p = chat_request.top_p,
    }, allocator);
    errdefer if (params) |pv| content.freeParams(pv, allocator);

    return .{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = chat_request.messages,
                        .tools = chat_request.tools,
                        .tool_choice = chat_request.tool_choice,
                        .response_format = chat_request.response_format,
                    },
                    .model = .{
                        .name = model,
                        .version = "latest",
                        .params = params,
                    },
                },
            },
            .stream = .{
                .enabled = chat_request.stream orelse false,
                .chunk_size = null,
            },
        },
    };
}

/// Free what transformResponsesRequest allocated: the delegated `Chat.Request`
/// (template messages, tools, tool_choice, plus the null-content replacements)
/// and the params object.
///
/// `chat_transformer.cleanupResponsesRequest` owns the Responses\u2194Chat allocations,
/// so the envelope is unpacked back into a `Chat.Request` and handed to it \u2014 the
/// same code that frees a native OpenAI request frees the SAP one.
pub fn cleanupResponsesRequest(request: Sap.Request, allocator: std.mem.Allocator) void {
    const pt = request.config.modules.prompt_templating.?;
    const prompt = pt.prompt;

    chat_transformer.cleanupResponsesRequest(.{
        .model = pt.model.name,
        .messages = prompt.template,
        .tools = prompt.tools,
        .tool_choice = prompt.tool_choice,
    }, allocator);

    if (pt.model.params) |p| content.freeParams(p, allocator);
}

/// SAP response → inbound responses response.
///
/// Unwraps the envelope's `final_result` (a `Chat.Response`) and delegates the
/// whole Chat→Responses mapping to `chat_transformer.transformResponsesResponse`
/// — output items, output_text / function_call, status (incomplete on
/// "length") and usage are owned and maintained there.
///
/// Skipped: Sap.Response.request_id, intermediate_results,
///   intermediate_failures (SAP envelope fields, not Responses wire).
pub fn transformResponsesResponse(
    upstream_response: Sap.Response,
    original_req: Responses.Request,
    allocator: std.mem.Allocator,
) !Responses.Response {
    return chat_transformer.transformResponsesResponse(
        upstream_response.final_result,
        original_req,
        allocator,
    );
}

/// Free what transformResponsesResponse allocated (delegated to chat_transformer).
pub fn cleanupResponsesResponse(inbound_response: Responses.Response, allocator: std.mem.Allocator) void {
    chat_transformer.cleanupResponsesResponse(inbound_response, allocator);
}

/// One SAP SSE line → Responses.ResponsesStreamLineResult (typed StreamEvent slice).
///
/// SAP wraps the chat chunk in an envelope, so this only unwraps `final_result`
/// (or an `error` payload) and hands the parsed `Chat.StreamChunk` to
/// `chat_transformer.transformResponsesStreamChunk` — the shared chunk-level
/// mapping used by the native responses path. The SAP inner stream ends with
/// `[DONE]`, handled by the pipeline (appendsDoneMarker = true).
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

    const chunk = switch (parsed.value) {
        // SAP error payload → Responses stream_error event (SAP-specific: the
        // code classification comes from SAP, not from the chat wire).
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
    if (chunk.id.len == 0) return .{ .skip = {} };

    return chat_transformer.transformResponsesStreamChunk(chunk, state, allocator);
}

/// Emit the terminal Responses events after `[DONE]`: output_item_done +
/// response_completed (or response_incomplete when finish_reason="length").
/// Returns null when no finish_reason was captured.
/// Emit the terminal Responses events after `[DONE]`: output_item_done +
/// response_completed (or response_incomplete when finish_reason="length").
/// Returns null when no finish_reason was captured.
///
/// Delegates to `chat_transformer.flushResponsesStream` (identical mapping,
/// plus cache-token details in the terminal usage).
pub fn flushResponsesStream(
    state: *ResponsesStreamState,
    allocator: std.mem.Allocator,
) ?[]const Responses.StreamEvent {
    return chat_transformer.flushResponsesStream(state, allocator);
}
