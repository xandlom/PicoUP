// Core types and constants for PicoUP
// This module defines the fundamental data structures used throughout the UPF

const std = @import("std");

// Configuration constants
pub const WORKER_THREADS = 4;
pub const QUEUE_SIZE = 1000;
pub const PFCP_PORT = 8805;
pub const GTPU_PORT = 2152;
pub const MAX_SESSIONS = 100;

// Packet Detection Information (PDI) - optional matching criteria
// Follows 3GPP TS 29.244 Section 5.2.1.2
pub const PDI = struct {
    // Mandatory fields
    source_interface: u8, // 0=Access (N3), 1=Core (N6), 2=N9 (UPF-to-UPF)

    // Optional fields - use flags to indicate presence
    has_fteid: bool,
    teid: u32, // GTP-U TEID to match (F-TEID)

    has_ue_ip: bool,
    ue_ip: [4]u8, // UE IP address to match

    has_application_id: bool,
    application_id: u32, // Application identifier

    has_sdf_filter: bool,
    sdf_protocol: u8, // IP protocol (6=TCP, 17=UDP, 0=any)
    sdf_dest_port_low: u16, // Destination port range low
    sdf_dest_port_high: u16, // Destination port range high

    pub fn init(source_interface: u8) PDI {
        return PDI{
            .source_interface = source_interface,
            .has_fteid = false,
            .teid = 0,
            .has_ue_ip = false,
            .ue_ip = .{ 0, 0, 0, 0 },
            .has_application_id = false,
            .application_id = 0,
            .has_sdf_filter = false,
            .sdf_protocol = 0,
            .sdf_dest_port_low = 0,
            .sdf_dest_port_high = 0,
        };
    }

    pub fn setFTeid(self: *PDI, teid: u32) void {
        self.has_fteid = true;
        self.teid = teid;
    }

    pub fn setUeIp(self: *PDI, ip: [4]u8) void {
        self.has_ue_ip = true;
        self.ue_ip = ip;
    }

    pub fn setApplicationId(self: *PDI, app_id: u32) void {
        self.has_application_id = true;
        self.application_id = app_id;
    }

    pub fn setSdfFilter(self: *PDI, protocol: u8, port_low: u16, port_high: u16) void {
        self.has_sdf_filter = true;
        self.sdf_protocol = protocol;
        self.sdf_dest_port_low = port_low;
        self.sdf_dest_port_high = port_high;
    }
};

// Packet Detection Rule (PDR)
// Defines how to identify packets that belong to a session
pub const PDR = struct {
    id: u16,
    precedence: u32,
    pdi: PDI, // Packet Detection Information
    far_id: u16, // Associated FAR
    qer_id: u16, // Associated QER ID (optional)
    has_qer: bool, // Whether QER is configured
    allocated: bool,

    pub fn init(id: u16, precedence: u32, source_interface: u8, teid: u32, far_id: u16) PDR {
        var pdi = PDI.init(source_interface);
        pdi.setFTeid(teid);
        return PDR{
            .id = id,
            .precedence = precedence,
            .pdi = pdi,
            .far_id = far_id,
            .qer_id = 0,
            .has_qer = false,
            .allocated = true,
        };
    }

    // Set QER reference
    pub fn setQER(self: *PDR, qer_id: u16) void {
        self.qer_id = qer_id;
        self.has_qer = true;
    }

    // Legacy accessors for backward compatibility
    pub fn getSourceInterface(self: *const PDR) u8 {
        return self.pdi.source_interface;
    }

    pub fn getTeid(self: *const PDR) u32 {
        return self.pdi.teid;
    }
};

// Forwarding Action Rule (FAR)
// Defines what action to take when a PDR matches
pub const FAR = struct {
    id: u16,
    action: u8, // 0=Drop, 1=Forward, 2=Buffer
    dest_interface: u8, // 0=Access (N3), 1=Core (N6), 2=N9 (UPF-to-UPF)
    outer_header_creation: bool,
    teid: u32, // TEID for encapsulation
    ipv4: [4]u8, // Destination IP for encapsulation
    allocated: bool,

    pub fn init(id: u16, action: u8, dest_interface: u8) FAR {
        return FAR{
            .id = id,
            .action = action,
            .dest_interface = dest_interface,
            .outer_header_creation = false,
            .teid = 0,
            .ipv4 = .{ 0, 0, 0, 0 },
            .allocated = true,
        };
    }

    pub fn setOuterHeader(self: *FAR, teid: u32, ipv4: [4]u8) void {
        self.outer_header_creation = true;
        self.teid = teid;
        self.ipv4 = ipv4;
    }
};

// QoS Enforcement Rule (QER)
// Defines QoS parameters and rate limiting for a flow
// Based on 3GPP TS 29.244 Section 5.2.1.11
pub const QER = struct {
    id: u16, // Unique QER identifier
    qfi: u8, // QoS Flow Identifier (0-63)

    // Rate limiting parameters
    has_mbr: bool, // Maximum Bit Rate configured
    mbr_uplink: u64, // MBR uplink in bits/second
    mbr_downlink: u64, // MBR downlink in bits/second

    has_gbr: bool, // Guaranteed Bit Rate configured (future)
    gbr_uplink: u64, // GBR uplink in bits/second
    gbr_downlink: u64, // GBR downlink in bits/second

    has_pps_limit: bool, // Packets Per Second limit configured
    pps_limit: u32, // Maximum packets per second

    // Token bucket state for rate limiting
    mbr_tokens: std.atomic.Value(u64), // Available bits (for MBR)
    pps_tokens: std.atomic.Value(u32), // Available packets (for PPS)
    last_refill: std.atomic.Value(i64), // Timestamp of last token refill (ns)

    // QoS parameters (for future implementation)
    packet_delay_budget: u32, // Max delay in milliseconds
    packet_error_rate: u8, // Target error rate (10^-N)

    allocated: bool,
    mutex: std.Thread.Mutex, // Protects token bucket operations

    pub fn init(id: u16, qfi: u8) QER {
        return QER{
            .id = id,
            .qfi = qfi,
            .has_mbr = false,
            .mbr_uplink = 0,
            .mbr_downlink = 0,
            .has_gbr = false,
            .gbr_uplink = 0,
            .gbr_downlink = 0,
            .has_pps_limit = false,
            .pps_limit = 0,
            .mbr_tokens = std.atomic.Value(u64).init(0),
            .pps_tokens = std.atomic.Value(u32).init(0),
            .last_refill = std.atomic.Value(i64).init(@intCast(std.time.nanoTimestamp())),
            .packet_delay_budget = 0,
            .packet_error_rate = 0,
            .allocated = true,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn setMBR(self: *QER, uplink: u64, downlink: u64) void {
        self.has_mbr = true;
        self.mbr_uplink = uplink;
        self.mbr_downlink = downlink;
        // Initialize token buckets to full capacity (1 second worth)
        self.mbr_tokens.store(uplink, .seq_cst);
    }

    pub fn setPPS(self: *QER, limit: u32) void {
        self.has_pps_limit = true;
        self.pps_limit = limit;
        // Initialize token bucket to full capacity (1 second worth)
        self.pps_tokens.store(limit, .seq_cst);
    }

    pub fn setGBR(self: *QER, uplink: u64, downlink: u64) void {
        self.has_gbr = true;
        self.gbr_uplink = uplink;
        self.gbr_downlink = downlink;
    }
};
