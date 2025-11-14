// GTP-U worker threads and packet queue
// Handles parallel packet processing across multiple worker threads

const std = @import("std");
const types = @import("../types.zig");
const stats_mod = @import("../stats.zig");
const session_mod = @import("../session.zig");
const handler = @import("handler.zig");

const net = std.net;
const print = std.debug.print;
const time = std.time;
const Atomic = std.atomic.Value;
const Mutex = std.Thread.Mutex;

// GTP-U packet structure for queue
pub const GtpuPacket = struct {
    data: [2048]u8,
    length: usize,
    client_address: net.Address,
    socket: std.posix.socket_t,
};

// Thread-safe packet queue for distributing work to worker threads
pub const PacketQueue = struct {
    packets: [types.QUEUE_SIZE]GtpuPacket,
    head: Atomic(usize),
    tail: Atomic(usize),
    count: Atomic(usize),
    mutex: Mutex,

    pub fn init() PacketQueue {
        return PacketQueue{
            .packets = undefined,
            .head = Atomic(usize).init(0),
            .tail = Atomic(usize).init(0),
            .count = Atomic(usize).init(0),
            .mutex = Mutex{},
        };
    }

    pub fn enqueue(self: *PacketQueue, packet: GtpuPacket) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count >= types.QUEUE_SIZE) {
            return false;
        }

        const tail = self.tail.load(.seq_cst);
        self.packets[tail] = packet;
        _ = self.tail.store((tail + 1) % types.QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchAdd(1, .seq_cst);
        return true;
    }

    pub fn dequeue(self: *PacketQueue) ?GtpuPacket {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count == 0) {
            return null;
        }

        const head = self.head.load(.seq_cst);
        const packet = self.packets[head];
        _ = self.head.store((head + 1) % types.QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchSub(1, .seq_cst);
        return packet;
    }

    pub fn size(self: *PacketQueue) usize {
        return self.count.load(.seq_cst);
    }
};

// Worker thread for processing GTP-U packets
pub fn gtpuWorkerThread(
    thread_id: u32,
    packet_queue: *PacketQueue,
    session_manager: *session_mod.SessionManager,
    stats: *stats_mod.Stats,
    should_stop: *Atomic(bool),
) void {
    print("GTP-U worker thread {} started\n", .{thread_id});

    while (!should_stop.load(.seq_cst)) {
        if (packet_queue.dequeue()) |packet| {
            stats.queue_size.store(packet_queue.size(), .seq_cst);

            // Parse GTP-U header
            const header = handler.parseGtpuHeader(packet.data[0..packet.length]) catch |err| {
                print("Worker {}: Failed to parse GTP-U header: {}\n", .{ thread_id, err });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                continue;
            };

            if (header.message_type == 0xFF) { // G-PDU
                // Find session by TEID (assuming uplink from Access)
                if (session_manager.findSessionByTeid(header.teid, 0)) |session| {
                    if (session.findPDRByTeid(header.teid, 0)) |pdr| {
                        if (session.findFAR(pdr.far_id)) |far| {
                            if (far.action == 1) { // Forward
                                // Extract inner payload
                                const payload = packet.data[header.payload_offset..packet.length];

                                switch (far.dest_interface) {
                                    0 => { // Access (N3) - Forward to gNodeB
                                        print("Worker {}: Forwarding to N3 (Access), TEID: 0x{x}, size: {} bytes\n", .{ thread_id, header.teid, payload.len });

                                        if (far.outer_header_creation) {
                                            // Re-encapsulate with GTP-U for N3
                                            var out_buffer: [2048]u8 = undefined;
                                            const out_len = handler.createGtpuHeader(&out_buffer, far.teid, payload);

                                            if (out_len > 0) {
                                                // Create destination address for gNodeB
                                                const dest_addr = net.Address.initIp4(far.ipv4, types.GTPU_PORT);

                                                _ = std.posix.sendto(packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
                                                    print("Worker {}: Failed to send to N3: {}\n", .{ thread_id, err });
                                                    _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                                _ = stats.n3_packets_tx.fetchAdd(1, .seq_cst);
                                            } else {
                                                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                            }
                                        } else {
                                            print("Worker {}: N3 forwarding requires outer header creation\n", .{thread_id});
                                            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                        }
                                    },
                                    1 => { // Core (N6) - Forward to data network (decapsulated)
                                        print("Worker {}: Forwarding to N6 (Core), TEID: 0x{x}, size: {} bytes\n", .{ thread_id, header.teid, payload.len });

                                        // For N6, we would send the decapsulated IP packet to the data network
                                        // This requires a separate socket and routing setup
                                        // For now, just count as forwarded
                                        _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                        _ = stats.n6_packets_tx.fetchAdd(1, .seq_cst);
                                    },
                                    2 => { // N9 - Forward to peer UPF
                                        print("Worker {}: Forwarding to N9 (UPF-to-UPF), TEID: 0x{x}, size: {} bytes, peer: {}.{}.{}.{}\n", .{ thread_id, header.teid, payload.len, far.ipv4[0], far.ipv4[1], far.ipv4[2], far.ipv4[3] });

                                        if (far.outer_header_creation) {
                                            // Re-encapsulate with new GTP-U header for N9
                                            var out_buffer: [2048]u8 = undefined;
                                            const out_len = handler.createGtpuHeader(&out_buffer, far.teid, payload);

                                            if (out_len > 0) {
                                                // Create destination address for peer UPF
                                                const dest_addr = net.Address.initIp4(far.ipv4, types.GTPU_PORT);

                                                _ = std.posix.sendto(packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
                                                    print("Worker {}: Failed to send to N9: {}\n", .{ thread_id, err });
                                                    _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                                _ = stats.n9_packets_tx.fetchAdd(1, .seq_cst);
                                            } else {
                                                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                            }
                                        } else {
                                            print("Worker {}: N9 forwarding requires outer header creation\n", .{thread_id});
                                            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                        }
                                    },
                                    else => { // Unknown interface
                                        print("Worker {}: Unknown dest_interface: {}\n", .{ thread_id, far.dest_interface });
                                        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                    },
                                }
                            } else if (far.action == 0) { // Drop
                                print("Worker {}: Dropping packet per FAR, TEID: 0x{x}\n", .{ thread_id, header.teid });
                                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                            }
                        } else {
                            print("Worker {}: FAR not found for PDR {}\n", .{ thread_id, pdr.far_id });
                            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                        }
                    } else {
                        print("Worker {}: PDR not found for TEID 0x{x}\n", .{ thread_id, header.teid });
                        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                    }
                } else {
                    print("Worker {}: Session not found for TEID 0x{x}\n", .{ thread_id, header.teid });
                    _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                }
            } else {
                print("Worker {}: Non-GPDU message type: 0x{x}\n", .{ thread_id, header.message_type });
            }
        } else {
            time.sleep(1 * time.ns_per_ms);
        }
    }

    print("GTP-U worker thread {} stopped\n", .{thread_id});
}
