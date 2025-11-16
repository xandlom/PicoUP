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

// Packet flow information extracted from IP header
const PacketFlowInfo = struct {
    has_ip_info: bool,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8, // 6=TCP, 17=UDP, etc.
    src_port: u16,
    dst_port: u16,

    fn init() PacketFlowInfo {
        return PacketFlowInfo{
            .has_ip_info = false,
            .src_ip = .{ 0, 0, 0, 0 },
            .dst_ip = .{ 0, 0, 0, 0 },
            .protocol = 0,
            .src_port = 0,
            .dst_port = 0,
        };
    }
};

// Packet processing context - carries state through pipeline stages
const PacketContext = struct {
    packet: GtpuPacket,
    header: handler.GtpuHeader,
    session: ?*session_mod.Session,
    pdr: ?*types.PDR,
    far: ?*types.FAR,
    qer: ?*types.QER, // QoS Enforcement Rule
    payload: []const u8,
    source_interface: u8, // Determined from packet context
    thread_id: u32,
    flow_info: PacketFlowInfo, // Parsed IP packet flow information
};

// Parse IP packet to extract flow information
fn parseIpPacket(payload: []const u8) PacketFlowInfo {
    var flow_info = PacketFlowInfo.init();

    // Minimum IPv4 header is 20 bytes
    if (payload.len < 20) {
        return flow_info;
    }

    // Check IP version (first 4 bits should be 4 for IPv4)
    const version = payload[0] >> 4;
    if (version != 4) {
        return flow_info; // Only support IPv4 for now
    }

    // Extract IP header fields
    const ihl = payload[0] & 0x0F; // Internet Header Length (in 32-bit words)
    const header_len = ihl * 4;

    if (payload.len < header_len or header_len < 20) {
        return flow_info;
    }

    flow_info.has_ip_info = true;
    flow_info.protocol = payload[9];

    // Source IP (bytes 12-15)
    flow_info.src_ip = [4]u8{ payload[12], payload[13], payload[14], payload[15] };

    // Destination IP (bytes 16-19)
    flow_info.dst_ip = [4]u8{ payload[16], payload[17], payload[18], payload[19] };

    // Extract port numbers for TCP/UDP
    const transport_offset = header_len;
    if (payload.len >= transport_offset + 4) {
        if (flow_info.protocol == 6 or flow_info.protocol == 17) { // TCP or UDP
            // Source port (bytes 0-1 of transport header)
            flow_info.src_port = std.mem.readInt(u16, payload[transport_offset..][0..2], .big);
            // Destination port (bytes 2-3 of transport header)
            flow_info.dst_port = std.mem.readInt(u16, payload[transport_offset + 2..][0..2], .big);
        }
    }

    return flow_info;
}

// Pipeline Stage 1: Parse GTP-U header and extract flow information
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

    // Parse IP packet for flow information
    ctx.flow_info = parseIpPacket(ctx.payload);

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

// Check if packet matches PDI criteria
fn matchesPDI(pdi: *const types.PDI, ctx: *const PacketContext) bool {
    // Source interface must match (mandatory)
    if (pdi.source_interface != ctx.source_interface) {
        return false;
    }

    // Check F-TEID if present in PDI
    if (pdi.has_fteid) {
        if (pdi.teid != ctx.header.teid) {
            return false;
        }
    }

    // Check UE IP address if present in PDI and we have IP info
    if (pdi.has_ue_ip and ctx.flow_info.has_ip_info) {
        // For uplink (N3), UE IP is the source; for downlink (N6), UE IP is the destination
        const ue_ip_matches = if (ctx.source_interface == 0) // N3 (Access)
            std.mem.eql(u8, &pdi.ue_ip, &ctx.flow_info.src_ip)
        else if (ctx.source_interface == 1) // N6 (Core)
            std.mem.eql(u8, &pdi.ue_ip, &ctx.flow_info.dst_ip)
        else
            false; // N9 - skip UE IP matching

        if (!ue_ip_matches) {
            return false;
        }
    }

    // Check SDF filter if present in PDI and we have IP info
    if (pdi.has_sdf_filter and ctx.flow_info.has_ip_info) {
        // Check protocol (0 means any protocol)
        if (pdi.sdf_protocol != 0 and pdi.sdf_protocol != ctx.flow_info.protocol) {
            return false;
        }

        // Check destination port range (for TCP/UDP)
        if (ctx.flow_info.protocol == 6 or ctx.flow_info.protocol == 17) { // TCP or UDP
            if (pdi.sdf_dest_port_low > 0 or pdi.sdf_dest_port_high > 0) {
                if (ctx.flow_info.dst_port < pdi.sdf_dest_port_low or
                    ctx.flow_info.dst_port > pdi.sdf_dest_port_high)
                {
                    return false;
                }
            }
        }
    }

    // TODO: Check Application ID if present
    // This would require application identification logic (DPI)

    return true;
}

// Pipeline Stage 3: Match PDR with comprehensive PDI matching and precedence handling
// Finds the best matching PDR based on PDI criteria, considering precedence
fn matchPDR(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    if (ctx.session) |session| {
        session.mutex.lock();
        defer session.mutex.unlock();

        var best_pdr: ?*types.PDR = null;
        var highest_precedence: u32 = 0;

        // Find all matching PDRs and select the one with highest precedence
        for (0..session.pdr_count) |i| {
            var pdr = &session.pdrs[i];
            if (!pdr.allocated) {
                continue;
            }

            // Check if packet matches this PDR's PDI
            if (matchesPDI(&pdr.pdi, ctx)) {
                // First match or higher precedence
                if (best_pdr == null or pdr.precedence > highest_precedence) {
                    best_pdr = pdr;
                    highest_precedence = pdr.precedence;
                }
            }
        }

        ctx.pdr = best_pdr;
        if (ctx.pdr == null) {
            if (ctx.flow_info.has_ip_info) {
                print("Worker {}: No matching PDR for TEID 0x{x}, src: {}.{}.{}.{}, dst: {}.{}.{}.{}, proto: {}, port: {}\n", .{
                    ctx.thread_id,
                    ctx.header.teid,
                    ctx.flow_info.src_ip[0],
                    ctx.flow_info.src_ip[1],
                    ctx.flow_info.src_ip[2],
                    ctx.flow_info.src_ip[3],
                    ctx.flow_info.dst_ip[0],
                    ctx.flow_info.dst_ip[1],
                    ctx.flow_info.dst_ip[2],
                    ctx.flow_info.dst_ip[3],
                    ctx.flow_info.protocol,
                    ctx.flow_info.dst_port,
                });
            } else {
                print("Worker {}: No matching PDR for TEID 0x{x}, source_interface: {}\n", .{ ctx.thread_id, ctx.header.teid, ctx.source_interface });
            }
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

// Pipeline Stage 5: Lookup QER if PDR references one
fn lookupQER(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    // Check if PDR has QER configured
    if (ctx.pdr) |pdr| {
        if (!pdr.has_qer) {
            // No QER configured - skip QoS enforcement
            ctx.qer = null;
            return true;
        }

        if (ctx.session) |session| {
            ctx.qer = session.findQER(pdr.qer_id);
            if (ctx.qer == null) {
                print("Worker {}: QER {} not found for PDR {}\n", .{ ctx.thread_id, pdr.qer_id, pdr.id });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                return false;
            }
            return true;
        }
    }
    return false;
}

// Pipeline Stage 6: Enforce QoS using token bucket algorithm
fn enforceQoS(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    // No QER configured - allow packet through
    if (ctx.qer == null) {
        return true;
    }

    const qer = ctx.qer.?;
    const payload_bits = ctx.payload.len * 8;
    const now = @as(i64, @intCast(time.nanoTimestamp()));

    qer.mutex.lock();
    defer qer.mutex.unlock();

    // Refill token buckets based on elapsed time
    const last_refill = qer.last_refill.load(.seq_cst);
    const elapsed_ns = @as(u64, @intCast(now - last_refill));
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Check PPS limit if configured
    if (qer.has_pps_limit) {
        // Refill PPS tokens: limit * elapsed_seconds
        const pps_refill = @as(u32, @intFromFloat(@as(f64, @floatFromInt(qer.pps_limit)) * elapsed_seconds));
        const current_pps = qer.pps_tokens.load(.seq_cst);
        const new_pps = @min(current_pps + pps_refill, qer.pps_limit);
        qer.pps_tokens.store(new_pps, .seq_cst);

        // Check if we have tokens available
        if (new_pps < 1) {
            print("Worker {}: PPS limit exceeded (QER {}), dropping packet\n", .{ ctx.thread_id, qer.id });
            _ = stats.qos_pps_dropped.fetchAdd(1, .seq_cst);
            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            return false;
        }

        // Consume 1 packet token
        qer.pps_tokens.store(new_pps - 1, .seq_cst);
    }

    // Check MBR limit if configured
    if (qer.has_mbr) {
        // Determine direction based on source interface
        const mbr_limit = if (ctx.source_interface == 0) // N3 = uplink
            qer.mbr_uplink
        else // N6/N9 = downlink
            qer.mbr_downlink;

        // Refill MBR tokens: bits/second * elapsed_seconds
        const mbr_refill = @as(u64, @intFromFloat(@as(f64, @floatFromInt(mbr_limit)) * elapsed_seconds));
        const current_mbr = qer.mbr_tokens.load(.seq_cst);
        const new_mbr = @min(current_mbr + mbr_refill, mbr_limit);
        qer.mbr_tokens.store(new_mbr, .seq_cst);

        // Check if we have enough tokens for this packet
        if (new_mbr < payload_bits) {
            print("Worker {}: MBR limit exceeded (QER {}), dropping packet ({} bits needed, {} available)\n", .{ ctx.thread_id, qer.id, payload_bits, new_mbr });
            _ = stats.qos_mbr_dropped.fetchAdd(1, .seq_cst);
            _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
            return false;
        }

        // Consume tokens
        qer.mbr_tokens.store(new_mbr - payload_bits, .seq_cst);
    }

    // Update last refill timestamp
    qer.last_refill.store(now, .seq_cst);

    // Packet passed QoS checks
    _ = stats.qos_packets_passed.fetchAdd(1, .seq_cst);
    return true;
}

// Pipeline Stage 7: Execute FAR action (forward/drop)
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
                .qer = null,
                .payload = undefined,
                .source_interface = 0,
                .thread_id = thread_id,
                .flow_info = PacketFlowInfo.init(),
            };

            // Execute pipeline stages
            if (!parseHeader(&ctx, stats)) continue;
            if (!lookupSession(&ctx, session_manager, stats)) continue;
            if (!matchPDR(&ctx, stats)) continue;
            if (!lookupFAR(&ctx, stats)) continue;
            if (!lookupQER(&ctx, stats)) continue;
            if (!enforceQoS(&ctx, stats)) continue;
            executeFAR(&ctx, stats);
        } else {
            time.sleep(1 * time.ns_per_ms);
        }
    }

    print("GTP-U worker thread {} stopped\n", .{thread_id});
}
