const std = @import("std");
const OpenAI = @import("../openai/types.zig");
const SapAiCore = @import("types.zig");

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
                .{ .enabled = s, .chunk_size = 100 }
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
    const final_result = response.final_result orelse return error.MissingFinalResult;

    // Allocate model string with provider prefix
    const model_str = try allocator.dupe(u8, original_model);

    return OpenAI.Response{
        .id = final_result.id,
        .object = final_result.object,
        .created = final_result.created,
        .model = model_str,
        .choices = final_result.choices,
        .usage = final_result.usage,
        .system_fingerprint = null,
        .service_tier = null,
    };
}

/// Cleanup transformed response
pub fn cleanupResponse(response: OpenAI.Response, allocator: std.mem.Allocator) void {
    allocator.free(response.model);
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

    const final_result = parsed.value.final_result orelse return null;

    // Skip empty chunks (initial templating results)
    if (final_result.id.len == 0) {
        return null;
    }

    // Create OpenAI chunk with original model (including provider prefix)
    const openai_chunk = OpenAI.StreamChunk{
        .id = final_result.id,
        .object = final_result.object,
        .created = final_result.created,
        .model = original_model,
        .choices = final_result.choices,
        .usage = final_result.usage,
    };

    // Serialize to JSON
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    buffer.writer(allocator).print("data: {f}", .{std.json.fmt(openai_chunk, .{})}) catch return null;

    return buffer.toOwnedSlice(allocator) catch null;
}