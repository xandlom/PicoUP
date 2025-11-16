// GTP-U packet parsing and encapsulation using zig-gtp-u library
// Handles GTP-U header operations for N3, N6, N9 interfaces

const std = @import("std");
const gtpu = @import("zig-gtp-u");

// Parsed GTP-U header information
pub const GtpuHeader = struct {
    version: u8,
    message_type: u8,
    teid: u32,
    payload_offset: usize,
};

// Parse GTP-U header using the zig-gtp-u library
// Returns header information and payload offset
pub fn parseGtpuHeader(data: []const u8) !GtpuHeader {
    if (data.len < gtpu.GtpuHeader.MANDATORY_SIZE) {
        return error.PacketTooShort;
    }

    // Use library's decode function
    var stream = std.io.fixedBufferStream(data);
    const header = gtpu.GtpuHeader.decode(stream.reader()) catch |err| {
        return err;
    };

    // Calculate payload offset based on header size
    const offset = header.size();

    return GtpuHeader{
        .version = header.flags.version,
        .message_type = @intFromEnum(header.message_type),
        .teid = header.teid,
        .payload_offset = offset,
    };
}

// Create GTP-U header for encapsulation (N3/N9 interfaces)
// Returns total packet size (header + payload)
pub fn createGtpuHeader(buffer: []u8, teid: u32, payload: []const u8) usize {
    if (buffer.len < gtpu.GtpuHeader.MANDATORY_SIZE + payload.len) {
        return 0; // Not enough space
    }

    // Create G-PDU header using library
    var header = gtpu.GtpuHeader.init(.g_pdu, teid);
    header.length = @intCast(payload.len);

    // Encode header to buffer
    var stream = std.io.fixedBufferStream(buffer);
    header.encode(stream.writer()) catch {
        return 0;
    };

    // Copy payload after header
    const header_size = header.size();
    @memcpy(buffer[header_size..][0..payload.len], payload);

    return header_size + payload.len;
}
