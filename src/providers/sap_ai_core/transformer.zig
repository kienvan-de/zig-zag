const std = @import("std");
const OpenAI = @import("../openai/types.zig");
const SapAiCore = @import("types.zig");

/// Parsed OpenAI response from final_result JSON
const ParsedFinalResult = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const OpenAI.ResponseChoice,
    usage: ?OpenAI.Usage = null,
};

/// Parsed OpenAI stream chunk from final_result JSON
const ParsedStreamChunk = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const OpenAI.StreamChoice,
    usage: ?OpenAI.Usage = null,
};

// ============================================================================
// Streaming State
// ============================================================================

/// State for SAP AI Core streaming (tracks original model name with provider prefix)
pub const StreamState = struct {
    original_model: []const u8,

    pub fn init(allocator: std.mem.Allocator, original_model: []const u8) StreamState {
        _ = allocator;
        return .{ .original_model = original_model };
    }

    pub fn deinit(self: *StreamState) void {
        _ = self;
    }
};

// ============================================================================
// Request Transformation: OpenAI -> SAP AI Core
// ============================================================================

/// Transform OpenAI request to SAP AI Core orchestration format
pub fn transform(
    request: OpenAI.Request,
    model: []const u8,
    allocator: std.mem.Allocator,
) !SapAiCore.Request {
    _ = allocator;

    return SapAiCore.Request{
        .config = .{
            .modules = .{
                .prompt_templating = .{
                    .prompt = .{
                        .template = request.messages,
                        .tools = request.tools,
                        .model = .{
                            .name = model,
                            .version = "latest",
                        },
                    },
                },
            },
            .stream = if (request.stream) |s|
                .{ .enabled = s, .chunk_size = null }
            else
                .{ .enabled = false, .chunk_size = null },
        },
    };
}

/// Cleanup transformed request
pub fn cleanupRequest(request: SapAiCore.Request, allocator: std.mem.Allocator) void {
    _ = request;
    _ = allocator;
    // No cleanup needed - request uses references from original
}

// ============================================================================
// Response Transformation: SAP AI Core -> OpenAI
// ============================================================================

/// Transform SAP AI Core response to OpenAI format
pub fn transformResponse(
    response: SapAiCore.Response,
    allocator: std.mem.Allocator,
    original_model: []const u8,
) !OpenAI.Response {
    // Stringify final_result json.Value and re-parse as typed struct
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try buffer.writer(allocator).print("{f}", .{std.json.fmt(response.final_result, .{})});

    const parsed = std.json.parseFromSlice(
        ParsedFinalResult,
        allocator,
        buffer.items,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidFinalResult;
    defer parsed.deinit();

    // Allocate model string with provider prefix
    const model_str = try allocator.dupe(u8, original_model);

    // Deep copy choices since parsed will be freed
    const choices = try allocator.dupe(OpenAI.ResponseChoice, parsed.value.choices);

    return OpenAI.Response{
        .id = try allocator.dupe(u8, parsed.value.id),
        .object = try allocator.dupe(u8, parsed.value.object),
        .created = parsed.value.created,
        .model = model_str,
        .choices = choices,
        .usage = parsed.value.usage orelse OpenAI.Usage{
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
        },
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Cleanup transformed response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    allocator.free(response.id);
    allocator.free(response.object);
    allocator.free(response.model);
    allocator.free(response.choices);
}

// ============================================================================
// Streaming Transformation
// ============================================================================

/// Transform a single SSE line for streaming responses
/// Extracts final_result from SAP AI Core wrapper and adds provider prefix to model
/// Returns null if line should be skipped
pub fn transformStreamLine(
    line: []const u8,
    state: *StreamState,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const original_model = state.original_model;

    // Check if this is a data line
    if (!std.mem.startsWith(u8, line, "data: ")) {
        return null;
    }

    const json_part = line["data: ".len..];

    // Handle [DONE] marker
    if (std.mem.eql(u8, json_part, "[DONE]")) {
        return allocator.dupe(u8, "data: [DONE]") catch null;
    }

    // Parse the SAP AI Core wrapper
    const parsed = std.json.parseFromSlice(
        SapAiCore.StreamChunk,
        allocator,
        json_part,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        return null;
    };
    defer parsed.deinit();

    // Stringify final_result and re-parse as typed chunk
    var inner_buffer = std.ArrayList(u8){};
    defer inner_buffer.deinit(allocator);

    inner_buffer.writer(allocator).print("{f}", .{std.json.fmt(parsed.value.final_result, .{})}) catch return null;

    const chunk_parsed = std.json.parseFromSlice(
        ParsedStreamChunk,
        allocator,
        inner_buffer.items,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    defer chunk_parsed.deinit();

    // Skip empty chunks (initial templating results)
    if (chunk_parsed.value.id.len == 0) {
        return null;
    }

    // Create OpenAI chunk with original model (including provider prefix)
    const openai_chunk = OpenAI.StreamChunk{
        .id = chunk_parsed.value.id,
        .object = chunk_parsed.value.object,
        .created = chunk_parsed.value.created,
        .model = original_model,
        .choices = chunk_parsed.value.choices,
        .usage = chunk_parsed.value.usage,
    };

    // Serialize to JSON
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    buffer.writer(allocator).print("data: {f}", .{std.json.fmt(openai_chunk, .{})}) catch return null;

    return buffer.toOwnedSlice(allocator) catch null;
}