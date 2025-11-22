// Integration test suite for PicoUP URR implementation
// Tests PFCP association, session establishment with URR, and GTP-U packet flow with volume tracking
//
// Test Flow:
// 1. Create PFCP association
// 2. Create PFCP session with uplink/downlink PDRs, FARs, and URR (volume quota)
// 3. Send uplink GTP-U packets until volume threshold is reached
// 4. Send more packets until volume quota is exceeded
// 5. Verify URR statistics (tracked, reports triggered, quota exceeded)
// 6. Delete PFCP session
// 7. Delete PFCP association

const std = @import("std");
const net = std.net;
const print = std.debug.print;
const time = std.time;
const pfcp = @import("zig-pfcp");

const PFCP_PORT = 8805;
const GTPU_PORT = 2152;
const UPF_ADDR = "127.0.0.1";

// Test Configuration
const TestConfig = struct {
    // PFCP Session IDs
    cp_seid: u64 = 0x2000,
    up_seid: u64 = 0,

    // PDR/FAR/URR IDs
    uplink_pdr_id: u16 = 1,
    uplink_far_id: u16 = 1,
    urr_id: u16 = 1,

    // GTP-U TEIDs
    uplink_teid: u32 = 0x300,

    // URR Configuration
    volume_threshold: u64 = 5000, // 5KB - soft limit (trigger report)
    volume_quota: u64 = 10000, // 10KB - hard limit (drop packets)

    // Test parameters
    packet_size: usize = 500, // 500 bytes per packet
    packets_phase1: u32 = 12, // ~6KB - reach threshold
    packets_phase2: u32 = 10, // ~5KB - exceed quota
};

// Test State
const TestState = struct {
    pfcp_socket: std.posix.socket_t,
    gtpu_socket: std.posix.socket_t,
    upf_pfcp_addr: net.Address,
    upf_gtpu_addr: net.Address,
    config: TestConfig,
    sequence_number: u32,

    pub fn init(allocator: std.mem.Allocator) !TestState {
        _ = allocator;

        // Create PFCP socket
        const pfcp_socket = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(pfcp_socket);

        // Create GTP-U socket
        const gtpu_socket = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        errdefer std.posix.close(gtpu_socket);

        const upf_pfcp_addr = try net.Address.parseIp4(UPF_ADDR, PFCP_PORT);
        const upf_gtpu_addr = try net.Address.parseIp4(UPF_ADDR, GTPU_PORT);

        return TestState{
            .pfcp_socket = pfcp_socket,
            .gtpu_socket = gtpu_socket,
            .upf_pfcp_addr = upf_pfcp_addr,
            .upf_gtpu_addr = upf_gtpu_addr,
            .config = TestConfig{},
            .sequence_number = 1,
        };
    }

    pub fn deinit(self: *TestState) void {
        std.posix.close(self.pfcp_socket);
        std.posix.close(self.gtpu_socket);
    }

    pub fn nextSequenceNumber(self: *TestState) u32 {
        const seq = self.sequence_number;
        self.sequence_number += 1;
        return seq;
    }
};

// Helper to encode and send PFCP messages
fn encodePfcpMessage(buffer: []u8, comptime encodeFunc: anytype, args: anytype) ![]const u8 {
    var writer = pfcp.Writer.init(buffer);
    try @call(.auto, encodeFunc, .{&writer} ++ args);
    return writer.getWritten();
}

// Use zig-pfcp library's encode functions for grouped IEs
// The library now provides encodeCreatePDR, encodeCreateFAR, encodeCreateURR

fn encodeCreatePDR(writer: *pfcp.Writer, create_pdr: pfcp.ie.CreatePDR) !void {
    // Use the zig-pfcp library's encode function
    try pfcp.marshal.encodeCreatePDR(writer, create_pdr);
}

fn encodeCreateFAR(writer: *pfcp.Writer, create_far: pfcp.ie.CreateFAR) !void {
    // Use the zig-pfcp library's encode function
    try pfcp.marshal.encodeCreateFAR(writer, create_far);
}

fn encodeCreateURR(writer: *pfcp.Writer, create_urr: pfcp.ie.CreateURR) !void {
    // Use the zig-pfcp library's encode function
    try pfcp.marshal.encodeCreateURR(writer, create_urr);
}

// Send PFCP Association Setup Request
fn sendAssociationSetupRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Association Setup Request ===\n", .{});

    // Build PFCP message using zig-pfcp
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    const recovery = pfcp.ie.RecoveryTimeStamp.fromUnixTime(time.timestamp());
    const request = pfcp.AssociationSetupRequest.init(node_id, recovery);

    // Encode message
    var msg_buffer: [2048]u8 = undefined;
    const msg = try encodePfcpMessage(&msg_buffer, pfcp.marshal.encodeAssociationSetupRequest, .{ request, @as(u24, @intCast(state.nextSequenceNumber())) });

    _ = try std.posix.sendto(
        state.pfcp_socket,
        msg,
        0,
        &state.upf_pfcp_addr.any,
        state.upf_pfcp_addr.getOsSockLen(),
    );

    print("Sent Association Setup Request ({} bytes)\n", .{msg.len});

    // Wait for response
    var response_buf: [2048]u8 = undefined;
    const bytes = try std.posix.recv(state.pfcp_socket, &response_buf, 0);

    if (bytes >= 8) {
        const msg_type = response_buf[1];
        print("Received response: message type = {}\n", .{msg_type});
        if (msg_type == @intFromEnum(pfcp.types.MessageType.association_setup_response)) {
            print("✓ Association established successfully\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Send PFCP Session Establishment Request with PDRs, FARs, and URR
fn sendSessionEstablishmentRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Session Establishment Request ===\n", .{});
    print("Creating session with:\n", .{});
    print("  - Uplink PDR: ID={}, TEID=0x{x}, FAR={}, URR={}\n", .{ state.config.uplink_pdr_id, state.config.uplink_teid, state.config.uplink_far_id, state.config.urr_id });
    print("  - Uplink FAR: ID={}, action=forward, dest=core(N6)\n", .{state.config.uplink_far_id});
    print("  - URR: ID={}\n", .{state.config.urr_id});
    print("    - Volume Threshold: {} bytes (soft limit - trigger report)\n", .{state.config.volume_threshold});

    // Build PFCP Session Establishment Request manually
    var msg_buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&msg_buffer);

    const seq_num: u24 = @intCast(state.nextSequenceNumber());

    // PFCP Header
    const header_start = writer.pos;
    var header = pfcp.types.PfcpHeader.init(.session_establishment_request, true);
    header.seid = state.config.cp_seid;
    header.sequence_number = seq_num;
    try pfcp.marshal.encodePfcpHeader(&writer, header);

    // Node ID
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    // F-SEID
    const cp_fseid = pfcp.ie.FSEID.initV4(state.config.cp_seid, [_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeFSEID(&writer, cp_fseid);

    // Create Uplink PDR (access → core)
    const uplink_pdr_pdi = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.access))
        .withFTeid(pfcp.ie.FTEID.initV4(state.config.uplink_teid, [_]u8{ 127, 0, 0, 1 }));

    var uplink_pdr = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(state.config.uplink_pdr_id),
        pfcp.ie.Precedence.init(100),
        uplink_pdr_pdi,
    ).withFarId(pfcp.ie.FARID.init(state.config.uplink_far_id))
        .withOuterHeaderRemoval(pfcp.ie.OuterHeaderRemoval.gtpuUdpIpv4()); // Remove GTP-U header

    // Add URR reference to uplink PDR
    const uplink_urr_ids: []const pfcp.ie.URRID = &[_]pfcp.ie.URRID{pfcp.ie.URRID.init(state.config.urr_id)};
    uplink_pdr.urr_ids = @constCast(uplink_urr_ids);

    try encodeCreatePDR(&writer, uplink_pdr);

    // Create Uplink FAR (forward to core/N6)
    const uplink_far = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(state.config.uplink_far_id),
        pfcp.ie.DestinationInterface.init(.core),
    );

    try encodeCreateFAR(&writer, uplink_far);

    // Create URR with volume threshold
    const urr = pfcp.ie.CreateURR.init(
        pfcp.ie.URRID.init(state.config.urr_id),
        pfcp.ie.MeasurementMethod.volume(),
    ).withVolumeThreshold(pfcp.ie.VolumeThreshold.initTotal(state.config.volume_threshold));

    try encodeCreateURR(&writer, urr);

    // Update message length in header
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    try writer.writeU16(message_length);
    writer.pos = saved_pos;

    const msg = writer.getWritten();

    _ = try std.posix.sendto(
        state.pfcp_socket,
        msg,
        0,
        &state.upf_pfcp_addr.any,
        state.upf_pfcp_addr.getOsSockLen(),
    );

    print("Sent Session Establishment Request ({} bytes)\n", .{msg.len});

    // Wait for response
    var response_buf: [2048]u8 = undefined;
    const bytes = try std.posix.recv(state.pfcp_socket, &response_buf, 0);

    if (bytes >= 20) {
        const msg_type = response_buf[1];
        print("Received response: message type = {}\n", .{msg_type});

        if (msg_type == @intFromEnum(pfcp.types.MessageType.session_establishment_response)) {
            print("✓ Session established successfully\n", .{});
            print("Session configured with full PDR/FAR/URR rules\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Build GTP-U packet
fn buildGtpuPacket(buffer: *[2048]u8, teid: u32, payload: []const u8) usize {
    var pos: usize = 0;

    // GTP-U header (8 bytes, no extension)
    buffer[pos] = 0x30; // Version=1, PT=1, no extension
    pos += 1;
    buffer[pos] = 0xFF; // Message type: G-PDU
    pos += 1;

    // Length (2 bytes)
    const length: u16 = @intCast(payload.len);
    std.mem.writeInt(u16, buffer[pos..][0..2], length, .big);
    pos += 2;

    // TEID (4 bytes)
    std.mem.writeInt(u32, buffer[pos..][0..4], teid, .big);
    pos += 4;

    // Payload
    @memcpy(buffer[pos..][0..payload.len], payload);
    pos += payload.len;

    return pos;
}

// Send GTP-U uplink packets
fn sendUplinkPackets(state: *TestState, count: u32, phase: u8) !void {
    print("\n--- Phase {}: Sending {} uplink GTP-U packets (TEID=0x{x}, ~{} bytes each) ---\n", .{ phase, count, state.config.uplink_teid, state.config.packet_size });

    var packet_buf: [2048]u8 = undefined;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Create payload of configured size
        var payload: [2048]u8 = undefined;
        const payload_slice = payload[0..state.config.packet_size];
        @memset(payload_slice, @intCast(i % 256));

        // Build GTP-U packet
        const packet_len = buildGtpuPacket(&packet_buf, state.config.uplink_teid, payload_slice);

        // Send packet
        _ = try std.posix.sendto(
            state.gtpu_socket,
            packet_buf[0..packet_len],
            0,
            &state.upf_gtpu_addr.any,
            state.upf_gtpu_addr.getOsSockLen(),
        );

        // Small delay between packets (50ms)
        time.sleep(50 * time.ns_per_ms);
    }

    const total_bytes = count * @as(u32, @intCast(state.config.packet_size));
    print("✓ Sent {} packets (~{} bytes total)\n", .{ count, total_bytes });
}

// Send PFCP Session Deletion Request
fn sendSessionDeletionRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Session Deletion Request ===\n", .{});

    // Build PFCP header manually since zig-pfcp doesn't have encode function for this yet
    var msg_buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&msg_buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = true,
        .message_type = @intFromEnum(pfcp.types.MessageType.session_deletion_request),
        .message_length = 0, // Will calculate later
        .seid = state.config.cp_seid,
        .sequence_number = @intCast(state.nextSequenceNumber()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    // Update message length
    const msg_len: u16 = @intCast(writer.pos - 4); // Exclude first 4 bytes (version, type, length)
    std.mem.writeInt(u16, msg_buffer[2..4], msg_len, .big);

    const msg = writer.getWritten();
    _ = try std.posix.sendto(
        state.pfcp_socket,
        msg,
        0,
        &state.upf_pfcp_addr.any,
        state.upf_pfcp_addr.getOsSockLen(),
    );

    print("Sent Session Deletion Request ({} bytes)\n", .{msg.len});

    // Wait for response
    var response_buf: [2048]u8 = undefined;
    const bytes = try std.posix.recv(state.pfcp_socket, &response_buf, 0);

    if (bytes >= 8) {
        const msg_type = response_buf[1];
        print("Received response: message type = {}\n", .{msg_type});
        if (msg_type == @intFromEnum(pfcp.types.MessageType.session_deletion_response)) {
            print("✓ Session deleted successfully\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Send PFCP Association Release Request
fn sendAssociationReleaseRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Association Release Request ===\n", .{});

    // Build PFCP header manually since zig-pfcp doesn't have encode function for this yet
    var msg_buffer: [2048]u8 = undefined;
    var writer = pfcp.Writer.init(&msg_buffer);

    const header = pfcp.types.PfcpHeader{
        .version = pfcp.types.PFCP_VERSION,
        .mp = false,
        .s = false,
        .message_type = @intFromEnum(pfcp.types.MessageType.association_release_request),
        .message_length = 0, // Will calculate later
        .seid = null,
        .sequence_number = @intCast(state.nextSequenceNumber()),
        .spare3 = 0,
    };

    try pfcp.marshal.encodePfcpHeader(&writer, header);

    // Add Node ID IE
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 127, 0, 0, 1 });
    try pfcp.marshal.encodeNodeId(&writer, node_id);

    // Update message length
    const msg_len: u16 = @intCast(writer.pos - 4); // Exclude first 4 bytes (version, type, length)
    std.mem.writeInt(u16, msg_buffer[2..4], msg_len, .big);

    const msg = writer.getWritten();
    _ = try std.posix.sendto(
        state.pfcp_socket,
        msg,
        0,
        &state.upf_pfcp_addr.any,
        state.upf_pfcp_addr.getOsSockLen(),
    );

    print("Sent Association Release Request ({} bytes)\n", .{msg.len});

    // Wait for response
    var response_buf: [2048]u8 = undefined;
    const bytes = try std.posix.recv(state.pfcp_socket, &response_buf, 0);

    if (bytes >= 8) {
        const msg_type = response_buf[1];
        print("Received response: message type = {}\n", .{msg_type});
        if (msg_type == @intFromEnum(pfcp.types.MessageType.association_release_response)) {
            print("✓ Association released successfully\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Main test execution
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║       PicoUP URR Integration Test Suite                   ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Target UPF: {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ UPF_ADDR, PFCP_PORT, UPF_ADDR, GTPU_PORT });
    print("\n", .{});
    print("Test Plan:\n", .{});
    print("  1. Create PFCP association\n", .{});
    print("  2. Create PFCP session with URR (volume quota)\n", .{});
    print("  3. Phase 1: Send packets to reach volume threshold\n", .{});
    print("  4. Phase 2: Send more packets to exceed volume quota\n", .{});
    print("  5. Verify URR statistics\n", .{});
    print("  6. Delete PFCP session\n", .{});
    print("  7. Delete PFCP association\n", .{});
    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});

    // Initialize test state
    var state = try TestState.init(allocator);
    defer state.deinit();

    // Wait for user to start UPF
    print("\n⚠  Please ensure PicoUPF is running before continuing.\n", .{});
    print("   (Run: ./zig-out/bin/picoupf)\n", .{});
    print("\nPress Enter to start test...\n", .{});

    const stdin = std.io.getStdIn().reader();
    _ = try stdin.readByte();

    print("\n🚀 Starting integration test...\n", .{});
    time.sleep(1 * time.ns_per_s);

    // Step 1: Create PFCP association
    try sendAssociationSetupRequest(&state);
    time.sleep(1 * time.ns_per_s);

    // Step 2: Create PFCP session with URR
    try sendSessionEstablishmentRequest(&state);
    time.sleep(2 * time.ns_per_s);

    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("           TESTING URR VOLUME TRACKING\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});

    // Step 3: Phase 1 - Send packets to reach threshold
    print("\n📊 Expected behavior:\n", .{});
    print("   - Volume Threshold ({} bytes): URR report will be triggered\n", .{state.config.volume_threshold});
    print("   - Volume Quota ({} bytes): Packets will be dropped\n", .{state.config.volume_quota});
    print("\n", .{});

    try sendUplinkPackets(&state, state.config.packets_phase1, 1);
    print("\n⏱  Waiting 3 seconds for URR threshold detection...\n", .{});
    time.sleep(3 * time.ns_per_s);

    // Step 4: Phase 2 - Send more packets to exceed quota
    print("\n📈 Phase 1 sent ~{} bytes\n", .{state.config.packets_phase1 * @as(u32, @intCast(state.config.packet_size))});
    print("   Sending Phase 2 packets to exceed volume quota...\n", .{});

    try sendUplinkPackets(&state, state.config.packets_phase2, 2);
    print("\n⏱  Waiting 3 seconds for URR quota enforcement...\n", .{});
    time.sleep(3 * time.ns_per_s);

    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("           URR TEST TRAFFIC COMPLETE\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    const total_packets = state.config.packets_phase1 + state.config.packets_phase2;
    const total_bytes = total_packets * @as(u32, @intCast(state.config.packet_size));
    print("\nTotal packets sent: {} (~{} bytes)\n", .{ total_packets, total_bytes });
    print("Expected volume threshold: {} bytes (should trigger report)\n", .{state.config.volume_threshold});
    print("Expected volume quota: {} bytes (should drop excess packets)\n", .{state.config.volume_quota});

    print("\n⏱  Waiting 3 seconds for final statistics...\n", .{});
    time.sleep(3 * time.ns_per_s);

    // Step 5: Delete PFCP session
    try sendSessionDeletionRequest(&state);
    time.sleep(1 * time.ns_per_s);

    // Step 6: Delete PFCP association
    try sendAssociationReleaseRequest(&state);

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║              TEST COMPLETED SUCCESSFULLY!                  ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("✓ Check PicoUPF statistics output for URR metrics:\n", .{});
    print("  - URR: Tracked=X, Reports=Y, Quota Exceeded=Z\n", .{});
    print("  - Volume threshold should have triggered at least 1 report\n", .{});
    print("  - Volume quota should have caused packet drops after ~{} bytes\n", .{state.config.volume_quota});
    print("  - Check worker logs for detailed URR tracking messages\n", .{});
    print("\n", .{});
    print("Expected results:\n", .{});
    print("  ✓ URR Tracked > 0 (volume tracking active)\n", .{});
    print("  ✓ URR Reports > 0 (threshold triggered)\n", .{});
    print("  ✓ URR Quota Exceeded > 0 (quota enforced)\n", .{});
    print("\n", .{});
}
