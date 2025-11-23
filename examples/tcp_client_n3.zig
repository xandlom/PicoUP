// TCP Client for N3 testing (simulates gNodeB + UE TCP traffic)
// Establishes PFCP sessions and sends GTP-U encapsulated TCP packets
// Performs full TCP handshake (SYN -> SYN-ACK -> ACK) through the tunnel
//
// Usage:
//   zig build example-tcp-n3-client
//   ./zig-out/bin/tcp_client_n3 <server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions]
//
// Example:
//   ./zig-out/bin/tcp_client_n3 127.0.0.1 9998 127.0.0.1 127.0.0.2 5

const std = @import("std");
const net = std.net;
const posix = std.posix;
const print = std.debug.print;
const time = std.time;
const pfcp = @import("zig-pfcp");
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// Configuration
const PFCP_PORT: u16 = 8805;
const GTPU_PORT: u16 = 2152;
const DEFAULT_TCP_PORT: u16 = 9998;
const MAX_SESSIONS: usize = 100;
const TCP_TIMEOUT_MS: u64 = 2000;

// TCP Flags
const TCP_FIN: u8 = 0x01;
const TCP_SYN: u8 = 0x02;
const TCP_RST: u8 = 0x04;
const TCP_PSH: u8 = 0x08;
const TCP_ACK: u8 = 0x10;

// Base values for session parameters
const BASE_UPLINK_TEID: u32 = 0x3000;
const BASE_DOWNLINK_TEID: u32 = 0x4000;
const BASE_CP_SEID: u64 = 0x3000;
const BASE_UE_IP: [4]u8 = .{ 10, 45, 0, 200 };

// TCP Connection state
const TcpState = enum {
    closed,
    syn_sent,
    established,
    fin_wait,
};

// Per-session state
const Session = struct {
    index: u32,
    cp_seid: u64,
    up_seid: u64,
    uplink_teid: u32,
    downlink_teid: u32,
    ue_ip: [4]u8,
    established: bool,
    // TCP state
    tcp_state: TcpState,
    local_seq: u32,
    remote_seq: u32,
    local_port: u16,

    fn init(index: u32) Session {
        return Session{
            .index = index,
            .cp_seid = BASE_CP_SEID + index,
            .up_seid = 0,
            .uplink_teid = BASE_UPLINK_TEID + index,
            .downlink_teid = BASE_DOWNLINK_TEID + index,
            .ue_ip = .{
                BASE_UE_IP[0],
                BASE_UE_IP[1],
                BASE_UE_IP[2],
                BASE_UE_IP[3] +| @as(u8, @truncate(index)),
            },
            .established = false,
            .tcp_state = .closed,
            .local_seq = 1000 + index * 1000,
            .remote_seq = 0,
            .local_port = 40000 + @as(u16, @truncate(index)),
        };
    }
};

// Global state
const GlobalState = struct {
    pfcp_socket: posix.socket_t,
    gtpu_socket: posix.socket_t,
    upf_pfcp_addr: net.Address,
    upf_gtpu_addr: net.Address,
    server_ip: [4]u8,
    server_port: u16,
    gnodeb_ip: [4]u8,
    sequence_number: Atomic(u32),
    sessions_created: Atomic(u32),
    sessions_failed: Atomic(u32),
    tcp_connections_established: Atomic(u32),
    tcp_connections_failed: Atomic(u32),

    fn nextSeq(self: *GlobalState) u24 {
        return @truncate(self.sequence_number.fetchAdd(1, .seq_cst));
    }
};

var global_state: GlobalState = undefined;
var sessions: [MAX_SESSIONS]Session = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions]\n", .{args[0]});
        print("\nArguments:\n", .{});
        print("  server_ip        - IP of the TCP server (N6 side)\n", .{});
        print("  port             - Port of TCP server (default: 9998)\n", .{});
        print("  upf_ip           - IP of the UPF (default: 127.0.0.1)\n", .{});
        print("  gnodeb_ip        - IP of THIS machine for downlink (default: 127.0.0.2)\n", .{});
        print("  num_sessions     - Number of sessions to create (default: 1, max: 100)\n", .{});
        print("\nExample:\n", .{});
        print("  {s} 127.0.0.1 9998 127.0.0.1 127.0.0.2 5\n", .{args[0]});
        return;
    }

    // Parse arguments
    const server_ip_str = args[1];
    const server_ip = net.Address.parseIp4(server_ip_str, 0) catch {
        print("Invalid server IP address: {s}\n", .{server_ip_str});
        return;
    };
    const server_ip_bytes: [4]u8 = @bitCast(server_ip.in.sa.addr);

    const server_port: u16 = if (args.len > 2)
        std.fmt.parseInt(u16, args[2], 10) catch DEFAULT_TCP_PORT
    else
        DEFAULT_TCP_PORT;

    const upf_ip_str = if (args.len > 3) args[3] else "127.0.0.1";
    const upf_ip = net.Address.parseIp4(upf_ip_str, 0) catch {
        print("Invalid UPF IP address: {s}\n", .{upf_ip_str});
        return;
    };
    const upf_ip_bytes: [4]u8 = @bitCast(upf_ip.in.sa.addr);

    const gnodeb_ip_str = if (args.len > 4) args[4] else "127.0.0.2";
    const gnodeb_ip = net.Address.parseIp4(gnodeb_ip_str, 0) catch {
        print("Invalid gNodeB IP address: {s}\n", .{gnodeb_ip_str});
        return;
    };
    const gnodeb_ip_bytes: [4]u8 = @bitCast(gnodeb_ip.in.sa.addr);

    const num_sessions: u32 = if (args.len > 5)
        @min(std.fmt.parseInt(u32, args[5], 10) catch 1, MAX_SESSIONS)
    else
        1;

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║     TCP Client (N3 Side - gNodeB Simulator)                ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Configuration:\n", .{});
    print("  UPF Address:     {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ upf_ip_str, PFCP_PORT, upf_ip_str, GTPU_PORT });
    print("  gNodeB Address:  {s}:{} (for downlink)\n", .{ gnodeb_ip_str, GTPU_PORT });
    print("  TCP Server:      {}.{}.{}.{}:{}\n", .{ server_ip_bytes[0], server_ip_bytes[1], server_ip_bytes[2], server_ip_bytes[3], server_port });
    print("  Sessions:        {}\n", .{num_sessions});
    print("\n", .{});

    // Create sockets
    const pfcp_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(pfcp_socket);

    const gtpu_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(gtpu_socket);

    const gnodeb_bind_addr = net.Address.initIp4(gnodeb_ip_bytes, GTPU_PORT);
    try posix.bind(gtpu_socket, &gnodeb_bind_addr.any, gnodeb_bind_addr.getOsSockLen());

    // Set receive timeout for GTP-U socket
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(gtpu_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    global_state = GlobalState{
        .pfcp_socket = pfcp_socket,
        .gtpu_socket = gtpu_socket,
        .upf_pfcp_addr = net.Address.initIp4(upf_ip_bytes, PFCP_PORT),
        .upf_gtpu_addr = net.Address.initIp4(upf_ip_bytes, GTPU_PORT),
        .server_ip = server_ip_bytes,
        .server_port = server_port,
        .gnodeb_ip = gnodeb_ip_bytes,
        .sequence_number = Atomic(u32).init(1),
        .sessions_created = Atomic(u32).init(0),
        .sessions_failed = Atomic(u32).init(0),
        .tcp_connections_established = Atomic(u32).init(0),
        .tcp_connections_failed = Atomic(u32).init(0),
    };

    for (0..num_sessions) |i| {
        sessions[i] = Session.init(@intCast(i));
    }

    // Step 1: PFCP Association Setup
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Step 1: PFCP Association Setup\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendAssociationSetup();
    time.sleep(200 * time.ns_per_ms);

    // Step 2: Session Establishment
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 2: PFCP Session Establishment ({} sessions)\n", .{num_sessions});
    print("═══════════════════════════════════════════════════════════\n", .{});

    const start_time = time.milliTimestamp();

    var threads: [MAX_SESSIONS]?Thread = [_]?Thread{null} ** MAX_SESSIONS;
    for (0..num_sessions) |i| {
        threads[i] = Thread.spawn(.{}, sessionEstablishmentThread, .{@as(u32, @intCast(i))}) catch |err| {
            print("Failed to spawn thread for session {}: {}\n", .{ i, err });
            continue;
        };
    }

    for (0..num_sessions) |i| {
        if (threads[i]) |t| {
            t.join();
        }
    }

    const elapsed = time.milliTimestamp() - start_time;
    const created = global_state.sessions_created.load(.seq_cst);
    const failed = global_state.sessions_failed.load(.seq_cst);
    print("\nSession creation completed in {}ms: {} created, {} failed\n", .{ elapsed, created, failed });

    // Step 3: TCP Traffic
    if (created > 0) {
        print("\n═══════════════════════════════════════════════════════════\n", .{});
        print("Step 3: TCP Connections via GTP-U Tunnels\n", .{});
        print("═══════════════════════════════════════════════════════════\n", .{});
        try runTcpTraffic(num_sessions);

        const tcp_ok = global_state.tcp_connections_established.load(.seq_cst);
        const tcp_fail = global_state.tcp_connections_failed.load(.seq_cst);
        print("\nTCP Results: {} established, {} failed\n", .{ tcp_ok, tcp_fail });
    }

    // Step 4: Cleanup
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 4: Cleanup ({} sessions)\n", .{created});
    print("═══════════════════════════════════════════════════════════\n", .{});

    var delete_threads: [MAX_SESSIONS]?Thread = [_]?Thread{null} ** MAX_SESSIONS;
    for (0..num_sessions) |i| {
        if (sessions[i].established) {
            delete_threads[i] = Thread.spawn(.{}, sessionDeletionThread, .{@as(u32, @intCast(i))}) catch continue;
        }
    }

    for (0..num_sessions) |i| {
        if (delete_threads[i]) |t| {
            t.join();
        }
    }

    time.sleep(100 * time.ns_per_ms);
    try sendAssociationRelease();

    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Test completed!\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
}

fn sessionEstablishmentThread(session_idx: u32) void {
    sendSessionEstablishment(session_idx) catch |err| {
        print("[Session {}] Failed: {}\n", .{ session_idx, err });
        _ = global_state.sessions_failed.fetchAdd(1, .seq_cst);
        return;
    };
    sessions[session_idx].established = true;
    _ = global_state.sessions_created.fetchAdd(1, .seq_cst);
}

fn sessionDeletionThread(session_idx: u32) void {
    sendSessionDeletion(session_idx) catch |err| {
        print("[Session {}] Deletion failed: {}\n", .{ session_idx, err });
    };
}

fn runTcpTraffic(num_sessions: u32) !void {
    for (0..num_sessions) |i| {
        const session = &sessions[i];
        if (!session.established) continue;

        print("\n[Session {}] Starting TCP connection...\n", .{i});

        // Perform TCP handshake
        const handshake_ok = performTcpHandshake(@intCast(i));
        if (!handshake_ok) {
            print("[Session {}] TCP handshake failed\n", .{i});
            _ = global_state.tcp_connections_failed.fetchAdd(1, .seq_cst);
            continue;
        }

        print("[Session {}] TCP connection established!\n", .{i});
        _ = global_state.tcp_connections_established.fetchAdd(1, .seq_cst);

        // Send test data
        sendTcpData(@intCast(i), "Hello from UE via GTP-U tunnel!") catch |err| {
            print("[Session {}] Failed to send data: {}\n", .{ i, err });
            continue;
        };

        // Wait for and receive echo response
        time.sleep(100 * time.ns_per_ms);
        receiveTcpResponse(@intCast(i));

        // Close connection gracefully
        sendTcpFin(@intCast(i)) catch {};
        time.sleep(50 * time.ns_per_ms);
    }
}

fn performTcpHandshake(session_idx: u32) bool {
    const session = &sessions[session_idx];

    // Send SYN
    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;

    const ip_len = buildTcpPacket(
        &ip_buf,
        session.ue_ip,
        global_state.server_ip,
        session.local_port,
        global_state.server_port,
        session.local_seq,
        0,
        TCP_SYN,
        "",
    );

    const gtpu_len = buildGtpuPacket(&gtpu_buf, session.uplink_teid, ip_buf[0..ip_len]);

    _ = posix.sendto(
        global_state.gtpu_socket,
        gtpu_buf[0..gtpu_len],
        0,
        &global_state.upf_gtpu_addr.any,
        global_state.upf_gtpu_addr.getOsSockLen(),
    ) catch return false;

    session.tcp_state = .syn_sent;
    session.local_seq += 1; // SYN consumes one sequence number

    // Wait for SYN-ACK
    var recv_buf: [2048]u8 = undefined;
    var from_addr: posix.sockaddr = undefined;
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    const recv_bytes = posix.recvfrom(
        global_state.gtpu_socket,
        &recv_buf,
        0,
        &from_addr,
        &from_len,
    ) catch return false;

    if (recv_bytes < 28) return false; // GTP-U (8) + IP (20) minimum

    // Parse GTP-U + IP + TCP to extract SYN-ACK
    const tcp_info = parseTcpFromGtpu(recv_buf[0..recv_bytes]) orelse return false;

    if ((tcp_info.flags & (TCP_SYN | TCP_ACK)) != (TCP_SYN | TCP_ACK)) {
        print("[Session {}] Expected SYN-ACK, got flags=0x{x}\n", .{ session_idx, tcp_info.flags });
        return false;
    }

    session.remote_seq = tcp_info.seq_num + 1; // Their SYN consumed one seq

    // Send ACK to complete handshake
    const ack_ip_len = buildTcpPacket(
        &ip_buf,
        session.ue_ip,
        global_state.server_ip,
        session.local_port,
        global_state.server_port,
        session.local_seq,
        session.remote_seq,
        TCP_ACK,
        "",
    );

    const ack_gtpu_len = buildGtpuPacket(&gtpu_buf, session.uplink_teid, ip_buf[0..ack_ip_len]);

    _ = posix.sendto(
        global_state.gtpu_socket,
        gtpu_buf[0..ack_gtpu_len],
        0,
        &global_state.upf_gtpu_addr.any,
        global_state.upf_gtpu_addr.getOsSockLen(),
    ) catch return false;

    session.tcp_state = .established;
    return true;
}

fn sendTcpData(session_idx: u32, data: []const u8) !void {
    const session = &sessions[session_idx];

    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;

    const ip_len = buildTcpPacket(
        &ip_buf,
        session.ue_ip,
        global_state.server_ip,
        session.local_port,
        global_state.server_port,
        session.local_seq,
        session.remote_seq,
        TCP_ACK | TCP_PSH,
        data,
    );

    const gtpu_len = buildGtpuPacket(&gtpu_buf, session.uplink_teid, ip_buf[0..ip_len]);

    _ = try posix.sendto(
        global_state.gtpu_socket,
        gtpu_buf[0..gtpu_len],
        0,
        &global_state.upf_gtpu_addr.any,
        global_state.upf_gtpu_addr.getOsSockLen(),
    );

    session.local_seq += @intCast(data.len);
    print("[Session {}] Sent {} bytes: \"{s}\"\n", .{ session_idx, data.len, data });
}

fn receiveTcpResponse(session_idx: u32) void {
    const session = &sessions[session_idx];
    var recv_buf: [2048]u8 = undefined;
    var from_addr: posix.sockaddr = undefined;
    var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    const recv_bytes = posix.recvfrom(
        global_state.gtpu_socket,
        &recv_buf,
        0,
        &from_addr,
        &from_len,
    ) catch {
        print("[Session {}] No response received (timeout)\n", .{session_idx});
        return;
    };

    const tcp_info = parseTcpFromGtpu(recv_buf[0..recv_bytes]) orelse {
        print("[Session {}] Failed to parse TCP response\n", .{session_idx});
        return;
    };

    if (tcp_info.payload_len > 0) {
        print("[Session {}] Received {} bytes: \"{s}\"\n", .{
            session_idx,
            tcp_info.payload_len,
            tcp_info.payload[0..tcp_info.payload_len],
        });
        session.remote_seq += @intCast(tcp_info.payload_len);
    }
}

fn sendTcpFin(session_idx: u32) !void {
    const session = &sessions[session_idx];

    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;

    const ip_len = buildTcpPacket(
        &ip_buf,
        session.ue_ip,
        global_state.server_ip,
        session.local_port,
        global_state.server_port,
        session.local_seq,
        session.remote_seq,
        TCP_FIN | TCP_ACK,
        "",
    );

    const gtpu_len = buildGtpuPacket(&gtpu_buf, session.uplink_teid, ip_buf[0..ip_len]);

    _ = try posix.sendto(
        global_state.gtpu_socket,
        gtpu_buf[0..gtpu_len],
        0,
        &global_state.upf_gtpu_addr.any,
        global_state.upf_gtpu_addr.getOsSockLen(),
    );

    session.tcp_state = .fin_wait;
    print("[Session {}] Sent FIN\n", .{session_idx});
}

const TcpInfo = struct {
    seq_num: u32,
    ack_num: u32,
    flags: u8,
    payload: []const u8,
    payload_len: usize,
};

fn parseTcpFromGtpu(data: []const u8) ?TcpInfo {
    if (data.len < 28) return null; // GTP-U(8) + IP(20) minimum

    // Skip GTP-U header (8 bytes for basic header)
    var offset: usize = 8;

    // Check for GTP-U extension headers
    if (data[0] & 0x07 != 0) {
        // Has extension/sequence/N-PDU, skip extra 4 bytes
        offset += 4;
    }

    if (offset + 20 > data.len) return null;

    // Parse IP header
    const ip_header_len = (data[offset] & 0x0F) * 4;
    const ip_total_len = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);
    const protocol = data[offset + 9];

    if (protocol != 6) return null; // Not TCP

    const tcp_offset = offset + ip_header_len;
    if (tcp_offset + 20 > data.len) return null;

    // Parse TCP header
    const tcp_data = data[tcp_offset..];
    const data_offset = (tcp_data[12] >> 4) * 4;
    const flags = tcp_data[13];
    const seq_num = std.mem.readInt(u32, tcp_data[4..8], .big);
    const ack_num = std.mem.readInt(u32, tcp_data[8..12], .big);

    const payload_start = tcp_offset + data_offset;
    const payload_end = offset + ip_total_len;

    var payload_len: usize = 0;
    var payload: []const u8 = &[_]u8{};

    if (payload_end > payload_start and payload_end <= data.len) {
        payload_len = payload_end - payload_start;
        payload = data[payload_start..payload_end];
    }

    return TcpInfo{
        .seq_num = seq_num,
        .ack_num = ack_num,
        .flags = flags,
        .payload = payload,
        .payload_len = payload_len,
    };
}

fn sendAssociationSetup() !void {
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = false,
        .message_type = @intFromEnum(pfcp.types.MessageType.association_setup_request),
        .message_length = 0,
        .seid = null,
        .sequence_number = global_state.nextSeq(),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.init(@intCast(@divTrunc(time.timestamp(), 1)));
    try pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(global_state.pfcp_socket, writer.getWritten(), 0, &global_state.upf_pfcp_addr.any, global_state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Association Setup Request\n", .{});

    var resp: [2048]u8 = undefined;
    const bytes = try posix.recv(global_state.pfcp_socket, &resp, 0);
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.association_setup_response)) {
        print("Received PFCP Association Setup Response - OK\n", .{});
    }
}

fn sendSessionEstablishment(session_idx: u32) !void {
    const session = &sessions[session_idx];
    var buffer: [4096]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = true,
        .message_type = @intFromEnum(pfcp.types.MessageType.session_establishment_request),
        .message_length = 0,
        .seid = 0,
        .sequence_number = global_state.nextSeq(),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    const cp_fseid = pfcp.ie.FSEID.initV4(session.cp_seid, [_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeFSEID(&writer, cp_fseid);

    // PDR uplink (N3 -> N6)
    const pdi_ul = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access))
        .withFTeid(pfcp.ie.FTEID.initV4(session.uplink_teid, [_]u8{ 127, 0, 0, 1 }))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_ul = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(1),
        pfcp.ie.Precedence.init(100),
        pdi_ul,
    ).withFarId(pfcp.ie.FARID.init(1));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_ul);

    // PDR downlink (N6 -> N3)
    const pdi_dl = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_dl = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(2),
        pfcp.ie.Precedence.init(100),
        pdi_dl,
    ).withFarId(pfcp.ie.FARID.init(2));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_dl);

    // FAR uplink - forward to N6
    const create_far_ul = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(1),
        pfcp.ie.DestinationInterface.init(.core),
    );
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_ul);

    // FAR downlink - forward to gNodeB with GTP-U encapsulation
    const fwd_params = pfcp.ie.ForwardingParameters.init(pfcp.ie.DestinationInterface.init(.access))
        .withOuterHeaderCreation(pfcp.ie.OuterHeaderCreation.initGtpuV4(session.downlink_teid, global_state.gnodeb_ip));
    const create_far_dl = pfcp.ie.CreateFAR.init(
        pfcp.ie.FARID.init(2),
        pfcp.ie.ApplyAction.forward(),
    ).withForwardingParameters(fwd_params);
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_dl);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(global_state.pfcp_socket, writer.getWritten(), 0, &global_state.upf_pfcp_addr.any, global_state.upf_pfcp_addr.getOsSockLen());

    var resp: [2048]u8 = undefined;
    const bytes = posix.recv(global_state.pfcp_socket, &resp, 0) catch |err| {
        return err;
    };

    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.session_establishment_response)) {
        var reader = pfcp.marshal.Reader.init(resp[0..bytes]);
        _ = pfcp.marshal.decodePfcpHeader(&reader) catch return error.ParseError;

        while (reader.remaining() > 0) {
            const ie_header = pfcp.marshal.decodeIEHeader(&reader) catch break;
            const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);
            if (ie_type == .f_seid) {
                const fseid = pfcp.marshal.decodeFSEID(&reader, ie_header.length) catch break;
                session.up_seid = fseid.seid;
                print("[Session {}] Created: UE={}.{}.{}.{}, TEID=0x{x}\n", .{
                    session_idx,
                    session.ue_ip[0], session.ue_ip[1], session.ue_ip[2], session.ue_ip[3],
                    session.uplink_teid,
                });
                return;
            } else {
                reader.pos += ie_header.length;
            }
        }
    }
    return error.SessionEstablishmentFailed;
}

fn sendSessionDeletion(session_idx: u32) !void {
    const session = &sessions[session_idx];
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = true,
        .message_type = @intFromEnum(pfcp.types.MessageType.session_deletion_request),
        .message_length = 0,
        .seid = session.up_seid,
        .sequence_number = global_state.nextSeq(),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(global_state.pfcp_socket, writer.getWritten(), 0, &global_state.upf_pfcp_addr.any, global_state.upf_pfcp_addr.getOsSockLen());

    var resp: [2048]u8 = undefined;
    const bytes = posix.recv(global_state.pfcp_socket, &resp, 0) catch return;
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.session_deletion_response)) {
        print("[Session {}] Deleted\n", .{session_idx});
    }
}

fn sendAssociationRelease() !void {
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = false,
        .message_type = @intFromEnum(pfcp.types.MessageType.association_release_request),
        .message_length = 0,
        .seid = null,
        .sequence_number = global_state.nextSeq(),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(global_state.pfcp_socket, writer.getWritten(), 0, &global_state.upf_pfcp_addr.any, global_state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Association Release Request\n", .{});

    var resp: [2048]u8 = undefined;
    const bytes = posix.recv(global_state.pfcp_socket, &resp, 0) catch return;
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.association_release_response)) {
        print("Received PFCP Association Release Response - OK\n", .{});
    }
}

fn buildGtpuPacket(buffer: *[2048]u8, teid: u32, payload: []const u8) usize {
    var pos: usize = 0;
    buffer[pos] = 0x30; // Version 1, PT=1, no extensions
    pos += 1;
    buffer[pos] = 0xFF; // G-PDU message type
    pos += 1;
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, buffer[pos..][0..2], length, .big);
    pos += 2;
    std.mem.writeInt(u32, buffer[pos..][0..4], teid, .big);
    pos += 4;
    @memcpy(buffer[pos..][0..payload.len], payload);
    pos += payload.len;
    return pos;
}

fn buildTcpPacket(
    buffer: *[1500]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    flags: u8,
    payload: []const u8,
) usize {
    const ip_header_len: usize = 20;
    const tcp_header_len: usize = 20;
    const total_len: u16 = @intCast(ip_header_len + tcp_header_len + payload.len);

    // Build IP header
    buffer[0] = 0x45; // Version 4, IHL 5
    buffer[1] = 0x00; // DSCP/ECN
    std.mem.writeInt(u16, buffer[2..4], total_len, .big);
    std.mem.writeInt(u16, buffer[4..6], 0x1234, .big); // ID
    std.mem.writeInt(u16, buffer[6..8], 0x4000, .big); // Flags (DF)
    buffer[8] = 64; // TTL
    buffer[9] = 6; // Protocol: TCP
    buffer[10] = 0; // Checksum (will be calculated)
    buffer[11] = 0;
    @memcpy(buffer[12..16], &src_ip);
    @memcpy(buffer[16..20], &dst_ip);

    // Build TCP header
    std.mem.writeInt(u16, buffer[20..22], src_port, .big);
    std.mem.writeInt(u16, buffer[22..24], dst_port, .big);
    std.mem.writeInt(u32, buffer[24..28], seq_num, .big);
    std.mem.writeInt(u32, buffer[28..32], ack_num, .big);
    buffer[32] = 0x50; // Data offset: 5 (20 bytes)
    buffer[33] = flags;
    std.mem.writeInt(u16, buffer[34..36], 65535, .big); // Window size
    std.mem.writeInt(u16, buffer[36..38], 0, .big); // Checksum (calculated below)
    std.mem.writeInt(u16, buffer[38..40], 0, .big); // Urgent pointer

    // Copy payload
    if (payload.len > 0) {
        @memcpy(buffer[40..][0..payload.len], payload);
    }

    // Calculate IP header checksum
    var ip_sum: u32 = 0;
    var i: usize = 0;
    while (i < ip_header_len) : (i += 2) {
        ip_sum += std.mem.readInt(u16, buffer[i..][0..2], .big);
    }
    while (ip_sum >> 16 != 0) {
        ip_sum = (ip_sum & 0xFFFF) + (ip_sum >> 16);
    }
    std.mem.writeInt(u16, buffer[10..12], @truncate(~ip_sum), .big);

    // Calculate TCP checksum (includes pseudo-header)
    var tcp_sum: u32 = 0;

    // Pseudo-header
    tcp_sum += @as(u32, src_ip[0]) << 8 | src_ip[1];
    tcp_sum += @as(u32, src_ip[2]) << 8 | src_ip[3];
    tcp_sum += @as(u32, dst_ip[0]) << 8 | dst_ip[1];
    tcp_sum += @as(u32, dst_ip[2]) << 8 | dst_ip[3];
    tcp_sum += 6; // Protocol TCP
    tcp_sum += @as(u32, @intCast(tcp_header_len + payload.len)); // TCP length

    // TCP header + payload
    const tcp_total_len = tcp_header_len + payload.len;
    i = 0;
    while (i + 1 < tcp_total_len) : (i += 2) {
        tcp_sum += std.mem.readInt(u16, buffer[20 + i ..][0..2], .big);
    }
    // Handle odd byte
    if (tcp_total_len % 2 != 0) {
        tcp_sum += @as(u32, buffer[20 + tcp_total_len - 1]) << 8;
    }

    while (tcp_sum >> 16 != 0) {
        tcp_sum = (tcp_sum & 0xFFFF) + (tcp_sum >> 16);
    }
    std.mem.writeInt(u16, buffer[36..38], @truncate(~tcp_sum), .big);

    return ip_header_len + tcp_header_len + payload.len;
}
