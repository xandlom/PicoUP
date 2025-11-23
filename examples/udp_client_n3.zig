// UDP Client for N3 testing (simulates gNodeB + UE traffic)
// Establishes PFCP sessions and sends GTP-U encapsulated UDP packets
// Supports multiple sessions created in parallel
//
// Usage:
//   zig build example-n3-client
//   ./zig-out/bin/udp_client_n3 <echo_server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions]
//
// Example:
//   # First start echo server: ./zig-out/bin/echo_server_n6 9999
//   # Then start UPF: ./zig-out/bin/picoupf
//   # Then run client with 10 sessions:
//   ./zig-out/bin/udp_client_n3 127.0.0.1 9999 127.0.0.1 127.0.0.2 10

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
const DEFAULT_ECHO_PORT: u16 = 9999;
const MAX_SESSIONS: usize = 100;

// Base values for session parameters (each session adds its index)
const BASE_UPLINK_TEID: u32 = 0x1000;
const BASE_DOWNLINK_TEID: u32 = 0x2000;
const BASE_CP_SEID: u64 = 0x1000;
const BASE_UE_IP: [4]u8 = .{ 10, 45, 0, 100 }; // 10.45.0.100 - 10.45.0.199

// Per-session state
const Session = struct {
    index: u32,
    cp_seid: u64,
    up_seid: u64,
    uplink_teid: u32,
    downlink_teid: u32,
    ue_ip: [4]u8,
    established: bool,

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
                BASE_UE_IP[3] +| @as(u8, @truncate(index)), // Saturating add
            },
            .established = false,
        };
    }
};

// Global state shared between threads
const GlobalState = struct {
    pfcp_socket: posix.socket_t,
    gtpu_socket: posix.socket_t,
    upf_pfcp_addr: net.Address,
    upf_gtpu_addr: net.Address,
    echo_server_ip: [4]u8,
    echo_server_port: u16,
    gnodeb_ip: [4]u8,
    sequence_number: Atomic(u32),
    sessions_created: Atomic(u32),
    sessions_failed: Atomic(u32),

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

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <echo_server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions]\n", .{args[0]});
        print("\nArguments:\n", .{});
        print("  echo_server_ip   - IP of the echo server (N6 side)\n", .{});
        print("  port             - Port of echo server (default: 9999)\n", .{});
        print("  upf_ip           - IP of the UPF (default: 127.0.0.1)\n", .{});
        print("  gnodeb_ip        - IP of THIS machine for downlink (default: 127.0.0.2)\n", .{});
        print("  num_sessions     - Number of sessions to create (default: 1, max: 100)\n", .{});
        print("\nExamples:\n", .{});
        print("  Single session:   {s} 127.0.0.1 9999\n", .{args[0]});
        print("  10 sessions:      {s} 127.0.0.1 9999 127.0.0.1 127.0.0.2 10\n", .{args[0]});
        print("  Distributed:      {s} 192.168.1.30 9999 192.168.1.20 192.168.1.10 50\n", .{args[0]});
        return;
    }

    // Parse echo server IP
    const echo_ip_str = args[1];
    const echo_ip = net.Address.parseIp4(echo_ip_str, 0) catch {
        print("Invalid echo server IP address: {s}\n", .{echo_ip_str});
        return;
    };
    const echo_server_ip: [4]u8 = @bitCast(echo_ip.in.sa.addr);

    // Parse echo server port
    const echo_server_port: u16 = if (args.len > 2)
        std.fmt.parseInt(u16, args[2], 10) catch DEFAULT_ECHO_PORT
    else
        DEFAULT_ECHO_PORT;

    // Parse UPF IP
    const upf_ip_str = if (args.len > 3) args[3] else "127.0.0.1";
    const upf_ip = net.Address.parseIp4(upf_ip_str, 0) catch {
        print("Invalid UPF IP address: {s}\n", .{upf_ip_str});
        return;
    };
    const upf_ip_bytes: [4]u8 = @bitCast(upf_ip.in.sa.addr);

    // Parse gNodeB IP
    const gnodeb_ip_str = if (args.len > 4) args[4] else "127.0.0.2";
    const gnodeb_ip = net.Address.parseIp4(gnodeb_ip_str, 0) catch {
        print("Invalid gNodeB IP address: {s}\n", .{gnodeb_ip_str});
        return;
    };
    const gnodeb_ip_bytes: [4]u8 = @bitCast(gnodeb_ip.in.sa.addr);

    // Parse number of sessions
    const num_sessions: u32 = if (args.len > 5)
        @min(std.fmt.parseInt(u32, args[5], 10) catch 1, MAX_SESSIONS)
    else
        1;

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║      UDP Client (N3 Side - Multi-Session gNodeB Sim)       ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Configuration:\n", .{});
    print("  UPF Address:     {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ upf_ip_str, PFCP_PORT, upf_ip_str, GTPU_PORT });
    print("  gNodeB Address:  {s}:{} (for downlink)\n", .{ gnodeb_ip_str, GTPU_PORT });
    print("  Echo Server:     {}.{}.{}.{}:{}\n", .{ echo_server_ip[0], echo_server_ip[1], echo_server_ip[2], echo_server_ip[3], echo_server_port });
    print("  Sessions:        {} (UE IPs: {}.{}.{}.{} - {}.{}.{}.{})\n", .{
        num_sessions,
        BASE_UE_IP[0], BASE_UE_IP[1], BASE_UE_IP[2], BASE_UE_IP[3],
        BASE_UE_IP[0], BASE_UE_IP[1], BASE_UE_IP[2], BASE_UE_IP[3] +| @as(u8, @truncate(num_sessions - 1)),
    });
    print("\n", .{});

    // Create sockets
    const pfcp_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(pfcp_socket);

    const gtpu_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(gtpu_socket);

    // Bind GTP-U socket
    const gnodeb_bind_addr = net.Address.initIp4(gnodeb_ip_bytes, GTPU_PORT);
    try posix.bind(gtpu_socket, &gnodeb_bind_addr.any, gnodeb_bind_addr.getOsSockLen());

    // Set receive timeout
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(gtpu_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    // Initialize global state
    global_state = GlobalState{
        .pfcp_socket = pfcp_socket,
        .gtpu_socket = gtpu_socket,
        .upf_pfcp_addr = net.Address.initIp4(upf_ip_bytes, PFCP_PORT),
        .upf_gtpu_addr = net.Address.initIp4(upf_ip_bytes, GTPU_PORT),
        .echo_server_ip = echo_server_ip,
        .echo_server_port = echo_server_port,
        .gnodeb_ip = gnodeb_ip_bytes,
        .sequence_number = Atomic(u32).init(1),
        .sessions_created = Atomic(u32).init(0),
        .sessions_failed = Atomic(u32).init(0),
    };

    // Initialize sessions
    for (0..num_sessions) |i| {
        sessions[i] = Session.init(@intCast(i));
    }

    // Step 1: PFCP Association Setup
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Step 1: PFCP Association Setup\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendAssociationSetup();
    time.sleep(200 * time.ns_per_ms);

    // Step 2: PFCP Session Establishment (parallel)
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 2: PFCP Session Establishment ({} sessions in parallel)\n", .{num_sessions});
    print("═══════════════════════════════════════════════════════════\n", .{});

    const start_time = time.milliTimestamp();

    // Spawn threads for parallel session creation
    var threads: [MAX_SESSIONS]?Thread = [_]?Thread{null} ** MAX_SESSIONS;
    for (0..num_sessions) |i| {
        threads[i] = Thread.spawn(.{}, sessionEstablishmentThread, .{@as(u32, @intCast(i))}) catch |err| {
            print("Failed to spawn thread for session {}: {}\n", .{ i, err });
            continue;
        };
    }

    // Wait for all threads to complete
    for (0..num_sessions) |i| {
        if (threads[i]) |t| {
            t.join();
        }
    }

    const elapsed = time.milliTimestamp() - start_time;
    const created = global_state.sessions_created.load(.seq_cst);
    const failed = global_state.sessions_failed.load(.seq_cst);
    print("\nSession creation completed in {}ms: {} created, {} failed\n", .{ elapsed, created, failed });

    // Step 3: Send UDP packets through GTP-U tunnels
    if (created > 0) {
        print("\n═══════════════════════════════════════════════════════════\n", .{});
        print("Step 3: Sending UDP Packets via GTP-U Tunnels\n", .{});
        print("═══════════════════════════════════════════════════════════\n", .{});
        try sendUdpPacketsAllSessions(num_sessions, 2); // 2 packets per session
    }

    // Step 4: Cleanup
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 4: Cleanup ({} sessions)\n", .{created});
    print("═══════════════════════════════════════════════════════════\n", .{});

    // Delete sessions in parallel
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

    // Create PDR for uplink (N3 -> N6)
    const pdi_ul = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access))
        .withFTeid(pfcp.ie.FTEID.initV4(session.uplink_teid, [_]u8{ 127, 0, 0, 1 }))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_ul = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(1),
        pfcp.ie.Precedence.init(100),
        pdi_ul,
    ).withFarId(pfcp.ie.FARID.init(1));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_ul);

    // Create PDR for downlink (N6 -> N3)
    const pdi_dl = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_dl = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(2),
        pfcp.ie.Precedence.init(100),
        pdi_dl,
    ).withFarId(pfcp.ie.FARID.init(2));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_dl);

    // Create FAR for uplink
    const create_far_ul = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(1),
        pfcp.ie.DestinationInterface.init(.core),
    );
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_ul);

    // Create FAR for downlink
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

    // Wait for response with timeout
    var resp: [2048]u8 = undefined;
    const bytes = posix.recv(global_state.pfcp_socket, &resp, 0) catch |err| {
        return err;
    };

    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.session_establishment_response)) {
        // Parse response to get UP SEID
        var reader = pfcp.marshal.Reader.init(resp[0..bytes]);
        _ = pfcp.marshal.decodePfcpHeader(&reader) catch return error.ParseError;

        while (reader.remaining() > 0) {
            const ie_header = pfcp.marshal.decodeIEHeader(&reader) catch break;
            const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);
            if (ie_type == .f_seid) {
                const fseid = pfcp.marshal.decodeFSEID(&reader, ie_header.length) catch break;
                session.up_seid = fseid.seid;
                print("[Session {}] Created: UE={}.{}.{}.{}, UL_TEID=0x{x}, DL_TEID=0x{x}, UP_SEID=0x{x}\n", .{
                    session_idx,
                    session.ue_ip[0], session.ue_ip[1], session.ue_ip[2], session.ue_ip[3],
                    session.uplink_teid,
                    session.downlink_teid,
                    session.up_seid,
                });
                return;
            } else {
                reader.pos += ie_header.length;
            }
        }
    }
    return error.SessionEstablishmentFailed;
}

fn sendUdpPacketsAllSessions(num_sessions: u32, packets_per_session: u32) !void {
    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;
    var recv_buf: [2048]u8 = undefined;

    var total_sent: u32 = 0;
    var total_received: u32 = 0;

    for (0..num_sessions) |session_idx| {
        const session = &sessions[session_idx];
        if (!session.established) continue;

        var pkt: u32 = 0;
        while (pkt < packets_per_session) : (pkt += 1) {
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "S{}P{}", .{ session_idx, pkt + 1 }) catch "Hello!";

            const ip_len = buildIpv4UdpPacket(
                &ip_buf,
                session.ue_ip,
                global_state.echo_server_ip,
                12345 + @as(u16, @truncate(session_idx)),
                global_state.echo_server_port,
                msg,
            );

            const gtpu_len = buildGtpuPacket(&gtpu_buf, session.uplink_teid, ip_buf[0..ip_len]);

            _ = posix.sendto(
                global_state.gtpu_socket,
                gtpu_buf[0..gtpu_len],
                0,
                &global_state.upf_gtpu_addr.any,
                global_state.upf_gtpu_addr.getOsSockLen(),
            ) catch continue;
            total_sent += 1;

            // Quick poll for response
            time.sleep(10 * time.ns_per_ms);

            var from_addr: posix.sockaddr = undefined;
            var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

            const recv_bytes = posix.recvfrom(
                global_state.gtpu_socket,
                &recv_buf,
                0,
                &from_addr,
                &from_len,
            ) catch continue;

            if (recv_bytes >= 8) {
                total_received += 1;
            }
        }
    }

    print("\nTraffic Results: Sent={}, Received={}, Lost={}\n", .{ total_sent, total_received, total_sent -| total_received });
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

    buffer[pos] = 0x30;
    pos += 1;
    buffer[pos] = 0xFF;
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

fn buildIpv4UdpPacket(
    buffer: *[1500]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
) usize {
    const ip_header_len: usize = 20;
    const udp_header_len: usize = 8;
    const total_len: u16 = @intCast(ip_header_len + udp_header_len + payload.len);
    const udp_len: u16 = @intCast(udp_header_len + payload.len);

    buffer[0] = 0x45;
    buffer[1] = 0x00;
    std.mem.writeInt(u16, buffer[2..4], total_len, .big);
    std.mem.writeInt(u16, buffer[4..6], 0x1234, .big);
    std.mem.writeInt(u16, buffer[6..8], 0x4000, .big);
    buffer[8] = 64;
    buffer[9] = 17;
    buffer[10] = 0;
    buffer[11] = 0;
    @memcpy(buffer[12..16], &src_ip);
    @memcpy(buffer[16..20], &dst_ip);

    var sum: u32 = 0;
    var i: usize = 0;
    while (i < ip_header_len) : (i += 2) {
        sum += std.mem.readInt(u16, buffer[i..][0..2], .big);
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    std.mem.writeInt(u16, buffer[10..12], @truncate(~sum), .big);

    std.mem.writeInt(u16, buffer[20..22], src_port, .big);
    std.mem.writeInt(u16, buffer[22..24], dst_port, .big);
    std.mem.writeInt(u16, buffer[24..26], udp_len, .big);
    std.mem.writeInt(u16, buffer[26..28], 0, .big);

    @memcpy(buffer[28..][0..payload.len], payload);

    return ip_header_len + udp_header_len + payload.len;
}
