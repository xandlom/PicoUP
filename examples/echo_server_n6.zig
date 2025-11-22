// Simple UDP Echo Server for N6 testing
// Runs on the data network side (eth0) and echoes back any UDP packets received
//
// Usage:
//   zig build example-echo-server
//   ./zig-out/bin/echo_server_n6 [port]
//
// Default port: 9999

const std = @import("std");
const net = std.net;
const posix = std.posix;
const print = std.debug.print;

const DEFAULT_PORT: u16 = 9999;
const BUFFER_SIZE: usize = 2048;

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
    print("║          UDP Echo Server (N6 Side)                        ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // Create UDP socket
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(socket);

    // Bind to all interfaces on specified port
    const bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &bind_addr.any, bind_addr.getOsSockLen());

    print("Echo server listening on 0.0.0.0:{}\n", .{port});
    print("Waiting for UDP packets...\n", .{});
    print("\n", .{});
    print("Press Ctrl+C to stop\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("\n", .{});

    var buffer: [BUFFER_SIZE]u8 = undefined;
    var packet_count: u64 = 0;
    var total_bytes: u64 = 0;

    while (true) {
        var client_addr: posix.sockaddr = undefined;
        var client_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        // Receive packet
        const bytes_received = posix.recvfrom(
            socket,
            &buffer,
            0,
            &client_addr,
            &client_addr_len,
        ) catch |err| {
            print("Error receiving: {}\n", .{err});
            continue;
        };

        if (bytes_received == 0) continue;

        packet_count += 1;
        total_bytes += bytes_received;

        // Parse client address for logging
        const client_ip = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&client_addr)));
        const ip_bytes = @as(*const [4]u8, @ptrCast(&client_ip.addr));
        const client_port = std.mem.bigToNative(u16, client_ip.port);

        print("[{}] Received {} bytes from {}.{}.{}.{}:{}", .{
            packet_count,
            bytes_received,
            ip_bytes[0],
            ip_bytes[1],
            ip_bytes[2],
            ip_bytes[3],
            client_port,
        });

        // Echo back the packet
        const bytes_sent = posix.sendto(
            socket,
            buffer[0..bytes_received],
            0,
            &client_addr,
            client_addr_len,
        ) catch |err| {
            print(" - Echo FAILED: {}\n", .{err});
            continue;
        };

        print(" - Echoed {} bytes\n", .{bytes_sent});
    }
}
