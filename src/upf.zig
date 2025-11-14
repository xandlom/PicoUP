const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// Import PFCP library
const pfcp = @import("zig-pfcp");

// Import our modules
const types = @import("types.zig");
const session_mod = @import("session.zig");
const stats_mod = @import("stats.zig");
const pfcp_handler = @import("pfcp/handler.zig");
const gtpu_worker = @import("gtpu/worker.zig");

// Re-export constants from types module
const WORKER_THREADS = types.WORKER_THREADS;
const PFCP_PORT = types.PFCP_PORT;
const GTPU_PORT = types.GTPU_PORT;

// Global variables (accessed by modules via @import("../upf.zig"))
pub var global_stats: stats_mod.Stats = undefined;
pub var session_manager: session_mod.SessionManager = undefined;
var packet_queue: gtpu_worker.PacketQueue = undefined;
var pfcp_association_established: Atomic(bool) = Atomic(bool).init(false);
var should_stop: Atomic(bool) = Atomic(bool).init(false);
var gtpu_socket: std.posix.socket_t = undefined;
pub var upf_ipv4: [4]u8 = undefined;

// PFCP thread - handles control plane messages
fn pfcpThread(allocator: std.mem.Allocator) !void {
    print("PFCP thread started\n", .{});

    const pfcp_addr = try net.Address.resolveIp("0.0.0.0", PFCP_PORT);
    const pfcp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(pfcp_socket);

    const enable: c_int = 1;
    try std.posix.setsockopt(pfcp_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try std.posix.bind(pfcp_socket, &pfcp_addr.any, pfcp_addr.getOsSockLen());

    print("PFCP listening on 0.0.0.0:{}\n", .{PFCP_PORT});

    var buffer: [2048]u8 = undefined;

    while (!should_stop.load(.seq_cst)) {
        var client_address: net.Address = undefined;
        var client_address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes_received = std.posix.recvfrom(
            pfcp_socket,
            &buffer,
            0,
            &client_address.any,
            &client_address_len,
        ) catch |err| {
            print("PFCP: Error receiving: {}\n", .{err});
            continue;
        };

        if (bytes_received > 0) {
            pfcp_handler.handlePfcpMessage(
                buffer[0..bytes_received],
                client_address,
                pfcp_socket,
                allocator,
                &global_stats,
                &session_manager,
                &pfcp_association_established,
            );
        }
    }

    print("PFCP thread stopped\n", .{});
}

// GTP-U thread - receives data plane packets and enqueues them
fn gtpuThread() !void {
    print("GTP-U thread started\n", .{});

    const gtpu_addr = try net.Address.resolveIp("0.0.0.0", GTPU_PORT);
    gtpu_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(gtpu_socket);

    const enable: c_int = 1;
    try std.posix.setsockopt(gtpu_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try std.posix.bind(gtpu_socket, &gtpu_addr.any, gtpu_addr.getOsSockLen());

    print("GTP-U listening on 0.0.0.0:{}\n", .{GTPU_PORT});

    var buffer: [2048]u8 = undefined;

    while (!should_stop.load(.seq_cst)) {
        var client_address: net.Address = undefined;
        var client_address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes_received = std.posix.recvfrom(
            gtpu_socket,
            &buffer,
            0,
            &client_address.any,
            &client_address_len,
        ) catch |err| {
            print("GTP-U: Error receiving: {}\n", .{err});
            continue;
        };

        if (bytes_received > 0) {
            _ = global_stats.gtpu_packets_rx.fetchAdd(1, .seq_cst);

            var packet = gtpu_worker.GtpuPacket{
                .data = undefined,
                .length = bytes_received,
                .client_address = client_address,
                .socket = gtpu_socket,
            };
            @memcpy(packet.data[0..bytes_received], buffer[0..bytes_received]);

            if (!packet_queue.enqueue(packet)) {
                _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                print("GTP-U: Queue full, dropping packet\n", .{});
            }
        }
    }

    print("GTP-U thread stopped\n", .{});
}

// Main function - initialization and thread orchestration
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== PicoUP - User Plane Function ===\n", .{});
    print("Version: 0.1.0\n", .{});
    print("Worker Threads: {}\n", .{WORKER_THREADS});
    print("Press Ctrl+C to stop\n\n", .{});

    // Initialize global state
    global_stats = stats_mod.Stats.init();
    session_manager = session_mod.SessionManager.init();
    packet_queue = gtpu_worker.PacketQueue.init();
    upf_ipv4 = .{ 10, 0, 0, 1 }; // Default UPF IP

    // Start GTP-U worker threads
    var worker_threads: [WORKER_THREADS]Thread = undefined;
    for (0..WORKER_THREADS) |i| {
        worker_threads[i] = try Thread.spawn(.{}, gtpu_worker.gtpuWorkerThread, .{
            @as(u32, @intCast(i)),
            &packet_queue,
            &session_manager,
            &global_stats,
            &should_stop,
        });
    }

    // Start PFCP thread
    const pfcp_thread_handle = try Thread.spawn(.{}, pfcpThread, .{allocator});

    // Start GTP-U thread
    const gtpu_thread_handle = try Thread.spawn(.{}, gtpuThread, .{});

    // Start statistics thread
    const stats_thread_handle = try Thread.spawn(.{}, stats_mod.statsThread, .{
        &global_stats,
        &session_manager,
        &should_stop,
    });

    // Wait for threads (will run until Ctrl+C)
    pfcp_thread_handle.join();
    gtpu_thread_handle.join();
    for (worker_threads) |thread| {
        thread.join();
    }
    stats_thread_handle.join();
}
