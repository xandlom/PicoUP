// GTP-U packet parsing and encapsulation using zig-gtp-u library
// Handles GTP-U header operations for N3, N6, N9 interfaces
// Supports extension headers for QFI extraction and echo request/response

const std = @import("std");
const gtpu = @import("zig-gtp-u");
const net = std.net;

const print = std.debug.print;

// Re-export common types from library for convenience
pub const MessageType = gtpu.message.MessageType;
pub const ExtensionHeaderType = gtpu.protocol.ExtensionHeaderType;
pub const PduSessionContainer = gtpu.extension.PduSessionContainer;

// Parsed GTP-U header information with extension header support
pub const GtpuHeader = struct {
    version: u8,
    message_type: u8,
    teid: u32,
    payload_offset: usize,
    sequence_number: ?u16 = null,
    // Extension header information
    has_extension_headers: bool = false,
    qfi: ?u6 = null, // QoS Flow Identifier from PDU Session Container
    pdu_type: ?u4 = null, // PDU Type (0=DL, 1=UL) from PDU Session Container
    rqi: bool = false, // Reflective QoS Indicator
};

// Parse GTP-U header using the zig-gtp-u library
// Returns header information and payload offset
// Supports extension headers for QFI extraction
pub fn parseGtpuHeader(data: []const u8) !GtpuHeader {
    if (data.len < gtpu.GtpuHeader.MANDATORY_SIZE) {
        return error.PacketTooShort;
    }

    // Use library's decode function
    var stream = std.io.fixedBufferStream(data);
    const header = gtpu.GtpuHeader.decode(stream.reader()) catch |err| {
        return err;
    };

    var result = GtpuHeader{
        .version = header.flags.version,
        .message_type = @intFromEnum(header.message_type),
        .teid = header.teid,
        .payload_offset = header.size(),
        .sequence_number = header.sequence_number,
        .has_extension_headers = header.flags.e,
    };

    // Parse extension headers if present
    if (header.flags.e and header.next_extension_type != null) {
        var next_type = header.next_extension_type.?;
        var offset = header.size();

        while (next_type != .no_more_headers and offset < data.len) {
            // Create a reader starting from the extension header
            var ext_stream = std.io.fixedBufferStream(data[offset..]);
            const decode_result = gtpu.extension.ExtensionHeader.decode(ext_stream.reader(), next_type) catch |err| {
                // Skip unsupported extension headers gracefully
                if (err == error.UnsupportedExtensionHeaderType) {
                    // Read length byte to skip this extension
                    if (offset < data.len) {
                        const length = data[offset];
                        const ext_size = @as(usize, length) * 4;
                        offset += ext_size;
                        // Try to read next extension type
                        if (offset > 0 and offset - 1 < data.len) {
                            const next_byte = data[offset - 1];
                            next_type = if (next_byte == 0) .no_more_headers else @enumFromInt(next_byte);
                        } else {
                            break;
                        }
                        continue;
                    }
                }
                break;
            };

            // Extract QFI from PDU Session Container
            switch (decode_result.header) {
                .pdu_session_container => |psc| {
                    result.qfi = psc.qfi;
                    result.pdu_type = psc.pdu_type;
                    result.rqi = psc.rqi;
                },
                else => {},
            }

            // Update offset and get next type
            offset += decode_result.header.size();
            next_type = decode_result.next_type;
        }

        result.payload_offset = offset;
    }

    return result;
}

// Parse GTP-U message using full library message decoder
// This provides access to all message information including IEs
pub fn parseGtpuMessage(allocator: std.mem.Allocator, data: []const u8) !gtpu.GtpuMessage {
    var stream = std.io.fixedBufferStream(data);
    return gtpu.GtpuMessage.decode(allocator, stream.reader());
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

// Create GTP-U G-PDU with PDU Session Container extension header (for QFI)
// This is essential for 5G QoS flow differentiation
pub fn createGtpuHeaderWithQFI(
    allocator: std.mem.Allocator,
    buffer: []u8,
    teid: u32,
    qfi: u6,
    is_uplink: bool,
    payload: []const u8,
) usize {
    // Create G-PDU message using library
    var msg = gtpu.GtpuMessage.createGpdu(allocator, teid, payload);
    defer msg.deinit();

    // Add PDU Session Container extension header
    const pdu_container = gtpu.extension.ExtensionHeader{
        .pdu_session_container = .{
            .pdu_type = if (is_uplink) 1 else 0, // 1=UL, 0=DL
            .qfi = qfi,
            .ppi = 0,
            .rqi = false,
        },
    };
    msg.addExtensionHeader(pdu_container) catch {
        return 0;
    };

    // Encode to buffer
    var stream = std.io.fixedBufferStream(buffer);
    msg.encode(stream.writer()) catch {
        return 0;
    };

    return stream.pos;
}

// Check if a GTP-U message is an Echo Request
pub fn isEchoRequest(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[1] == @intFromEnum(MessageType.echo_request);
}

// Check if a GTP-U message is an Echo Response
pub fn isEchoResponse(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[1] == @intFromEnum(MessageType.echo_response);
}

// Handle Echo Request and send Echo Response
// Returns true if the message was an Echo Request and was handled
pub fn handleEchoRequest(
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    data: []const u8,
    sender: net.Address,
) bool {
    if (!isEchoRequest(data)) {
        return false;
    }

    // Parse the incoming echo request to get sequence number
    var stream = std.io.fixedBufferStream(data);
    const header = gtpu.GtpuHeader.decode(stream.reader()) catch {
        print("GTP-U Echo: Failed to parse echo request header\n", .{});
        return true; // Still consumed the message
    };

    const sequence = header.sequence_number orelse 0;
    print("GTP-U Echo: Received Echo Request, seq={}\n", .{sequence});

    // Create Echo Response using the library
    var response = gtpu.GtpuMessage.createEchoResponse(allocator, sequence) catch {
        print("GTP-U Echo: Failed to create echo response\n", .{});
        return true;
    };
    defer response.deinit();

    // Encode response
    var response_buffer: [64]u8 = undefined;
    var resp_stream = std.io.fixedBufferStream(&response_buffer);
    response.encode(resp_stream.writer()) catch {
        print("GTP-U Echo: Failed to encode echo response\n", .{});
        return true;
    };

    // Send response
    _ = std.posix.sendto(
        socket,
        response_buffer[0..resp_stream.pos],
        0,
        &sender.any,
        sender.getOsSockLen(),
    ) catch |err| {
        print("GTP-U Echo: Failed to send echo response: {}\n", .{err});
        return true;
    };

    print("GTP-U Echo: Sent Echo Response, seq={}\n", .{sequence});
    return true;
}

// Create and send an Echo Request
pub fn sendEchoRequest(
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    dest: net.Address,
    sequence: u16,
) !void {
    var request = try gtpu.GtpuMessage.createEchoRequest(allocator, sequence);
    defer request.deinit();

    var buffer: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try request.encode(stream.writer());

    _ = try std.posix.sendto(
        socket,
        buffer[0..stream.pos],
        0,
        &dest.any,
        dest.getOsSockLen(),
    );

    print("GTP-U Echo: Sent Echo Request to {}, seq={}\n", .{ dest, sequence });
}

// Get message type from raw data
pub fn getMessageType(data: []const u8) ?MessageType {
    if (data.len < 2) return null;
    return @enumFromInt(data[1]);
}
