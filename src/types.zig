// Core types and constants for PicoUP
// This module defines the fundamental data structures used throughout the UPF

const std = @import("std");

// Configuration constants
pub const WORKER_THREADS = 4;
pub const QUEUE_SIZE = 1000;
pub const PFCP_PORT = 8805;
pub const GTPU_PORT = 2152;
pub const MAX_SESSIONS = 100;

// Packet Detection Rule (PDR)
// Defines how to identify packets that belong to a session
pub const PDR = struct {
    id: u16,
    precedence: u32,
    source_interface: u8, // 0=Access (N3), 1=Core (N6), 2=N9 (UPF-to-UPF)
    teid: u32, // GTP-U TEID to match
    far_id: u16, // Associated FAR
    allocated: bool,

    pub fn init(id: u16, precedence: u32, source_interface: u8, teid: u32, far_id: u16) PDR {
        return PDR{
            .id = id,
            .precedence = precedence,
            .source_interface = source_interface,
            .teid = teid,
            .far_id = far_id,
            .allocated = true,
        };
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
