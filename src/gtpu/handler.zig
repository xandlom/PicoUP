// GTP-U packet parsing and encapsulation
// Handles GTP-U header operations for N3, N6, N9 interfaces

const std = @import("std");

// Parse GTP-U header (simplified)
// Returns header information and payload offset
pub fn parseGtpuHeader(data: []const u8) !struct {
    version: u8,
    message_type: u8,
    teid: u32,
    payload_offset: usize,
} {
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
// Returns total packet size (header + payload)
pub fn createGtpuHeader(buffer: []u8, teid: u32, payload: []const u8) usize {
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
    @memcpy(buffer[8..][0..payload.len], payload);

    return 8 + payload.len;
}
