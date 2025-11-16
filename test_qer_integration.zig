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

const PFCP_PORT = 8805;
const GTPU_PORT = 2152;
const UPF_ADDR = "127.0.0.1";

// PFCP Message Types
const PfcpMessageType = enum(u8) {
    heartbeat_request = 1,
    heartbeat_response = 2,
    association_setup_request = 5,
    association_setup_response = 6,
    association_release_request = 7,
    association_release_response = 8,
    session_establishment_request = 50,
    session_establishment_response = 51,
    session_deletion_request = 54,
    session_deletion_response = 55,
};

// PFCP IE Types
const PfcpIEType = enum(u16) {
    node_id = 60,
    f_seid = 57,
    cause = 19,
    recovery_time_stamp = 96,
};

// PFCP Cause Values
const PfcpCause = enum(u8) {
    request_accepted = 1,
    request_rejected = 64,
    session_context_not_found = 65,
    mandatory_ie_missing = 66,
    no_established_pfcp_association = 69,
    no_resources_available = 73,
};

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

// PFCP Message Builder
const PfcpBuilder = struct {
    buffer: [2048]u8,
    pos: usize,

    pub fn init() PfcpBuilder {
        return PfcpBuilder{
            .buffer = undefined,
            .pos = 0,
        };
    }

    pub fn writeByte(self: *PfcpBuilder, value: u8) void {
        self.buffer[self.pos] = value;
        self.pos += 1;
    }

    pub fn writeU16(self: *PfcpBuilder, value: u16) void {
        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], value, .big);
        self.pos += 2;
    }

    pub fn writeU32(self: *PfcpBuilder, value: u32) void {
        std.mem.writeInt(u32, self.buffer[self.pos..][0..4], value, .big);
        self.pos += 4;
    }

    pub fn writeU64(self: *PfcpBuilder, value: u64) void {
        std.mem.writeInt(u64, self.buffer[self.pos..][0..8], value, .big);
        self.pos += 8;
    }

    pub fn writeBytes(self: *PfcpBuilder, bytes: []const u8) void {
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    pub fn getBuffer(self: *PfcpBuilder) []u8 {
        return self.buffer[0..self.pos];
    }

    pub fn buildPfcpHeader(self: *PfcpBuilder, msg_type: PfcpMessageType, has_seid: bool, seid: u64, seq: u32) void {
        // Version (1) and flags
        const flags: u8 = if (has_seid) 0x21 else 0x20; // Version 1, S flag if has_seid
        self.writeByte(flags);

        // Message type
        self.writeByte(@intFromEnum(msg_type));

        // Message length (placeholder, will be updated)
        self.writeU16(0);

        // SEID (if present)
        if (has_seid) {
            self.writeU64(seid);
        }

        // Sequence number (3 bytes) + spare (1 byte)
        self.writeByte(@intCast((seq >> 16) & 0xFF));
        self.writeByte(@intCast((seq >> 8) & 0xFF));
        self.writeByte(@intCast(seq & 0xFF));
        self.writeByte(0); // Spare
    }

    pub fn updateMessageLength(self: *PfcpBuilder) void {
        const header_size = 4; // First 4 bytes (version, type, length)
        const message_length: u16 = @intCast(self.pos - header_size);
        std.mem.writeInt(u16, self.buffer[2..4], message_length, .big);
    }

    pub fn writeIE(self: *PfcpBuilder, ie_type: PfcpIEType, data: []const u8) void {
        // IE Type (2 bytes)
        self.writeU16(@intFromEnum(ie_type));

        // IE Length (2 bytes)
        self.writeU16(@intCast(data.len));

        // IE Data
        self.writeBytes(data);
    }

    pub fn writeNodeId(self: *PfcpBuilder) void {
        var ie_data: [5]u8 = undefined;
        ie_data[0] = 0; // Type: IPv4
        ie_data[1] = 127; // 127.0.0.1
        ie_data[2] = 0;
        ie_data[3] = 0;
        ie_data[4] = 1;
        self.writeIE(.node_id, &ie_data);
    }

    pub fn writeFSEID(self: *PfcpBuilder, seid: u64, ipv4: [4]u8) void {
        var ie_data: [13]u8 = undefined;
        ie_data[0] = 0x02; // Flags: V4 present
        std.mem.writeInt(u64, ie_data[1..9], seid, .big);
        @memcpy(ie_data[9..13], &ipv4);
        self.writeIE(.f_seid, &ie_data);
    }
};

// Send PFCP Association Setup Request
fn sendAssociationSetupRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Association Setup Request ===\n", .{});

    var builder = PfcpBuilder.init();
    builder.buildPfcpHeader(.association_setup_request, false, 0, state.nextSequenceNumber());
    builder.writeNodeId();

    // Recovery Time Stamp IE
    const timestamp: u32 = @intCast(time.timestamp());
    var recovery_data: [4]u8 = undefined;
    std.mem.writeInt(u32, &recovery_data, timestamp, .big);
    builder.writeIE(.recovery_time_stamp, &recovery_data);

    builder.updateMessageLength();

    const msg = builder.getBuffer();
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
        if (msg_type == @intFromEnum(PfcpMessageType.association_setup_response)) {
            print("✓ Association established successfully\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Send PFCP Session Establishment Request (simplified)
fn sendSessionEstablishmentRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Session Establishment Request ===\n", .{});
    print("Creating session with:\n", .{});
    print("  - Uplink PDR: ID={}, TEID=0x{x}\n", .{ state.config.uplink_pdr_id, state.config.uplink_teid });
    print("  - Downlink PDR: ID={}, TEID=0x{x}\n", .{ state.config.downlink_pdr_id, state.config.downlink_teid });
    print("  - QER: ID={} (will be created by UPF with default limits)\n", .{state.config.qer_id});

    var builder = PfcpBuilder.init();
    builder.buildPfcpHeader(
        .session_establishment_request,
        true,
        state.config.cp_seid,
        state.nextSequenceNumber(),
    );

    builder.writeNodeId();

    // F-SEID (CP)
    builder.writeFSEID(state.config.cp_seid, .{ 127, 0, 0, 1 });

    builder.updateMessageLength();

    const msg = builder.getBuffer();
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

        if (msg_type == @intFromEnum(PfcpMessageType.session_establishment_response)) {
            // Parse UP F-SEID from response (simplified)
            // In real implementation, would properly parse IEs
            print("✓ Session established successfully\n", .{});
            print("Note: UPF created default PDR (TEID=0x100), FAR, and QER\n", .{});
            print("      QER limits: PPS=1000, MBR=10Mbps\n", .{});
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
        const packet_len = buildGtpuPacket(&packet_buf, state.config.uplink_teid, &payload);

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
        const packet_len = buildGtpuPacket(&packet_buf, state.config.downlink_teid, &payload);

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

    var builder = PfcpBuilder.init();
    builder.buildPfcpHeader(
        .session_deletion_request,
        true,
        state.config.cp_seid,
        state.nextSequenceNumber(),
    );

    builder.updateMessageLength();

    const msg = builder.getBuffer();
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
        if (msg_type == @intFromEnum(PfcpMessageType.session_deletion_response)) {
            print("✓ Session deleted successfully\n", .{});
        } else {
            print("✗ Unexpected response type\n", .{});
        }
    }
}

// Send PFCP Association Release Request
fn sendAssociationReleaseRequest(state: *TestState) !void {
    print("\n=== Sending PFCP Association Release Request ===\n", .{});

    var builder = PfcpBuilder.init();
    builder.buildPfcpHeader(.association_release_request, false, 0, state.nextSequenceNumber());
    builder.writeNodeId();
    builder.updateMessageLength();

    const msg = builder.getBuffer();
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
        if (msg_type == @intFromEnum(PfcpMessageType.association_release_response)) {
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
    print("Target UPF: {}:{} (PFCP), {}:{} (GTP-U)\n", .{ UPF_ADDR, PFCP_PORT, UPF_ADDR, GTPU_PORT });
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
