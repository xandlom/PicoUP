# PicoUP - Lightweight 5G User Plane Function

PicoUP is a simple, lightweight User Plane Function (UPF) implementation for 5G networks, written in Zig and running in user space.

## Features

- **PFCP Control Plane**: Handles PFCP (Packet Forwarding Control Protocol) messages on port 8805
  - Association Setup (PFCP session establishment between SMF and UPF)
  - Heartbeat Request/Response
  - Session Establishment/Modification/Deletion
  - PDR (Packet Detection Rules) and FAR (Forwarding Action Rules) management
  - QER (QoS Enforcement Rules) with MBR and PPS rate limiting
  - URR (Usage Reporting Rules) with volume/time tracking

- **GTP-U Data Plane**: Handles GTP-U (GPRS Tunneling Protocol - User Plane) packets on port 2152
  - G-PDU packet processing
  - TEID-based session lookup
  - Packet forwarding based on FAR rules
  - QoS enforcement via QER (token bucket rate limiting)
  - Usage tracking via URR (volume quota and threshold enforcement)
  - N3 interface support (Access network - gNodeB)
  - N6 interface support (Data network - partial implementation)
  - N9 interface support (UPF-to-UPF communication)

- **Multi-threaded Architecture**: Based on echo_udp_srv.zig pattern
  - Dedicated PFCP control plane thread
  - Dedicated GTP-U data plane thread
  - 4 worker threads for parallel packet processing
  - Statistics thread for monitoring

- **Session Management**:
  - Support for up to 100 concurrent PFCP sessions
  - Each session can have up to 16 PDRs, 16 FARs, 16 QERs, and 16 URRs
  - Thread-safe session lookup and management

## Architecture

```
┌─────────────┐         ┌─────────────┐
│     SMF     │◄───────►│ PFCP Thread │
└─────────────┘  8805   └─────────────┘
                              │
                              ▼
                        ┌──────────────┐
                        │   Session    │
                        │   Manager    │
                        └──────────────┘
                              ▲
┌─────────────┐         ┌─────┴────────┐      ┌──────────────┐
│    gNodeB   │────────►│ GTP-U Thread │─────►│ Packet Queue │
└─────────────┘  2152   └──────────────┘      └──────┬───────┘
                                                      │
                        ┌──────────────────────┬──────┴───┬────────┐
                        ▼                      ▼          ▼        ▼
                   ┌─────────┐           ┌─────────┐ ┌─────────┐ ...
                   │Worker 0 │           │Worker 1 │ │Worker 2 │
                   └─────────┘           └─────────┘ └─────────┘
```

## Dependencies

- **zig-pfcp**: PFCP protocol implementation ([github.com/xandlom/zig-pfcp](https://github.com/xandlom/zig-pfcp))
- **zig-gtp-u**: GTP-U protocol implementation ([github.com/xandlom/zig-gtp-u](https://github.com/xandlom/zig-gtp-u))

## Building

### Requirements

- Zig 0.14.1

### Install Zig

```bash
cd /tmp
curl -L https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz -o zig-0.14.1.tar.xz
tar -xJf zig-0.14.1.tar.xz
export PATH=/tmp/zig-x86_64-linux-0.14.1:$PATH
```

### Build PicoUP

```bash
git clone <repository-url>
cd PicoUP
zig build
```

The executable will be located at `zig-out/bin/picoupf`

## Running

```bash
./zig-out/bin/picoupf
```

The UPF will start listening on:
- Port 8805 for PFCP messages (UDP)
- Port 2152 for GTP-U packets (UDP)

## Statistics

The UPF prints statistics every 5 seconds:

```
=== PicoUP Statistics ===
Uptime: 30s
PFCP Messages: 15, Active Sessions: 3/3
GTP-U RX: 1500, TX: 1450, Dropped: 50
GTP-U Rate: 50 pkt/s RX, 48 pkt/s TX
Interface TX: N3=500, N6=800, N9=150
QoS: Passed=1400, MBR Dropped=30, PPS Dropped=20
URR: Tracked=1350, Reports=2, Quota Exceeded=5
Queue Size: 0
Worker Threads: 4
========================
```

## Current Limitations

This is a simplified UPF implementation for educational and testing purposes:

1. **Limited PFCP Support**: Session Modification is basic; URR triggers reports but PFCP Session Report messages not sent to SMF
2. **Simplified Packet Processing**: N6 interface logs packets but doesn't forward to data network
3. **Partial N6 Interface**: Does not forward decapsulated packets to data network (requires routing setup)
4. **Partial N9 Interface**: Basic UPF-to-UPF forwarding implemented, but no path management or QoS
5. **Partial QoS Support**: QER implemented with MBR/PPS rate limiting, but no QFI parsing from GTP-U extension headers
6. **Partial Usage Reporting**: URR tracks usage locally, but no PFCP Session Report messages sent to SMF

## Future Enhancements

To make this a production-ready UPF, the following features need to be added:

- [x] Basic N9 interface for UPF-to-UPF communication
- [x] Session Modification support
- [x] PFCP Association Setup
- [x] QoS enforcement (QER) with MBR and PPS rate limiting
- [x] Usage reporting (URR) with volume/time tracking and quota enforcement
- [ ] PFCP Session Report messages (URR local tracking works, but no PFCP reports sent to SMF)
- [ ] Full N6 interface for forwarding to data network
- [ ] Advanced N9 features (path management, redundancy)
- [ ] QoS flow support with QFI parsing from GTP-U extension headers
- [ ] Complete PDR matching (source IP ports, enhanced SDF filters)
- [ ] Complete FAR actions (buffering, notification to SMF)
- [ ] Charging integration
- [ ] Proper GTP-U extension header support

## File Structure

```
PicoUP/
├── build.zig                  # Build configuration
├── build.zig.zon              # Package metadata
├── src/
│   ├── upf.zig               # Main entry point and thread orchestration
│   ├── types.zig             # Core types (PDR, FAR, QER, URR) and constants
│   ├── session.zig           # Session and SessionManager
│   ├── stats.zig             # Statistics collection and reporting
│   ├── pfcp/                 # PFCP control plane modules
│   │   ├── handler.zig       # Main PFCP message router
│   │   ├── heartbeat.zig     # Heartbeat handling
│   │   ├── association.zig   # Association setup
│   │   └── session.zig       # Session lifecycle management
│   └── gtpu/                 # GTP-U data plane modules
│       ├── handler.zig       # GTP-U header parsing/creation
│       └── worker.zig        # Worker threads and packet processing pipeline
├── deps/                      # Dependencies (git submodules)
│   ├── zig-pfcp/
│   └── zig-gtp-u/
├── echo_udp_srv.zig           # Reference UDP server implementation
├── test_qer_integration.zig   # QER integration test
├── test_urr_integration.zig   # URR integration test
├── README.md                  # This file
└── CLAUDE.md                  # AI assistant guide
```

## License

Apache-2.0 (following the dependencies)

## Contributing

This is a simple reference implementation. For feature requests or issues with PFCP or GTP-U functionality, please file issues in the respective dependency repositories:

- PFCP issues: https://github.com/xandlom/zig-pfcp/issues
- GTP-U issues: https://github.com/xandlom/zig-gtp-u/issues

## References

- 3GPP TS 29.244: PFCP Protocol
- 3GPP TS 29.281: GTP-U Protocol
- 3GPP TS 23.501: 5G System Architecture
