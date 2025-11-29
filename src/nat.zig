// NAT (Network Address Translation) table management
// Implements SNAT for uplink (UE → External) and reverse NAT for downlink (External → UE)
// Based on RFC 3022 (Traditional IP NAT)

const std = @import("std");
const types = @import("types.zig");

const Atomic = std.atomic.Value;
const Mutex = std.Thread.Mutex;
const print = std.debug.print;
const time = std.time;

// NAT table configuration
pub const NAT_TABLE_SIZE = 4096;
pub const NAT_TIMEOUT_NS = 120 * time.ns_per_s; // 120 seconds default timeout
pub const NAT_PORT_START: u16 = 10000;
pub const NAT_PORT_END: u16 = 60000;

/// NAT entry representing a single address/port mapping
pub const NATEntry = struct {
    // Original UE address/port (internal)
    ue_ip: [4]u8,
    ue_port: u16,
    protocol: u8, // 6=TCP, 17=UDP

    // Translated address/port (external)
    external_ip: [4]u8,
    external_port: u16,

    // Session binding
    seid: u64, // PFCP session ID for cleanup

    // State tracking
    last_activity: Atomic(i64), // Timestamp for timeout
    packet_count: Atomic(u64), // Traffic counter
    byte_count: Atomic(u64), // Byte counter
    allocated: bool,

    /// Check if this entry has expired
    pub fn isExpired(self: *const NATEntry) bool {
        const now = time.nanoTimestamp();
        const last = self.last_activity.load(.seq_cst);
        return (now - last) > NAT_TIMEOUT_NS;
    }

    /// Update last activity timestamp
    pub fn touch(self: *NATEntry) void {
        _ = self.last_activity.store(@intCast(time.nanoTimestamp()), .seq_cst);
    }

    /// Update traffic counters
    pub fn updateStats(self: *NATEntry, bytes: usize) void {
        _ = self.packet_count.fetchAdd(1, .seq_cst);
        _ = self.byte_count.fetchAdd(bytes, .seq_cst);
        self.touch();
    }
};

/// NAT table managing all active translations
pub const NATTable = struct {
    entries: [NAT_TABLE_SIZE]NATEntry,
    entry_count: Atomic(usize),
    next_port: Atomic(u16),
    external_ip: [4]u8, // UPF's external IP for SNAT
    mutex: Mutex,

    // Statistics
    lookups: Atomic(u64),
    hits: Atomic(u64),
    misses: Atomic(u64),
    creates: Atomic(u64),
    expirations: Atomic(u64),

    pub fn init(external_ip: [4]u8) NATTable {
        var table = NATTable{
            .entries = undefined,
            .entry_count = Atomic(usize).init(0),
            .next_port = Atomic(u16).init(NAT_PORT_START),
            .external_ip = external_ip,
            .mutex = .{},
            .lookups = Atomic(u64).init(0),
            .hits = Atomic(u64).init(0),
            .misses = Atomic(u64).init(0),
            .creates = Atomic(u64).init(0),
            .expirations = Atomic(u64).init(0),
        };

        // Initialize all entries as unallocated
        for (&table.entries) |*entry| {
            entry.allocated = false;
        }

        return table;
    }

    /// Allocate the next available port
    fn allocatePort(self: *NATTable) u16 {
        var port = self.next_port.fetchAdd(1, .seq_cst);

        // Wrap around if we exceed the range
        if (port > NAT_PORT_END) {
            port = NAT_PORT_START;
            self.next_port.store(NAT_PORT_START + 1, .seq_cst);
        }

        return port;
    }

    /// Find or create NAT mapping for uplink (UE → External)
    /// Returns pointer to NAT entry, or null if table is full
    pub fn getOrCreateMapping(
        self: *NATTable,
        ue_ip: [4]u8,
        ue_port: u16,
        protocol: u8,
        seid: u64,
    ) ?*NATEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.lookups.fetchAdd(1, .seq_cst);

        // First, look for existing mapping
        for (&self.entries) |*entry| {
            if (entry.allocated and
                !entry.isExpired() and
                std.mem.eql(u8, &entry.ue_ip, &ue_ip) and
                entry.ue_port == ue_port and
                entry.protocol == protocol)
            {
                _ = self.hits.fetchAdd(1, .seq_cst);
                entry.touch();
                return entry;
            }
        }

        _ = self.misses.fetchAdd(1, .seq_cst);

        // Create new mapping - find empty or expired slot
        for (&self.entries) |*entry| {
            if (!entry.allocated or entry.isExpired()) {
                const was_allocated = entry.allocated;

                entry.* = NATEntry{
                    .ue_ip = ue_ip,
                    .ue_port = ue_port,
                    .protocol = protocol,
                    .external_ip = self.external_ip,
                    .external_port = self.allocatePort(),
                    .seid = seid,
                    .last_activity = Atomic(i64).init(@intCast(time.nanoTimestamp())),
                    .packet_count = Atomic(u64).init(0),
                    .byte_count = Atomic(u64).init(0),
                    .allocated = true,
                };

                if (!was_allocated) {
                    _ = self.entry_count.fetchAdd(1, .seq_cst);
                }
                _ = self.creates.fetchAdd(1, .seq_cst);

                print("NAT: Created mapping {}.{}.{}.{}:{} -> {}.{}.{}.{}:{} (proto={}, seid=0x{x})\n", .{
                    ue_ip[0],        ue_ip[1],             ue_ip[2],             ue_ip[3],             ue_port,
                    entry.external_ip[0], entry.external_ip[1], entry.external_ip[2], entry.external_ip[3], entry.external_port,
                    protocol,        seid,
                });

                return entry;
            }
        }

        print("NAT: Table full, cannot create mapping for {}.{}.{}.{}:{}\n", .{
            ue_ip[0], ue_ip[1], ue_ip[2], ue_ip[3], ue_port,
        });
        return null; // Table full
    }

    /// Lookup NAT mapping by external port (for downlink/reverse NAT)
    /// Used when packets arrive from data network
    pub fn lookupByExternal(
        self: *NATTable,
        external_port: u16,
        protocol: u8,
    ) ?*NATEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.lookups.fetchAdd(1, .seq_cst);

        for (&self.entries) |*entry| {
            if (entry.allocated and
                !entry.isExpired() and
                entry.external_port == external_port and
                entry.protocol == protocol)
            {
                _ = self.hits.fetchAdd(1, .seq_cst);
                entry.touch();
                return entry;
            }
        }

        _ = self.misses.fetchAdd(1, .seq_cst);
        return null;
    }

    /// Lookup NAT mapping by UE address/port (for checking existing mappings)
    pub fn lookupByUe(
        self: *NATTable,
        ue_ip: [4]u8,
        ue_port: u16,
        protocol: u8,
    ) ?*NATEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.entries) |*entry| {
            if (entry.allocated and
                !entry.isExpired() and
                std.mem.eql(u8, &entry.ue_ip, &ue_ip) and
                entry.ue_port == ue_port and
                entry.protocol == protocol)
            {
                return entry;
            }
        }

        return null;
    }

    /// Delete all NAT entries associated with a PFCP session
    /// Called when session is deleted
    pub fn deleteBySession(self: *NATTable, seid: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var deleted: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.allocated and entry.seid == seid) {
                entry.allocated = false;
                deleted += 1;
                _ = self.entry_count.fetchSub(1, .seq_cst);
            }
        }

        if (deleted > 0) {
            print("NAT: Deleted {} entries for session 0x{x}\n", .{ deleted, seid });
        }

        return deleted;
    }

    /// Clean up expired entries
    /// Should be called periodically
    pub fn cleanup(self: *NATTable) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var cleaned: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.allocated and entry.isExpired()) {
                print("NAT: Expired mapping {}.{}.{}.{}:{} -> {}.{}.{}.{}:{}\n", .{
                    entry.ue_ip[0],        entry.ue_ip[1],        entry.ue_ip[2],        entry.ue_ip[3],        entry.ue_port,
                    entry.external_ip[0], entry.external_ip[1], entry.external_ip[2], entry.external_ip[3], entry.external_port,
                });
                entry.allocated = false;
                cleaned += 1;
                _ = self.entry_count.fetchSub(1, .seq_cst);
                _ = self.expirations.fetchAdd(1, .seq_cst);
            }
        }

        return cleaned;
    }

    /// Get current statistics
    pub fn getStats(self: *NATTable) NATStats {
        return NATStats{
            .active_entries = self.entry_count.load(.seq_cst),
            .total_lookups = self.lookups.load(.seq_cst),
            .hits = self.hits.load(.seq_cst),
            .misses = self.misses.load(.seq_cst),
            .creates = self.creates.load(.seq_cst),
            .expirations = self.expirations.load(.seq_cst),
        };
    }
};

/// NAT statistics for monitoring
pub const NATStats = struct {
    active_entries: usize,
    total_lookups: u64,
    hits: u64,
    misses: u64,
    creates: u64,
    expirations: u64,
};

/// NAT cleanup thread function
/// Periodically cleans up expired NAT entries
pub fn natCleanupThread(
    nat_table: *NATTable,
    should_stop: *Atomic(bool),
) void {
    print("NAT cleanup thread started\n", .{});

    while (!should_stop.load(.seq_cst)) {
        // Run cleanup every 30 seconds
        std.Thread.sleep(30 * time.ns_per_s);

        const cleaned = nat_table.cleanup();
        if (cleaned > 0) {
            print("NAT: Cleaned {} expired entries\n", .{cleaned});
        }
    }

    print("NAT cleanup thread stopped\n", .{});
}
