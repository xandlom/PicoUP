// PFCP Heartbeat handler
// Handles PFCP Heartbeat Request/Response for keepalive

const std = @import("std");
const stats_mod = @import("../stats.zig");
const pfcp = @import("zig-pfcp");

const net = std.net;
const print = std.debug.print;

// Heartbeat Request handler
pub fn handleHeartbeatRequest(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    stats: *stats_mod.Stats,
) void {
    print("PFCP: Heartbeat Request received\n", .{});

    // Build Heartbeat Response
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    // Create response header
    var resp_header = pfcp.types.PfcpHeader.init(.heartbeat_response, false);
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch {
        print("PFCP: Failed to encode header\n", .{});
        return;
    };

    // Add Recovery Time Stamp IE
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.fromUnixTime(stats.start_time);
    pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts) catch {
        print("PFCP: Failed to encode Recovery Time Stamp\n", .{});
        return;
    };

    // Update message length
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    // Send response
    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
        print("PFCP: Failed to send Heartbeat Response\n", .{});
    };
}
