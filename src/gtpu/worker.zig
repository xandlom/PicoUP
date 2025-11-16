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

// Packet processing context - carries state through pipeline stages
const PacketContext = struct {
    packet: GtpuPacket,
    header: handler.GtpuHeader,
    session: ?*session_mod.Session,
    pdr: ?*types.PDR,
    far: ?*types.FAR,
    payload: []const u8,
    source_interface: u8, // Determined from packet context
    thread_id: u32,
};

// Pipeline Stage 1: Parse GTP-U header
fn parseHeader(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    ctx.header = handler.parseGtpuHeader(ctx.packet.data[0..ctx.packet.length]) catch |err| {
        print("Worker {}: Failed to parse GTP-U header: {}\n", .{ ctx.thread_id, err });
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return false;
    };

    // Only process G-PDU messages
    if (ctx.header.message_type != 0xFF) {
        print("Worker {}: Non-GPDU message type: 0x{x}\n", .{ ctx.thread_id, ctx.header.message_type });
        return false;
    }

    // Extract payload
    ctx.payload = ctx.packet.data[ctx.header.payload_offset..ctx.packet.length];

    // Determine source interface (simplified: assume N3/Access for now)
    // In a real implementation, this would be determined by which socket received the packet
    ctx.source_interface = 0; // N3 (Access)

    return true;
}

// Pipeline Stage 2: Lookup session by TEID
fn lookupSession(ctx: *PacketContext, session_manager: *session_mod.SessionManager, stats: *stats_mod.Stats) bool {
    ctx.session = session_manager.findSessionByTeid(ctx.header.teid, ctx.source_interface);
    if (ctx.session == null) {
        print("Worker {}: Session not found for TEID 0x{x}, source_interface: {}\n", .{ ctx.thread_id, ctx.header.teid, ctx.source_interface });
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return false;
    }
    return true;
}

// Pipeline Stage 3: Match PDR with precedence handling
// Finds the best matching PDR based on TEID and source_interface, considering precedence
fn matchPDR(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    if (ctx.session) |session| {
        session.mutex.lock();
        defer session.mutex.unlock();

        var best_pdr: ?*types.PDR = null;
        var highest_precedence: u32 = 0;

        // Find all matching PDRs and select the one with highest precedence
        for (0..session.pdr_count) |i| {
            const pdr = &session.pdrs[i];
            if (pdr.allocated and
                pdr.teid == ctx.header.teid and
                pdr.source_interface == ctx.source_interface)
            {
                // First match or higher precedence
                if (best_pdr == null or pdr.precedence > highest_precedence) {
                    best_pdr = pdr;
                    highest_precedence = pdr.precedence;
                }
            }
        }

        ctx.pdr = best_pdr;
        if (ctx.pdr == null) {
            print("Worker {}: No matching PDR for TEID 0x{x}, source_interface: {}\n", .{ ctx.thread_id, ctx.header.teid, ctx.source_interface });
            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            return false;
        }

        print("Worker {}: Matched PDR {} (precedence: {}) for TEID 0x{x}\n", .{ ctx.thread_id, ctx.pdr.?.id, ctx.pdr.?.precedence, ctx.header.teid });
        return true;
    }
    return false;
}

// Pipeline Stage 4: Lookup FAR associated with matched PDR
fn lookupFAR(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    if (ctx.session) |session| {
        if (ctx.pdr) |pdr| {
            ctx.far = session.findFAR(pdr.far_id);
            if (ctx.far == null) {
                print("Worker {}: FAR {} not found for PDR {}\n", .{ ctx.thread_id, pdr.far_id, pdr.id });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                return false;
            }
            return true;
        }
    }
    return false;
}

// Pipeline Stage 5: Execute FAR action (forward/drop)
fn executeFAR(ctx: *PacketContext, stats: *stats_mod.Stats) void {
    if (ctx.far) |far| {
        switch (far.action) {
            0 => { // Drop
                print("Worker {}: Dropping packet per FAR {}, TEID: 0x{x}\n", .{ ctx.thread_id, far.id, ctx.header.teid });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            },
            1 => { // Forward
                forwardPacket(ctx, far, stats);
            },
            2 => { // Buffer
                print("Worker {}: Buffering not implemented, TEID: 0x{x}\n", .{ ctx.thread_id, ctx.header.teid });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            },
            else => {
                print("Worker {}: Unknown FAR action: {}\n", .{ ctx.thread_id, far.action });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            },
        }
    }
}

// Forward packet based on destination interface
fn forwardPacket(ctx: *PacketContext, far: *types.FAR, stats: *stats_mod.Stats) void {
    switch (far.dest_interface) {
        0 => forwardToN3(ctx, far, stats), // Access
        1 => forwardToN6(ctx, far, stats), // Core
        2 => forwardToN9(ctx, far, stats), // UPF-to-UPF
        else => {
            print("Worker {}: Unknown dest_interface: {}\n", .{ ctx.thread_id, far.dest_interface });
            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        },
    }
}

// Forward to N3 (Access/gNodeB)
fn forwardToN3(ctx: *PacketContext, far: *types.FAR, stats: *stats_mod.Stats) void {
    print("Worker {}: Forwarding to N3 (Access), TEID: 0x{x}, size: {} bytes\n", .{ ctx.thread_id, ctx.header.teid, ctx.payload.len });

    if (!far.outer_header_creation) {
        print("Worker {}: N3 forwarding requires outer header creation\n", .{ctx.thread_id});
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    }

    // Re-encapsulate with GTP-U for N3
    var out_buffer: [2048]u8 = undefined;
    const out_len = handler.createGtpuHeader(&out_buffer, far.teid, ctx.payload);

    if (out_len == 0) {
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    }

    // Create destination address for gNodeB
    const dest_addr = net.Address.initIp4(far.ipv4, types.GTPU_PORT);

    _ = std.posix.sendto(ctx.packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
        print("Worker {}: Failed to send to N3: {}\n", .{ ctx.thread_id, err });
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    };

    _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
    _ = stats.n3_packets_tx.fetchAdd(1, .seq_cst);
}

// Forward to N6 (Core/Data Network)
fn forwardToN6(ctx: *PacketContext, far: *types.FAR, stats: *stats_mod.Stats) void {
    _ = far;
    print("Worker {}: Forwarding to N6 (Core), TEID: 0x{x}, size: {} bytes\n", .{ ctx.thread_id, ctx.header.teid, ctx.payload.len });

    // For N6, we would send the decapsulated IP packet to the data network
    // This requires a separate socket and routing setup
    // For now, just count as forwarded
    _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
    _ = stats.n6_packets_tx.fetchAdd(1, .seq_cst);
}

// Forward to N9 (UPF-to-UPF)
fn forwardToN9(ctx: *PacketContext, far: *types.FAR, stats: *stats_mod.Stats) void {
    print("Worker {}: Forwarding to N9 (UPF-to-UPF), TEID: 0x{x}, size: {} bytes, peer: {}.{}.{}.{}\n", .{ ctx.thread_id, ctx.header.teid, ctx.payload.len, far.ipv4[0], far.ipv4[1], far.ipv4[2], far.ipv4[3] });

    if (!far.outer_header_creation) {
        print("Worker {}: N9 forwarding requires outer header creation\n", .{ctx.thread_id});
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    }

    // Re-encapsulate with new GTP-U header for N9
    var out_buffer: [2048]u8 = undefined;
    const out_len = handler.createGtpuHeader(&out_buffer, far.teid, ctx.payload);

    if (out_len == 0) {
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    }

    // Create destination address for peer UPF
    const dest_addr = net.Address.initIp4(far.ipv4, types.GTPU_PORT);

    _ = std.posix.sendto(ctx.packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
        print("Worker {}: Failed to send to N9: {}\n", .{ ctx.thread_id, err });
        _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
        return;
    };

    _ = stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
    _ = stats.n9_packets_tx.fetchAdd(1, .seq_cst);
}

// Worker thread for processing GTP-U packets using pipeline pattern
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

            // Initialize packet processing context
            var ctx = PacketContext{
                .packet = packet,
                .header = undefined,
                .session = null,
                .pdr = null,
                .far = null,
                .payload = undefined,
                .source_interface = 0,
                .thread_id = thread_id,
            };

            // Execute pipeline stages
            if (!parseHeader(&ctx, stats)) continue;
            if (!lookupSession(&ctx, session_manager, stats)) continue;
            if (!matchPDR(&ctx, stats)) continue;
            if (!lookupFAR(&ctx, stats)) continue;
            executeFAR(&ctx, stats);
        } else {
            time.sleep(1 * time.ns_per_ms);
        }
    }

    print("GTP-U worker thread {} stopped\n", .{thread_id});
}
