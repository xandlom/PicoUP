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
const gtpu_handler = @import("gtpu/handler.zig");
const nat_mod = @import("nat.zig");
const tun_mod = @import("tun.zig");

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

// N6 NAT and TUN interface
var nat_table: nat_mod.NATTable = undefined;
var tun_device: tun_mod.OptionalTun = undefined;

// PFCP thread - handles control plane messages
fn pfcpThread(allocator: std.mem.Allocator) !void {
    print("PFCP thread started\n", .{});

    const pfcp_addr = try net.Address.resolveIp("0.0.0.0", PFCP_PORT);
    const pfcp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(pfcp_socket);

    const enable: c_int = 1;
    try std.posix.setsockopt(pfcp_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try std.posix.bind(pfcp_socket, &pfcp_addr.any, pfcp_addr.getOsSockLen());

    print("PFCP listening on 0.0.0.0:{d}\n", .{PFCP_PORT});

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
            print("PFCP: Error receiving: {any}\n", .{err});
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
fn gtpuThread(allocator: std.mem.Allocator) !void {
    print("GTP-U thread started\n", .{});

    const gtpu_addr = try net.Address.resolveIp("0.0.0.0", GTPU_PORT);
    gtpu_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(gtpu_socket);

    const enable: c_int = 1;
    try std.posix.setsockopt(gtpu_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try std.posix.bind(gtpu_socket, &gtpu_addr.any, gtpu_addr.getOsSockLen());

    print("GTP-U listening on 0.0.0.0:{d}\n", .{GTPU_PORT});

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

            // Handle Echo Request/Response messages (path management)
            // These don't need session lookup, handle them directly
            if (gtpu_handler.handleEchoRequest(allocator, gtpu_socket, buffer[0..bytes_received], client_address)) {
                _ = global_stats.gtpu_echo_requests.fetchAdd(1, .seq_cst);
                continue; // Echo request handled, don't enqueue
            }

            // Check for Echo Response (for RTT monitoring, future enhancement)
            if (gtpu_handler.isEchoResponse(buffer[0..bytes_received])) {
                _ = global_stats.gtpu_echo_responses.fetchAdd(1, .seq_cst);
                print("GTP-U: Received Echo Response from {any}\n", .{client_address});
                continue; // Echo response received, don't enqueue
            }

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

// N6 receiver thread - receives packets from data network via TUN
fn n6ReceiverThread() void {
    print("N6 receiver thread started\n", .{});

    // Check if TUN device is available
    if (tun_device.isStubMode()) {
        print("N6 receiver: TUN not available, thread exiting\n", .{});
        print("N6 receiver: To enable, run scripts/setup_n6.sh and restart UPF\n", .{});
        return;
    }

    var buffer: [2048]u8 = undefined;

    while (!should_stop.load(.seq_cst)) {
        // Read packet from TUN device (this is a downlink packet from internet)
        const bytes_read = tun_device.read(&buffer) catch |err| {
            if (err == error.StubMode) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }
            print("N6 receiver: Read error: {}\n", .{err});
            continue;
        };

        if (bytes_read < 20) continue; // Skip invalid packets

        _ = global_stats.n6_packets_rx.fetchAdd(1, .seq_cst);

        // Process the downlink packet (reverse NAT and forward to gNodeB)
        gtpu_worker.processN6Downlink(
            buffer[0..bytes_read],
            bytes_read,
            &nat_table,
            &session_manager,
            &global_stats,
            gtpu_socket,
        );
    }

    print("N6 receiver thread stopped\n", .{});
}

// NAT cleanup thread - periodically cleans up expired NAT entries
fn natCleanupThread() void {
    nat_mod.natCleanupThread(&nat_table, &should_stop);
}

// Main function - initialization and thread orchestration
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== PicoUP - User Plane Function ===\n", .{});
    print("Version: 0.1.0\n", .{});
    print("Worker Threads: {d}\n", .{WORKER_THREADS});
    print("Press Ctrl+C to stop\n\n", .{});

    // Initialize global state
    global_stats = stats_mod.Stats.init();
    session_manager = session_mod.SessionManager.init();
    packet_queue = gtpu_worker.PacketQueue.init();
    upf_ipv4 = types.N6_EXTERNAL_IP; // Use N6 external IP as UPF IP

    // Initialize N6 NAT table and TUN interface
    nat_table = nat_mod.NATTable.init(types.N6_EXTERNAL_IP);
    tun_device = tun_mod.OptionalTun.init(types.N6_TUN_DEVICE);
    defer tun_device.close();

    if (tun_device.isStubMode()) {
        print("N6: Running in stub mode (TUN device '{s}' not available)\n", .{types.N6_TUN_DEVICE});
        print("N6: Uplink packets will be counted but not forwarded\n", .{});
        print("N6: To enable N6 forwarding, run: scripts/setup_n6.sh\n\n", .{});
    } else {
        print("N6: TUN device '{s}' attached, NAT enabled\n", .{types.N6_TUN_DEVICE});
        print("N6: External IP: {}.{}.{}.{}\n\n", .{
            types.N6_EXTERNAL_IP[0], types.N6_EXTERNAL_IP[1],
            types.N6_EXTERNAL_IP[2], types.N6_EXTERNAL_IP[3],
        });
    }

    // Start GTP-U worker threads (with NAT and TUN for N6 forwarding)
    var worker_threads: [WORKER_THREADS]Thread = undefined;
    for (0..WORKER_THREADS) |i| {
        worker_threads[i] = try Thread.spawn(.{}, gtpu_worker.gtpuWorkerThread, .{
            @as(u32, @intCast(i)),
            &packet_queue,
            &session_manager,
            &global_stats,
            &should_stop,
            &nat_table,
            &tun_device,
        });
    }

    // Start PFCP thread
    const pfcp_thread_handle = try Thread.spawn(.{}, pfcpThread, .{allocator});

    // Start GTP-U thread
    const gtpu_thread_handle = try Thread.spawn(.{}, gtpuThread, .{allocator});

    // Start N6 receiver thread (for downlink from data network)
    const n6_thread_handle = try Thread.spawn(.{}, n6ReceiverThread, .{});

    // Start NAT cleanup thread
    const nat_cleanup_handle = try Thread.spawn(.{}, natCleanupThread, .{});

    // Start statistics thread
    const stats_thread_handle = try Thread.spawn(.{}, stats_mod.statsThread, .{
        &global_stats,
        &session_manager,
        &should_stop,
    });

    // Wait for threads (will run until Ctrl+C)
    pfcp_thread_handle.join();
    gtpu_thread_handle.join();
    n6_thread_handle.join();
    nat_cleanup_handle.join();
    for (worker_threads) |thread| {
        thread.join();
    }
    stats_thread_handle.join();
}
