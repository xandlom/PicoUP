// UDP Client for N3 testing (simulates gNodeB + UE traffic)
// Establishes PFCP session and sends GTP-U encapsulated UDP packets
//
// Usage:
//   zig build example-n3-client
//   ./zig-out/bin/udp_client_n3 <echo_server_ip> [echo_server_port]
//
// Example:
//   # First start echo server: ./zig-out/bin/echo_server_n6 9999
//   # Then start UPF: ./zig-out/bin/picoupf
//   # Then run client:
//   ./zig-out/bin/udp_client_n3 192.168.1.100 9999

const std = @import("std");
const net = std.net;
const posix = std.posix;
const print = std.debug.print;
const time = std.time;
const pfcp = @import("zig-pfcp");

// Configuration - these can be overridden via command line arguments
// For distributed deployment:
//   - UPF_IP should be the IP of the machine running picoupf
//   - GNODEB_IP should be the IP of THIS machine (where client runs), reachable from UPF
// For local testing (all on same machine):
//   - Use 127.0.0.1 for UPF and 127.0.0.2 for gNodeB
var upf_ip_str: []const u8 = "127.0.0.1";
var gnodeb_ip_str: []const u8 = "127.0.0.2";
const PFCP_PORT: u16 = 8805;
const GTPU_PORT: u16 = 2152;
const DEFAULT_ECHO_PORT: u16 = 9999;

// Session parameters
const UPLINK_TEID: u32 = 0x1000; // TEID for uplink (to UPF)
const DOWNLINK_TEID: u32 = 0x2000; // TEID for downlink (from UPF)
const UE_IP = [4]u8{ 10, 45, 0, 100 }; // UE IP address
const CP_SEID: u64 = 0x1000;

const State = struct {
    pfcp_socket: posix.socket_t,
    gtpu_socket: posix.socket_t,
    upf_pfcp_addr: net.Address,
    upf_gtpu_addr: net.Address,
    echo_server_ip: [4]u8,
    echo_server_port: u16,
    sequence_number: u32,
    up_seid: u64,
    gnodeb_ip: [4]u8, // gNodeB IP for downlink (where UPF sends GTP-U responses)

    fn nextSeq(self: *State) u32 {
        const seq = self.sequence_number;
        self.sequence_number += 1;
        return seq;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {s} <echo_server_ip> [echo_server_port] [upf_ip] [gnodeb_ip]\n", .{args[0]});
        print("\nArguments:\n", .{});
        print("  echo_server_ip   - IP of the echo server (N6 side)\n", .{});
        print("  echo_server_port - Port of echo server (default: 9999)\n", .{});
        print("  upf_ip           - IP of the UPF (default: 127.0.0.1)\n", .{});
        print("  gnodeb_ip        - IP of THIS machine for downlink (default: 127.0.0.2)\n", .{});
        print("\nExamples:\n", .{});
        print("  Local test:       {s} 127.0.0.1 9999\n", .{args[0]});
        print("  Distributed:      {s} 192.168.1.30 9999 192.168.1.20 192.168.1.10\n", .{args[0]});
        print("                    (echo on .30, UPF on .20, client on .10)\n", .{});
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

    // Parse UPF IP (optional, default 127.0.0.1)
    if (args.len > 3) {
        upf_ip_str = args[3];
    }
    const upf_ip = net.Address.parseIp4(upf_ip_str, 0) catch {
        print("Invalid UPF IP address: {s}\n", .{upf_ip_str});
        return;
    };
    const upf_ip_bytes: [4]u8 = @bitCast(upf_ip.in.sa.addr);

    // Parse gNodeB IP (optional, default 127.0.0.2)
    // IMPORTANT: For distributed deployment, this must be the IP of this client machine
    // that is reachable from the UPF, so the UPF can send downlink GTP-U packets back
    if (args.len > 4) {
        gnodeb_ip_str = args[4];
    }
    const gnodeb_ip = net.Address.parseIp4(gnodeb_ip_str, 0) catch {
        print("Invalid gNodeB IP address: {s}\n", .{gnodeb_ip_str});
        return;
    };
    const gnodeb_ip_bytes: [4]u8 = @bitCast(gnodeb_ip.in.sa.addr);

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║          UDP Client (N3 Side - gNodeB Simulator)           ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Configuration:\n", .{});
    print("  UPF Address:     {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ upf_ip_str, PFCP_PORT, upf_ip_str, GTPU_PORT });
    print("  gNodeB Address:  {s}:{} (for downlink)\n", .{ gnodeb_ip_str, GTPU_PORT });
    print("  Echo Server:     {}.{}.{}.{}:{}\n", .{ echo_server_ip[0], echo_server_ip[1], echo_server_ip[2], echo_server_ip[3], echo_server_port });
    print("  UE IP:           {}.{}.{}.{}\n", .{ UE_IP[0], UE_IP[1], UE_IP[2], UE_IP[3] });
    print("  Uplink TEID:     0x{x}\n", .{UPLINK_TEID});
    print("  Downlink TEID:   0x{x}\n", .{DOWNLINK_TEID});
    print("\n", .{});

    // Create sockets
    const pfcp_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(pfcp_socket);

    const gtpu_socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    defer posix.close(gtpu_socket);

    // Bind GTP-U socket to gNodeB address to receive downlink responses
    // For local testing with 127.0.0.2, this avoids conflict with UPF's GTP-U port on 127.0.0.1:2152
    // For distributed deployment, this binds to the actual interface IP
    const gnodeb_bind_addr = net.Address.initIp4(gnodeb_ip_bytes, GTPU_PORT);
    try posix.bind(gtpu_socket, &gnodeb_bind_addr.any, gnodeb_bind_addr.getOsSockLen());

    // Set receive timeout on GTP-U socket
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    try posix.setsockopt(gtpu_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

    var state = State{
        .pfcp_socket = pfcp_socket,
        .gtpu_socket = gtpu_socket,
        .upf_pfcp_addr = net.Address.initIp4(upf_ip_bytes, PFCP_PORT),
        .upf_gtpu_addr = net.Address.initIp4(upf_ip_bytes, GTPU_PORT),
        .echo_server_ip = echo_server_ip,
        .echo_server_port = echo_server_port,
        .sequence_number = 1,
        .up_seid = 0,
        .gnodeb_ip = gnodeb_ip_bytes,
    };

    // Step 1: PFCP Association Setup
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Step 1: PFCP Association Setup\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendAssociationSetup(&state);
    time.sleep(500 * time.ns_per_ms);

    // Step 2: PFCP Session Establishment
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 2: PFCP Session Establishment\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendSessionEstablishment(&state);
    time.sleep(500 * time.ns_per_ms);

    // Step 3: Send UDP packets through GTP-U tunnel
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 3: Sending UDP Packets via GTP-U Tunnel\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendUdpPackets(&state, 5);

    // Step 4: Cleanup
    print("\n═══════════════════════════════════════════════════════════\n", .{});
    print("Step 4: Cleanup\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    try sendSessionDeletion(&state);
    time.sleep(200 * time.ns_per_ms);
    try sendAssociationRelease(&state);

    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("Test completed!\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
}

fn sendAssociationSetup(state: *State) !void {
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = false,
        .message_type = @intFromEnum(pfcp.types.MessageType.association_setup_request),
        .message_length = 0,
        .seid = null,
        .sequence_number = @intCast(state.nextSeq()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    // Node ID
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    // Recovery Time Stamp
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.init(@intCast(@divTrunc(time.timestamp(), 1)));
    try pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts);

    // Update length
    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(state.pfcp_socket, writer.getWritten(), 0, &state.upf_pfcp_addr.any, state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Association Setup Request\n", .{});

    // Wait for response
    var resp: [2048]u8 = undefined;
    const bytes = try posix.recv(state.pfcp_socket, &resp, 0);
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.association_setup_response)) {
        print("Received PFCP Association Setup Response - OK\n", .{});
    }
}

fn sendSessionEstablishment(state: *State) !void {
    var buffer: [4096]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = true,
        .message_type = @intFromEnum(pfcp.types.MessageType.session_establishment_request),
        .message_length = 0,
        .seid = 0, // UPF SEID (0 for new session)
        .sequence_number = @intCast(state.nextSeq()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    // Node ID
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    // CP F-SEID
    const cp_fseid = pfcp.ie.FSEID.initV4(CP_SEID, [_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeFSEID(&writer, cp_fseid);

    // Create PDR for uplink (N3 -> N6)
    const pdi_ul = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access)) // Access (N3)
        .withFTeid(pfcp.ie.FTEID.initV4(UPLINK_TEID, [_]u8{ 127, 0, 0, 1 }))
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(UE_IP, false));
    const create_pdr_ul = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(1),
        pfcp.ie.Precedence.init(100),
        pdi_ul,
    ).withFarId(pfcp.ie.FARID.init(1));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_ul);

    // Create PDR for downlink (N6 -> N3)
    const pdi_dl = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core)) // Core (N6)
        .withUeIp(pfcp.ie.UEIPAddress.initIpv4(UE_IP, false));
    const create_pdr_dl = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(2),
        pfcp.ie.Precedence.init(100),
        pdi_dl,
    ).withFarId(pfcp.ie.FARID.init(2));
    try pfcp.marshal.encodeCreatePDR(&writer, create_pdr_dl);

    // Create FAR for uplink (forward to N6)
    const create_far_ul = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(1),
        pfcp.ie.DestinationInterface.init(.core), // Core (N6)
    );
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_ul);

    // Create FAR for downlink (forward to N3 with GTP-U encapsulation)
    // gNodeB IP is where the UPF will send downlink GTP-U packets
    // For distributed deployment, this MUST be the actual IP of the client machine
    const fwd_params = pfcp.ie.ForwardingParameters.init(pfcp.ie.DestinationInterface.init(.access)) // Access (N3)
        .withOuterHeaderCreation(pfcp.ie.OuterHeaderCreation.initGtpuV4(DOWNLINK_TEID, state.gnodeb_ip));
    const create_far_dl = pfcp.ie.CreateFAR.init(
        pfcp.ie.FARID.init(2),
        pfcp.ie.ApplyAction.forward(),
    ).withForwardingParameters(fwd_params);
    try pfcp.marshal.encodeCreateFAR(&writer, create_far_dl);

    // Update length
    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(state.pfcp_socket, writer.getWritten(), 0, &state.upf_pfcp_addr.any, state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Session Establishment Request\n", .{});
    print("  - PDR 1: Uplink (N3->N6), TEID=0x{x}\n", .{UPLINK_TEID});
    print("  - PDR 2: Downlink (N6->N3), UE IP={}.{}.{}.{}\n", .{ UE_IP[0], UE_IP[1], UE_IP[2], UE_IP[3] });
    print("  - FAR 1: Forward to N6\n", .{});
    print("  - FAR 2: Forward to N3 with GTP-U encap (TEID=0x{x}, gNodeB={}.{}.{}.{})\n", .{ DOWNLINK_TEID, state.gnodeb_ip[0], state.gnodeb_ip[1], state.gnodeb_ip[2], state.gnodeb_ip[3] });

    // Wait for response
    var resp: [2048]u8 = undefined;
    const bytes = try posix.recv(state.pfcp_socket, &resp, 0);
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.session_establishment_response)) {
        print("Received PFCP Session Establishment Response - OK\n", .{});
        // Parse response using zig-pfcp library
        var reader = pfcp.marshal.Reader.init(resp[0..bytes]);
        _ = pfcp.marshal.decodePfcpHeader(&reader) catch {
            print("  Failed to parse response header\n", .{});
            return;
        };
        // Parse IEs to find UP F-SEID
        while (reader.remaining() > 0) {
            const ie_header = pfcp.marshal.decodeIEHeader(&reader) catch break;
            const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);
            if (ie_type == .f_seid) {
                const fseid = pfcp.marshal.decodeFSEID(&reader, ie_header.length) catch break;
                state.up_seid = fseid.seid;
                print("  UP SEID: 0x{x}\n", .{state.up_seid});
                break;
            } else {
                reader.pos += ie_header.length;
            }
        }
    }
}

fn sendUdpPackets(state: *State, count: u32) !void {
    var gtpu_buf: [2048]u8 = undefined;
    var ip_buf: [1500]u8 = undefined;
    var recv_buf: [2048]u8 = undefined;

    var sent: u32 = 0;
    var received: u32 = 0;

    print("\nSending {} packets to {}.{}.{}.{}:{}\n", .{
        count,
        state.echo_server_ip[0],
        state.echo_server_ip[1],
        state.echo_server_ip[2],
        state.echo_server_ip[3],
        state.echo_server_port,
    });
    print("\n", .{});

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Create test message
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Hello from UE! Packet #{}", .{i + 1}) catch "Hello!";

        // Build IPv4/UDP packet
        const ip_len = buildIpv4UdpPacket(
            &ip_buf,
            UE_IP, // Source: UE
            state.echo_server_ip, // Dest: Echo server
            12345 + @as(u16, @intCast(i)), // Source port
            state.echo_server_port, // Dest port
            msg,
        );

        // Build GTP-U packet
        const gtpu_len = buildGtpuPacket(&gtpu_buf, UPLINK_TEID, ip_buf[0..ip_len]);

        // Send to UPF
        _ = try posix.sendto(
            state.gtpu_socket,
            gtpu_buf[0..gtpu_len],
            0,
            &state.upf_gtpu_addr.any,
            state.upf_gtpu_addr.getOsSockLen(),
        );
        sent += 1;
        print("[TX {}] Sent: \"{s}\" ({} bytes)\n", .{ i + 1, msg, ip_len });

        // Try to receive response (with timeout)
        time.sleep(100 * time.ns_per_ms);

        var from_addr: posix.sockaddr = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const recv_bytes = posix.recvfrom(
            state.gtpu_socket,
            &recv_buf,
            0,
            &from_addr,
            &from_len,
        ) catch |err| {
            if (err == error.WouldBlock) {
                print("[RX {}] Timeout waiting for response\n", .{i + 1});
                continue;
            }
            return err;
        };

        if (recv_bytes >= 8) {
            // Parse GTP-U header
            const gtpu_teid = std.mem.readInt(u32, recv_buf[4..8], .big);
            const gtpu_payload_len = std.mem.readInt(u16, recv_buf[2..4], .big);

            if (gtpu_payload_len > 0 and recv_bytes >= 8 + 28) {
                // Extract UDP payload from IP packet
                const ip_start: usize = 8;
                const udp_start = ip_start + 20;
                const payload_start = udp_start + 8;
                const payload_end = @min(recv_bytes, ip_start + gtpu_payload_len);

                if (payload_end > payload_start) {
                    const payload = recv_buf[payload_start..payload_end];
                    print("[RX {}] Received echo (TEID=0x{x}): \"{s}\"\n", .{ i + 1, gtpu_teid, payload });
                    received += 1;
                }
            }
        }
    }

    print("\n", .{});
    print("Results: Sent={}, Received={}, Lost={}\n", .{ sent, received, sent - received });
}

fn sendSessionDeletion(state: *State) !void {
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = true,
        .message_type = @intFromEnum(pfcp.types.MessageType.session_deletion_request),
        .message_length = 0,
        .seid = state.up_seid,
        .sequence_number = @intCast(state.nextSeq()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(state.pfcp_socket, writer.getWritten(), 0, &state.upf_pfcp_addr.any, state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Session Deletion Request\n", .{});

    var resp: [2048]u8 = undefined;
    const bytes = try posix.recv(state.pfcp_socket, &resp, 0);
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.session_deletion_response)) {
        print("Received PFCP Session Deletion Response - OK\n", .{});
    }
}

fn sendAssociationRelease(state: *State) !void {
    var buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = false,
        .message_type = @intFromEnum(pfcp.types.MessageType.association_release_request),
        .message_length = 0,
        .seid = null,
        .sequence_number = @intCast(state.nextSeq()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    const msg_len: u16 = @intCast(writer.pos - 4);
    std.mem.writeInt(u16, buffer[2..4], msg_len, .big);

    _ = try posix.sendto(state.pfcp_socket, writer.getWritten(), 0, &state.upf_pfcp_addr.any, state.upf_pfcp_addr.getOsSockLen());
    print("Sent PFCP Association Release Request\n", .{});

    var resp: [2048]u8 = undefined;
    const bytes = try posix.recv(state.pfcp_socket, &resp, 0);
    if (bytes >= 8 and resp[1] == @intFromEnum(pfcp.types.MessageType.association_release_response)) {
        print("Received PFCP Association Release Response - OK\n", .{});
    }
}

// Build GTP-U packet
fn buildGtpuPacket(buffer: *[2048]u8, teid: u32, payload: []const u8) usize {
    var pos: usize = 0;

    buffer[pos] = 0x30; // Version=1, PT=1, no extension
    pos += 1;
    buffer[pos] = 0xFF; // Message type: G-PDU
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

// Build IPv4/UDP packet
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

    // IPv4 Header
    buffer[0] = 0x45; // Version=4, IHL=5
    buffer[1] = 0x00; // DSCP=0, ECN=0
    std.mem.writeInt(u16, buffer[2..4], total_len, .big);
    std.mem.writeInt(u16, buffer[4..6], 0x1234, .big); // ID
    std.mem.writeInt(u16, buffer[6..8], 0x4000, .big); // Flags
    buffer[8] = 64; // TTL
    buffer[9] = 17; // Protocol: UDP
    buffer[10] = 0;
    buffer[11] = 0;
    @memcpy(buffer[12..16], &src_ip);
    @memcpy(buffer[16..20], &dst_ip);

    // Calculate IP checksum
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < ip_header_len) : (i += 2) {
        sum += std.mem.readInt(u16, buffer[i..][0..2], .big);
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    std.mem.writeInt(u16, buffer[10..12], @truncate(~sum), .big);

    // UDP Header
    std.mem.writeInt(u16, buffer[20..22], src_port, .big);
    std.mem.writeInt(u16, buffer[22..24], dst_port, .big);
    std.mem.writeInt(u16, buffer[24..26], udp_len, .big);
    std.mem.writeInt(u16, buffer[26..28], 0, .big); // Checksum optional

    // Payload
    @memcpy(buffer[28..][0..payload.len], payload);

    return ip_header_len + udp_header_len + payload.len;
}
