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
const QER = types.QER;

// Additional IE type constants not in zig-pfcp types
const IE_FAR_ID: u16 = 108;
const IE_QER_ID_IN_PDR: u16 = 109;

// Parsed QER data from PFCP message
const ParsedQER = struct {
    qer_id: u32,
    qfi: u8,
    has_gate_status: bool,
    ul_gate_open: bool,
    dl_gate_open: bool,
    has_mbr: bool,
    mbr_uplink: u64,
    mbr_downlink: u64,
    has_gbr: bool,
    gbr_uplink: u64,
    gbr_downlink: u64,

    fn init(qer_id: u32) ParsedQER {
        return ParsedQER{
            .qer_id = qer_id,
            .qfi = 5, // Default QFI
            .has_gate_status = false,
            .ul_gate_open = true,
            .dl_gate_open = true,
            .has_mbr = false,
            .mbr_uplink = 0,
            .mbr_downlink = 0,
            .has_gbr = false,
            .gbr_uplink = 0,
            .gbr_downlink = 0,
        };
    }
};

// Parsed PDR data from PFCP message
const ParsedPDR = struct {
    pdr_id: u16,
    precedence: u32,
    source_interface: u8,
    has_fteid: bool,
    teid: u32,
    far_id: u16,
    has_qer: bool,
    qer_id: u16,

    fn init(pdr_id: u16) ParsedPDR {
        return ParsedPDR{
            .pdr_id = pdr_id,
            .precedence = 0,
            .source_interface = 0,
            .has_fteid = false,
            .teid = 0,
            .far_id = 0,
            .has_qer = false,
            .qer_id = 0,
        };
    }
};

// Parsed FAR data from PFCP message
const ParsedFAR = struct {
    far_id: u16,
    action: u8, // 0=Drop, 1=Forward, 2=Buffer
    dest_interface: u8,
    has_outer_header_creation: bool,
    ohc_teid: u32,
    ohc_ipv4: [4]u8,

    fn init(far_id: u16) ParsedFAR {
        return ParsedFAR{
            .far_id = far_id,
            .action = 0,
            .dest_interface = 0,
            .has_outer_header_creation = false,
            .ohc_teid = 0,
            .ohc_ipv4 = .{ 0, 0, 0, 0 },
        };
    }
};

// Bitrate result type for MBR/GBR decoding
const BitrateResult = struct { ul: u64, dl: u64 };

// Decode MBR IE (3GPP TS 29.244 Section 8.2.27)
// MBR is 10 bytes: 5 bytes UL (40 bits) + 5 bytes DL (40 bits)
fn decodeMBR(data: []const u8) BitrateResult {
    if (data.len < 10) {
        return .{ .ul = 0, .dl = 0 };
    }
    // Uplink: 5 bytes (40 bits) in kbps
    const ul_high: u64 = data[0];
    const ul_low: u64 = std.mem.readInt(u32, data[1..5], .big);
    const ul_kbps = (ul_high << 32) | ul_low;

    // Downlink: 5 bytes (40 bits) in kbps
    const dl_high: u64 = data[5];
    const dl_low: u64 = std.mem.readInt(u32, data[6..10], .big);
    const dl_kbps = (dl_high << 32) | dl_low;

    // Convert from kbps to bps
    return .{ .ul = ul_kbps * 1000, .dl = dl_kbps * 1000 };
}

// Decode GBR IE (3GPP TS 29.244 Section 8.2.28)
// GBR has same format as MBR
fn decodeGBR(data: []const u8) BitrateResult {
    return decodeMBR(data);
}

// Decode Gate Status IE (3GPP TS 29.244 Section 8.2.26)
fn decodeGateStatus(data: []const u8) struct { ul_open: bool, dl_open: bool } {
    if (data.len < 1) {
        return .{ .ul_open = true, .dl_open = true };
    }
    // UL gate: bits 0-1, DL gate: bits 2-3
    // 0 = OPEN, 1 = CLOSED
    const ul_gate = data[0] & 0x03;
    const dl_gate = (data[0] >> 2) & 0x03;
    return .{ .ul_open = (ul_gate == 0), .dl_open = (dl_gate == 0) };
}

// Decode QFI IE (3GPP TS 29.244 Section 8.2.89)
fn decodeQFI(data: []const u8) u8 {
    if (data.len < 1) {
        return 5; // Default QFI
    }
    return data[0] & 0x3F; // QFI is 6 bits
}

// Parse Create QER grouped IE
fn parseCreateQER(reader: *pfcp.marshal.Reader, ie_length: u16) ?ParsedQER {
    const ie_end = reader.pos + ie_length;
    var parsed_qer: ?ParsedQER = null;

    while (reader.pos < ie_end and reader.remaining() >= 4) {
        const sub_ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const sub_ie_end = reader.pos + sub_ie_header.length;

        if (sub_ie_end > ie_end) break;

        switch (sub_ie_header.ie_type) {
            IE_QER_ID_IN_PDR => { // QER ID
                if (sub_ie_header.length >= 4) {
                    const qer_id = reader.readU32() catch break;
                    parsed_qer = ParsedQER.init(qer_id);
                    print("PFCP: Parsed QER ID: {}\n", .{qer_id});
                }
            },
            @intFromEnum(pfcp.types.IEType.gate_status) => {
                if (parsed_qer != null and sub_ie_header.length >= 1) {
                    const data = reader.readBytes(sub_ie_header.length) catch break;
                    const gate = decodeGateStatus(data);
                    parsed_qer.?.has_gate_status = true;
                    parsed_qer.?.ul_gate_open = gate.ul_open;
                    parsed_qer.?.dl_gate_open = gate.dl_open;
                    print("PFCP: Parsed Gate Status - UL: {}, DL: {}\n", .{ gate.ul_open, gate.dl_open });
                }
            },
            @intFromEnum(pfcp.types.IEType.mbr) => {
                if (parsed_qer != null and sub_ie_header.length >= 10) {
                    const data = reader.readBytes(sub_ie_header.length) catch break;
                    const mbr = decodeMBR(data);
                    parsed_qer.?.has_mbr = true;
                    parsed_qer.?.mbr_uplink = mbr.ul;
                    parsed_qer.?.mbr_downlink = mbr.dl;
                    print("PFCP: Parsed MBR - UL: {} bps, DL: {} bps\n", .{ mbr.ul, mbr.dl });
                }
            },
            @intFromEnum(pfcp.types.IEType.gbr) => {
                if (parsed_qer != null and sub_ie_header.length >= 10) {
                    const data = reader.readBytes(sub_ie_header.length) catch break;
                    const gbr = decodeGBR(data);
                    parsed_qer.?.has_gbr = true;
                    parsed_qer.?.gbr_uplink = gbr.ul;
                    parsed_qer.?.gbr_downlink = gbr.dl;
                    print("PFCP: Parsed GBR - UL: {} bps, DL: {} bps\n", .{ gbr.ul, gbr.dl });
                }
            },
            @intFromEnum(pfcp.types.IEType.qfi) => {
                if (parsed_qer != null and sub_ie_header.length >= 1) {
                    const data = reader.readBytes(sub_ie_header.length) catch break;
                    parsed_qer.?.qfi = decodeQFI(data);
                    print("PFCP: Parsed QFI: {}\n", .{parsed_qer.?.qfi});
                }
            },
            else => {
                // Skip unknown sub-IE
                reader.pos += sub_ie_header.length;
            },
        }

        // Ensure we're at the end of this sub-IE
        reader.pos = sub_ie_end;
    }

    return parsed_qer;
}

// Parse PDI grouped IE
fn parsePDI(reader: *pfcp.marshal.Reader, ie_length: u16, parsed_pdr: *ParsedPDR) void {
    const ie_end = reader.pos + ie_length;

    while (reader.pos < ie_end and reader.remaining() >= 4) {
        const sub_ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const sub_ie_end = reader.pos + sub_ie_header.length;

        if (sub_ie_end > ie_end) break;

        switch (sub_ie_header.ie_type) {
            @intFromEnum(pfcp.types.IEType.source_interface) => {
                if (sub_ie_header.length >= 1) {
                    parsed_pdr.source_interface = reader.readByte() catch break;
                }
            },
            @intFromEnum(pfcp.types.IEType.f_teid) => {
                const fteid = pfcp.marshal.decodeFTEID(reader, sub_ie_header.length) catch break;
                parsed_pdr.has_fteid = true;
                parsed_pdr.teid = fteid.teid;
                print("PFCP: Parsed F-TEID: 0x{x}\n", .{fteid.teid});
            },
            else => {
                reader.pos += sub_ie_header.length;
            },
        }

        reader.pos = sub_ie_end;
    }
}

// Parse Create PDR grouped IE
fn parseCreatePDR(reader: *pfcp.marshal.Reader, ie_length: u16) ?ParsedPDR {
    const ie_end = reader.pos + ie_length;
    var parsed_pdr: ?ParsedPDR = null;

    while (reader.pos < ie_end and reader.remaining() >= 4) {
        const sub_ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const sub_ie_end = reader.pos + sub_ie_header.length;

        if (sub_ie_end > ie_end) break;

        switch (sub_ie_header.ie_type) {
            @intFromEnum(pfcp.types.IEType.pdr_id) => {
                if (sub_ie_header.length >= 2) {
                    const pdr_id = reader.readU16() catch break;
                    parsed_pdr = ParsedPDR.init(pdr_id);
                    print("PFCP: Parsed PDR ID: {}\n", .{pdr_id});
                }
            },
            @intFromEnum(pfcp.types.IEType.precedence) => {
                if (parsed_pdr != null and sub_ie_header.length >= 4) {
                    parsed_pdr.?.precedence = reader.readU32() catch break;
                }
            },
            @intFromEnum(pfcp.types.IEType.pdi) => {
                if (parsed_pdr != null) {
                    parsePDI(reader, sub_ie_header.length, &parsed_pdr.?);
                }
            },
            IE_FAR_ID => { // FAR ID
                if (parsed_pdr != null and sub_ie_header.length >= 4) {
                    const far_id = reader.readU32() catch break;
                    parsed_pdr.?.far_id = @truncate(far_id);
                }
            },
            IE_QER_ID_IN_PDR => { // QER ID reference in PDR
                if (parsed_pdr != null and sub_ie_header.length >= 4) {
                    const qer_id = reader.readU32() catch break;
                    parsed_pdr.?.has_qer = true;
                    parsed_pdr.?.qer_id = @truncate(qer_id);
                    print("PFCP: PDR {} references QER {}\n", .{ parsed_pdr.?.pdr_id, qer_id });
                }
            },
            else => {
                reader.pos += sub_ie_header.length;
            },
        }

        reader.pos = sub_ie_end;
    }

    return parsed_pdr;
}

// Parse Forwarding Parameters grouped IE
fn parseForwardingParameters(reader: *pfcp.marshal.Reader, ie_length: u16, parsed_far: *ParsedFAR) void {
    const ie_end = reader.pos + ie_length;

    while (reader.pos < ie_end and reader.remaining() >= 4) {
        const sub_ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const sub_ie_end = reader.pos + sub_ie_header.length;

        if (sub_ie_end > ie_end) break;

        switch (sub_ie_header.ie_type) {
            @intFromEnum(pfcp.types.IEType.destination_interface) => {
                if (sub_ie_header.length >= 1) {
                    parsed_far.dest_interface = reader.readByte() catch break;
                }
            },
            @intFromEnum(pfcp.types.IEType.outer_header_creation) => {
                if (sub_ie_header.length >= 1) {
                    const flags = reader.readByte() catch break;
                    _ = flags;
                    parsed_far.has_outer_header_creation = true;

                    // Read TEID if present (assumes GTP-U/UDP/IPv4)
                    if (sub_ie_header.length >= 5) {
                        parsed_far.ohc_teid = reader.readU32() catch break;
                    }
                    // Read IPv4 if present
                    if (sub_ie_header.length >= 9) {
                        const ip_bytes = reader.readBytes(4) catch break;
                        @memcpy(&parsed_far.ohc_ipv4, ip_bytes);
                    }
                    print("PFCP: Parsed Outer Header Creation - TEID: 0x{x}, IP: {}.{}.{}.{}\n", .{
                        parsed_far.ohc_teid,
                        parsed_far.ohc_ipv4[0],
                        parsed_far.ohc_ipv4[1],
                        parsed_far.ohc_ipv4[2],
                        parsed_far.ohc_ipv4[3],
                    });
                }
            },
            else => {
                reader.pos += sub_ie_header.length;
            },
        }

        reader.pos = sub_ie_end;
    }
}

// Parse Create FAR grouped IE
fn parseCreateFAR(reader: *pfcp.marshal.Reader, ie_length: u16) ?ParsedFAR {
    const ie_end = reader.pos + ie_length;
    var parsed_far: ?ParsedFAR = null;

    while (reader.pos < ie_end and reader.remaining() >= 4) {
        const sub_ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const sub_ie_end = reader.pos + sub_ie_header.length;

        if (sub_ie_end > ie_end) break;

        switch (sub_ie_header.ie_type) {
            IE_FAR_ID => { // FAR ID
                if (sub_ie_header.length >= 4) {
                    const far_id = reader.readU32() catch break;
                    parsed_far = ParsedFAR.init(@truncate(far_id));
                    print("PFCP: Parsed FAR ID: {}\n", .{far_id});
                }
            },
            @intFromEnum(pfcp.types.IEType.apply_action) => {
                if (parsed_far != null and sub_ie_header.length >= 1) {
                    const action_flags = reader.readByte() catch break;
                    // Bit 0 = DROP, Bit 1 = FORW, Bit 2 = BUFF
                    if (action_flags & 0x01 != 0) {
                        parsed_far.?.action = 0; // Drop
                    } else if (action_flags & 0x02 != 0) {
                        parsed_far.?.action = 1; // Forward
                    } else if (action_flags & 0x04 != 0) {
                        parsed_far.?.action = 2; // Buffer
                    }
                    // Skip remaining bytes if length > 1
                    if (sub_ie_header.length > 1) {
                        reader.pos += sub_ie_header.length - 1;
                    }
                }
            },
            @intFromEnum(pfcp.types.IEType.forwarding_parameters) => {
                if (parsed_far != null) {
                    parseForwardingParameters(reader, sub_ie_header.length, &parsed_far.?);
                }
            },
            else => {
                reader.pos += sub_ie_header.length;
            },
        }

        reader.pos = sub_ie_end;
    }

    return parsed_far;
}

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

    // Parse IEs from the message body
    var cp_seid: u64 = 0;
    var found_fseid = false;

    // Arrays to store parsed rules (support up to 16 of each)
    var parsed_pdrs: [16]ParsedPDR = undefined;
    var parsed_fars: [16]ParsedFAR = undefined;
    var parsed_qers: [16]ParsedQER = undefined;
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
            .create_pdr => {
                if (pdr_count < 16) {
                    if (parseCreatePDR(reader, ie_header.length)) |parsed| {
                        parsed_pdrs[pdr_count] = parsed;
                        pdr_count += 1;
                    }
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .create_far => {
                if (far_count < 16) {
                    if (parseCreateFAR(reader, ie_header.length)) |parsed| {
                        parsed_fars[far_count] = parsed;
                        far_count += 1;
                    }
                } else {
                    reader.pos += ie_header.length;
                }
            },
            .create_qer => {
                if (qer_count < 16) {
                    if (parseCreateQER(reader, ie_header.length)) |parsed| {
                        parsed_qers[qer_count] = parsed;
                        qer_count += 1;
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
        // Add parsed QERs to session
        for (0..qer_count) |i| {
            const parsed = parsed_qers[i];
            var qer = QER.init(@truncate(parsed.qer_id), parsed.qfi);

            // Configure MBR if present
            if (parsed.has_mbr) {
                qer.setMBR(parsed.mbr_uplink, parsed.mbr_downlink);
                print("PFCP: QER {} configured with MBR UL: {} bps, DL: {} bps\n", .{
                    parsed.qer_id,
                    parsed.mbr_uplink,
                    parsed.mbr_downlink,
                });
            }

            // Configure GBR if present
            if (parsed.has_gbr) {
                qer.setGBR(parsed.gbr_uplink, parsed.gbr_downlink);
            }

            // Set a default PPS limit if MBR is configured but PPS is not explicitly set
            // This provides basic rate limiting even without explicit PPS
            if (parsed.has_mbr and !qer.has_pps_limit) {
                // Estimate PPS based on MBR (assume 1500 byte MTU = 12000 bits)
                const estimated_pps = @max(parsed.mbr_uplink / 12000, 100);
                qer.setPPS(@truncate(estimated_pps));
                print("PFCP: QER {} auto-configured with PPS: {}\n", .{ parsed.qer_id, estimated_pps });
            }

            session.addQER(qer) catch {
                print("PFCP: Failed to add QER {} to session\n", .{parsed.qer_id});
            };
        }

        // Add parsed FARs to session
        for (0..far_count) |i| {
            const parsed = parsed_fars[i];
            var far = FAR.init(parsed.far_id, parsed.action, parsed.dest_interface);

            if (parsed.has_outer_header_creation) {
                far.setOuterHeader(parsed.ohc_teid, parsed.ohc_ipv4);
            }

            session.addFAR(far) catch {
                print("PFCP: Failed to add FAR {} to session\n", .{parsed.far_id});
            };
        }

        // Add parsed PDRs to session
        for (0..pdr_count) |i| {
            const parsed = parsed_pdrs[i];
            var pdr = PDR.init(
                parsed.pdr_id,
                parsed.precedence,
                parsed.source_interface,
                parsed.teid,
                parsed.far_id,
            );

            // Associate QER if present
            if (parsed.has_qer) {
                pdr.setQER(parsed.qer_id);
            }

            session.addPDR(pdr) catch {
                print("PFCP: Failed to add PDR {} to session\n", .{parsed.pdr_id});
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

// Parse Update QER grouped IE (same format as Create QER)
fn parseUpdateQER(reader: *pfcp.marshal.Reader, ie_length: u16) ?ParsedQER {
    return parseCreateQER(reader, ie_length);
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

    const session = session_manager.findSession(seid) orelse {
        print("PFCP: Session 0x{x} not found\n", .{seid});
        sendSessionModificationResponse(socket, req_header, client_addr, .session_context_not_found);
        return;
    };

    // Arrays to store parsed updates (support up to 16 of each)
    var updated_qers: [16]ParsedQER = undefined;
    var qer_update_count: usize = 0;

    // Parse IEs
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .update_qer => {
                if (qer_update_count < 16) {
                    if (parseUpdateQER(reader, ie_header.length)) |parsed| {
                        updated_qers[qer_update_count] = parsed;
                        qer_update_count += 1;
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
        const parsed = updated_qers[i];

        // Find existing QER and update it
        if (session.findQERById(@truncate(parsed.qer_id))) |qer| {
            // Update MBR if present in update
            if (parsed.has_mbr) {
                qer.setMBR(parsed.mbr_uplink, parsed.mbr_downlink);
                print("PFCP: Updated QER {} MBR - UL: {} bps, DL: {} bps\n", .{
                    parsed.qer_id,
                    parsed.mbr_uplink,
                    parsed.mbr_downlink,
                });
            }

            // Update GBR if present
            if (parsed.has_gbr) {
                qer.setGBR(parsed.gbr_uplink, parsed.gbr_downlink);
                print("PFCP: Updated QER {} GBR - UL: {} bps, DL: {} bps\n", .{
                    parsed.qer_id,
                    parsed.gbr_uplink,
                    parsed.gbr_downlink,
                });
            }

            // Update PPS based on new MBR if needed
            if (parsed.has_mbr and !qer.has_pps_limit) {
                const estimated_pps = @max(parsed.mbr_uplink / 12000, 100);
                qer.setPPS(@truncate(estimated_pps));
            }
        } else {
            print("PFCP: QER {} not found for update, creating new\n", .{parsed.qer_id});

            // Create new QER if not found (treat as create)
            var qer = QER.init(@truncate(parsed.qer_id), parsed.qfi);
            if (parsed.has_mbr) {
                qer.setMBR(parsed.mbr_uplink, parsed.mbr_downlink);
            }
            if (parsed.has_gbr) {
                qer.setGBR(parsed.gbr_uplink, parsed.gbr_downlink);
            }
            if (parsed.has_mbr and !qer.has_pps_limit) {
                const estimated_pps = @max(parsed.mbr_uplink / 12000, 100);
                qer.setPPS(@truncate(estimated_pps));
            }

            session.addQER(qer) catch {
                print("PFCP: Failed to add QER {} to session\n", .{parsed.qer_id});
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
