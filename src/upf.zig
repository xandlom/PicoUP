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
const MAX_SESSIONS = 100;

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

    fn findPDRById(self: *Session, pdr_id: u16) ?*PDR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr_id) {
                return &self.pdrs[i];
            }
        }
        return null;
    }

    fn updatePDR(self: *Session, pdr: PDR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr.id) {
                self.pdrs[i] = pdr;
                return;
            }
        }
        return error.PDRNotFound;
    }

    fn removePDR(self: *Session, pdr_id: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr_id) {
                self.pdrs[i].allocated = false;
                // Compact the array by shifting remaining PDRs
                var j = i;
                while (j < self.pdr_count - 1) : (j += 1) {
                    self.pdrs[j] = self.pdrs[j + 1];
                }
                self.pdr_count -= 1;
                return;
            }
        }
        return error.PDRNotFound;
    }

    fn updateFAR(self: *Session, far: FAR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far.id) {
                self.fars[i] = far;
                return;
            }
        }
        return error.FARNotFound;
    }

    fn removeFAR(self: *Session, far_id: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far_id) {
                self.fars[i].allocated = false;
                // Compact the array by shifting remaining FARs
                var j = i;
                while (j < self.far_count - 1) : (j += 1) {
                    self.fars[j] = self.fars[j + 1];
                }
                self.far_count -= 1;
                return;
            }
        }
        return error.FARNotFound;
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
var pfcp_association_established: Atomic(bool) = Atomic(bool).init(false);
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
                                                const dest_addr = net.Address.initIp4(far.ipv4, GTPU_PORT);

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
                                                const dest_addr = net.Address.initIp4(far.ipv4, GTPU_PORT);

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

    // Parse PFCP header using zig-pfcp library
    var reader = pfcp.marshal.Reader.init(data);
    const header = pfcp.marshal.decodePfcpHeader(&reader) catch |err| {
        print("PFCP: Failed to decode header: {}\n", .{err});
        return;
    };

    print("PFCP: Received message type {}, SEID: {?x}, seq: {}, from {}\n",
        .{ header.message_type, header.seid, header.sequence_number, client_addr });

    // Handle different message types
    const msg_type: pfcp.types.MessageType = @enumFromInt(header.message_type);
    switch (msg_type) {
        .heartbeat_request => {
            handleHeartbeatRequest(socket, &header, client_addr);
        },
        .association_setup_request => {
            handleAssociationSetup(socket, &header, &reader, client_addr);
        },
        .session_establishment_request => {
            handleSessionEstablishment(socket, &header, &reader, client_addr);
        },
        .session_modification_request => {
            handleSessionModification(socket, &header, &reader, client_addr);
        },
        .session_deletion_request => {
            handleSessionDeletion(socket, &header, &reader, client_addr);
        },
        else => {
            print("PFCP: Unsupported message type: {}\n", .{msg_type});
        },
    }
}

// Heartbeat Request handler
fn handleHeartbeatRequest(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address) void {
    print("PFCP: Heartbeat Request received\n", .{});

    // Build Heartbeat Response
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    // Create response header
    var resp_header = pfcp.types.PfcpHeader.init(.heartbeat_response, false);
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch {
        print("PFCP: Failed to encode header\n", .{});
        return;
    };

    // Add Recovery Time Stamp IE
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.fromUnixTime(global_stats.start_time);
    pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts) catch {
        print("PFCP: Failed to encode Recovery Time Stamp\n", .{});
        return;
    };

    // Update message length
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    // Send response
    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
        print("PFCP: Failed to send Heartbeat Response\n", .{});
    };
}

// Association Setup Request handler
fn handleAssociationSetup(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, reader: *pfcp.marshal.Reader, client_addr: net.Address) void {
    print("PFCP: Association Setup Request received from {}\n", .{client_addr});

    // Parse mandatory IEs: Node ID and Recovery Time Stamp
    var found_node_id = false;
    var found_recovery_ts = false;
    var remote_node_id_type: pfcp.types.NodeIdType = .ipv4;
    var remote_recovery_ts: u32 = 0;

    // Parse IEs from the message body
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Parse node ID type (first byte)
                if (ie_header.length >= 1) {
                    const type_byte = reader.readByte() catch break;
                    remote_node_id_type = @enumFromInt(@as(u4, @truncate(type_byte)));
                    // Skip the rest of the node ID value
                    reader.pos += ie_header.length - 1;
                    found_node_id = true;
                    print("PFCP: Remote Node ID type: {}\n", .{remote_node_id_type});
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .recovery_time_stamp => {
                if (ie_header.length == 4) {
                    remote_recovery_ts = reader.readU32() catch break;
                    found_recovery_ts = true;
                    print("PFCP: Remote Recovery Time Stamp: {}\n", .{remote_recovery_ts});
                } else {
                    reader.pos += ie_header.length;
                }
            },
            else => {
                // Skip other optional IEs (UP Function Features, CP Function Features, etc.)
                reader.pos += ie_header.length;
            },
        }
    }

    // Validate mandatory IEs
    if (!found_node_id or !found_recovery_ts) {
        print("PFCP: Missing mandatory IE in Association Setup Request\n", .{});
        sendAssociationSetupResponse(socket, req_header, client_addr, .mandatory_ie_missing);
        return;
    }

    // Establish association
    _ = pfcp_association_established.store(true, .seq_cst);
    print("PFCP: Association established with {}\n", .{client_addr});

    // Send success response
    sendAssociationSetupResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Association Setup Response
fn sendAssociationSetupResponse(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address, cause_value: pfcp.types.CauseValue) void {
    var response_buf: [512]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    // Create response header (Association Setup is a node message, no SEID)
    var resp_header = pfcp.types.PfcpHeader.init(.association_setup_response, false);
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    // Encode mandatory IEs: Node ID, Cause, Recovery Time Stamp

    // Node ID (use our UPF IPv4 address)
    const node_id = pfcp.ie.NodeId.initIpv4(upf_ipv4);
    pfcp.marshal.encodeNodeId(&writer, node_id) catch return;

    // Cause
    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    // Recovery Time Stamp
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.fromUnixTime(global_stats.start_time);
    pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts) catch return;

    // Update message length
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    // Send response
    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
        print("PFCP: Failed to send Association Setup Response\n", .{});
    };

    if (cause_value == .request_accepted) {
        print("PFCP: Association Setup Response sent (accepted)\n", .{});
    } else {
        print("PFCP: Association Setup Response sent (cause: {})\n", .{cause_value});
    }
}

// Session Establishment Request handler
fn handleSessionEstablishment(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, reader: *pfcp.marshal.Reader, client_addr: net.Address) void {
    print("PFCP: Session Establishment Request received\n", .{});

    // Check if PFCP association is established
    if (!pfcp_association_established.load(.seq_cst)) {
        print("PFCP: No PFCP association established\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .no_established_pfcp_association);
        return;
    }

    // Parse mandatory IEs: Node ID and F-SEID
    var cp_seid: u64 = 0;
    var found_fseid = false;

    // Parse IEs from the message body
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Skip node ID for now
                reader.pos += ie_header.length;
            },
            .f_seid => {
                // Parse F-SEID to get CP SEID
                if (ie_header.length >= 9) {
                    const flags = reader.readByte() catch break;
                    cp_seid = reader.readU64() catch break;
                    // Skip IP address bytes
                    const remaining_bytes = ie_header.length - 9;
                    reader.pos += remaining_bytes;
                    found_fseid = true;
                    print("PFCP: CP F-SEID: 0x{x}, flags: 0x{x}\n", .{ cp_seid, flags });
                } else {
                    reader.pos += ie_header.length;
                }
            },
            else => {
                // Skip other IEs
                reader.pos += ie_header.length;
            },
        }
    }

    // Validate mandatory IEs
    if (!found_fseid) {
        print("PFCP: Missing F-SEID in Session Establishment Request\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .mandatory_ie_missing);
        return;
    }

    // Create session
    const up_seid = session_manager.createSession(cp_seid) catch {
        print("PFCP: Failed to create session\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .no_resources_available);
        return;
    };

    // Create default PDR and FAR
    if (session_manager.findSession(up_seid)) |session| {
        const pdr = PDR.init(1, 100, 0, 0x100, 1);
        const far = FAR.init(1, 1, 1);

        session.addPDR(pdr) catch {};
        session.addFAR(far) catch {};

        _ = global_stats.pfcp_sessions.fetchAdd(1, .seq_cst);
        print("PFCP: Created session with UP SEID 0x{x}, PDR TEID: 0x{x}\n", .{ up_seid, pdr.teid });
    }

    sendSessionEstablishmentResponse(socket, req_header, client_addr, up_seid, .request_accepted);
}

// Helper: Send Session Establishment Response
fn sendSessionEstablishmentResponse(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address, up_seid: u64, cause_value: pfcp.types.CauseValue) void {
    var response_buf: [512]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_establishment_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const up_fseid = pfcp.ie.FSEID.initV4(up_seid, [_]u8{ 10, 0, 0, 1 });
    pfcp.marshal.encodeFSEID(&writer, up_fseid) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Helper: Send Session Establishment Error Response
fn sendSessionEstablishmentError(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address, cause_value: pfcp.types.CauseValue) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_establishment_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Session Modification Request handler
fn handleSessionModification(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, reader: *pfcp.marshal.Reader, client_addr: net.Address) void {
    print("PFCP: Session Modification Request received\n", .{});

    const seid = req_header.seid orelse {
        print("PFCP: Session Modification Request missing SEID\n", .{});
        return;
    };

    print("PFCP: Modifying session SEID 0x{x}\n", .{seid});

    const session = session_manager.findSession(seid);
    if (session == null) {
        print("PFCP: Session 0x{x} not found\n", .{seid});
        sendSessionModificationResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    }

    // Parse IEs (simplified - full implementation would handle all IE types)
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        reader.pos += ie_header.length;
    }

    print("PFCP: Session modification completed for SEID 0x{x}\n", .{seid});
    sendSessionModificationResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Session Modification Response
fn sendSessionModificationResponse(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address, cause_value: pfcp.types.CauseValue) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_modification_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Session Deletion Request handler
fn handleSessionDeletion(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, reader: *pfcp.marshal.Reader, client_addr: net.Address) void {
    print("PFCP: Session Deletion Request received\n", .{});
    _ = reader;

    const seid = req_header.seid orelse {
        print("PFCP: Session Deletion Request missing SEID\n", .{});
        return;
    };

    print("PFCP: Deleting session SEID 0x{x}\n", .{seid});

    const deleted = session_manager.deleteSession(seid);
    if (!deleted) {
        print("PFCP: Failed to delete session 0x{x}\n", .{seid});
        sendSessionDeletionResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    }

    print("PFCP: Session 0x{x} deleted successfully\n", .{seid});
    sendSessionDeletionResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Session Deletion Response
fn sendSessionDeletionResponse(socket: std.posix.socket_t, req_header: *const pfcp.types.PfcpHeader, client_addr: net.Address, cause_value: pfcp.types.CauseValue) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_deletion_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
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
