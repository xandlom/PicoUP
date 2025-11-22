// PFCP Session management handlers
// Handles Session Establishment, Modification, and Deletion
// Uses zig-pfcp library for parsing grouped IEs (CreatePDR, CreateFAR, CreateQER, CreateURR)

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
const QER = types.QER;

// Helper: Convert zig-pfcp CreatePDR to PicoUP PDR
fn convertCreatePDRtoPDR(create_pdr: pfcp.ie.CreatePDR) PDR {
    const pdr_id = create_pdr.pdr_id.rule_id;
    const precedence = create_pdr.precedence.precedence;
    const source_interface = @intFromEnum(create_pdr.pdi.source_interface.interface);
    const teid = if (create_pdr.pdi.f_teid) |fteid| fteid.teid else 0;
    const far_id: u16 = if (create_pdr.far_id) |fid| @truncate(fid.far_id) else 0;

    var pdr = PDR.init(pdr_id, precedence, source_interface, teid, far_id);

    // Associate first QER if present
    if (create_pdr.qer_ids) |qer_ids| {
        if (qer_ids.len > 0) {
            pdr.setQER(@truncate(qer_ids[0].qer_id));
        }
    }

    print("PFCP: Converted CreatePDR - PDR ID: {}, TEID: 0x{x}, FAR ID: {}\n", .{ pdr_id, teid, far_id });
    return pdr;
}

// Helper: Convert zig-pfcp CreateFAR to PicoUP FAR
fn convertCreateFARtoFAR(create_far: pfcp.ie.CreateFAR) FAR {
    const far_id: u16 = @truncate(create_far.far_id.far_id);

    // Determine action from ApplyAction flags
    var action: u8 = 0; // Default: Drop
    if (create_far.apply_action.actions.drop) {
        action = 0;
    } else if (create_far.apply_action.actions.forw) {
        action = 1;
    } else if (create_far.apply_action.actions.buff) {
        action = 2;
    }

    // Extract destination interface from forwarding parameters
    var dest_interface: u8 = 0;
    var ohc_teid: u32 = 0;
    var ohc_ipv4: [4]u8 = .{ 0, 0, 0, 0 };
    var has_outer_header: bool = false;

    if (create_far.forwarding_parameters) |fp| {
        dest_interface = @intFromEnum(fp.destination_interface.interface);

        if (fp.outer_header_creation) |ohc| {
            has_outer_header = true;
            if (ohc.teid) |teid| ohc_teid = teid;
            if (ohc.ipv4) |ipv4| ohc_ipv4 = ipv4;
        }
    }

    var far = FAR.init(far_id, action, dest_interface);
    if (has_outer_header) {
        far.setOuterHeader(ohc_teid, ohc_ipv4);
    }

    print("PFCP: Converted CreateFAR - FAR ID: {}, Action: {}, Dest: {}\n", .{ far_id, action, dest_interface });
    return far;
}

// Helper: Convert zig-pfcp CreateQER to PicoUP QER
fn convertCreateQERtoQER(create_qer: pfcp.ie.CreateQER) QER {
    const qer_id: u16 = @truncate(create_qer.qer_id.qer_id);
    const qfi: u8 = 5; // Default QFI

    var qer = QER.init(qer_id, qfi);

    // Configure MBR if present
    if (create_qer.mbr) |mbr| {
        qer.setMBR(mbr.ul_mbr, mbr.dl_mbr);
        print("PFCP: QER {} configured with MBR UL: {} bps, DL: {} bps\n", .{
            qer_id,
            mbr.ul_mbr,
            mbr.dl_mbr,
        });

        // Estimate PPS based on MBR (assume 1500 byte MTU = 12000 bits)
        if (!qer.has_pps_limit) {
            const estimated_pps = @max(mbr.ul_mbr / 12000, 100);
            qer.setPPS(@truncate(estimated_pps));
            print("PFCP: QER {} auto-configured with PPS: {}\n", .{ qer_id, estimated_pps });
        }
    }

    // Configure GBR if present
    if (create_qer.gbr) |gbr| {
        qer.setGBR(gbr.ul_gbr, gbr.dl_gbr);
    }

    print("PFCP: Converted CreateQER - QER ID: {}\n", .{qer_id});
    return qer;
}

// Use standard library's FixedBufferAllocator for decoding grouped IEs

// Session Establishment Request handler
// Now uses zig-pfcp library's decodeCreatePDR, decodeCreateFAR, decodeCreateQER functions
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

    // Stack-based allocator buffer for decoding grouped IEs
    var alloc_buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buffer);
    const allocator = fba.allocator();

    // Parse IEs from the message body
    var cp_seid: u64 = 0;
    var found_fseid = false;

    // Arrays to store decoded rules (support up to 16 of each)
    var decoded_pdrs: [16]pfcp.ie.CreatePDR = undefined;
    var decoded_fars: [16]pfcp.ie.CreateFAR = undefined;
    var decoded_qers: [16]pfcp.ie.CreateQER = undefined;
    var pdr_count: usize = 0;
    var far_count: usize = 0;
    var qer_count: usize = 0;

    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Skip node ID for now
                reader.pos += ie_header.length;
            },
            .f_seid => {
                // Parse F-SEID using zig-pfcp library
                const fseid = pfcp.marshal.decodeFSEID(reader, ie_header.length) catch {
                    reader.pos += ie_header.length;
                    continue;
                };
                cp_seid = fseid.seid;
                found_fseid = true;
                print("PFCP: CP F-SEID: 0x{x}\n", .{cp_seid});
            },
            .create_pdr => {
                if (pdr_count < 16) {
                    // Use zig-pfcp library's decodeCreatePDR function
                    if (pfcp.marshal.decodeCreatePDR(reader, ie_header.length, allocator)) |create_pdr| {
                        decoded_pdrs[pdr_count] = create_pdr;
                        pdr_count += 1;
                        print("PFCP: Decoded CreatePDR - PDR ID: {}\n", .{create_pdr.pdr_id.rule_id});
                    } else |_| {
                        print("PFCP: Failed to decode CreatePDR\n", .{});
                    }
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .create_far => {
                if (far_count < 16) {
                    // Use zig-pfcp library's decodeCreateFAR function
                    if (pfcp.marshal.decodeCreateFAR(reader, ie_header.length, allocator)) |create_far| {
                        decoded_fars[far_count] = create_far;
                        far_count += 1;
                        print("PFCP: Decoded CreateFAR - FAR ID: {}\n", .{create_far.far_id.far_id});
                    } else |_| {
                        print("PFCP: Failed to decode CreateFAR\n", .{});
                    }
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .create_qer => {
                if (qer_count < 16) {
                    // Use zig-pfcp library's decodeCreateQER function
                    if (pfcp.marshal.decodeCreateQER(reader, ie_header.length, allocator)) |create_qer| {
                        decoded_qers[qer_count] = create_qer;
                        qer_count += 1;
                        print("PFCP: Decoded CreateQER - QER ID: {}\n", .{create_qer.qer_id.qer_id});
                    } else |_| {
                        print("PFCP: Failed to decode CreateQER\n", .{});
                    }
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

    if (session_manager.findSession(up_seid)) |session| {
        // Add decoded QERs to session (converted using helper function)
        for (0..qer_count) |i| {
            const qer = convertCreateQERtoQER(decoded_qers[i]);
            session.addQER(qer) catch {
                print("PFCP: Failed to add QER to session\n", .{});
            };
        }

        // Add decoded FARs to session (converted using helper function)
        for (0..far_count) |i| {
            const far = convertCreateFARtoFAR(decoded_fars[i]);
            session.addFAR(far) catch {
                print("PFCP: Failed to add FAR to session\n", .{});
            };
        }

        // Add decoded PDRs to session (converted using helper function)
        for (0..pdr_count) |i| {
            const pdr = convertCreatePDRtoPDR(decoded_pdrs[i]);
            session.addPDR(pdr) catch {
                print("PFCP: Failed to add PDR to session\n", .{});
            };
        }

        // If no rules were parsed from message, create defaults for backward compatibility
        if (pdr_count == 0 and far_count == 0 and qer_count == 0) {
            print("PFCP: No Create PDR/FAR/QER IEs found, creating default rules\n", .{});

            // Create default QER with rate limiting
            var qer = QER.init(1, 5); // QER ID 1, QFI 5
            qer.setPPS(1000); // 1000 packets per second limit
            qer.setMBR(10_000_000, 10_000_000); // 10 Mbps uplink/downlink

            session.addQER(qer) catch {
                print("PFCP: Failed to add default QER to session\n", .{});
            };

            // Create default PDR with QER association
            var pdr = PDR.init(1, 100, 0, 0x100, 1);
            pdr.setQER(1); // Associate PDR with QER ID 1

            // Create default FAR
            const far = FAR.init(1, 1, 1);

            session.addPDR(pdr) catch {};
            session.addFAR(far) catch {};
        }

        _ = stats.pfcp_sessions.fetchAdd(1, .seq_cst);
        print("PFCP: Created session with UP SEID 0x{x}, PDRs: {}, FARs: {}, QERs: {}\n", .{
            up_seid,
            if (pdr_count > 0) pdr_count else 1,
            if (far_count > 0) far_count else 1,
            if (qer_count > 0) qer_count else 1,
        });
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
// Now uses zig-pfcp library's decodeCreateQER function for Update QER (same structure)
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

    const session = session_manager.findSession(seid) orelse {
        print("PFCP: Session 0x{x} not found\n", .{seid});
        sendSessionModificationResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    };

    // Stack-based allocator buffer for decoding grouped IEs
    var alloc_buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buffer);
    const allocator = fba.allocator();

    // Arrays to store decoded updates (support up to 16 of each)
    var decoded_qers: [16]pfcp.ie.CreateQER = undefined;
    var qer_update_count: usize = 0;

    // Parse IEs
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .update_qer => {
                if (qer_update_count < 16) {
                    // Update QER has same structure as Create QER
                    if (pfcp.marshal.decodeCreateQER(reader, ie_header.length, allocator)) |decoded| {
                        decoded_qers[qer_update_count] = decoded;
                        qer_update_count += 1;
                        print("PFCP: Decoded UpdateQER - QER ID: {}\n", .{decoded.qer_id.qer_id});
                    } else |_| {
                        print("PFCP: Failed to decode UpdateQER\n", .{});
                    }
                } else {
                    reader.pos += ie_header.length;
                }
            },
            else => {
                // Skip other IEs for now
                reader.pos += ie_header.length;
            },
        }
    }

    // Apply QER updates to session
    for (0..qer_update_count) |i| {
        const decoded = decoded_qers[i];
        const qer_id: u16 = @truncate(decoded.qer_id.qer_id);

        // Find existing QER and update it
        if (session.findQERById(qer_id)) |qer| {
            // Update MBR if present in update
            if (decoded.mbr) |mbr| {
                qer.setMBR(mbr.ul_mbr, mbr.dl_mbr);
                print("PFCP: Updated QER {} MBR - UL: {} bps, DL: {} bps\n", .{
                    qer_id,
                    mbr.ul_mbr,
                    mbr.dl_mbr,
                });

                // Update PPS based on new MBR if needed
                if (!qer.has_pps_limit) {
                    const estimated_pps = @max(mbr.ul_mbr / 12000, 100);
                    qer.setPPS(@truncate(estimated_pps));
                }
            }

            // Update GBR if present
            if (decoded.gbr) |gbr| {
                qer.setGBR(gbr.ul_gbr, gbr.dl_gbr);
                print("PFCP: Updated QER {} GBR - UL: {} bps, DL: {} bps\n", .{
                    qer_id,
                    gbr.ul_gbr,
                    gbr.dl_gbr,
                });
            }
        } else {
            print("PFCP: QER {} not found for update, creating new\n", .{qer_id});

            // Create new QER if not found (treat as create)
            const new_qer = convertCreateQERtoQER(decoded);
            session.addQER(new_qer) catch {
                print("PFCP: Failed to add QER {} to session\n", .{qer_id});
            };
        }
    }

    if (qer_update_count > 0) {
        print("PFCP: Session modification completed for SEID 0x{x}, updated {} QERs\n", .{ seid, qer_update_count });
    } else {
        print("PFCP: Session modification completed for SEID 0x{x}\n", .{seid});
    }
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
