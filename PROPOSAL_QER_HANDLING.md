# QER (QoS Enforcement Rule) Handling Proposal

**Author**: Claude
**Date**: 2025-11-16
**Target**: PicoUP GTP-U Worker Pipeline Enhancement

---

## Executive Summary

This proposal outlines the implementation of **QoS Enforcement Rules (QER)** in the GTP-U worker pipeline, focusing on **MBR (Maximum Bit Rate)** and **PPS (Packets Per Second)** rate limiting as the initial implementation.

### Key Goals
1. Add QER data structure with rate limiting parameters
2. Integrate QER enforcement into the packet processing pipeline
3. Implement token bucket algorithm for MBR/PPS rate limiting
4. Add QER statistics and monitoring
5. Maintain backward compatibility with existing PDR/FAR flow

---

## Current Architecture Analysis

### Existing Pipeline (worker.zig:436-468)

```zig
// Pipeline execution in gtpuWorkerThread
if (!parseHeader(&ctx, stats)) continue;        // Stage 1: Parse GTP-U header
if (!lookupSession(&ctx, session_manager, stats)) continue;  // Stage 2: Find session
if (!matchPDR(&ctx, stats)) continue;           // Stage 3: Match PDR
if (!lookupFAR(&ctx, stats)) continue;          // Stage 4: Find FAR
executeFAR(&ctx, stats);                        // Stage 5: Execute action
```

### Data Flow
```
Packet → GtpuHeader → Session → PDR → FAR → Forward/Drop
```

### Missing Component
**QoS Enforcement** - No rate limiting or QoS policy enforcement exists between PDR matching and FAR execution.

---

## Proposed Solution

### Enhanced Pipeline

```zig
// Add QER enforcement stage between lookupFAR and executeFAR
if (!parseHeader(&ctx, stats)) continue;
if (!lookupSession(&ctx, session_manager, stats)) continue;
if (!matchPDR(&ctx, stats)) continue;
if (!lookupFAR(&ctx, stats)) continue;
if (!enforceQoS(&ctx, stats)) continue;         // NEW: QoS enforcement
executeFAR(&ctx, stats);
```

### Enhanced Data Flow
```
Packet → GtpuHeader → Session → PDR → QER → FAR → Forward/Drop
                                      ↓
                              Rate Limiting
                            (MBR/PPS Check)
```

---

## Implementation Details

### 1. QER Data Structure (types.zig)

```zig
// QoS Enforcement Rule (QER)
// Defines QoS parameters and rate limiting for a flow
// Based on 3GPP TS 29.244 Section 5.2.1.11
pub const QER = struct {
    id: u16,                    // Unique QER identifier
    qfi: u8,                    // QoS Flow Identifier (0-63)

    // Rate limiting parameters
    has_mbr: bool,              // Maximum Bit Rate configured
    mbr_uplink: u64,           // MBR uplink in bits/second
    mbr_downlink: u64,         // MBR downlink in bits/second

    has_gbr: bool,              // Guaranteed Bit Rate configured (future)
    gbr_uplink: u64,           // GBR uplink in bits/second
    gbr_downlink: u64,         // GBR downlink in bits/second

    has_pps_limit: bool,        // Packets Per Second limit configured
    pps_limit: u32,            // Maximum packets per second

    // Token bucket state for rate limiting
    mbr_tokens: Atomic(u64),   // Available bits (for MBR)
    pps_tokens: Atomic(u32),   // Available packets (for PPS)
    last_refill: Atomic(i64),  // Timestamp of last token refill (ns)

    // QoS parameters (for future implementation)
    packet_delay_budget: u32,  // Max delay in milliseconds
    packet_error_rate: u8,     // Target error rate (10^-N)

    allocated: bool,
    mutex: Mutex,              // Protects token bucket operations

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
            .mbr_tokens = Atomic(u64).init(0),
            .pps_tokens = Atomic(u32).init(0),
            .last_refill = Atomic(i64).init(std.time.nanoTimestamp()),
            .packet_delay_budget = 0,
            .packet_error_rate = 0,
            .allocated = true,
            .mutex = Mutex{},
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
```

### 2. Update PDR Structure (types.zig)

```zig
// Add QER reference to PDR
pub const PDR = struct {
    id: u16,
    precedence: u32,
    pdi: PDI,
    far_id: u16,
    qer_id: u16,           // NEW: Associated QER ID
    has_qer: bool,         // NEW: Whether QER is configured
    allocated: bool,

    pub fn init(id: u16, precedence: u32, source_interface: u8, teid: u32, far_id: u16) PDR {
        var pdi = PDI.init(source_interface);
        pdi.setFTeid(teid);
        return PDR{
            .id = id,
            .precedence = precedence,
            .pdi = pdi,
            .far_id = far_id,
            .qer_id = 0,       // NEW
            .has_qer = false,  // NEW
            .allocated = true,
        };
    }

    // NEW: Set QER reference
    pub fn setQER(self: *PDR, qer_id: u16) void {
        self.qer_id = qer_id;
        self.has_qer = true;
    }
};
```

### 3. Update Session Structure (session.zig)

```zig
pub const Session = struct {
    seid: u64,
    cp_fseid: u64,
    up_fseid: u64,
    pdrs: [16]PDR,
    fars: [16]FAR,
    qers: [16]QER,         // NEW: QER array
    pdr_count: u8,
    far_count: u8,
    qer_count: u8,         // NEW: QER count
    allocated: bool,
    mutex: Mutex,

    pub fn init(seid: u64, cp_fseid: u64, up_fseid: u64) Session {
        var session = Session{
            .seid = seid,
            .cp_fseid = cp_fseid,
            .up_fseid = up_fseid,
            .pdrs = undefined,
            .fars = undefined,
            .qers = undefined,  // NEW
            .pdr_count = 0,
            .far_count = 0,
            .qer_count = 0,     // NEW
            .allocated = true,
            .mutex = Mutex{},
        };
        for (0..16) |i| {
            session.pdrs[i].allocated = false;
            session.fars[i].allocated = false;
            session.qers[i].allocated = false;  // NEW
        }
        return session;
    }

    // NEW: Add QER to session
    pub fn addQER(self: *Session, qer: QER) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.qer_count >= 16) {
            return error.TooManyQERs;
        }

        self.qers[self.qer_count] = qer;
        self.qer_count += 1;
    }

    // NEW: Find QER by ID
    pub fn findQER(self: *Session, qer_id: u16) ?*QER {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (0..self.qer_count) |i| {
            if (self.qers[i].allocated and self.qers[i].id == qer_id) {
                return &self.qers[i];
            }
        }
        return null;
    }
};
```

### 4. Update PacketContext (worker.zig)

```zig
const PacketContext = struct {
    packet: GtpuPacket,
    header: handler.GtpuHeader,
    session: ?*session_mod.Session,
    pdr: ?*types.PDR,
    far: ?*types.FAR,
    qer: ?*types.QER,         // NEW: Matched QER
    payload: []const u8,
    source_interface: u8,
    thread_id: u32,
    flow_info: PacketFlowInfo,
};
```

### 5. Add QER Lookup Stage (worker.zig)

```zig
// Pipeline Stage 4.5: Lookup QER if PDR references one
fn lookupQER(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    // Check if PDR has QER configured
    if (ctx.pdr) |pdr| {
        if (!pdr.has_qer) {
            // No QER configured - skip QoS enforcement
            ctx.qer = null;
            return true;
        }

        if (ctx.session) |session| {
            ctx.qer = session.findQER(pdr.qer_id);
            if (ctx.qer == null) {
                print("Worker {}: QER {} not found for PDR {}\n",
                      .{ ctx.thread_id, pdr.qer_id, pdr.id });
                _ = stats.gtpu_packets_dropped.fetchAdd(1, .seq_cst);
                return false;
            }
            return true;
        }
    }
    return false;
}
```

### 6. Implement Token Bucket Rate Limiting (worker.zig)

```zig
// Pipeline Stage 5: Enforce QoS using token bucket algorithm
fn enforceQoS(ctx: *PacketContext, stats: *stats_mod.Stats) bool {
    // No QER configured - allow packet through
    if (ctx.qer == null) {
        return true;
    }

    const qer = ctx.qer.?;
    const payload_bits = ctx.payload.len * 8;
    const now = time.nanoTimestamp();

    qer.mutex.lock();
    defer qer.mutex.unlock();

    // Refill token buckets based on elapsed time
    const last_refill = qer.last_refill.load(.seq_cst);
    const elapsed_ns = @as(u64, @intCast(now - last_refill));
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Check PPS limit if configured
    if (qer.has_pps_limit) {
        // Refill PPS tokens: limit * elapsed_seconds
        const pps_refill = @as(u32, @intFromFloat(
            @as(f64, @floatFromInt(qer.pps_limit)) * elapsed_seconds
        ));
        const current_pps = qer.pps_tokens.load(.seq_cst);
        const new_pps = @min(current_pps + pps_refill, qer.pps_limit);
        qer.pps_tokens.store(new_pps, .seq_cst);

        // Check if we have tokens available
        if (new_pps < 1) {
            print("Worker {}: PPS limit exceeded (QER {}), dropping packet\n",
                  .{ ctx.thread_id, qer.id });
            _ = stats.qos_pps_dropped.fetchAdd(1, .seq_cst);
            return false;
        }

        // Consume 1 packet token
        qer.pps_tokens.store(new_pps - 1, .seq_cst);
    }

    // Check MBR limit if configured
    if (qer.has_mbr) {
        // Determine direction based on source interface
        const mbr_limit = if (ctx.source_interface == 0)  // N3 = uplink
            qer.mbr_uplink
        else  // N6/N9 = downlink
            qer.mbr_downlink;

        // Refill MBR tokens: bits/second * elapsed_seconds
        const mbr_refill = @as(u64, @intFromFloat(
            @as(f64, @floatFromInt(mbr_limit)) * elapsed_seconds
        ));
        const current_mbr = qer.mbr_tokens.load(.seq_cst);
        const new_mbr = @min(current_mbr + mbr_refill, mbr_limit);
        qer.mbr_tokens.store(new_mbr, .seq_cst);

        // Check if we have enough tokens for this packet
        if (new_mbr < payload_bits) {
            print("Worker {}: MBR limit exceeded (QER {}), dropping packet ({} bits needed, {} available)\n",
                  .{ ctx.thread_id, qer.id, payload_bits, new_mbr });
            _ = stats.qos_mbr_dropped.fetchAdd(1, .seq_cst);
            return false;
        }

        // Consume tokens
        qer.mbr_tokens.store(new_mbr - payload_bits, .seq_cst);
    }

    // Update last refill timestamp
    qer.last_refill.store(now, .seq_cst);

    // Packet passed QoS checks
    _ = stats.qos_packets_passed.fetchAdd(1, .seq_cst);
    return true;
}
```

### 7. Update Statistics (stats.zig)

```zig
pub const Stats = struct {
    // ... existing fields ...

    // NEW: QoS enforcement statistics
    qos_packets_passed: Atomic(u64),    // Packets that passed QoS checks
    qos_mbr_dropped: Atomic(u64),       // Packets dropped due to MBR limit
    qos_pps_dropped: Atomic(u64),       // Packets dropped due to PPS limit

    pub fn init() Stats {
        return Stats{
            // ... existing init ...
            .qos_packets_passed = Atomic(u64).init(0),
            .qos_mbr_dropped = Atomic(u64).init(0),
            .qos_pps_dropped = Atomic(u64).init(0),
        };
    }
};

// Update statsThread to display QoS metrics
pub fn statsThread(stats: *Stats, session_mgr: *session.SessionManager, should_stop: *Atomic(bool)) void {
    // ... existing code ...

    const qos_passed = stats.qos_packets_passed.load(.seq_cst);
    const qos_mbr_drop = stats.qos_mbr_dropped.load(.seq_cst);
    const qos_pps_drop = stats.qos_pps_dropped.load(.seq_cst);

    print("QoS: Passed={}, MBR Dropped={}, PPS Dropped={}\n",
          .{ qos_passed, qos_mbr_drop, qos_pps_drop });
}
```

### 8. Update Worker Thread Pipeline (worker.zig)

```zig
pub fn gtpuWorkerThread(
    thread_id: u32,
    packet_queue: *PacketQueue,
    session_manager: *session_mod.SessionManager,
    stats: *stats_mod.Stats,
    should_stop: *Atomic(bool),
) void {
    print("GTP-U worker thread {} started\n", .{thread_id});

    while (!should_stop.load(.seq_cst)) {
        if (packet_queue.dequeue()) |packet| {
            stats.queue_size.store(packet_queue.size(), .seq_cst);

            var ctx = PacketContext{
                .packet = packet,
                .header = undefined,
                .session = null,
                .pdr = null,
                .far = null,
                .qer = null,          // NEW
                .payload = undefined,
                .source_interface = 0,
                .thread_id = thread_id,
                .flow_info = PacketFlowInfo.init(),
            };

            // Execute enhanced pipeline with QoS enforcement
            if (!parseHeader(&ctx, stats)) continue;
            if (!lookupSession(&ctx, session_manager, stats)) continue;
            if (!matchPDR(&ctx, stats)) continue;
            if (!lookupFAR(&ctx, stats)) continue;
            if (!lookupQER(&ctx, stats)) continue;    // NEW
            if (!enforceQoS(&ctx, stats)) continue;   // NEW
            executeFAR(&ctx, stats);
        } else {
            time.sleep(1 * time.ns_per_ms);
        }
    }

    print("GTP-U worker thread {} stopped\n", .{thread_id});
}
```

---

## Algorithm Details: Token Bucket

### Concept

Token bucket is a classic rate limiting algorithm that:
1. Maintains a "bucket" of tokens representing available capacity
2. Refills tokens at a constant rate (e.g., bits/second or packets/second)
3. Consumes tokens when packets arrive
4. Drops packets when insufficient tokens are available

### Parameters

**For MBR (Maximum Bit Rate)**:
- Bucket capacity = MBR limit (bits/second)
- Refill rate = MBR limit (bits/second)
- Token cost = packet size in bits

**For PPS (Packets Per Second)**:
- Bucket capacity = PPS limit (packets/second)
- Refill rate = PPS limit (packets/second)
- Token cost = 1 packet

### Example Calculation

```
Given:
- MBR limit = 10 Mbps (10,000,000 bits/second)
- Packet size = 1500 bytes = 12,000 bits
- Last refill = 100ms ago (0.1 seconds)

Calculation:
1. Refill amount = 10,000,000 * 0.1 = 1,000,000 bits
2. Current tokens = 500,000 bits (from previous state)
3. New tokens = min(500,000 + 1,000,000, 10,000,000) = 1,500,000 bits
4. Packet needs 12,000 bits
5. Check: 1,500,000 >= 12,000? YES → Allow packet
6. Remaining tokens = 1,500,000 - 12,000 = 1,488,000 bits
```

### Advantages

- **Burst tolerance**: Allows short bursts up to bucket capacity
- **Smooth rate limiting**: Gradual token refill prevents abrupt drops
- **Low overhead**: Simple arithmetic, no complex state
- **Lock-free friendly**: Atomic operations for token counters

---

## Testing Strategy

### Unit Tests

```zig
test "QER token bucket - MBR enforcement" {
    var qer = QER.init(1, 5);
    qer.setMBR(1_000_000, 1_000_000); // 1 Mbps

    // Simulate 1500-byte packet (12,000 bits)
    // Should consume tokens
    const payload_bits = 1500 * 8;

    // Initial tokens should be 1,000,000
    const initial = qer.mbr_tokens.load(.seq_cst);
    try std.testing.expectEqual(@as(u64, 1_000_000), initial);

    // Consume tokens
    qer.mbr_tokens.store(initial - payload_bits, .seq_cst);

    // Should have 988,000 bits remaining
    const remaining = qer.mbr_tokens.load(.seq_cst);
    try std.testing.expectEqual(@as(u64, 988_000), remaining);
}

test "QER token bucket - PPS enforcement" {
    var qer = QER.init(2, 10);
    qer.setPPS(100); // 100 packets/second

    // Initial tokens should be 100
    const initial = qer.pps_tokens.load(.seq_cst);
    try std.testing.expectEqual(@as(u32, 100), initial);

    // Consume 1 packet
    qer.pps_tokens.store(initial - 1, .seq_cst);

    // Should have 99 packets remaining
    const remaining = qer.pps_tokens.load(.seq_cst);
    try std.testing.expectEqual(@as(u32, 99), remaining);
}
```

### Integration Tests

1. **Test QER with PDR/FAR flow**:
   - Create session with PDR, FAR, and QER
   - Send packets and verify QoS enforcement
   - Check statistics counters

2. **Test rate limiting**:
   - Configure MBR limit (e.g., 1 Mbps)
   - Send packets faster than limit
   - Verify excess packets are dropped
   - Check qos_mbr_dropped counter

3. **Test PPS limiting**:
   - Configure PPS limit (e.g., 100 pps)
   - Send 200 packets in 1 second
   - Verify ~100 are dropped
   - Check qos_pps_dropped counter

### Performance Benchmarks

- Measure latency impact of QoS stage
- Test throughput with various MBR limits
- Verify token refill accuracy
- Check mutex contention under load

---

## Migration Path

### Phase 1: Core Implementation (Week 1)
- [ ] Add QER structure to types.zig
- [ ] Update PDR with QER reference
- [ ] Update Session with QER array and methods
- [ ] Add QER statistics counters

### Phase 2: Pipeline Integration (Week 2)
- [ ] Implement lookupQER stage
- [ ] Implement enforceQoS with token bucket
- [ ] Update worker thread pipeline
- [ ] Add unit tests

### Phase 3: PFCP Integration (Week 3)
- [ ] Add QER IE parsing in PFCP session handler
- [ ] Support Create QER in Session Establishment
- [ ] Support Update QER in Session Modification
- [ ] Support Delete QER in Session Deletion

### Phase 4: Testing & Optimization (Week 4)
- [ ] Integration tests with real traffic
- [ ] Performance benchmarking
- [ ] Optimize token bucket algorithm
- [ ] Documentation updates

---

## Performance Considerations

### Memory Impact

```
QER struct size: ~128 bytes (estimated)
Session impact: 16 QERs * 128 bytes = 2 KB per session
Total: 100 sessions * 2 KB = 200 KB additional memory
```

**Acceptable**: Minimal increase to working set.

### CPU Impact

**Token bucket operations per packet**:
1. Load timestamp (atomic read)
2. Calculate elapsed time
3. Calculate refill amount (2 FP operations)
4. Update tokens (atomic read-modify-write)
5. Check limit (comparison)
6. Store timestamp (atomic write)

**Estimated**: ~50-100 CPU cycles per packet

**Mitigation**:
- Use atomic operations to minimize lock contention
- Batch refills (refill once per N packets)
- Consider per-QER worker threads for high-rate flows

### Lock Contention

**Issue**: QER mutex could become bottleneck for high-rate flows

**Solutions**:
1. Use lock-free atomic operations for token updates
2. Shard QERs across multiple buckets
3. Per-worker-thread token buckets with periodic sync

---

## Future Enhancements

### Phase 5: GBR (Guaranteed Bit Rate)
- Implement minimum rate guarantee
- Add priority queuing
- Scheduler for GBR flows

### Phase 6: Packet Delay Budget
- Track per-packet timestamps
- Measure queueing delay
- Drop packets exceeding budget

### Phase 7: Advanced QoS
- Multi-level token buckets (burst + sustained)
- Traffic shaping (smooth output rate)
- Congestion control integration

### Phase 8: QFI Support
- Parse QFI from GTP-U extension headers
- Map QFI to QER
- Support multiple QoS flows per session

---

## References

### 3GPP Specifications
- **TS 29.244** Section 5.2.1.11 - Create QER IE
- **TS 29.244** Section 8.2.26 - QER definition
- **TS 23.501** Section 5.7.1 - QoS model
- **TS 23.501** Section 5.7.3 - QoS parameters

### Algorithm References
- Token bucket algorithm: RFC 2697, RFC 2698
- Leaky bucket algorithm: RFC 5481

### Related Issues
- #TODO: Link to GitHub issue for QER implementation

---

## Conclusion

This proposal provides a complete path to implementing QER handling in PicoUP with:

1. **Clear data structures** for QER with rate limiting
2. **Token bucket algorithm** for MBR and PPS enforcement
3. **Minimal pipeline changes** - single new stage
4. **Backward compatibility** - QER is optional
5. **Comprehensive statistics** for monitoring
6. **Phased implementation** for manageable development

**Recommendation**: Start with **PPS (Packets Per Second)** rate limiting as it's simpler (no bit calculations), then add MBR support.

**Next Steps**: Review proposal, adjust parameters, begin Phase 1 implementation.
