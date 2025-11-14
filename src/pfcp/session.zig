// PFCP Session management handlers
// Handles Session Establishment, Modification, and Deletion

const std = @import("std");
const types = @import("../types.zig");
const stats_mod = @import("../stats.zig");
const session_mod = @import("../session.zig");

const pfcp = @import("zig-pfcp");
const net = std.net;
const print = std.debug.print;
const Atomic = std.atomic.Value;

const PDR = types.PDR;
const FAR = types.FAR;

// Session Establishment Request handler
pub fn handleSessionEstablishment(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
    pfcp_association_established: *Atomic(bool),
    stats: *stats_mod.Stats,
) void {
    print("PFCP: Session Establishment Request received\n", .{});

    // Check if PFCP association is established
    if (!pfcp_association_established.load(.seq_cst)) {
        print("PFCP: No PFCP association established\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .no_established_pfcp_association);
        return;
    }

    // Parse mandatory IEs: Node ID and F-SEID
    var cp_seid: u64 = 0;
    var found_fseid = false;

    // Parse IEs from the message body
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Skip node ID for now
                reader.pos += ie_header.length;
            },
            .f_seid => {
                // Parse F-SEID to get CP SEID
                if (ie_header.length >= 9) {
                    const flags = reader.readByte() catch break;
                    cp_seid = reader.readU64() catch break;
                    // Skip IP address bytes
                    const remaining_bytes = ie_header.length - 9;
                    reader.pos += remaining_bytes;
                    found_fseid = true;
                    print("PFCP: CP F-SEID: 0x{x}, flags: 0x{x}\n", .{ cp_seid, flags });
                } else {
                    reader.pos += ie_header.length;
                }
            },
            else => {
                // Skip other IEs
                reader.pos += ie_header.length;
            },
        }
    }

    // Validate mandatory IEs
    if (!found_fseid) {
        print("PFCP: Missing F-SEID in Session Establishment Request\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .mandatory_ie_missing);
        return;
    }

    // Create session
    const up_seid = session_manager.createSession(cp_seid) catch {
        print("PFCP: Failed to create session\n", .{});
        sendSessionEstablishmentError(socket, req_header, client_addr, .no_resources_available);
        return;
    };

    // Create default PDR and FAR
    if (session_manager.findSession(up_seid)) |session| {
        const pdr = PDR.init(1, 100, 0, 0x100, 1);
        const far = FAR.init(1, 1, 1);

        session.addPDR(pdr) catch {};
        session.addFAR(far) catch {};

        _ = stats.pfcp_sessions.fetchAdd(1, .seq_cst);
        print("PFCP: Created session with UP SEID 0x{x}, PDR TEID: 0x{x}\n", .{ up_seid, pdr.teid });
    }

    sendSessionEstablishmentResponse(socket, req_header, client_addr, up_seid, .request_accepted);
}

// Helper: Send Session Establishment Response
fn sendSessionEstablishmentResponse(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    up_seid: u64,
    cause_value: pfcp.types.CauseValue,
) void {
    var response_buf: [512]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_establishment_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const up_fseid = pfcp.ie.FSEID.initV4(up_seid, [_]u8{ 10, 0, 0, 1 });
    pfcp.marshal.encodeFSEID(&writer, up_fseid) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Helper: Send Session Establishment Error Response
fn sendSessionEstablishmentError(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    cause_value: pfcp.types.CauseValue,
) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_establishment_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Session Modification Request handler
pub fn handleSessionModification(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
) void {
    print("PFCP: Session Modification Request received\n", .{});

    const seid = req_header.seid orelse {
        print("PFCP: Session Modification Request missing SEID\n", .{});
        return;
    };

    print("PFCP: Modifying session SEID 0x{x}\n", .{seid});

    const session = session_manager.findSession(seid);
    if (session == null) {
        print("PFCP: Session 0x{x} not found\n", .{seid});
        sendSessionModificationResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    }

    // Parse IEs (simplified - full implementation would handle all IE types)
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        reader.pos += ie_header.length;
    }

    print("PFCP: Session modification completed for SEID 0x{x}\n", .{seid});
    sendSessionModificationResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Session Modification Response
fn sendSessionModificationResponse(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    cause_value: pfcp.types.CauseValue,
) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_modification_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}

// Session Deletion Request handler
pub fn handleSessionDeletion(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
) void {
    print("PFCP: Session Deletion Request received\n", .{});
    _ = reader;

    const seid = req_header.seid orelse {
        print("PFCP: Session Deletion Request missing SEID\n", .{});
        return;
    };

    print("PFCP: Deleting session SEID 0x{x}\n", .{seid});

    const deleted = session_manager.deleteSession(seid);
    if (!deleted) {
        print("PFCP: Failed to delete session 0x{x}\n", .{seid});
        sendSessionDeletionResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    }

    print("PFCP: Session 0x{x} deleted successfully\n", .{seid});
    sendSessionDeletionResponse(socket, req_header, client_addr, .request_accepted);
}

// Helper: Send Session Deletion Response
fn sendSessionDeletionResponse(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    client_addr: net.Address,
    cause_value: pfcp.types.CauseValue,
) void {
    var response_buf: [256]u8 = undefined;
    var writer = pfcp.marshal.Writer.init(&response_buf);

    var resp_header = pfcp.types.PfcpHeader.init(.session_deletion_response, true);
    resp_header.seid = req_header.seid;
    resp_header.sequence_number = req_header.sequence_number;

    const header_start = writer.pos;
    pfcp.marshal.encodePfcpHeader(&writer, resp_header) catch return;

    const cause = pfcp.ie.Cause.init(cause_value);
    pfcp.marshal.encodeCause(&writer, cause) catch return;

    const message_length: u16 = @intCast(writer.pos - header_start - 4);
    const saved_pos = writer.pos;
    writer.pos = header_start + 2;
    _ = writer.writeU16(message_length) catch return;
    writer.pos = saved_pos;

    const response = writer.getWritten();
    _ = std.posix.sendto(socket, response, 0, &client_addr.any, client_addr.getOsSockLen()) catch {};
}
