// Internet checksum utilities for NAT
// Implements RFC 1071 (Internet Checksum) and RFC 1624 (Incremental Update)
// Used for IP header and TCP/UDP checksum calculation after NAT rewriting

const std = @import("std");

/// Calculate Internet checksum (RFC 1071)
/// This is the standard 16-bit one's complement checksum used in IP/TCP/UDP
pub fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // Sum 16-bit words
    while (i + 1 < data.len) : (i += 2) {
        sum += std.mem.readInt(u16, data[i..][0..2], .big);
    }

    // Handle odd byte (pad with zero)
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @truncate(~sum);
}

/// Calculate IPv4 header checksum
/// Zeros out existing checksum before calculation
pub fn calculateIpChecksum(packet: []u8) u16 {
    if (packet.len < 20) return 0;

    const ihl = (packet[0] & 0x0F) * 4;
    if (packet.len < ihl or ihl < 20) return 0;

    // Zero out existing checksum (bytes 10-11)
    packet[10] = 0;
    packet[11] = 0;

    return calculateChecksum(packet[0..ihl]);
}

/// Incremental IP checksum update after NAT (RFC 1624)
/// More efficient than recalculating entire checksum
pub fn updateIpChecksumNAT(
    packet: []u8,
    old_addr: [4]u8,
    new_addr: [4]u8,
) void {
    if (packet.len < 20) return;

    const old_sum = std.mem.readInt(u16, packet[10..12], .big);

    // Calculate difference using 1's complement arithmetic
    var diff: i32 = 0;
    diff -= @as(i32, std.mem.readInt(u16, old_addr[0..2], .big));
    diff -= @as(i32, std.mem.readInt(u16, old_addr[2..4], .big));
    diff += @as(i32, std.mem.readInt(u16, new_addr[0..2], .big));
    diff += @as(i32, std.mem.readInt(u16, new_addr[2..4], .big));

    var new_sum: i32 = ~@as(i32, old_sum) & 0xFFFF;
    new_sum += diff;

    // Handle carry/borrow
    while (new_sum < 0) new_sum += 0x10000;
    while (new_sum > 0xFFFF) new_sum = (new_sum & 0xFFFF) + (new_sum >> 16);

    const result: u16 = @truncate(~@as(u32, @intCast(new_sum)));
    std.mem.writeInt(u16, packet[10..12], result, .big);
}

/// Update TCP/UDP checksum after NAT
/// TCP/UDP checksums include a pseudo-header with IP addresses
pub fn updateTransportChecksumNAT(
    packet: []u8,
    old_addr: [4]u8,
    new_addr: [4]u8,
    old_port: u16,
    new_port: u16,
    protocol: u8,
) void {
    if (packet.len < 20) return;

    const ihl = (packet[0] & 0x0F) * 4;
    const transport_offset = ihl;

    // Checksum offset within transport header: TCP=16, UDP=6
    const checksum_offset: usize = switch (protocol) {
        6 => transport_offset + 16, // TCP
        17 => transport_offset + 6, // UDP
        else => return, // Other protocols don't need this
    };

    if (checksum_offset + 2 > packet.len) return;

    const old_sum = std.mem.readInt(u16, packet[checksum_offset..][0..2], .big);

    // UDP checksum is optional (0 means not calculated)
    if (old_sum == 0 and protocol == 17) return;

    var diff: i32 = 0;

    // Address change contribution
    diff -= @as(i32, std.mem.readInt(u16, old_addr[0..2], .big));
    diff -= @as(i32, std.mem.readInt(u16, old_addr[2..4], .big));
    diff += @as(i32, std.mem.readInt(u16, new_addr[0..2], .big));
    diff += @as(i32, std.mem.readInt(u16, new_addr[2..4], .big));

    // Port change contribution
    diff -= @as(i32, old_port);
    diff += @as(i32, new_port);

    var new_sum: i32 = ~@as(i32, old_sum) & 0xFFFF;
    new_sum += diff;

    // Handle carry/borrow
    while (new_sum < 0) new_sum += 0x10000;
    while (new_sum > 0xFFFF) new_sum = (new_sum & 0xFFFF) + (new_sum >> 16);

    const result: u16 = @truncate(~@as(u32, @intCast(new_sum)));
    std.mem.writeInt(u16, packet[checksum_offset..][0..2], result, .big);
}

/// Perform Source NAT (SNAT) on a packet - for uplink (UE → External)
/// Rewrites source IP and port, updates checksums
pub fn applySNAT(
    packet: []u8,
    packet_len: usize,
    new_src_ip: [4]u8,
    new_src_port: u16,
) bool {
    if (packet_len < 20) return false;

    // Verify IPv4
    const version = packet[0] >> 4;
    if (version != 4) return false;

    const ihl = (packet[0] & 0x0F) * 4;
    if (packet_len < ihl) return false;

    // Get original source IP and port
    const old_src_ip = [4]u8{ packet[12], packet[13], packet[14], packet[15] };
    const protocol = packet[9];

    var old_src_port: u16 = 0;
    if ((protocol == 6 or protocol == 17) and packet_len >= ihl + 2) {
        old_src_port = std.mem.readInt(u16, packet[ihl..][0..2], .big);
    }

    // Rewrite source IP
    @memcpy(packet[12..16], &new_src_ip);

    // Rewrite source port (for TCP/UDP)
    if ((protocol == 6 or protocol == 17) and packet_len >= ihl + 2) {
        std.mem.writeInt(u16, packet[ihl..][0..2], new_src_port, .big);
    }

    // Update IP header checksum
    updateIpChecksumNAT(packet, old_src_ip, new_src_ip);

    // Update transport layer checksum
    if (protocol == 6 or protocol == 17) {
        updateTransportChecksumNAT(packet, old_src_ip, new_src_ip, old_src_port, new_src_port, protocol);
    }

    return true;
}

/// Perform Destination NAT (DNAT) on a packet - for downlink (External → UE)
/// Rewrites destination IP and port, updates checksums
pub fn applyDNAT(
    packet: []u8,
    packet_len: usize,
    new_dst_ip: [4]u8,
    new_dst_port: u16,
) bool {
    if (packet_len < 20) return false;

    // Verify IPv4
    const version = packet[0] >> 4;
    if (version != 4) return false;

    const ihl = (packet[0] & 0x0F) * 4;
    if (packet_len < ihl) return false;

    // Get original destination IP and port
    const old_dst_ip = [4]u8{ packet[16], packet[17], packet[18], packet[19] };
    const protocol = packet[9];

    var old_dst_port: u16 = 0;
    if ((protocol == 6 or protocol == 17) and packet_len >= ihl + 4) {
        old_dst_port = std.mem.readInt(u16, packet[ihl + 2..][0..2], .big);
    }

    // Rewrite destination IP
    @memcpy(packet[16..20], &new_dst_ip);

    // Rewrite destination port (for TCP/UDP)
    if ((protocol == 6 or protocol == 17) and packet_len >= ihl + 4) {
        std.mem.writeInt(u16, packet[ihl + 2..][0..2], new_dst_port, .big);
    }

    // Update IP header checksum
    updateIpChecksumNAT(packet, old_dst_ip, new_dst_ip);

    // Update transport layer checksum
    if (protocol == 6 or protocol == 17) {
        updateTransportChecksumNAT(packet, old_dst_ip, new_dst_ip, old_dst_port, new_dst_port, protocol);
    }

    return true;
}
