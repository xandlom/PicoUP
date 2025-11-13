# PicoUP - Lightweight 5G User Plane Function

PicoUP is a simple, lightweight User Plane Function (UPF) implementation for 5G networks, written in Zig and running in user space.

## Features

- **PFCP Control Plane**: Handles PFCP (Packet Forwarding Control Protocol) messages on port 8805
  - Heartbeat Request/Response
  - Session Establishment/Deletion
  - PDR (Packet Detection Rules) and FAR (Forwarding Action Rules) management

- **GTP-U Data Plane**: Handles GTP-U (GPRS Tunneling Protocol - User Plane) packets on port 2152
  - G-PDU packet processing
  - TEID-based session lookup
  - Packet forwarding based on FAR rules

- **Multi-threaded Architecture**: Based on echo_udp_srv.zig pattern
  - Dedicated PFCP control plane thread
  - Dedicated GTP-U data plane thread
  - 4 worker threads for parallel packet processing
  - Statistics thread for monitoring

- **Session Management**:
  - Support for up to 10,000 concurrent PFCP sessions
  - Each session can have up to 16 PDRs and 16 FARs
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
Queue Size: 0
Worker Threads: 4
========================
```

## Current Limitations

This is a simplified UPF implementation for educational and testing purposes:

1. **Limited PFCP Support**: Only basic session establishment/deletion is implemented
2. **Simplified Packet Processing**: Currently logs and drops packets based on FAR rules
3. **No N6 Interface**: Does not forward decapsulated packets to data network
4. **No N9 Interface**: Does not support UPF-to-UPF forwarding
5. **No QoS Support**: QoS flows and QFI handling not implemented
6. **Simplified PDR/FAR**: Only basic TEID matching and forward/drop actions

## Future Enhancements

To make this a production-ready UPF, the following features need to be added:

- [ ] Complete PFCP message support (Session Modification, Session Reports)
- [ ] N6 interface for forwarding to data network
- [ ] N9 interface for UPF-to-UPF communication
- [ ] QoS flow support with QFI handling
- [ ] Complete PDR matching (source IP, destination IP, etc.)
- [ ] Complete FAR actions (buffering, notification)
- [ ] Usage reporting (URR)
- [ ] QoS enforcement (QER)
- [ ] Proper GTP-U extension header support

## File Structure

```
PicoUP/
├── build.zig           # Build configuration
├── build.zig.zon       # Package metadata
├── src/
│   └── upf.zig        # Main UPF implementation
├── deps/              # Dependencies (cloned via git)
│   ├── zig-pfcp/
│   └── zig-gtp-u/
├── echo_udp_srv.zig   # Reference implementation
└── README.md          # This file
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
