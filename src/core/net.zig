// SPDX-License-Identifier: Apache-2.0
//! TCP networking primitives for zig-zag.
//!
//! Replaces the removed `std.net.Server`, `std.net.Server.Connection`, and
//! `std.net.Stream` from Zig 0.15 with direct POSIX/libc socket APIs that
//! work in Zig 0.16's synchronous blocking model.

const std = @import("std");
const builtin = @import("builtin");

/// A TCP connection — wraps a socket fd with read/write/close helpers.
/// Drop-in replacement for the old `std.net.Server.Connection` + `std.net.Stream`.
pub const Connection = struct {
    handle: std.posix.fd_t,

    /// Read bytes from the connection into `buf`.
    /// Returns the number of bytes read, or 0 on EOF.
    pub fn read(self: Connection, buf: []u8) !usize {
        return std.posix.read(self.handle, buf);
    }

    /// Write all bytes to the connection. Loops until all data is sent.
    /// Retries on EINTR; maps EAGAIN/EWOULDBLOCK to WriteFailed.
    pub fn writeAll(self: Connection, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const n = std.c.write(self.handle, remaining.ptr, remaining.len);
            if (n < 0) {
                const err = std.posix.errno(n);
                if (err == .INTR) continue;
                return error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            remaining = remaining[@intCast(n)..];
        }
    }

    /// Close the connection socket.
    pub fn close(self: Connection) void {
        _ = std.c.close(self.handle);
    }
};

/// A TCP listener — wraps a listening socket fd.
/// Drop-in replacement for the old `std.net.Server`.
pub const TcpServer = struct {
    fd: std.posix.fd_t,

    pub const ListenOptions = struct {
        reuse_address: bool = false,
    };

    /// Create a TCP server listening on host:port.
    pub fn listen(host: []const u8, port: u16, options: ListenOptions) !TcpServer {
        // Create socket
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        errdefer _ = std.c.close(fd);

        // Set SO_REUSEADDR
        if (options.reuse_address) {
            const enable: i32 = 1;
            const rc = std.c.setsockopt(
                fd,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEADDR,
                @ptrCast(&enable),
                @sizeOf(i32),
            );
            if (rc < 0) return error.SetSockOptFailed;
        }

        // Parse IP address and bind
        var addr: std.posix.sockaddr.in = .{
            .port = @byteSwap(port),
            .addr = parseIpv4(host) orelse return error.InvalidAddress,
        };

        const bind_rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
        if (bind_rc < 0) return error.BindFailed;

        // Listen
        const listen_rc = std.c.listen(fd, 128);
        if (listen_rc < 0) return error.ListenFailed;

        return .{ .fd = fd };
    }

    /// Accept a new connection. Blocks until a client connects.
    pub fn accept(self: *TcpServer) !Connection {
        const client_fd = std.c.accept(self.fd, null, null);
        if (client_fd < 0) return error.AcceptFailed;
        return .{ .handle = client_fd };
    }

    /// Close the listening socket.
    pub fn deinit(self: *TcpServer) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }

    /// Parse a dotted-quad IPv4 address string to a u32 in network byte order.
    fn parseIpv4(host: []const u8) ?u32 {
        var parts: [4]u8 = undefined;
        var part_idx: usize = 0;
        var current: u16 = 0;
        var has_digit = false;

        for (host) |ch| {
            if (ch == '.') {
                if (!has_digit or part_idx >= 3) return null;
                parts[part_idx] = @intCast(current);
                part_idx += 1;
                current = 0;
                has_digit = false;
            } else if (ch >= '0' and ch <= '9') {
                current = current * 10 + (ch - '0');
                if (current > 255) return null;
                has_digit = true;
            } else {
                return null;
            }
        }
        if (!has_digit or part_idx != 3) return null;
        parts[3] = @intCast(current);

        return @bitCast(parts);
    }
};

/// Ignore SIGPIPE so writes to sockets closed by the peer return EPIPE
/// (error.BrokenPipe) instead of terminating the process.
///
/// Zig ≤0.15 installed this automatically from std.start; in 0.16 the handler
/// install moved into Io backend init(), which we bypass (see core/time.zig),
/// so we must install it ourselves.
pub fn ignoreSigpipe() void {
    const posix = std.posix;
    if (builtin.os.tag == .windows) return;
    if (posix.SIG != void and @hasField(posix.SIG, "PIPE")) {
        const act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        _ = posix.sigaction(.PIPE, &act, null);
    }
}
