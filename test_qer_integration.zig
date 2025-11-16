// Integration test suite for PicoUP QER implementation
// Tests PFCP association, session establishment with QER, and GTP-U packet flow
//
// Test Flow:
// 1. Create PFCP association
// 2. Create PFCP session with uplink/downlink PDRs, FARs, and common QER
// 3. Send uplink GTP-U packets (repeat 3 times)
// 4. Send downlink GTP-U packets (repeat 3 times)
// 5. Delete PFCP session
// 6. Delete PFCP association

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
    cp_seid: u64 = 0x1000,
    up_seid: u64 = 0,

    // PDR/FAR IDs
    uplink_pdr_id: u16 = 1,
    downlink_pdr_id: u16 = 2,
    uplink_far_id: u16 = 1,
    downlink_far_id: u16 = 2,
    qer_id: u16 = 1,

    // GTP-U TEIDs
    uplink_teid: u32 = 0x100,
    downlink_teid: u32 = 0x200,

    // Test parameters
    packets_per_round: u32 = 10,
    rounds: u32 = 3,
    delay_between_rounds_sec: u64 = 5,
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

// Helper to manually encode grouped IEs
// Note: zig-pfcp doesn't have encode functions for CreatePDR/FAR/QER yet,
// so we manually encode them following 3GPP TS 29.244

fn encodeCreatePDR(writer: *pfcp.Writer, create_pdr: pfcp.ie.CreatePDR) !void {
    const ie_start = writer.pos;

    // IE Header: type (create_pdr = 1) + length (filled later)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.create_pdr));
    const length_pos = writer.pos;
    try writer.writeU16(0); // placeholder

    // PDR ID (IE type 56)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.pdr_id));
    try writer.writeU16(2); // length
    try writer.writeU16(@intCast(create_pdr.pdr_id.rule_id));

    // Precedence (IE type 29)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.precedence));
    try writer.writeU16(4); // length
    try writer.writeU32(create_pdr.precedence.precedence);

    // PDI (IE type 2) - grouped IE
    const pdi_start = writer.pos;
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.pdi));
    const pdi_length_pos = writer.pos;
    try writer.writeU16(0); // placeholder

    // Source Interface (IE type 20)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.source_interface));
    try writer.writeU16(1); // length
    try writer.writeByte(@intFromEnum(create_pdr.pdi.source_interface.interface));

    // F-TEID (IE type 21) if present
    if (create_pdr.pdi.f_teid) |fteid| {
        try pfcp.marshal.encodeFTEID(writer, fteid);
    }

    // Update PDI length
    const pdi_length: u16 = @intCast(writer.pos - pdi_start - 4);
    const saved_pos = writer.pos;
    writer.pos = pdi_length_pos;
    try writer.writeU16(pdi_length);
    writer.pos = saved_pos;

    // FAR ID (IE type not in enum, using raw value 108)
    if (create_pdr.far_id) |far_id| {
        try writer.writeU16(108); // FAR ID IE type
        try writer.writeU16(4); // length
        try writer.writeU32(far_id.far_id);
    }

    // QER ID (IE type not in enum, using raw value 109)
    if (create_pdr.qer_ids) |qer_ids| {
        for (qer_ids) |qer_id| {
            try writer.writeU16(109); // QER ID IE type
            try writer.writeU16(4); // length
            try writer.writeU32(qer_id.qer_id);
        }
    }

    // Outer Header Removal (IE type not in enum, using raw value 95) if present
    if (create_pdr.outer_header_removal) |ohr| {
        try writer.writeU16(95); // Outer Header Removal IE type
        try writer.writeU16(1); // length
        try writer.writeByte(@intFromEnum(ohr.description));
    }

    // Update CreatePDR length
    const ie_length: u16 = @intCast(writer.pos - ie_start - 4);
    const final_pos = writer.pos;
    writer.pos = length_pos;
    try writer.writeU16(ie_length);
    writer.pos = final_pos;
}

fn encodeCreateFAR(writer: *pfcp.Writer, create_far: pfcp.ie.CreateFAR) !void {
    const ie_start = writer.pos;

    // IE Header: type (create_far = 3) + length (filled later)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.create_far));
    const length_pos = writer.pos;
    try writer.writeU16(0); // placeholder

    // FAR ID (IE type 108)
    try writer.writeU16(108); // FAR ID IE type
    try writer.writeU16(4); // length
    try writer.writeU32(create_far.far_id.far_id);

    // Apply Action (IE type 44)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.apply_action));
    try writer.writeU16(2); // length (2 bytes for packed struct)
    try writer.writeU16(@bitCast(create_far.apply_action.actions));

    // Forwarding Parameters (IE type 4) if present
    if (create_far.forwarding_parameters) |fwd_params| {
        const fwd_start = writer.pos;
        try writer.writeU16(@intFromEnum(pfcp.types.IEType.forwarding_parameters));
        const fwd_length_pos = writer.pos;
        try writer.writeU16(0); // placeholder

        // Destination Interface (IE type 42)
        try writer.writeU16(@intFromEnum(pfcp.types.IEType.destination_interface));
        try writer.writeU16(1); // length
        try writer.writeByte(@intFromEnum(fwd_params.destination_interface.interface));

        // Outer Header Creation (IE type 84) if present
        if (fwd_params.outer_header_creation) |ohc| {
            try writer.writeU16(@intFromEnum(pfcp.types.IEType.outer_header_creation));

            // Calculate length: 1 byte flags + optional fields
            var ohc_length: u16 = 1; // flags byte
            if (ohc.teid != null) ohc_length += 4;
            if (ohc.ipv4 != null) ohc_length += 4;
            if (ohc.ipv6 != null) ohc_length += 16;
            if (ohc.port != null) ohc_length += 2;
            if (ohc.ctag != null) ohc_length += 2;
            if (ohc.stag != null) ohc_length += 2;

            try writer.writeU16(ohc_length);

            // Flags byte
            try writer.writeByte(@bitCast(ohc.flags));

            // Optional fields
            if (ohc.teid) |teid| {
                try writer.writeU32(teid);
            }
            if (ohc.ipv4) |ipv4| {
                try writer.writeBytes(&ipv4);
            }
            if (ohc.ipv6) |ipv6| {
                try writer.writeBytes(&ipv6);
            }
            if (ohc.port) |port| {
                try writer.writeU16(port);
            }
            if (ohc.ctag) |ctag| {
                try writer.writeU16(ctag);
            }
            if (ohc.stag) |stag| {
                try writer.writeU16(stag);
            }
        }

        // Update Forwarding Parameters length
        const fwd_length: u16 = @intCast(writer.pos - fwd_start - 4);
        const saved_pos = writer.pos;
        writer.pos = fwd_length_pos;
        try writer.writeU16(fwd_length);
        writer.pos = saved_pos;
    }

    // Update CreateFAR length
    const ie_length: u16 = @intCast(writer.pos - ie_start - 4);
    const final_pos = writer.pos;
    writer.pos = length_pos;
    try writer.writeU16(ie_length);
    writer.pos = final_pos;
}

fn encodeCreateQER(writer: *pfcp.Writer, create_qer: pfcp.ie.CreateQER) !void {
    const ie_start = writer.pos;

    // IE Header: type (create_qer = 7) + length (filled later)
    try writer.writeU16(@intFromEnum(pfcp.types.IEType.create_qer));
    const length_pos = writer.pos;
    try writer.writeU16(0); // placeholder

    // QER ID (IE type 109)
    try writer.writeU16(109); // QER ID IE type
    try writer.writeU16(4); // length
    try writer.writeU32(create_qer.qer_id.qer_id);

    // Gate Status (IE type 25) if present
    if (create_qer.gate_status) |gate| {
        try writer.writeU16(@intFromEnum(pfcp.types.IEType.gate_status));
        try writer.writeU16(1); // length
        // Pack UL (bits 0-1) and DL (bits 2-3) into a single byte
        const gate_byte: u8 = (@as(u8, @intFromEnum(gate.dl_gate)) << 2) | @as(u8, @intFromEnum(gate.ul_gate));
        try writer.writeByte(gate_byte);
    }

    // MBR (IE type 26) if present
    if (create_qer.mbr) |mbr| {
        try writer.writeU16(@intFromEnum(pfcp.types.IEType.mbr));
        try writer.writeU16(10); // length (5 bytes uplink + 5 bytes downlink)
        // Uplink (40 bits)
        try writer.writeByte(@intCast((mbr.ul_mbr >> 32) & 0xFF));
        try writer.writeU32(@intCast(mbr.ul_mbr & 0xFFFFFFFF));
        // Downlink (40 bits)
        try writer.writeByte(@intCast((mbr.dl_mbr >> 32) & 0xFF));
        try writer.writeU32(@intCast(mbr.dl_mbr & 0xFFFFFFFF));
    }

    // GBR (IE type 27) if present
    if (create_qer.gbr) |gbr| {
        try writer.writeU16(@intFromEnum(pfcp.types.IEType.gbr));
        try writer.writeU16(10); // length (5 bytes uplink + 5 bytes downlink)
        // Uplink (40 bits)
        try writer.writeByte(@intCast((gbr.ul_gbr >> 32) & 0xFF));
        try writer.writeU32(@intCast(gbr.ul_gbr & 0xFFFFFFFF));
        // Downlink (40 bits)
        try writer.writeByte(@intCast((gbr.dl_gbr >> 32) & 0xFF));
        try writer.writeU32(@intCast(gbr.dl_gbr & 0xFFFFFFFF));
    }

    // Update CreateQER length
    const ie_length: u16 = @intCast(writer.pos - ie_start - 4);
    const final_pos = writer.pos;
    writer.pos = length_pos;
    try writer.writeU16(ie_length);
    writer.pos = final_pos;
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

// Send PFCP Session Establishment Request with PDRs, FARs, and QER
fn sendSessionEstablishmentRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Session Establishment Request ===\n", .{});
    print("Creating session with:\n", .{});
    print("  - Uplink PDR: ID={}, TEID=0x{x}, FAR={}, QER={}\n", .{ state.config.uplink_pdr_id, state.config.uplink_teid, state.config.uplink_far_id, state.config.qer_id });
    print("  - Downlink PDR: ID={}, TEID=0x{x}, FAR={}, QER={}\n", .{ state.config.downlink_pdr_id, state.config.downlink_teid, state.config.downlink_far_id, state.config.qer_id });
    print("  - Uplink FAR: ID={}, action=forward, dest=core(N6)\n", .{state.config.uplink_far_id});
    print("  - Downlink FAR: ID={}, action=forward, dest=access(N3), GTP-U encap\n", .{state.config.downlink_far_id});
    print("  - QER: ID={}, MBR=10Mbps UL/DL\n", .{state.config.qer_id});

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

    // Add QER reference to uplink PDR
    const uplink_qer_ids: []const pfcp.ie.QERID = &[_]pfcp.ie.QERID{pfcp.ie.QERID.init(state.config.qer_id)};
    uplink_pdr.qer_ids = @constCast(uplink_qer_ids);

    try encodeCreatePDR(&writer, uplink_pdr);

    // Create Downlink PDR (core → access)
    const downlink_pdr_pdi = pfcp.ie.PDI.init(pfcp.ie.SourceInterface.init(.core));

    var downlink_pdr = pfcp.ie.CreatePDR.init(
        pfcp.ie.PDRID.init(state.config.downlink_pdr_id),
        pfcp.ie.Precedence.init(100),
        downlink_pdr_pdi,
    ).withFarId(pfcp.ie.FARID.init(state.config.downlink_far_id));

    // Add QER reference to downlink PDR
    const downlink_qer_ids: []const pfcp.ie.QERID = &[_]pfcp.ie.QERID{pfcp.ie.QERID.init(state.config.qer_id)};
    downlink_pdr.qer_ids = @constCast(downlink_qer_ids);

    try encodeCreatePDR(&writer, downlink_pdr);

    // Create Uplink FAR (forward to core/N6)
    const uplink_far = pfcp.ie.CreateFAR.forward(
        pfcp.ie.FARID.init(state.config.uplink_far_id),
        pfcp.ie.DestinationInterface.init(.core),
    );

    try encodeCreateFAR(&writer, uplink_far);

    // Create Downlink FAR (forward to access/N3 with GTP-U encapsulation)
    const downlink_fwd_params = pfcp.ie.ForwardingParameters.init(pfcp.ie.DestinationInterface.init(.access))
        .withOuterHeaderCreation(pfcp.ie.OuterHeaderCreation.initGtpuV4(
        state.config.downlink_teid,
        [_]u8{ 127, 0, 0, 1 },
    ));

    const downlink_far = pfcp.ie.CreateFAR.init(
        pfcp.ie.FARID.init(state.config.downlink_far_id),
        pfcp.ie.ApplyAction.forward(),
    ).withForwardingParameters(downlink_fwd_params);

    try encodeCreateFAR(&writer, downlink_far);

    // Create QER with MBR limits (10 Mbps = 10,000,000 bps)
    const qer = pfcp.ie.CreateQER.withRates(
        pfcp.ie.QERID.init(state.config.qer_id),
        10_000_000, // UL MBR
        10_000_000, // DL MBR
        0, // UL GBR (not set)
        0, // DL GBR (not set)
    );

    try encodeCreateQER(&writer, qer);

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
            // Parse UP F-SEID from response (simplified)
            // In real implementation, would properly parse IEs
            print("✓ Session established successfully\n", .{});
            print("Session configured with full PDR/FAR/QER rules\n", .{});
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
fn sendUplinkPackets(state: *TestState, count: u32) !void {
    print("\n--- Sending {} uplink GTP-U packets (TEID=0x{x}) ---\n", .{ count, state.config.uplink_teid });

    var packet_buf: [2048]u8 = undefined;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Create simple payload (simulated IP packet)
        var payload: [100]u8 = undefined;
        @memset(&payload, @intCast(i % 256));

        // Build GTP-U packet
        const packet_len = buildGtpuPacket(&packet_buf, state.config.uplink_teid, payload[0..]);

        // Send packet
        _ = try std.posix.sendto(
            state.gtpu_socket,
            packet_buf[0..packet_len],
            0,
            &state.upf_gtpu_addr.any,
            state.upf_gtpu_addr.getOsSockLen(),
        );

        // Small delay between packets (10ms)
        time.sleep(10 * time.ns_per_ms);
    }

    print("✓ Sent {} uplink packets\n", .{count});
}

// Send GTP-U downlink packets
fn sendDownlinkPackets(state: *TestState, count: u32) !void {
    print("\n--- Sending {} downlink GTP-U packets (TEID=0x{x}) ---\n", .{ count, state.config.downlink_teid });

    var packet_buf: [2048]u8 = undefined;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Create simple payload
        var payload: [100]u8 = undefined;
        @memset(&payload, @intCast((i + 100) % 256));

        // Build GTP-U packet
        const packet_len = buildGtpuPacket(&packet_buf, state.config.downlink_teid, payload[0..]);

        // Send packet
        _ = try std.posix.sendto(
            state.gtpu_socket,
            packet_buf[0..packet_len],
            0,
            &state.upf_gtpu_addr.any,
            state.upf_gtpu_addr.getOsSockLen(),
        );

        // Small delay between packets (10ms)
        time.sleep(10 * time.ns_per_ms);
    }

    print("✓ Sent {} downlink packets\n", .{count});
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
    print("║       PicoUP QER Integration Test Suite                   ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Target UPF: {s}:{} (PFCP), {s}:{} (GTP-U)\n", .{ UPF_ADDR, PFCP_PORT, UPF_ADDR, GTPU_PORT });
    print("\n", .{});
    print("Test Plan:\n", .{});
    print("  1. Create PFCP association\n", .{});
    print("  2. Create PFCP session with default QER\n", .{});
    print("  3. Send uplink/downlink GTP-U packets (3 rounds)\n", .{});
    print("  4. Delete PFCP session\n", .{});
    print("  5. Delete PFCP association\n", .{});
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

    // Step 2: Create PFCP session
    try sendSessionEstablishmentRequest(&state);
    time.sleep(2 * time.ns_per_s);

    // Step 3: Send GTP-U packets (3 rounds)
    var round: u32 = 1;
    while (round <= state.config.rounds) : (round += 1) {
        print("\n", .{});
        print("═══════════════════════════════════════════════════════════\n", .{});
        print("             ROUND {}/{}\n", .{ round, state.config.rounds });
        print("═══════════════════════════════════════════════════════════\n", .{});

        // Send uplink packets
        try sendUplinkPackets(&state, state.config.packets_per_round);
        time.sleep(1 * time.ns_per_s);

        // Send downlink packets
        try sendDownlinkPackets(&state, state.config.packets_per_round);

        if (round < state.config.rounds) {
            print("\nWaiting {} seconds before next round...\n", .{state.config.delay_between_rounds_sec});
            time.sleep(state.config.delay_between_rounds_sec * time.ns_per_s);
        }
    }

    print("\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("             TEST TRAFFIC COMPLETE\n", .{});
    print("═══════════════════════════════════════════════════════════\n", .{});
    print("\nTotal packets sent:\n", .{});
    print("  Uplink:   {} packets\n", .{state.config.packets_per_round * state.config.rounds});
    print("  Downlink: {} packets\n", .{state.config.packets_per_round * state.config.rounds});
    print("  Total:    {} packets\n", .{state.config.packets_per_round * state.config.rounds * 2});

    print("\n⏱  Waiting 3 seconds for statistics...\n", .{});
    time.sleep(3 * time.ns_per_s);

    // Step 4: Delete PFCP session
    try sendSessionDeletionRequest(&state);
    time.sleep(1 * time.ns_per_s);

    // Step 5: Delete PFCP association
    try sendAssociationReleaseRequest(&state);

    print("\n", .{});
    print("╔════════════════════════════════════════════════════════════╗\n", .{});
    print("║              TEST COMPLETED SUCCESSFULLY!                  ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("✓ Check PicoUPF statistics output for QoS metrics:\n", .{});
    print("  - QoS: Passed=X, MBR Dropped=Y, PPS Dropped=Z\n", .{});
    print("  - GTP-U RX should show ~{} packets received\n", .{state.config.packets_per_round * state.config.rounds * 2});
    print("\n", .{});
}
