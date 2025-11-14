// Statistics collection and reporting
// This module tracks UPF performance metrics and provides periodic reporting

const std = @import("std");
const types = @import("types.zig");
const session = @import("session.zig");

const Atomic = std.atomic.Value;
const print = std.debug.print;
const time = std.time;

// Statistics counters
pub const Stats = struct {
    pfcp_messages: Atomic(u64),
    pfcp_sessions: Atomic(u64),
    gtpu_packets_rx: Atomic(u64),
    gtpu_packets_tx: Atomic(u64),
    gtpu_packets_dropped: Atomic(u64),
    n3_packets_tx: Atomic(u64), // N3 (Access) transmit
    n6_packets_tx: Atomic(u64), // N6 (Core) transmit
    n9_packets_tx: Atomic(u64), // N9 (UPF-to-UPF) transmit
    queue_size: Atomic(usize),
    start_time: i64,

    pub fn init() Stats {
        return Stats{
            .pfcp_messages = Atomic(u64).init(0),
            .pfcp_sessions = Atomic(u64).init(0),
            .gtpu_packets_rx = Atomic(u64).init(0),
            .gtpu_packets_tx = Atomic(u64).init(0),
            .gtpu_packets_dropped = Atomic(u64).init(0),
            .n3_packets_tx = Atomic(u64).init(0),
            .n6_packets_tx = Atomic(u64).init(0),
            .n9_packets_tx = Atomic(u64).init(0),
            .queue_size = Atomic(usize).init(0),
            .start_time = time.timestamp(),
        };
    }
};

// Statistics reporting thread
// Displays metrics every 5 seconds
pub fn statsThread(stats: *Stats, session_mgr: *session.SessionManager, should_stop: *Atomic(bool)) void {
    print("Statistics thread started\n", .{});

    var last_rx: u64 = 0;
    var last_tx: u64 = 0;

    while (!should_stop.load(.seq_cst)) {
        time.sleep(5 * time.ns_per_s);

        const pfcp_msgs = stats.pfcp_messages.load(.seq_cst);
        const pfcp_sess = stats.pfcp_sessions.load(.seq_cst);
        const gtpu_rx = stats.gtpu_packets_rx.load(.seq_cst);
        const gtpu_tx = stats.gtpu_packets_tx.load(.seq_cst);
        const gtpu_drop = stats.gtpu_packets_dropped.load(.seq_cst);
        const n3_tx = stats.n3_packets_tx.load(.seq_cst);
        const n6_tx = stats.n6_packets_tx.load(.seq_cst);
        const n9_tx = stats.n9_packets_tx.load(.seq_cst);
        const queue_sz = stats.queue_size.load(.seq_cst);

        const rx_rate = (gtpu_rx - last_rx) / 5;
        const tx_rate = (gtpu_tx - last_tx) / 5;

        const uptime = time.timestamp() - stats.start_time;
        const active_sessions = session_mgr.session_count.load(.seq_cst);

        print("\n=== PicoUP Statistics ===\n", .{});
        print("Uptime: {}s\n", .{uptime});
        print("PFCP Messages: {}, Active Sessions: {}/{}\n", .{ pfcp_msgs, active_sessions, pfcp_sess });
        print("GTP-U RX: {}, TX: {}, Dropped: {}\n", .{ gtpu_rx, gtpu_tx, gtpu_drop });
        print("GTP-U Rate: {} pkt/s RX, {} pkt/s TX\n", .{ rx_rate, tx_rate });
        print("Interface TX: N3={}, N6={}, N9={}\n", .{ n3_tx, n6_tx, n9_tx });
        print("Queue Size: {}\n", .{queue_sz});
        print("Worker Threads: {}\n", .{types.WORKER_THREADS});
        print("========================\n", .{});

        last_rx = gtpu_rx;
        last_tx = gtpu_tx;
    }

    print("Statistics thread stopped\n", .{});
}
