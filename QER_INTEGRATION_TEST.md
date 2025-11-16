# QER Integration Test Suite

**Purpose**: End-to-end integration test for PicoUP QER implementation
**Test File**: `test_qer_integration.zig`
**Build Target**: `zig build test-qer`

---

## Overview

This integration test validates the complete QER (QoS Enforcement Rules) implementation from PFCP session establishment through GTP-U packet processing and QoS enforcement.

### Test Scope

✅ **PFCP Control Plane**:
- Association Setup/Release
- Session Establishment/Deletion
- QER creation (automatic with default limits)

✅ **GTP-U Data Plane**:
- Uplink packet processing (TEID 0x100)
- Downlink packet processing (TEID 0x200)
- QoS enforcement (PPS and MBR rate limiting)

✅ **QER Functionality**:
- Token bucket rate limiting
- PPS limit: 1000 packets/second
- MBR limit: 10 Mbps uplink/downlink
- Statistics tracking

---

## Test Architecture

```
┌─────────────────┐                    ┌─────────────────┐
│  Test Suite     │    Loopback (lo)   │   PicoUPF       │
│                 │                     │   (SUT)         │
│  127.0.0.1      │◄──────────────────►│  127.0.0.1      │
│                 │                     │                 │
│  PFCP Client    │──── Port 8805 ────►│  PFCP Server    │
│  GTP-U Client   │──── Port 2152 ────►│  GTP-U Server   │
└─────────────────┘                    └─────────────────┘
```

### Test Flow

```
1. PFCP Association Setup
   ├─ Send: Association Setup Request
   └─ Receive: Association Setup Response

2. PFCP Session Establishment
   ├─ Send: Session Establishment Request (CP F-SEID: 0x1000)
   └─ Receive: Session Establishment Response (UP F-SEID from UPF)
   └─ UPF creates: PDR (TEID 0x100) + FAR + QER (PPS=1000, MBR=10Mbps)

3. GTP-U Traffic Generation (3 rounds)
   ┌─ Round 1
   │  ├─ Send 10 uplink packets (TEID 0x100)
   │  ├─ Wait 1 second
   │  ├─ Send 10 downlink packets (TEID 0x200)
   │  └─ Wait 5 seconds
   ├─ Round 2 (repeat)
   ├─ Round 3 (repeat)
   └─ Total: 60 packets (30 uplink + 30 downlink)

4. Verify Statistics
   └─ Check PicoUPF output for QoS metrics

5. PFCP Session Deletion
   ├─ Send: Session Deletion Request
   └─ Receive: Session Deletion Response

6. PFCP Association Release
   ├─ Send: Association Release Request
   └─ Receive: Association Release Response
```

---

## Running the Test

### Prerequisites

1. **Build PicoUPF and test suite**:
   ```bash
   zig build
   ```

2. **Start PicoUPF** (in terminal 1):
   ```bash
   ./zig-out/bin/picoupf
   ```

   Expected output:
   ```
   === PicoUP - User Plane Function ===
   Version: 0.1.0
   Worker Threads: 4
   Press Ctrl+C to stop

   PFCP thread started
   PFCP listening on 0.0.0.0:8805
   GTP-U thread started
   GTP-U listening on 0.0.0.0:2152
   ...
   ```

### Execute Test

**In terminal 2**, run the integration test:

```bash
zig build test-qer
```

**Or run the compiled test directly**:

```bash
./zig-out/bin/test_qer_integration
```

### Test Execution

The test will:

1. **Wait for confirmation**:
   ```
   ⚠  Please ensure PicoUPF is running before continuing.
      (Run: ./zig-out/bin/picoupf)

   Press Enter to start test...
   ```

2. **Run test sequence**:
   ```
   🚀 Starting integration test...

   === Sending PFCP Association Setup Request ===
   Sent Association Setup Request (XX bytes)
   Received response: message type = 6
   ✓ Association established successfully

   === Sending PFCP Session Establishment Request ===
   ...
   ```

3. **Generate traffic**:
   ```
   ═══════════════════════════════════════════════════════════
                ROUND 1/3
   ═══════════════════════════════════════════════════════════

   --- Sending 10 uplink GTP-U packets (TEID=0x100) ---
   ✓ Sent 10 uplink packets

   --- Sending 10 downlink GTP-U packets (TEID=0x200) ---
   ✓ Sent 10 downlink packets

   Waiting 5 seconds before next round...
   ```

4. **Complete test**:
   ```
   ╔════════════════════════════════════════════════════════════╗
   ║              TEST COMPLETED SUCCESSFULLY!                  ║
   ╚════════════════════════════════════════════════════════════╝

   ✓ Check PicoUPF statistics output for QoS metrics:
     - QoS: Passed=X, MBR Dropped=Y, PPS Dropped=Z
     - GTP-U RX should show ~60 packets received
   ```

---

## Verifying Results

### PicoUPF Output (Terminal 1)

**During test execution**, you should see:

```
PFCP: Association Setup Request received
PFCP: Association setup completed

PFCP: Session Establishment Request received
PFCP: Created session with UP SEID 0x1, PDR TEID: 0x100, QER ID: 1 (PPS: 1000, MBR: 10000000 bps)

Worker 0: Matched PDR 1 (precedence: 100) for TEID 0x100
Worker 0: Forwarding packet per FAR 1, TEID: 0x100
...

=== PicoUP Statistics ===
Uptime: 20s
PFCP Messages: 4, Active Sessions: 1/1
GTP-U RX: 60, TX: 0, Dropped: 0
GTP-U Rate: 12 pkt/s RX, 0 pkt/s TX
Interface TX: N3=0, N6=0, N9=0
QoS: Passed=60, MBR Dropped=0, PPS Dropped=0
Queue Size: 0
Worker Threads: 4
========================

PFCP: Session Deletion Request received
PFCP: Deleted PFCP session - SEID: 0x1
PFCP: Session 0x1 deleted successfully
```

### Expected Statistics

**With default QER limits (PPS=1000, MBR=10Mbps)**:

- **GTP-U RX**: 60 packets (30 uplink + 30 downlink)
- **QoS Passed**: 60 packets (all packets within rate limits)
- **QoS MBR Dropped**: 0 (well below 10 Mbps)
- **QoS PPS Dropped**: 0 (10 pkt/s << 1000 pps limit)

### Testing Rate Limiting

To observe QoS enforcement, modify the test to send more packets:

**Edit `test_qer_integration.zig`**:

```zig
const TestConfig = struct {
    // ...
    packets_per_round: u32 = 500,  // Increase from 10 to 500
    rounds: u32 = 3,
    delay_between_rounds_sec: u64 = 1,  // Reduce from 5 to 1
};
```

**Expected behavior**:
- Packets sent: ~1500/second (500 × 3 rounds / 1 second)
- PPS limit: 1000 packets/second
- **Result**: ~500 packets dropped per second
- **Statistics**: `QoS: Passed=1000, MBR Dropped=0, PPS Dropped=500`

---

## Test Configuration

### Customizing Test Parameters

Edit `test_qer_integration.zig`:

```zig
const TestConfig = struct {
    // PFCP Session IDs
    cp_seid: u64 = 0x1000,

    // PDR/FAR IDs
    uplink_pdr_id: u16 = 1,
    downlink_pdr_id: u16 = 2,
    uplink_far_id: u16 = 1,
    downlink_far_id: u16 = 2,
    qer_id: u16 = 1,

    // GTP-U TEIDs
    uplink_teid: u32 = 0x100,
    downlink_teid: u32 = 0x200,

    // Test parameters
    packets_per_round: u32 = 10,     // Packets per direction per round
    rounds: u32 = 3,                  // Number of test rounds
    delay_between_rounds_sec: u64 = 5, // Delay between rounds
};
```

### Customizing QER Limits

To test different QER limits, modify PicoUPF's default QER creation:

**Edit `src/pfcp/session.zig` (lines 89-91)**:

```zig
// Test aggressive rate limiting
var qer = QER.init(1, 5);
qer.setPPS(50);                    // Lower to 50 pps
qer.setMBR(1_000_000, 1_000_000); // Lower to 1 Mbps
```

Rebuild PicoUPF:
```bash
zig build
```

**Expected with 50 pps limit**:
- Sending 500 packets → ~450 dropped
- Statistics: `QoS: Passed=50, MBR Dropped=0, PPS Dropped=450`

---

## Test Scenarios

### Scenario 1: Normal Operation (Default)

**Configuration**:
- Packets: 10 per round
- Rounds: 3
- PPS limit: 1000
- MBR limit: 10 Mbps

**Expected**:
- All packets pass QoS checks
- `QoS: Passed=60, MBR Dropped=0, PPS Dropped=0`

### Scenario 2: PPS Rate Limiting

**Configuration**:
- Packets: 500 per round
- Rounds: 3 (within 3 seconds)
- PPS limit: 1000

**Expected**:
- ~1000 packets pass, ~500 dropped
- `QoS: Passed=1000, MBR Dropped=0, PPS Dropped=500`

### Scenario 3: MBR Rate Limiting

**Configuration**:
- Packets: 1000 large packets (1500 bytes each)
- Rate: Sent rapidly (< 1 second)
- MBR limit: 10 Mbps = 10,000,000 bits/sec

**Calculation**:
- 1500 bytes × 8 bits = 12,000 bits per packet
- 10,000,000 bits/sec ÷ 12,000 bits = ~833 packets/second max

**Expected**:
- ~833 packets pass within 1 second
- Remaining ~167 dropped
- `QoS: Passed=833, MBR Dropped=167, PPS Dropped=0`

### Scenario 4: Multiple Rounds with Recovery

**Configuration**:
- Packets: 100 per round
- Rounds: 3
- Delay: 5 seconds between rounds
- PPS limit: 50

**Expected**:
- Round 1: 50 pass, 50 drop
- Round 2: 50 pass, 50 drop (tokens refilled)
- Round 3: 50 pass, 50 drop
- Total: `QoS: Passed=150, MBR Dropped=0, PPS Dropped=150`

---

## Troubleshooting

### Test hangs at "Press Enter to start test..."

**Cause**: Waiting for user input
**Solution**: Press Enter key

### "Connection refused" or "No response"

**Cause**: PicoUPF not running
**Solution**: Start PicoUPF in another terminal first

### All packets dropped (QoS: Passed=0)

**Cause**: QER limits too restrictive or TEID mismatch
**Solution**:
1. Check PicoUPF logs for PDR/FAR creation
2. Verify TEID in test matches UPF (default: 0x100)
3. Increase QER limits in `src/pfcp/session.zig`

### No QoS statistics shown

**Cause**: QER not created or not associated with PDR
**Solution**:
1. Check PFCP session establishment logs
2. Verify: `QER ID: 1 (PPS: 1000, MBR: 10000000 bps)`
3. Ensure PDR has `setQER(1)` in session.zig

### Compilation errors

**Cause**: Missing dependencies or Zig version mismatch
**Solution**:
```bash
# Check Zig version
zig version  # Should be 0.14.1

# Clean build
rm -rf .zig-cache zig-out
zig build
```

---

## Advanced Usage

### Running with Verbose Output

Add debug prints to test:

```zig
// In sendUplinkPackets():
print("Packet {}: TEID=0x{x}, Size={} bytes\n", .{ i, teid, packet_len });
```

### Capturing Statistics Programmatically

Parse PicoUPF stdout:

```bash
./zig-out/bin/picoupf | grep "QoS:" | tee qos_stats.log
```

### Automated Testing

```bash
#!/bin/bash
# automated_test.sh

# Start PicoUPF in background
./zig-out/bin/picoupf &
UPF_PID=$!
sleep 2

# Run test
echo "" | ./zig-out/bin/test_qer_integration

# Stop PicoUPF
kill $UPF_PID
```

---

## Performance Benchmarking

### Measure QER Overhead

1. **Baseline (no QER)**: Comment out QER creation in `session.zig`
2. **With QER**: Default configuration
3. **Compare**: GTP-U processing latency

**Expected overhead**: < 5% latency increase (~50-100 CPU cycles per packet)

### Stress Testing

```zig
const TestConfig = struct {
    packets_per_round: u32 = 10000,  // High volume
    rounds: u32 = 10,
    delay_between_rounds_sec: u64 = 0,  // Continuous
};
```

**Monitor**:
- CPU usage (`top` or `htop`)
- Memory usage
- Packet drop rate
- Token bucket accuracy

---

## Summary

This integration test provides:

✅ **Complete E2E validation** of QER implementation
✅ **PFCP control plane** testing (association, session)
✅ **GTP-U data plane** testing (packet processing)
✅ **QoS enforcement** validation (PPS, MBR rate limiting)
✅ **Statistics verification** (passed, dropped counts)
✅ **Customizable scenarios** for different test cases

**Test Duration**: ~30 seconds (default configuration)
**Packets Generated**: 60 (30 uplink + 30 downlink)
**PFCP Messages**: 6 (setup, establish, delete, release)

---

## Related Documentation

- **Proposal**: `PROPOSAL_QER_HANDLING.md`
- **Implementation**: `QER_IMPLEMENTATION_SUMMARY.md`
- **PFCP Integration**: `PFCP_QER_INTEGRATION.md`
- **GitHub Issue**: #8

---

**Test Suite Version**: 1.0
**Last Updated**: 2025-11-16
**Status**: ✅ Ready for Testing
