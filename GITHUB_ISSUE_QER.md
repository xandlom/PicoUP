# Implement QER (QoS Enforcement Rules) with MBR and PPS Rate Limiting

## Summary

Implement QoS Enforcement Rules (QER) in the GTP-U worker pipeline to support rate limiting with Maximum Bit Rate (MBR) and Packets Per Second (PPS) enforcement using token bucket algorithm.

## Background

Currently, the GTP-U pipeline processes packets through PDR (Packet Detection Rules) and FAR (Forwarding Action Rules) but has no QoS enforcement mechanism. This means:
- No rate limiting on traffic flows
- No differentiation between QoS flows
- Cannot enforce MBR or GBR limits from PFCP sessions

**Reference**: See detailed proposal in `PROPOSAL_QER_HANDLING.md` on branch `claude/gtpu-qer-handling-01WyK7dWpcrvsZaSFCwYaHw2`

## Proposed Solution

### Enhanced Pipeline Architecture

**Current Pipeline:**
```
parseHeader → lookupSession → matchPDR → lookupFAR → executeFAR
```

**Proposed Pipeline:**
```
parseHeader → lookupSession → matchPDR → lookupFAR → lookupQER → enforceQoS → executeFAR
                                                         ↑            ↑
                                                    NEW STAGES  RATE LIMITING
```

### Core Components

1. **QER Data Structure** (`types.zig`)
   - QER ID and QFI (QoS Flow Identifier)
   - MBR limits (uplink/downlink in bits/second)
   - PPS limits (packets/second)
   - Token bucket state (atomic counters)
   - Thread-safe operations

2. **Token Bucket Rate Limiting**
   - Refill tokens at constant rate
   - Consume tokens per packet
   - Drop packets when insufficient tokens
   - Separate buckets for MBR and PPS

3. **Session Integration**
   - Add `qers[16]` array to Session
   - Add `qer_id` reference to PDR (optional)
   - Add `findQER()` method

4. **QoS Statistics**
   - `qos_packets_passed` - packets passing QoS checks
   - `qos_mbr_dropped` - dropped due to bit rate limit
   - `qos_pps_dropped` - dropped due to packet rate limit

## Implementation Plan

### Phase 1: Core Implementation (Week 1)
- [ ] Add QER structure to `src/types.zig`
- [ ] Update PDR with optional QER reference
- [ ] Update Session with QER array and methods
- [ ] Add QER statistics counters to `src/stats.zig`
- [ ] Write unit tests for QER structure

### Phase 2: Pipeline Integration (Week 2)
- [ ] Implement `lookupQER()` stage in `src/gtpu/worker.zig`
- [ ] Implement `enforceQoS()` with token bucket algorithm
- [ ] Update `PacketContext` to include QER pointer
- [ ] Update worker thread pipeline
- [ ] Add integration tests

### Phase 3: PFCP Integration (Week 3)
- [ ] Add QER IE parsing in `src/pfcp/session.zig`
- [ ] Support Create QER in Session Establishment Request
- [ ] Support Update QER in Session Modification Request
- [ ] Support Delete QER in Session Deletion Request
- [ ] Test with real SMF

### Phase 4: Testing & Optimization (Week 4)
- [ ] Performance benchmarking
- [ ] Latency impact measurement
- [ ] Lock contention analysis
- [ ] Token bucket accuracy verification
- [ ] Documentation updates

## Recommended Approach

**Start with PPS (Packets Per Second) limiting first:**
- ✅ Simpler implementation (integer-only arithmetic)
- ✅ No bit-to-byte conversions
- ✅ Easier to test and debug
- ✅ Add MBR support once PPS is stable

## Technical Details

### Token Bucket Algorithm

**For PPS:**
```
Bucket capacity = PPS limit (e.g., 100 packets/sec)
Refill rate = PPS limit
Cost per packet = 1 token
Drop if tokens < 1
```

**For MBR:**
```
Bucket capacity = MBR limit (e.g., 10 Mbps)
Refill rate = MBR limit (bits/sec)
Cost per packet = payload_size * 8 bits
Drop if tokens < packet_bits
```

### Memory Impact

```
QER struct: ~128 bytes
Per session: 16 QERs × 128 bytes = 2 KB
Total: 100 sessions × 2 KB = 200 KB additional memory
```

**Acceptable**: Minimal increase to working set.

### Performance Impact

**Token bucket operations per packet:**
- Load timestamp (atomic read)
- Calculate elapsed time
- Calculate refill amount (2 FP operations)
- Update tokens (atomic read-modify-write)
- Check limit (comparison)
- Store timestamp (atomic write)

**Estimated**: ~50-100 CPU cycles per packet

## References

### 3GPP Specifications
- **TS 29.244** Section 5.2.1.11 - Create QER IE
- **TS 29.244** Section 8.2.26 - QER definition
- **TS 23.501** Section 5.7.1 - QoS model
- **TS 23.501** Section 5.7.3 - QoS parameters

### Related Documents
- Full proposal: `PROPOSAL_QER_HANDLING.md`
- Branch: `claude/gtpu-qer-handling-01WyK7dWpcrvsZaSFCwYaHw2`

## Success Criteria

- [ ] QER structure integrated into types.zig
- [ ] Token bucket algorithm working for PPS
- [ ] Token bucket algorithm working for MBR
- [ ] QoS statistics displayed in stats thread
- [ ] PFCP can create/update/delete QERs
- [ ] Performance impact < 5% latency increase
- [ ] Unit tests with >80% coverage
- [ ] Integration tests with real traffic
- [ ] Documentation updated

## Future Enhancements

- GBR (Guaranteed Bit Rate) enforcement
- Packet Delay Budget tracking
- QFI support from GTP-U extension headers
- Multi-level token buckets
- Traffic shaping
- Priority queuing

---

**Labels**: enhancement, qos, gtpu, performance
**Milestone**: v0.2.0
**Assignee**: TBD
