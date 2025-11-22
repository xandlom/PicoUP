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

    // QoS enforcement statistics
    qos_packets_passed: Atomic(u64), // Packets that passed QoS checks
    qos_mbr_dropped: Atomic(u64), // Packets dropped due to MBR limit
    qos_pps_dropped: Atomic(u64), // Packets dropped due to PPS limit

    // URR statistics
    urr_packets_tracked: Atomic(u64), // Packets with usage tracked
    urr_reports_triggered: Atomic(u64), // Number of reports triggered
    urr_quota_exceeded: Atomic(u64), // Packets dropped due to quota

    // Echo Request/Response statistics (path management)
    gtpu_echo_requests: Atomic(u64), // Echo requests received and responded to
    gtpu_echo_responses: Atomic(u64), // Echo responses received

    // N6 NAT statistics
    n6_packets_rx: Atomic(u64), // Packets received from data network (downlink)
    n6_nat_created: Atomic(u64), // NAT entries created
    n6_nat_hits: Atomic(u64), // NAT table lookup hits
    n6_nat_misses: Atomic(u64), // NAT table lookup misses
    n6_nat_active: Atomic(usize), // Currently active NAT entries

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
            .qos_packets_passed = Atomic(u64).init(0),
            .qos_mbr_dropped = Atomic(u64).init(0),
            .qos_pps_dropped = Atomic(u64).init(0),
            .urr_packets_tracked = Atomic(u64).init(0),
            .urr_reports_triggered = Atomic(u64).init(0),
            .urr_quota_exceeded = Atomic(u64).init(0),
            .gtpu_echo_requests = Atomic(u64).init(0),
            .gtpu_echo_responses = Atomic(u64).init(0),
            .n6_packets_rx = Atomic(u64).init(0),
            .n6_nat_created = Atomic(u64).init(0),
            .n6_nat_hits = Atomic(u64).init(0),
            .n6_nat_misses = Atomic(u64).init(0),
            .n6_nat_active = Atomic(usize).init(0),
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
        const qos_passed = stats.qos_packets_passed.load(.seq_cst);
        const qos_mbr_drop = stats.qos_mbr_dropped.load(.seq_cst);
        const qos_pps_drop = stats.qos_pps_dropped.load(.seq_cst);
        const urr_tracked = stats.urr_packets_tracked.load(.seq_cst);
        const urr_reports = stats.urr_reports_triggered.load(.seq_cst);
        const urr_quota = stats.urr_quota_exceeded.load(.seq_cst);
        const echo_req = stats.gtpu_echo_requests.load(.seq_cst);
        const echo_resp = stats.gtpu_echo_responses.load(.seq_cst);

        const rx_rate = (gtpu_rx - last_rx) / 5;
        const tx_rate = (gtpu_tx - last_tx) / 5;

        const uptime = time.timestamp() - stats.start_time;
        const active_sessions = session_mgr.session_count.load(.seq_cst);

        print("\n=== PicoUP Statistics ===\n", .{});
        print("Uptime: {}s\n", .{uptime});
        print("PFCP Messages: {}, Active Sessions: {}/{}\n", .{ pfcp_msgs, active_sessions, pfcp_sess });
        print("GTP-U RX: {}, TX: {}, Dropped: {}\n", .{ gtpu_rx, gtpu_tx, gtpu_drop });
        print("GTP-U Rate: {} pkt/s RX, {} pkt/s TX\n", .{ rx_rate, tx_rate });
        print("GTP-U Echo: Req={}, Resp={}\n", .{ echo_req, echo_resp });
        print("Interface TX: N3={}, N6={}, N9={}\n", .{ n3_tx, n6_tx, n9_tx });
        print("QoS: Passed={}, MBR Dropped={}, PPS Dropped={}\n", .{ qos_passed, qos_mbr_drop, qos_pps_drop });
        print("URR: Tracked={}, Reports={}, Quota Exceeded={}\n", .{ urr_tracked, urr_reports, urr_quota });

        // N6 NAT statistics
        const n6_rx = stats.n6_packets_rx.load(.seq_cst);
        const nat_created = stats.n6_nat_created.load(.seq_cst);
        const nat_hits = stats.n6_nat_hits.load(.seq_cst);
        const nat_misses = stats.n6_nat_misses.load(.seq_cst);
        const nat_active = stats.n6_nat_active.load(.seq_cst);
        print("N6 NAT: RX={}, Active={}, Created={}, Hits={}, Misses={}\n", .{ n6_rx, nat_active, nat_created, nat_hits, nat_misses });

        print("Queue Size: {}\n", .{queue_sz});
        print("Worker Threads: {}\n", .{types.WORKER_THREADS});
        print("========================\n", .{});

        last_rx = gtpu_rx;
        last_tx = gtpu_tx;
    }

    print("Statistics thread stopped\n", .{});
}
