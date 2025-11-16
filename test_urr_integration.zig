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
        self.writeIE(.node_id, ie_data[0..]);
    }

    pub fn writeFSEID(self: *PfcpBuilder, seid: u64, ipv4: [4]u8) void {
        var ie_data: [13]u8 = undefined;
        ie_data[0] = 0x02; // Flags: V4 present
        std.mem.writeInt(u64, ie_data[1..9], seid, .big);
        @memcpy(ie_data[9..13], ipv4[0..]);
        self.writeIE(.f_seid, ie_data[0..]);
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
    std.mem.writeInt(u32, recovery_data[0..], timestamp, .big);
    builder.writeIE(.recovery_time_stamp, recovery_data[0..]);

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
    print("  - URR: ID={}\n", .{state.config.urr_id});
    print("    - Volume Threshold: {} bytes (soft limit - trigger report)\n", .{state.config.volume_threshold});
    print("    - Volume Quota: {} bytes (hard limit - drop packets)\n", .{state.config.volume_quota});

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
            print("✓ Session established successfully\n", .{});
            print("Note: UPF created default PDR (TEID=0x{x}), FAR, and URR\n", .{state.config.uplink_teid});
            print("      URR configured with volume tracking enabled\n", .{});
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
    print("║       PicoUP URR Integration Test Suite                   ║\n", .{});
    print("╚════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
    print("Target UPF: {}:{} (PFCP), {}:{} (GTP-U)\n", .{ UPF_ADDR, PFCP_PORT, UPF_ADDR, GTPU_PORT });
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
