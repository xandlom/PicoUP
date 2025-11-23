// UDP Client for N3 testing (simulates gNodeB + UE traffic)
// Establishes PFCP sessions and sends GTP-U encapsulated UDP packets
// Supports multiple sessions created in parallel with QoS flows
//
// Usage:
//   zig build example-n3-client
//   ./zig-out/bin/udp_client_n3 <echo_server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions] [--qos]
//
// Example:
//   # Basic test with 10 sessions:
//   ./zig-out/bin/udp_client_n3 127.0.0.1 9999 127.0.0.1 127.0.0.2 10
//
//   # QoS test with multiple flows per session:
//   ./zig-out/bin/udp_client_n3 127.0.0.1 9999 127.0.0.1 127.0.0.2 5 --qos

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

// Base values for session parameters
const BASE_UPLINK_TEID: u32 = 0x1000;
const BASE_DOWNLINK_TEID: u32 = 0x2000;
const BASE_CP_SEID: u64 = 0x1000;
const BASE_UE_IP: [4]u8 = .{ 10, 45, 0, 100 };

// QoS Flow definitions for --qos mode
const QosFlow = struct {
    name: []const u8,
    qer_id: u32,
    qfi: u8,
    ul_mbr: u64, // bits per second
    dl_mbr: u64,
    dest_port: u16, // Traffic sent to this port
    packets_to_send: u32,
};

// QoS flows for testing (video, voice, best-effort)
const QOS_FLOWS = [_]QosFlow{
    .{ .name = "Video", .qer_id = 1, .qfi = 5, .ul_mbr = 10_000_000, .dl_mbr = 10_000_000, .dest_port = 9001, .packets_to_send = 50 },
    .{ .name = "Voice", .qer_id = 2, .qfi = 1, .ul_mbr = 256_000, .dl_mbr = 256_000, .dest_port = 9002, .packets_to_send = 30 },
    .{ .name = "Best-Effort", .qer_id = 3, .qfi = 9, .ul_mbr = 1_000_000, .dl_mbr = 1_000_000, .dest_port = 9003, .packets_to_send = 100 },
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
        };
    }
};

// Global state
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
    qos_mode: bool,

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
        print("Usage: {s} <echo_server_ip> [port] [upf_ip] [gnodeb_ip] [num_sessions] [--qos]\n", .{args[0]});
        print("\nArguments:\n", .{});
        print("  echo_server_ip   - IP of the echo server (N6 side)\n", .{});
        print("  port             - Port of echo server (default: 9999)\n", .{});
        print("  upf_ip           - IP of the UPF (default: 127.0.0.1)\n", .{});
        print("  gnodeb_ip        - IP of THIS machine for downlink (default: 127.0.0.2)\n", .{});
        print("  num_sessions     - Number of sessions to create (default: 1, max: 100)\n", .{});
        print("  --qos            - Enable QoS test mode with multiple flows per session\n", .{});
        print("\nQoS Test Mode:\n", .{});
        print("  Creates 3 QERs per session with different rate limits:\n", .{});
        print("    - Video (QFI 5):       10 Mbps, port 9001\n", .{});
        print("    - Voice (QFI 1):       256 Kbps, port 9002\n", .{});
        print("    - Best-Effort (QFI 9): 1 Mbps, port 9003\n", .{});
        print("\nExamples:\n", .{});
        print("  Basic:     {s} 127.0.0.1 9999\n", .{args[0]});
        print("  QoS test:  {s} 127.0.0.1 9999 127.0.0.1 127.0.0.2 5 --qos\n", .{args[0]});
        return;
    }

    // Parse arguments
    const echo_ip_str = args[1];
    const echo_ip = net.Address.parseIp4(echo_ip_str, 0) catch {
        print("Invalid echo server IP address: {s}\n", .{echo_ip_str});
        return;
    };
    const echo_server_ip: [4]u8 = @bitCast(echo_ip.in.sa.addr);

    const echo_server_port: u16 = if (args.len > 2)
        std.fmt.parseInt(u16, args[2], 10) catch DEFAULT_ECHO_PORT
    else
        DEFAULT_ECHO_PORT;

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

    var num_sessions: u32 = 1;
    var qos_mode: bool = false;

    // Parse remaining args for num_sessions and --qos
    for (args[5..]) |arg| {
        if (std.mem.eql(u8, arg, "--qos")) {
            qos_mode = true;
        } else {
            num_sessions = @min(std.fmt.parseInt(u32, arg, 10) catch num_sessions, MAX_SESSIONS);
        }
    }

    // Also check arg[5] if it exists
    if (args.len > 5) {
        if (!std.mem.eql(u8, args[5], "--qos")) {
            num_sessions = @min(std.fmt.parseInt(u32, args[5], 10) catch 1, MAX_SESSIONS);
        } else {
            qos_mode = true;
        }
    }

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    if (qos_mode) {
        print("║     UDP Client (N3 Side - Multi-QoS Flow Testing)         ║\n", .{});
    } else {
        print("║     UDP Client (N3 Side - Multi-Session gNodeB Sim)       ║\n", .{});
    }
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Configuration:\n", .{});
    print("  UPF Address:     {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ upf_ip_str, PFCP_PORT, upf_ip_str, GTPU_PORT });
    print("  gNodeB Address:  {s}:{} (for downlink)\n", .{ gnodeb_ip_str, GTPU_PORT });
    print("  Echo Server:     {}.{}.{}.{}:{}\n", .{ echo_server_ip[0], echo_server_ip[1], echo_server_ip[2], echo_server_ip[3], echo_server_port });
    print("  Sessions:        {}\n", .{num_sessions});
    if (qos_mode) {
        print("  QoS Mode:        ENABLED (3 QERs per session)\n", .{});
        print("    Flow 1 - Video:       10 Mbps (QFI 5)\n", .{});
        print("    Flow 2 - Voice:       256 Kbps (QFI 1)\n", .{});
        print("    Flow 3 - Best-Effort: 1 Mbps (QFI 9)\n", .{});
    }
    print("\n", .{});

    // Create sockets
    const pfcp_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(pfcp_socket);

    const gtpu_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(gtpu_socket);

    const gnodeb_bind_addr = net.Address.initIp4(gnodeb_ip_bytes, GTPU_PORT);
    try posix.bind(gtpu_socket, &gnodeb_bind_addr.any, gnodeb_bind_addr.getOsSockLen());

    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(gtpu_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

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
        .qos_mode = qos_mode,
    };

    for (0..num_sessions) |i| {
        sessions[i] = Session.init(@intCast(i));
    }

    // Step 1: Association Setup
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Step 1: PFCP Association Setup\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendAssociationSetup();
    time.sleep(200 * time.ns_per_ms);

    // Step 2: Session Establishment
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    if (qos_mode) {
        print("Step 2: PFCP Session Establishment with QoS ({} sessions)\n", .{num_sessions});
    } else {
        print("Step 2: PFCP Session Establishment ({} sessions in parallel)\n", .{num_sessions});
    }
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

    // Step 3: Traffic
    if (created > 0) {
        print("\n═══════════════════════════════════════════════════════════\n", .{});
        if (qos_mode) {
            print("Step 3: QoS Flow Traffic Test\n", .{});
            print("═══════════════════════════════════════════════════════════\n", .{});
            try sendQosTraffic(num_sessions);
        } else {
            print("Step 3: Sending UDP Packets via GTP-U Tunnels\n", .{});
            print("═══════════════════════════════════════════════════════════\n", .{});
            try sendUdpPacketsAllSessions(num_sessions, 2);
        }
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
    if (global_state.qos_mode) {
        sendSessionEstablishmentWithQos(session_idx) catch |err| {
            print("[Session {}] Failed: {}\n", .{ session_idx, err });
            _ = global_state.sessions_failed.fetchAdd(1, .seq_cst);
            return;
        };
    } else {
        sendSessionEstablishment(session_idx) catch |err| {
            print("[Session {}] Failed: {}\n", .{ session_idx, err });
            _ = global_state.sessions_failed.fetchAdd(1, .seq_cst);
            return;
        };
    }
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

    // PDR uplink
    const pdi_ul = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access))
        .withFTeid(pfcp.ie.FTEID.initV4(session.uplink_teid, [_]u8{ 127, 0, 0, 1 }))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_ul = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(1),
        pfcp.ie.Precedence.init(100),
        pdi_ul,
    ).withFarId(pfcp.ie.FARID.init(1));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_ul);

    // PDR downlink
    const pdi_dl = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    const create_pdr_dl = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(2),
        pfcp.ie.Precedence.init(100),
        pdi_dl,
    ).withFarId(pfcp.ie.FARID.init(2));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_dl);

    // FAR uplink
    const create_far_ul = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(1),
        pfcp.ie.DestinationInterface.init(.core),
    );
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_ul);

    // FAR downlink
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

fn sendSessionEstablishmentWithQos(session_idx: u32) !void {
    const session = &sessions[session_idx];
    var buffer: [8192]u8 = undefined;
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

    // Create QERs for each flow
    for (QOS_FLOWS) |flow| {
        const qer = pfcp.ie.CreateQER.init(pfcp.ie.QERID.init(flow.qer_id))
            .withGateStatus(pfcp.ie.GateStatus.open())
            .withMbr(pfcp.ie.MBR.init(flow.ul_mbr, flow.dl_mbr));
        try pfcp.marshal.encodeCreateQER(&writer, qer);
    }

    // PDR for uplink (N3 -> N6) with QER
    const pdi_ul = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access))
        .withFTeid(pfcp.ie.FTEID.initV4(session.uplink_teid, [_]u8{ 127, 0, 0, 1 }))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    var create_pdr_ul = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(1),
        pfcp.ie.Precedence.init(100),
        pdi_ul,
    ).withFarId(pfcp.ie.FARID.init(1));
    // Associate with first QER (video flow)
    var qer_ids_ul = [_]pfcp.ie.QERID{pfcp.ie.QERID.init(1)};
    create_pdr_ul.qer_ids = &qer_ids_ul;
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_ul);

    // PDR for downlink (N6 -> N3) with QER
    const pdi_dl = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(session.ue_ip, false));
    var create_pdr_dl = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(2),
        pfcp.ie.Precedence.init(100),
        pdi_dl,
    ).withFarId(pfcp.ie.FARID.init(2));
    var qer_ids_dl = [_]pfcp.ie.QERID{pfcp.ie.QERID.init(1)};
    create_pdr_dl.qer_ids = &qer_ids_dl;
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_dl);

    // FAR uplink
    const create_far_ul = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(1),
        pfcp.ie.DestinationInterface.init(.core),
    );
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_ul);

    // FAR downlink
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
                print("[Session {}] Created with QoS: UE={}.{}.{}.{}, 3 QERs (Video/Voice/Best-Effort)\n", .{
                    session_idx,
                    session.ue_ip[0], session.ue_ip[1], session.ue_ip[2], session.ue_ip[3],
                });
                return;
            } else {
                reader.pos += ie_header.length;
            }
        }
    }
    return error.SessionEstablishmentFailed;
}

fn sendQosTraffic(num_sessions: u32) !void {
    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;
    var recv_buf: [2048]u8 = undefined;

    print("\nSending traffic through QoS flows...\n\n", .{});

    // Test each flow type
    for (QOS_FLOWS) |flow| {
        var total_sent: u32 = 0;
        var total_received: u32 = 0;

        const flow_start = time.milliTimestamp();

        // Send packets for this flow across all sessions
        for (0..num_sessions) |session_idx| {
            const session = &sessions[session_idx];
            if (!session.established) continue;

            var pkt: u32 = 0;
            while (pkt < flow.packets_to_send) : (pkt += 1) {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "{s}-S{}-P{}", .{ flow.name, session_idx, pkt + 1 }) catch "QoS";

                const ip_len = buildIpv4UdpPacket(
                    &ip_buf,
                    session.ue_ip,
                    global_state.echo_server_ip,
                    12345 + @as(u16, @truncate(session_idx)),
                    flow.dest_port,
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

                // Quick poll for responses (non-blocking check)
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

        const flow_elapsed = time.milliTimestamp() - flow_start;
        const dropped = total_sent -| total_received;
        const drop_rate = if (total_sent > 0) (dropped * 100) / total_sent else 0;

        print("  {s:12} (QFI {}, {} Kbps): Sent={:4}, Recv={:4}, Dropped={:4} ({:2}%) - {}ms\n", .{
            flow.name,
            flow.qfi,
            flow.ul_mbr / 1000,
            total_sent,
            total_received,
            dropped,
            drop_rate,
            flow_elapsed,
        });
    }

    print("\n", .{});
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
