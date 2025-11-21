# zig-gtp-u Library Analysis for PicoUP

This document analyzes the zig-gtp-u library capabilities and identifies gaps/underutilization in PicoUP.

## Current Usage in PicoUP

PicoUP uses zig-gtp-u minimally in 1 file with ~8 API references:

| File | Usage |
|------|-------|
| `src/gtpu/handler.zig` | Header encode/decode only |

### What's Currently Used

```zig
const gtpu = @import("zig-gtp-u");

// Only these features are used:
gtpu.GtpuHeader.MANDATORY_SIZE  // Constant (8 bytes)
gtpu.GtpuHeader.decode()        // Parse incoming header
gtpu.GtpuHeader.encode()        // Create outgoing header
gtpu.GtpuHeader.init()          // Initialize header struct
header.teid                      // Access TEID field
header.size()                    // Get header size
```

## Library Capabilities vs PicoUP Usage

The zig-gtp-u library is **feature-rich but underutilized** by PicoUP:

| Feature | zig-gtp-u Support | PicoUP Usage |
|---------|-------------------|--------------|
| G-PDU (0xFF) messages | Full | Basic |
| Echo Request/Response | Full | Not used |
| End Marker | Full | Not used |
| Error Indication | Full | Not used |
| Extension headers (11 types) | Full | Not used |
| PDU Session Container (QFI) | Full | Not used |
| Path management | Full | Not used |
| Tunnel state machine | Full | Not used |
| Session management | Full | Not used |
| QoS flow management | Full | Not used |
| Anti-replay protection | Full | Not used |
| Memory pooling | Full | Not used |
| PCAP capture | Full | Not used |
| TEID generation | Full | Not used |

## Critical Underutilized Features

### 1. Extension Headers (Critical for 5G)

The library supports 11 extension header types:

| Type | Code | Purpose | 5G Relevance |
|------|------|---------|--------------|
| PDU Session Container | 0x85 | Contains QFI | Critical |
| PDCP PDU Number | 0xC0 | Sequencing | Important |
| Long PDCP PDU Number | 0x82 | Extended sequencing | Important |
| Service Class Indicator | 0x20 | Classification | Useful |
| UDP Port | 0x40 | Port info | Useful |
| RAN Container | 0x81 | RAN data | Useful |
| NR RAN Container | 0x84 | NR specific | Useful |

#### PDU Session Container (0x85)

This is **essential for 5G QoS** and contains:
- PDU Type (4 bits): 0=downlink, 1=uplink
- **QFI - QoS Flow Identifier** (6 bits): 0-63
- Paging Policy Indicator (3 bits)
- Reflective QoS Indicator (1 bit)

**Current PicoUP limitation** (from CLAUDE.md):
> "No QFI parsing from GTP-U extension headers"

**Solution**: Use the existing library feature:
```zig
const gtpu = @import("zig-gtp-u");

// Parse extension headers
const header = try gtpu.GtpuHeader.decode(reader);
if (header.next_extension_type) |ext_type| {
    if (ext_type == .pdu_session_container) {
        const ext = try gtpu.extension.PduSessionContainer.decode(reader);
        const qfi = ext.qfi;  // QoS Flow Identifier (0-63)
        // Use QFI for QoS enforcement
    }
}
```

### 2. Echo Request/Response (Path Management)

The library provides full path management:

```zig
const gtpu = @import("zig-gtp-u");

// Path states: unknown → active → suspect → failed
const path_manager = gtpu.path.PathManager.init();

// Echo mechanism
// - Configurable interval (default: 60s)
// - Timeout detection (default: 5s)
// - Max consecutive failures (default: 3)
// - RTT monitoring (min/max/avg)
```

**Current PicoUP limitation** (from CLAUDE.md):
> "Echo requests with sequence numbers fail"

### 3. Tunnel State Machine

The library provides proper tunnel lifecycle:

```zig
// States: inactive → establishing → active → modifying → releasing → released
const tunnel = gtpu.tunnel.Tunnel.init(config);
tunnel.activate();
tunnel.modify(new_params);
tunnel.release();
```

**Current PicoUP limitation**: Uses simple boolean flags instead of state machine.

### 4. QoS Flow Management

The library has comprehensive 5G QoS support:

```zig
const gtpu = @import("zig-gtp-u");

// 5QI (5G QoS Identifier) definitions
const qos_flow = gtpu.qos.QosFlow.init()
    .setQfi(5)
    .set5qi(.conversational_voice)  // GBR flow
    .setMbr(uplink_mbr, downlink_mbr)
    .setGbr(uplink_gbr, downlink_gbr)
    .build();
```

### 5. Anti-Replay Protection

```zig
const gtpu = @import("zig-gtp-u");

// Sliding window for sequence number validation
const anti_replay = gtpu.utils.AntiReplayWindow.init(window_size);
if (!anti_replay.check(sequence_number)) {
    // Replay attack detected
}
```

### 6. PCAP Capture (Debugging)

```zig
const gtpu = @import("zig-gtp-u");

// Wireshark-compatible capture
const pcap = gtpu.pcap.PcapWriter.init("capture.pcap");
pcap.writePacket(timestamp, packet_data);
```

### 7. TEID Generation

```zig
const gtpu = @import("zig-gtp-u");

// Cryptographic TEID generation (vs simple counter)
const teid_gen = gtpu.utils.TeidGenerator.init();
const teid = teid_gen.generate();  // Never returns 0
```

## What's Actually Missing in zig-gtp-u

The library is quite complete. Minor gaps:

| Gap | Impact | Severity |
|-----|--------|----------|
| UPF-specific integration examples | Learning curve | Low |
| Batch packet processing helpers | Performance | Low |

## Recommended PicoUP Enhancements

### Priority 1: Enable Extension Header Parsing

Update `src/gtpu/handler.zig` to parse PDU Session Container:

```zig
pub fn parseGtpuPacket(data: []const u8) !GtpuPacketInfo {
    const header = try gtpu.GtpuHeader.decode(data);

    var qfi: ?u8 = null;
    if (header.flags.extension_header) {
        // Parse extension header chain
        var offset = header.size();
        while (true) {
            const ext_type = data[offset];
            if (ext_type == 0x85) {  // PDU Session Container
                const pdu_container = try gtpu.extension.PduSessionContainer.decode(data[offset..]);
                qfi = pdu_container.qfi;
            }
            // ... handle chain
        }
    }

    return GtpuPacketInfo{
        .teid = header.teid,
        .qfi = qfi,
        .payload_offset = header.size(),
    };
}
```

### Priority 2: Add Path Management

Implement Echo Request/Response handling:

```zig
// In src/gtpu/handler.zig or new src/gtpu/path.zig
pub fn handleEchoRequest(socket: Socket, data: []const u8, sender: Address) !void {
    const header = try gtpu.GtpuHeader.decode(data);

    // Create Echo Response
    var response: [16]u8 = undefined;
    const resp_header = gtpu.GtpuHeader.init(.echo_response);
    resp_header.sequence_number = header.sequence_number;
    resp_header.encode(&response);

    _ = try std.posix.sendto(socket, &response, 0, sender);
}
```

### Priority 3: Use PCAP for Debugging

Add optional packet capture:

```zig
// In src/upf.zig
var pcap_writer: ?gtpu.pcap.PcapWriter = null;

pub fn enablePcapCapture(filename: []const u8) !void {
    pcap_writer = try gtpu.pcap.PcapWriter.init(filename);
}
```

### Priority 4: Leverage Memory Pooling

Replace current PacketQueue with library's pool:

```zig
const gtpu = @import("zig-gtp-u");

// Use library's optimized memory pool
var packet_pool = gtpu.pool.PacketPool.init(allocator, pool_size);
defer packet_pool.deinit();

const packet = try packet_pool.acquire();
defer packet_pool.release(packet);
```

## Library Statistics

| Module | Lines | Purpose |
|--------|-------|---------|
| `lib.zig` | 39 | Main exports |
| `protocol.zig` | 157 | Message types, constants |
| `header.zig` | 172 | Header encode/decode |
| `message.zig` | 267 | Message handling |
| `extension.zig` | 349 | 11 extension types |
| `tunnel.zig` | 379 | Tunnel state machine |
| `session.zig` | 360 | PDU session lifecycle |
| `qos.zig` | 322 | 5G QoS flows |
| `path.zig` | 308 | Path management |
| `utils.zig` | 408 | TEID gen, anti-replay |
| `pool.zig` | 375 | Memory pooling |
| `pcap.zig` | 561 | Wireshark capture |
| **Total** | ~4,075 | Full GTP-U stack |

## Impact Assessment

| Underutilized Feature | Impact on PicoUP |
|-----------------------|------------------|
| Extension headers | Cannot extract QFI for QoS |
| Path management | No peer liveness detection |
| State machines | Less robust session handling |
| PCAP capture | Harder debugging |
| Memory pooling | Suboptimal performance |

**Estimated Utilization**: PicoUP uses ~5% of zig-gtp-u capabilities

## References

- 3GPP TS 29.281 - GTP-U Protocol Specification
- 3GPP TS 23.501 - 5G System Architecture (QoS)
- zig-gtp-u repository: https://github.com/xandlom/zig-gtp-u
