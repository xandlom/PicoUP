// Simple TCP Echo Server for N6 testing
// Runs on the data network side and echoes back any TCP data received
//
// Usage:
//   zig build example-tcp-echo-server
//   ./zig-out/bin/tcp_echo_server_n6 [port]
//
// Default port: 9998

const std = @import("std");
const net = std.net;
const posix = std.posix;
const print = std.debug.print;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const DEFAULT_PORT: u16 = 9998;
const BUFFER_SIZE: usize = 4096;
const MAX_CLIENTS: usize = 64;

var connection_count: Atomic(u64) = Atomic(u64).init(0);
var total_bytes_received: Atomic(u64) = Atomic(u64).init(0);
var total_bytes_sent: Atomic(u64) = Atomic(u64).init(0);
var active_connections: Atomic(u32) = Atomic(u32).init(0);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Parse command line arguments
    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    const port: u16 = if (args.len > 1)
        std.fmt.parseInt(u16, args[1], 10) catch DEFAULT_PORT
    else
        DEFAULT_PORT;

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║          TCP Echo Server (N6 Side)                        ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // Create TCP socket
    const server_socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(server_socket);

    // Allow address reuse
    const enable: u32 = 1;
    try posix.setsockopt(server_socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    // Bind to all interfaces on specified port
    const bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(server_socket, &bind_addr.any, bind_addr.getOsSockLen());

    // Listen for connections
    try posix.listen(server_socket, 128);

    print("TCP Echo server listening on 0.0.0.0:{}\n", .{port});
    print("Waiting for TCP connections...\n", .{});
    print("\n", .{});
    print("Press Ctrl+C to stop\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("\n", .{});

    // Accept connections in a loop
    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_socket = posix.accept(server_socket, &client_addr, &client_addr_len, 0) catch |err| {
            print("Error accepting connection: {}\n", .{err});
            continue;
        };

        const conn_num = connection_count.fetchAdd(1, .seq_cst) + 1;
        _ = active_connections.fetchAdd(1, .seq_cst);

        // Parse client address for logging
        const client_ip = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&client_addr)));
        const ip_bytes = @as(*const [4]u8, @ptrCast(&client_ip.addr));
        const client_port = std.mem.bigToNative(u16, client_ip.port);

        print("[Conn {}] New connection from {}.{}.{}.{}:{} (active: {})\n", .{
            conn_num,
            ip_bytes[0],
            ip_bytes[1],
            ip_bytes[2],
            ip_bytes[3],
            client_port,
            active_connections.load(.seq_cst),
        });

        // Spawn a thread to handle this client
        const thread = Thread.spawn(.{}, handleClient, .{ client_socket, conn_num }) catch |err| {
            print("[Conn {}] Failed to spawn handler thread: {}\n", .{ conn_num, err });
            posix.close(client_socket);
            _ = active_connections.fetchSub(1, .seq_cst);
            continue;
        };
        thread.detach();
    }
}

fn handleClient(client_socket: posix.socket_t, conn_num: u64) void {
    defer {
        posix.close(client_socket);
        const active = active_connections.fetchSub(1, .seq_cst) - 1;
        print("[Conn {}] Connection closed (active: {})\n", .{ conn_num, active });
    }

    var buffer: [BUFFER_SIZE]u8 = undefined;
    var bytes_this_conn: u64 = 0;
    var messages_this_conn: u64 = 0;

    while (true) {
        // Receive data
        const bytes_received = posix.recv(client_socket, &buffer, 0) catch |err| {
            print("[Conn {}] Receive error: {}\n", .{ conn_num, err });
            break;
        };

        // Client closed connection
        if (bytes_received == 0) {
            break;
        }

        messages_this_conn += 1;
        bytes_this_conn += bytes_received;
        _ = total_bytes_received.fetchAdd(bytes_received, .seq_cst);

        // Log received data (truncate if too long)
        const display_len = @min(bytes_received, 64);
        const data = buffer[0..display_len];
        const truncated = if (bytes_received > 64) "..." else "";

        print("[Conn {}] Received {} bytes: \"{s}\"{s}\n", .{
            conn_num,
            bytes_received,
            data,
            truncated,
        });

        // Echo back the data
        var total_sent: usize = 0;
        while (total_sent < bytes_received) {
            const bytes_sent = posix.send(client_socket, buffer[total_sent..bytes_received], 0) catch |err| {
                print("[Conn {}] Send error: {}\n", .{ conn_num, err });
                return;
            };
            total_sent += bytes_sent;
            _ = total_bytes_sent.fetchAdd(bytes_sent, .seq_cst);
        }

        print("[Conn {}] Echoed {} bytes\n", .{ conn_num, total_sent });
    }

    print("[Conn {}] Session summary: {} messages, {} bytes\n", .{
        conn_num,
        messages_this_conn,
        bytes_this_conn,
    });
}
