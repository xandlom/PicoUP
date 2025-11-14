// PFCP Session management
// This module handles session state, PDR/FAR lifecycle, and session lookups

const std = @import("std");
const types = @import("types.zig");
const PDR = types.PDR;
const FAR = types.FAR;

const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;
const print = std.debug.print;

// PFCP Session
// Represents a PFCP session with associated PDRs and FARs
pub const Session = struct {
    seid: u64,
    cp_fseid: u64, // Control Plane F-SEID
    up_fseid: u64, // User Plane F-SEID (local)
    pdrs: [16]PDR,
    fars: [16]FAR,
    pdr_count: u8,
    far_count: u8,
    allocated: bool,
    mutex: Mutex,

    pub fn init(seid: u64, cp_fseid: u64, up_fseid: u64) Session {
        var session = Session{
            .seid = seid,
            .cp_fseid = cp_fseid,
            .up_fseid = up_fseid,
            .pdrs = undefined,
            .fars = undefined,
            .pdr_count = 0,
            .far_count = 0,
            .allocated = true,
            .mutex = Mutex{},
        };
        for (0..16) |i| {
            session.pdrs[i].allocated = false;
            session.fars[i].allocated = false;
        }
        return session;
    }

    pub fn addPDR(self: *Session, pdr: PDR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pdr_count >= 16) {
            return error.TooManyPDRs;
        }

        self.pdrs[self.pdr_count] = pdr;
        self.pdr_count += 1;
    }

    pub fn addFAR(self: *Session, far: FAR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.far_count >= 16) {
            return error.TooManyFARs;
        }

        self.fars[self.far_count] = far;
        self.far_count += 1;
    }

    pub fn findPDRByTeid(self: *Session, teid: u32, source_interface: u8) ?*PDR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and
                self.pdrs[i].teid == teid and
                self.pdrs[i].source_interface == source_interface)
            {
                return &self.pdrs[i];
            }
        }
        return null;
    }

    pub fn findFAR(self: *Session, far_id: u16) ?*FAR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far_id) {
                return &self.fars[i];
            }
        }
        return null;
    }

    pub fn findPDRById(self: *Session, pdr_id: u16) ?*PDR {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr_id) {
                return &self.pdrs[i];
            }
        }
        return null;
    }

    pub fn updatePDR(self: *Session, pdr: PDR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr.id) {
                self.pdrs[i] = pdr;
                return;
            }
        }
        return error.PDRNotFound;
    }

    pub fn removePDR(self: *Session, pdr_id: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.pdr_count) |i| {
            if (self.pdrs[i].allocated and self.pdrs[i].id == pdr_id) {
                self.pdrs[i].allocated = false;
                // Compact the array by shifting remaining PDRs
                var j = i;
                while (j < self.pdr_count - 1) : (j += 1) {
                    self.pdrs[j] = self.pdrs[j + 1];
                }
                self.pdr_count -= 1;
                return;
            }
        }
        return error.PDRNotFound;
    }

    pub fn updateFAR(self: *Session, far: FAR) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far.id) {
                self.fars[i] = far;
                return;
            }
        }
        return error.FARNotFound;
    }

    pub fn removeFAR(self: *Session, far_id: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.far_count) |i| {
            if (self.fars[i].allocated and self.fars[i].id == far_id) {
                self.fars[i].allocated = false;
                // Compact the array by shifting remaining FARs
                var j = i;
                while (j < self.far_count - 1) : (j += 1) {
                    self.fars[j] = self.fars[j + 1];
                }
                self.far_count -= 1;
                return;
            }
        }
        return error.FARNotFound;
    }
};

// Session Manager - manages all PFCP sessions
pub const SessionManager = struct {
    sessions: [types.MAX_SESSIONS]Session,
    session_count: Atomic(usize),
    mutex: Mutex,
    next_up_seid: Atomic(u64),

    pub fn init() SessionManager {
        var manager = SessionManager{
            .sessions = undefined,
            .session_count = Atomic(usize).init(0),
            .mutex = Mutex{},
            .next_up_seid = Atomic(u64).init(1),
        };
        for (0..types.MAX_SESSIONS) |i| {
            manager.sessions[i].allocated = false;
        }
        return manager;
    }

    pub fn createSession(self: *SessionManager, cp_fseid: u64) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const count = self.session_count.load(.seq_cst);
        if (count >= types.MAX_SESSIONS) {
            return error.TooManySessions;
        }

        // Find first available slot
        for (0..types.MAX_SESSIONS) |i| {
            if (!self.sessions[i].allocated) {
                const up_seid = self.next_up_seid.fetchAdd(1, .seq_cst);
                self.sessions[i] = Session.init(up_seid, cp_fseid, up_seid);
                _ = self.session_count.fetchAdd(1, .seq_cst);
                print("Created PFCP session - UP SEID: 0x{x}, CP SEID: 0x{x}\n", .{ up_seid, cp_fseid });
                return up_seid;
            }
        }

        return error.NoSessionSlot;
    }

    pub fn findSession(self: *SessionManager, seid: u64) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..types.MAX_SESSIONS) |i| {
            if (self.sessions[i].allocated and self.sessions[i].up_fseid == seid) {
                return &self.sessions[i];
            }
        }
        return null;
    }

    pub fn findSessionByTeid(self: *SessionManager, teid: u32, source_interface: u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..types.MAX_SESSIONS) |i| {
            if (!self.sessions[i].allocated) continue;

            var session = &self.sessions[i];
            session.mutex.lock();
            defer session.mutex.unlock();

            for (0..session.pdr_count) |j| {
                if (session.pdrs[j].allocated and
                    session.pdrs[j].teid == teid and
                    session.pdrs[j].source_interface == source_interface)
                {
                    return session;
                }
            }
        }
        return null;
    }

    pub fn deleteSession(self: *SessionManager, seid: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..types.MAX_SESSIONS) |i| {
            if (self.sessions[i].allocated and self.sessions[i].up_fseid == seid) {
                self.sessions[i].allocated = false;
                _ = self.session_count.fetchSub(1, .seq_cst);
                print("Deleted PFCP session - SEID: 0x{x}\n", .{seid});
                return true;
            }
        }
        return false;
    }
};
