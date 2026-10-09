// SPDX-License-Identifier: Apache-2.0
//! TCP networking primitives for zig-zag.
//!
//! Provides `Connection` (an inbound client socket) and `TcpServer` (used by
//! the OAuth callback server and integration test mock upstream). Inbound HTTP
//! connections for the main proxy are accepted via `std.Io.net` in server.zig;
//! `Connection` wraps the accepted socket handle so all handlers stay unchanged.
//!
//! All networking goes through `std.Io.net` — cross-platform (macOS, Linux,
//! Windows). The previous raw libc socket/bind/listen/accept/read/write/close
//! implementation was POSIX-only.

const std = @import("std");
const builtin = @import("builtin");
const time = @import("time.zig");

/// A TCP connection — wraps an Io Stream with read/write/close/timeout helpers.
/// The handle field is exposed so server.zig can construct a Connection from
/// an already-accepted std.Io.net.Stream (same handle type, posix.fd_t / HANDLE).
pub const Connection = struct {
    handle: std.Io.net.Socket.Handle,

    fn stream(self: Connection) std.Io.net.Stream {
        return .{ .socket = .{ .handle = self.handle, .address = undefined } };
    }

    /// Read bytes from the connection into `buf`.
    /// Returns the number of bytes read, or 0 on EOF.
    pub fn read(self: Connection, buf: []u8) !usize {
        var bufs = [1][]u8{buf};
        const op_result = try time.io().operate(.{ .net_read = .{
            .socket_handle = self.handle,
            .data = &bufs,
        } });
        const read_result = try op_result.net_read;
        return read_result.data_len;
    }

    /// Write all bytes to the connection.
    pub fn writeAll(self: Connection, data: []const u8) !void {
        var io_writer = self.stream().writer(time.io(), &[_]u8{});
        try io_writer.interface.writeAll(data);
        try io_writer.interface.flush();
    }

    /// Close the connection socket.
    pub fn close(self: Connection) void {
        const socket: std.Io.net.Socket = .{ .handle = self.handle, .address = undefined };
        socket.close(time.io());
    }
};

/// A TCP listener — accepts incoming connections.
/// Used by the OAuth callback server and integration test mock upstream.
pub const TcpServer = struct {
    server: std.Io.net.Server,

    pub const ListenOptions = struct {
        reuse_address: bool = false,
    };

    /// Create a TCP server listening on host:port.
    pub fn listen(host: []const u8, port: u16, options: ListenOptions) !TcpServer {
        _ = options; // reuse_address is always set by std.Io.net
        var addr_buf: [64]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch
            return error.InvalidAddress;
        const address = std.Io.net.IpAddress.parseLiteral(addr_str) catch
            return error.InvalidAddress;
        const server = try std.Io.net.IpAddress.listen(&address, time.io(), .{
            .reuse_address = true,
        });
        return .{ .server = server };
    }

    /// Accept a new connection. Blocks until a client connects.
    pub fn accept(self: *TcpServer) !Connection {
        const stream = try self.server.accept(time.io());
        return .{ .handle = stream.socket.handle };
    }

    /// Close the listening socket.
    pub fn deinit(self: *TcpServer) void {
        self.server.deinit(time.io());
    }
};

/// Ignore SIGPIPE so writes to sockets closed by the peer return EPIPE
/// (error.BrokenPipe) instead of terminating the process.
///
/// std.Io.Threaded.init installs its own SIGPIPE handler on POSIX platforms,
/// so this is only needed when running without an Io backend (e.g. early init).
/// Safe to call multiple times; a no-op on Windows.
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
