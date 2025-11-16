// PFCP Association management
// Handles Association Setup/Update/Release for PFCP connections

const std = @import("std");
const stats_mod = @import("../stats.zig");
const pfcp = @import("zig-pfcp");

const net = std.net;
const print = std.debug.print;
const Atomic = std.atomic.Value;

// Association Setup Request handler
pub fn handleAssociationSetup(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    pfcp_association_established: *Atomic(bool),
    stats: *stats_mod.Stats,
) void {
    print("PFCP: Association Setup Request received from {}\n", .{client_addr});

    // Parse mandatory IEs: Node ID and Recovery Time Stamp
    var found_node_id = false;
    var found_recovery_ts = false;
    var remote_node_id_type: pfcp.types.NodeIdType = .ipv4;
    var remote_recovery_ts: u32 = 0;

    // Parse IEs from the message body
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Parse node ID type (first byte)
                if (ie_header.length >= 1) {
                    const type_byte = reader.readByte() catch break;
                    remote_node_id_type = @enumFromInt(@as(u4, @truncate(type_byte)));
                    // Skip the rest of the node ID value
                    reader.pos += ie_header.length - 1;
                    found_node_id = true;
                    print("PFCP: Remote Node ID type: {}\n", .{remote_node_id_type});
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .recovery_time_stamp => {
                if (ie_header.length == 4) {
                    remote_recovery_ts = reader.readU32() catch break;
                    found_recovery_ts = true;
                    print("PFCP: Remote Recovery Time Stamp: {}\n", .{remote_recovery_ts});
                } else {
                    reader.pos += ie_header.length;
                }
            },
            else => {
                // Skip other optional IEs (UP Function Features, CP Function Features, etc.)
                reader.pos += ie_header.length;
            },
        }
    }

    // Validate mandatory IEs
    if (!found_node_id or !found_recovery_ts) {
        print("PFCP: Missing mandatory IE in Association Setup Request\n", .{});
        sendAssociationSetupResponse(socket, req_header, client_addr, .mandatory_ie_missing, stats);
        return;
    }

    // Establish association
    _ = pfcp_association_established.store(true, .seq_cst);
    print("PFCP: Association established with {}\n", .{client_addr});

    // Send success response
    sendAssociationSetupResponse(socket, req_header, client_addr, .request_accepted, stats);
}

// Helper: Send Association Setup Response
fn sendAssociationSetupResponse(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    cause_value: pfcp.types.CauseValue,
    stats: *stats_mod.Stats,
) void {
    var response_buf: [512]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    // Create response header (Association Setup is a node message, no SEID)
    var resp_header = pfcp.types.PfcpHeader.init(.association_setup_response, false);
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    // Encode mandatory IEs: Node ID, Cause, Recovery Time Stamp

    // Node ID (use dummy IPv4 for now - will be configurable)
    const node_id = pfcp.ie.NodeId.initIpv4([_]u8{ 10, 0, 0, 1 });
    pfcp.marshal.encodeNodeId(&writer, node_id) catch return;

    // Cause
    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    // Recovery Time Stamp
    const recovery_ts = pfcp.ie.RecoveryTimeStamp.fromUnixTime(stats.start_time);
    pfcp.marshal.encodeRecoveryTimeStamp(&writer, recovery_ts) catch return;

    // Update message length
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    // Send response
    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
        print("PFCP: Failed to send Association Setup Response\n", .{});
    };

    if (cause_value == .request_accepted) {
        print("PFCP: Association Setup Response sent (accepted)\n", .{});
    } else {
        print("PFCP: Association Setup Response sent (cause: {})\n", .{cause_value});
    }
}

// Association Release Request handler
pub fn handleAssociationRelease(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    pfcp_association_established: *Atomic(bool),
) void {
    print("PFCP: Association Release Request received from {}\n", .{client_addr});
    _ = reader;

    // Release the association
    _ = pfcp_association_established.store(false, .seq_cst);
    print("PFCP: Association released\n", .{});

    // Send success response
    sendAssociationReleaseResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Association Release Response
fn sendAssociationReleaseResponse(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    cause_value: pfcp.types.CauseValue,
) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    // Create response header (Association Release is a node message, no SEID)
    var resp_header = pfcp.types.PfcpHeader.init(.association_release_response, false);
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    // Encode mandatory IE: Cause
    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    // Update message length
    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    // Send response
    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {
        print("PFCP: Failed to send Association Release Response\n", .{});
    };

    print("PFCP: Association Release Response sent (cause: {})\n", .{cause_value});
}
