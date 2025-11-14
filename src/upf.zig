const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const time = std.time;
const Mutex = std.Thread.Mutex;

// Import PFCP and GTP-U libraries
const pfcp = @import("zig-pfcp");
const gtpu = @import("zig-gtp-u");

// Configuration constants
const WORKER_THREADS = 4;
const QUEUE_SIZE = 1000;
const PFCP_PORT = 8805;
const GTPU_PORT = 2152;
const MAX_SESSIONS = 10000;

// Packet Detection Rule (PDR)
const PDR = struct {
    id: u16,
    precedence: u32,
    source_interface: u8, // 0=Access (N3), 1=Core (N6), 2=N9 (UPF-to-UPF)
    teid: u32, // GTP-U TEID to match
    far_id: u16, // Associated FAR
    allocated: bool,

    fn init(id: u16, precedence: u32, source_interface: u8, teid: u32, far_id: u16) PDR {
        return PDR{
            .id = id,
            .precedence = precedence,
            .source_interface = source_interface,
            .teid = teid,
            .far_id = far_id,
            .allocated = true,
        };
    }
};

// Forwarding Action Rule (FAR)
const FAR = struct {
    id: u16,
    action: u8, // 0=Drop, 1=Forward, 2=Buffer
    dest_interface: u8, // 0=Access (N3), 1=Core (N6), 2=N9 (UPF-to-UPF)
    outer_header_creation: bool,
    teid: u32, // TEID for encapsulation
    ipv4: [4]u8, // Destination IP for encapsulation
    allocated: bool,

    fn init(id: u16, action: u8, dest_interface: u8) FAR {
        return FAR{
            .id = id,
            .action = action,
            .dest_interface = dest_interface,
            .outer_header_creation = false,
            .teid = 0,
            .ipv4 = .{ 0, 0, 0, 0 },
            .allocated = true,
        };
    }

    fn setOuterHeader(self: *FAR, teid: u32, ipv4: [4]u8) void {
        self.outer_header_creation = true;
        self.teid = teid;
        self.ipv4 = ipv4;
    }
};

// PFCP Session
const Session = struct {
    seid: u64,
    cp_fseid: u64, // Control Plane F-SEID
    up_fseid: u64, // User Plane F-SEID (local)
    pdrs: [16]PDR,
    fars: [16]FAR,
    pdr_count: u8,
    far_count: u8,
    allocated: bool,
    mutex: Mutex,

    fn init(seid: u64, cp_fseid: u64, up_fseid: u64) Session {
        var session = Session{
            .seid = seid,
            .cp_fseid = cp_fseid,
            .up_fseid = up_fseid,
            .pdrs = undefined,
            .fars = undefined,
            .pdr_count = 0,
            .far_count = 0,
            .allocated = true,
            .mutex = Mutex{},
        };
        for (0..16) |i| {
            session.pdrs[i].allocated = false;
            session.fars[i].allocated = false;
        }
        return session;
    }

    fn addPDR(self: *Session, pdr: PDR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pdr_count >= 16) {
            return error.TooManyPDRs;
        }

        self.pdrs[self.pdr_count] = pdr;
        self.pdr_count += 1;
    }

    fn addFAR(self: *Session, far: FAR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.far_count >= 16) {
            return error.TooManyFARs;
        }

        self.fars[self.far_count] = far;
        self.far_count += 1;
    }

    fn findPDRByTeid(self: *Session, teid: u32, source_interface: u8) ?*PDR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and
                self.pdrs[i].teid == teid and
                self.pdrs[i].source_interface == source_interface) {
                return &self.pdrs[i];
            }
        }
        return null;
    }

    fn findFAR(self: *Session, far_id: u16) ?*FAR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far_id) {
                return &self.fars[i];
            }
        }
        return null;
    }
};

// Session Manager - manages all PFCP sessions
const SessionManager = struct {
    sessions: [MAX_SESSIONS]Session,
    session_count: Atomic(usize),
    mutex: Mutex,
    next_up_seid: Atomic(u64),

    fn init() SessionManager {
        var mgr = SessionManager{
            .sessions = undefined,
            .session_count = Atomic(usize).init(0),
            .mutex = Mutex{},
            .next_up_seid = Atomic(u64).init(1),
        };
        for (0..MAX_SESSIONS) |i| {
            mgr.sessions[i].allocated = false;
        }
        return mgr;
    }

    fn createSession(self: *SessionManager, cp_fseid: u64) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.session_count.load(.seq_cst);
        if (count >= MAX_SESSIONS) {
            return error.TooManySessions;
        }

        // Generate UP F-SEID
        const up_fseid = self.next_up_seid.fetchAdd(1, .seq_cst);

        // Find first available slot
        for (0..MAX_SESSIONS) |i| {
            if (!self.sessions[i].allocated) {
                self.sessions[i] = Session.init(up_fseid, cp_fseid, up_fseid);
                _ = self.session_count.fetchAdd(1, .seq_cst);
                print("Created PFCP session - CP SEID: 0x{x}, UP SEID: 0x{x}\n", .{ cp_fseid, up_fseid });
                return up_fseid;
            }
        }

        return error.NoSessionSlot;
    }

    fn findSession(self: *SessionManager, seid: u64) ?*Session {
        for (0..MAX_SESSIONS) |i| {
            if (self.sessions[i].allocated and self.sessions[i].up_fseid == seid) {
                return &self.sessions[i];
            }
        }
        return null;
    }

    fn findSessionByTeid(self: *SessionManager, teid: u32, source_interface: u8) ?*Session {
        for (0..MAX_SESSIONS) |i| {
            if (self.sessions[i].allocated) {
                if (self.sessions[i].findPDRByTeid(teid, source_interface)) |_| {
                    return &self.sessions[i];
                }
            }
        }
        return null;
    }

    fn deleteSession(self: *SessionManager, seid: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..MAX_SESSIONS) |i| {
            if (self.sessions[i].allocated and self.sessions[i].up_fseid == seid) {
                self.sessions[i].allocated = false;
                _ = self.session_count.fetchSub(1, .seq_cst);
                print("Deleted PFCP session - SEID: 0x{x}\n", .{seid});
                return true;
            }
        }
        return false;
    }
};

// GTP-U packet message
const GtpuPacket = struct {
    data: [2048]u8,
    length: usize,
    client_address: net.Address,
    socket: std.posix.socket_t,
};

// Thread-safe packet queue
const PacketQueue = struct {
    packets: [QUEUE_SIZE]GtpuPacket,
    head: Atomic(usize),
    tail: Atomic(usize),
    count: Atomic(usize),
    mutex: Mutex,

    fn init() PacketQueue {
        return PacketQueue{
            .packets = undefined,
            .head = Atomic(usize).init(0),
            .tail = Atomic(usize).init(0),
            .count = Atomic(usize).init(0),
            .mutex = Mutex{},
        };
    }

    fn enqueue(self: *PacketQueue, packet: GtpuPacket) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count >= QUEUE_SIZE) {
            return false;
        }

        const tail = self.tail.load(.seq_cst);
        self.packets[tail] = packet;
        _ = self.tail.store((tail + 1) % QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchAdd(1, .seq_cst);
        return true;
    }

    fn dequeue(self: *PacketQueue) ?GtpuPacket {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count == 0) {
            return null;
        }

        const head = self.head.load(.seq_cst);
        const packet = self.packets[head];
        _ = self.head.store((head + 1) % QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchSub(1, .seq_cst);
        return packet;
    }

    fn size(self: *PacketQueue) usize {
        return self.count.load(.seq_cst);
    }
};

// Statistics
const Stats = struct {
    pfcp_messages: Atomic(u64),
    pfcp_sessions: Atomic(u64),
    gtpu_packets_rx: Atomic(u64),
    gtpu_packets_tx: Atomic(u64),
    gtpu_packets_dropped: Atomic(u64),
    n3_packets_tx: Atomic(u64), // N3 (Access) transmit
    n6_packets_tx: Atomic(u64), // N6 (Core) transmit
    n9_packets_tx: Atomic(u64), // N9 (UPF-to-UPF) transmit
    queue_size: Atomic(usize),
    start_time: i64,

    fn init() Stats {
        return Stats{
            .pfcp_messages = Atomic(u64).init(0),
            .pfcp_sessions = Atomic(u64).init(0),
            .gtpu_packets_rx = Atomic(u64).init(0),
            .gtpu_packets_tx = Atomic(u64).init(0),
            .gtpu_packets_dropped = Atomic(u64).init(0),
            .n3_packets_tx = Atomic(u64).init(0),
            .n6_packets_tx = Atomic(u64).init(0),
            .n9_packets_tx = Atomic(u64).init(0),
            .queue_size = Atomic(usize).init(0),
            .start_time = time.timestamp(),
        };
    }
};

// Global variables
var global_stats: Stats = undefined;
var session_manager: SessionManager = undefined;
var packet_queue: PacketQueue = undefined;
var should_stop: Atomic(bool) = Atomic(bool).init(false);
var gtpu_socket: std.posix.socket_t = undefined;
var upf_ipv4: [4]u8 = undefined;

// Parse GTP-U header (simplified)
fn parseGtpuHeader(data: []const u8) !struct { version: u8, message_type: u8, teid: u32, payload_offset: usize } {
    if (data.len < 8) {
        return error.PacketTooShort;
    }

    const flags = data[0];
    const version = (flags >> 5) & 0x07;
    const message_type = data[1];
    const teid = std.mem.readInt(u32, data[4..8], .big);

    const offset: usize = 8;

    // Check for extension headers
    if ((flags & 0x04) != 0) { // E flag
        return error.ExtensionHeadersNotSupported;
    }

    return .{
        .version = version,
        .message_type = message_type,
        .teid = teid,
        .payload_offset = offset,
    };
}

// Create GTP-U header for encapsulation (N3/N9 interfaces)
fn createGtpuHeader(buffer: []u8, teid: u32, payload: []const u8) usize {
    if (buffer.len < 8 + payload.len) {
        return 0; // Not enough space
    }

    // GTP-U header (8 bytes without extension headers)
    buffer[0] = 0x30; // Version 1, PT=1, E=0, S=0, PN=0
    buffer[1] = 0xFF; // Message Type: G-PDU

    // Length (excluding first 8 bytes)
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, buffer[2..4], length, .big);

    // TEID
    std.mem.writeInt(u32, buffer[4..8], teid, .big);

    // Copy payload
    @memcpy(buffer[8..8 + payload.len], payload);

    return 8 + payload.len;
}

// Worker thread for processing GTP-U packets
fn gtpuWorkerThread(thread_id: u32) void {
    print("GTP-U worker thread {} started\n", .{thread_id});

    while (!should_stop.load(.seq_cst)) {
        if (packet_queue.dequeue()) |packet| {
            global_stats.queue_size.store(packet_queue.size(), .seq_cst);

            // Parse GTP-U header
            const header = parseGtpuHeader(packet.data[0..packet.length]) catch |err| {
                print("Worker {}: Failed to parse GTP-U header: {}\n", .{ thread_id, err });
                _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
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
                                        print("Worker {}: Forwarding to N3 (Access), TEID: 0x{x}, size: {} bytes\n",
                                            .{ thread_id, header.teid, payload.len });

                                        if (far.outer_header_creation) {
                                            // Re-encapsulate with GTP-U for N3
                                            var out_buffer: [2048]u8 = undefined;
                                            const out_len = createGtpuHeader(&out_buffer, far.teid, payload);

                                            if (out_len > 0) {
                                                // Create destination address for gNodeB
                                                const dest_addr = net.Address.initIp4(far.ipv4, GTPU_PORT) catch {
                                                    print("Worker {}: Invalid N3 destination address\n", .{thread_id});
                                                    _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = std.posix.sendto(packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
                                                    print("Worker {}: Failed to send to N3: {}\n", .{ thread_id, err });
                                                    _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = global_stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                                _ = global_stats.n3_packets_tx.fetchAdd(1, .seq_cst);
                                            } else {
                                                _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                            }
                                        } else {
                                            print("Worker {}: N3 forwarding requires outer header creation\n", .{thread_id});
                                            _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                        }
                                    },
                                    1 => { // Core (N6) - Forward to data network (decapsulated)
                                        print("Worker {}: Forwarding to N6 (Core), TEID: 0x{x}, size: {} bytes\n",
                                            .{ thread_id, header.teid, payload.len });

                                        // For N6, we would send the decapsulated IP packet to the data network
                                        // This requires a separate socket and routing setup
                                        // For now, just count as forwarded
                                        _ = global_stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                        _ = global_stats.n6_packets_tx.fetchAdd(1, .seq_cst);
                                    },
                                    2 => { // N9 - Forward to peer UPF
                                        print("Worker {}: Forwarding to N9 (UPF-to-UPF), TEID: 0x{x}, size: {} bytes, peer: {}.{}.{}.{}\n",
                                            .{ thread_id, header.teid, payload.len, far.ipv4[0], far.ipv4[1], far.ipv4[2], far.ipv4[3] });

                                        if (far.outer_header_creation) {
                                            // Re-encapsulate with new GTP-U header for N9
                                            var out_buffer: [2048]u8 = undefined;
                                            const out_len = createGtpuHeader(&out_buffer, far.teid, payload);

                                            if (out_len > 0) {
                                                // Create destination address for peer UPF
                                                const dest_addr = net.Address.initIp4(far.ipv4, GTPU_PORT) catch {
                                                    print("Worker {}: Invalid N9 destination address\n", .{thread_id});
                                                    _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = std.posix.sendto(packet.socket, out_buffer[0..out_len], 0, &dest_addr.any, dest_addr.getOsSockLen()) catch |err| {
                                                    print("Worker {}: Failed to send to N9: {}\n", .{ thread_id, err });
                                                    _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                                    continue;
                                                };

                                                _ = global_stats.gtpu_packets_tx.fetchAdd(1, .seq_cst);
                                                _ = global_stats.n9_packets_tx.fetchAdd(1, .seq_cst);
                                            } else {
                                                _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                            }
                                        } else {
                                            print("Worker {}: N9 forwarding requires outer header creation\n", .{thread_id});
                                            _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                        }
                                    },
                                    else => { // Unknown interface
                                        print("Worker {}: Unknown dest_interface: {}\n", .{ thread_id, far.dest_interface });
                                        _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                                    }
                                }
                            } else if (far.action == 0) { // Drop
                                print("Worker {}: Dropping packet per FAR, TEID: 0x{x}\n", .{ thread_id, header.teid });
                                _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                            }
                        } else {
                            print("Worker {}: FAR not found for PDR {}\n", .{ thread_id, pdr.far_id });
                            _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                        }
                    } else {
                        print("Worker {}: PDR not found for TEID 0x{x}\n", .{ thread_id, header.teid });
                        _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                    }
                } else {
                    print("Worker {}: Session not found for TEID 0x{x}\n", .{ thread_id, header.teid });
                    _ = global_stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
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

// PFCP message handler
fn handlePfcpMessage(data: []const u8, client_addr: net.Address, socket: std.posix.socket_t, allocator: std.mem.Allocator) void {
    _ = allocator;
    _ = global_stats.pfcp_messages.fetchAdd(1, .seq_cst);

    if (data.len < 4) {
        print("PFCP: Packet too short\n", .{});
        return;
    }

    const version = (data[0] >> 5) & 0x07;
    const message_type = data[1];

    print("PFCP: Received message type 0x{x}, version {}, from {}\n",
        .{ message_type, version, client_addr });

    // Handle different message types
    switch (message_type) {
        1 => { // Heartbeat Request
            print("PFCP: Heartbeat Request received\n", .{});
            // Send Heartbeat Response (simplified)
            var response = [_]u8{
                0x20, 0x02, 0x00, 0x0C, // Version, Message Type, Length
                0x00, 0x00, 0x00, 0x00, // Sequence Number (copy from request)
                0x00, 0x00, 0x00, 0x00, // Recovery Time Stamp IE
                0x00, 0x60, 0x00, 0x04, // IE type and length
                0x00, 0x00, 0x00, 0x01, // Recovery timestamp value
            };
            // Copy sequence number from request
            if (data.len >= 8) {
                @memcpy(response[4..8], data[4..8]);
            }
            _ = std.posix.sendto(socket, &response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
                print("PFCP: Failed to send Heartbeat Response\n", .{});
            };
        },
        50 => { // Session Establishment Request
            print("PFCP: Session Establishment Request received\n", .{});

            // For now, create a simple session with dummy PDR/FAR
            const cp_seid: u64 = 0x1234567890ABCDEF; // Should parse from message
            const up_seid = session_manager.createSession(cp_seid) catch {
                print("PFCP: Failed to create session\n", .{});
                return;
            };

            // Create default PDR and FAR
            if (session_manager.findSession(up_seid)) |session| {
                const pdr = PDR.init(1, 100, 0, 0x100, 1); // PDR ID 1, TEID 0x100, FAR ID 1
                const far = FAR.init(1, 1, 1); // FAR ID 1, Forward, Core interface

                session.addPDR(pdr) catch {
                    print("PFCP: Failed to add PDR\n", .{});
                };
                session.addFAR(far) catch {
                    print("PFCP: Failed to add FAR\n", .{});
                };

                _ = global_stats.pfcp_sessions.fetchAdd(1, .seq_cst);
                print("PFCP: Created session with SEID 0x{x}, PDR TEID: 0x{x}\n", .{ up_seid, pdr.teid });
            }

            // Send simplified Session Establishment Response
            var response = [_]u8{
                0x21, 0x32, 0x00, 0x20, // Version with SEID, Message Type, Length
            } ++ [_]u8{0} ** 60;

            // Add UP F-SEID to response
            std.mem.writeInt(u64, response[4..12], up_seid, .big);

            _ = std.posix.sendto(socket, response[0..36], 0, &client_addr.any, client_addr.getOsSockLen()) catch {
                print("PFCP: Failed to send Session Establishment Response\n", .{});
            };
        },
        53 => { // Session Deletion Request
            print("PFCP: Session Deletion Request received\n", .{});
            // Parse SEID and delete session
            // Simplified response
            var response = [_]u8{ 0x21, 0x35, 0x00, 0x0C } ++ [_]u8{0} ** 20;
            _ = std.posix.sendto(socket, response[0..16], 0, &client_addr.any, client_addr.getOsSockLen()) catch {
                print("PFCP: Failed to send Session Deletion Response\n", .{});
            };
        },
        else => {
            print("PFCP: Unsupported message type: 0x{x}\n", .{message_type});
        },
    }
}

// PFCP thread
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
            handlePfcpMessage(buffer[0..bytes_received], client_address, pfcp_socket, allocator);
        }
    }

    print("PFCP thread stopped\n", .{});
}

// GTP-U thread
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

            var packet = GtpuPacket{
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

// Statistics thread
fn statsThread() void {
    print("Statistics thread started\n", .{});

    var last_rx: u64 = 0;
    var last_tx: u64 = 0;

    while (!should_stop.load(.seq_cst)) {
        time.sleep(5 * time.ns_per_s);

        const pfcp_msgs = global_stats.pfcp_messages.load(.seq_cst);
        const pfcp_sess = global_stats.pfcp_sessions.load(.seq_cst);
        const gtpu_rx = global_stats.gtpu_packets_rx.load(.seq_cst);
        const gtpu_tx = global_stats.gtpu_packets_tx.load(.seq_cst);
        const gtpu_drop = global_stats.gtpu_packets_dropped.load(.seq_cst);
        const n3_tx = global_stats.n3_packets_tx.load(.seq_cst);
        const n6_tx = global_stats.n6_packets_tx.load(.seq_cst);
        const n9_tx = global_stats.n9_packets_tx.load(.seq_cst);
        const queue_sz = global_stats.queue_size.load(.seq_cst);

        const rx_rate = (gtpu_rx - last_rx) / 5;
        const tx_rate = (gtpu_tx - last_tx) / 5;

        const uptime = time.timestamp() - global_stats.start_time;
        const active_sessions = session_manager.session_count.load(.seq_cst);

        print("\n=== PicoUP Statistics ===\n", .{});
        print("Uptime: {}s\n", .{uptime});
        print("PFCP Messages: {}, Active Sessions: {}/{}\n", .{ pfcp_msgs, active_sessions, pfcp_sess });
        print("GTP-U RX: {}, TX: {}, Dropped: {}\n", .{ gtpu_rx, gtpu_tx, gtpu_drop });
        print("GTP-U Rate: {} pkt/s RX, {} pkt/s TX\n", .{ rx_rate, tx_rate });
        print("Interface TX: N3={}, N6={}, N9={}\n", .{ n3_tx, n6_tx, n9_tx });
        print("Queue Size: {}\n", .{queue_sz});
        print("Worker Threads: {}\n", .{WORKER_THREADS});
        print("========================\n", .{});

        last_rx = gtpu_rx;
        last_tx = gtpu_tx;
    }

    print("Statistics thread stopped\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== PicoUP - User Plane Function ===\n", .{});
    print("Version: 0.1.0\n", .{});
    print("Worker Threads: {}\n", .{WORKER_THREADS});
    print("Press Ctrl+C to stop\n\n", .{});

    // Initialize global state
    global_stats = Stats.init();
    session_manager = SessionManager.init();
    packet_queue = PacketQueue.init();
    upf_ipv4 = .{ 10, 0, 0, 1 }; // Default UPF IP

    // Start GTP-U worker threads
    var worker_threads: [WORKER_THREADS]Thread = undefined;
    for (0..WORKER_THREADS) |i| {
        worker_threads[i] = try Thread.spawn(.{}, gtpuWorkerThread, .{@as(u32, @intCast(i))});
    }

    // Start PFCP thread
    const pfcp_thread_handle = try Thread.spawn(.{}, pfcpThread, .{allocator});

    // Start GTP-U thread
    const gtpu_thread_handle = try Thread.spawn(.{}, gtpuThread, .{});

    // Start statistics thread
    const stats_thread_handle = try Thread.spawn(.{}, statsThread, .{});

    // Wait for threads (will run until Ctrl+C)
    pfcp_thread_handle.join();
    gtpu_thread_handle.join();
    for (worker_threads) |thread| {
        thread.join();
    }
    stats_thread_handle.join();
}
