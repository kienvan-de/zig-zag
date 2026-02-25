const std = @import("std");
const log = @import("../log.zig");

/// Set socket read/write timeout
pub fn setSocketTimeout(handle: std.posix.socket_t, timeout_ms: u64) void {
    if (timeout_ms == 0) return;

    const timeout_sec: i64 = @intCast(timeout_ms / 1000);
    const timeout_usec: i32 = @intCast((timeout_ms % 1000) * 1000);
    const timeval = std.posix.timeval{
        .sec = timeout_sec,
        .usec = timeout_usec,
    };

    // Set read timeout
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch |err| {
        log.debug("Failed to set socket read timeout: {}", .{err});
    };

    // Set write timeout
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeval)) catch |err| {
        log.debug("Failed to set socket write timeout: {}", .{err});
    };
}

/// Iterator for SSE streaming responses - reads from socket on-demand
pub const StreamIterator = struct {
    reader: *std.io.Reader,
    done: bool,

    pub fn init(reader: *std.io.Reader) StreamIterator {
        return .{
            .reader = reader,
            .done = false,
        };
    }

    /// Get the next SSE data line (full line including "data: " prefix)
    /// Returns null when stream is complete or on error
    /// Reads directly from socket - no buffering of full response
    pub fn next(self: *StreamIterator) ?[]const u8 {
        if (self.done) return null;

        while (true) {
            // Read one line from socket (up to newline, excluding it)
            // Use takeDelimiter which handles EndOfStream gracefully
            const line = self.reader.takeDelimiter('\n') catch {
                self.done = true;
                return null;
            } orelse {
                // null means end of stream with no more data
                self.done = true;
                return null;
            };

            // Trim carriage return if present
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;

            // Only return lines with "data: " prefix
            if (std.mem.startsWith(u8, trimmed, "data: ")) {
                const data = trimmed["data: ".len..];
                // Check for [DONE] marker
                if (std.mem.eql(u8, data, "[DONE]")) {
                    self.done = true;
                }
                return trimmed;
            }
        }
    }
};