// PFCP message handler - main message routing
// Routes PFCP messages to appropriate handlers based on message type

const std = @import("std");
const stats_mod = @import("../stats.zig");
const session_mod = @import("../session.zig");
const heartbeat = @import("heartbeat.zig");
const association = @import("association.zig");
const pfcp_session = @import("session.zig");

const pfcp = @import("zig-pfcp");
const net = std.net;
const print = std.debug.print;
const Atomic = std.atomic.Value;

// Main PFCP message handler
// Parses header and routes to appropriate handler based on message type
pub fn handlePfcpMessage(
    data: []const u8,
    client_addr: net.Address,
    socket: std.posix.socket_t,
    allocator: std.mem.Allocator,
    stats: *stats_mod.Stats,
    session_manager: *session_mod.SessionManager,
    pfcp_association_established: *Atomic(bool),
) void {
    _ = allocator;
    _ = stats.pfcp_messages.fetchAdd(1, .seq_cst);

    // Parse PFCP header using zig-pfcp library
    var reader = pfcp.marshal.Reader.init(data);
    const header = pfcp.marshal.decodePfcpHeader(&reader) catch |err| {
        print("PFCP: Failed to decode header: {any}\n", .{err});
        return;
    };

    print("PFCP: Received message type {d}, SEID: {?x}, seq: {d}, from {any}\n", .{ header.message_type, header.seid, header.sequence_number, client_addr });

    // Handle different message types
    const msg_type: pfcp.types.MessageType = @enumFromInt(header.message_type);
    switch (msg_type) {
        .heartbeat_request => {
            heartbeat.handleHeartbeatRequest(socket, &header, client_addr, stats);
        },
        .association_setup_request => {
            association.handleAssociationSetup(socket, &header, &reader, client_addr, pfcp_association_established, stats);
        },
        .association_release_request => {
            association.handleAssociationRelease(socket, &header, &reader, client_addr, pfcp_association_established);
        },
        .session_establishment_request => {
            pfcp_session.handleSessionEstablishment(socket, &header, &reader, client_addr, session_manager, pfcp_association_established, stats);
        },
        .session_modification_request => {
            pfcp_session.handleSessionModification(socket, &header, &reader, client_addr, session_manager);
        },
        .session_deletion_request => {
            pfcp_session.handleSessionDeletion(socket, &header, &reader, client_addr, session_manager);
        },
        else => {
            print("PFCP: Unsupported message type: {}\n", .{msg_type});
        },
    }
}
