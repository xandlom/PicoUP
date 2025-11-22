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
  - N6 interface support (Data network - with NAT)
  - N9 interface support (UPF-to-UPF communication)

- **N6 NAT Support**: Full bidirectional data network connectivity
  - Source NAT (SNAT) for uplink traffic (UE to internet)
  - Destination NAT (DNAT) for downlink traffic (internet to UE)
  - Automatic NAT table management with timeout
  - TUN interface for user-space packet forwarding
  - Graceful fallback to stub mode when TUN unavailable

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
                   └────┬────┘           └─────────┘ └─────────┘
                        │
                        │ N6 (Uplink with SNAT)
                        ▼
                   ┌──────────┐        ┌─────────────┐
                   │NAT Table │◄──────►│ N6 Receiver │
                   └────┬─────┘        │   Thread    │
                        │              └──────┬──────┘
                        │                     │ N6 (Downlink with DNAT)
                        ▼                     │
                   ┌─────────┐                │
                   │   TUN   │◄───────────────┘
                   │Interface│
                   │  (upf0) │
                   └────┬────┘
                        │
                        ▼
                   ┌─────────┐
                   │ Internet│
                   └─────────┘
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

## N6 Interface Setup (NAT)

To enable actual forwarding of UE traffic to the internet, you need to set up the N6 TUN interface.

### Quick Setup

```bash
# Set up TUN interface and routing (requires root)
sudo ./scripts/setup_n6.sh setup

# Start PicoUP
./zig-out/bin/picoupf
```

### Manual Setup

If you prefer manual setup or need customization:

```bash
# 1. Create TUN device (replace $USER with your username)
sudo ip tuntap add dev upf0 mode tun user $USER

# 2. Configure IP address (UPF's external IP for NAT)
sudo ip addr add 10.45.0.1/16 dev upf0

# 3. Bring up the interface
sudo ip link set upf0 up

# 4. Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# 5. Add NAT masquerade (replace eth0 with your external interface)
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o eth0 -j MASQUERADE

# 6. Allow forwarding for TUN interface
sudo iptables -A FORWARD -i upf0 -j ACCEPT
sudo iptables -A FORWARD -o upf0 -j ACCEPT
```

### Check N6 Status

```bash
sudo ./scripts/setup_n6.sh status
```

### Teardown

```bash
sudo ./scripts/setup_n6.sh teardown
```

### Stub Mode (No TUN)

If the TUN interface is not available, PicoUP runs in "stub mode":
- Uplink N6 packets are counted but not forwarded to the internet
- Downlink is not functional
- All other features (PFCP, N3, N9, QoS, URR) work normally

This is useful for testing session management without network setup.

## Examples

The `examples/` directory contains tools for testing the complete data path.

### End-to-End Test with Echo Server

This demonstrates the complete N3 → UPF → N6 → Echo Server → N6 → UPF → N3 flow.

**Terminal 1: Start Echo Server (N6 side)**
```bash
# Build examples
zig build

# Start UDP echo server on port 9999
./zig-out/bin/echo_server_n6 9999
```

**Terminal 2: Set up N6 and Start UPF**
```bash
# Set up TUN interface (if not already done)
sudo ./scripts/setup_n6.sh setup

# Start PicoUP
./zig-out/bin/picoupf
```

**Terminal 3: Run N3 Client**
```bash
# Run client (simulates gNodeB + UE)
# Usage: udp_client_n3 <echo_server_ip> [port]
./zig-out/bin/udp_client_n3 127.0.0.1 9999
```

The N3 client will:
1. Establish PFCP association with UPF
2. Create a PFCP session with uplink/downlink PDRs and FARs
3. Send GTP-U encapsulated UDP packets to the UPF
4. Receive echoed responses via the GTP-U downlink path
5. Clean up the session and association

### Example Output

**Echo Server:**
```
╔════════════════════════════════════════════════════════════╗
║          UDP Echo Server (N6 Side)                        ║
╚════════════════════════════════════════════════════════════╝

Echo server listening on 0.0.0.0:9999
[1] Received 22 bytes from 10.45.0.1:10000 - Echoed 22 bytes
[2] Received 22 bytes from 10.45.0.1:10001 - Echoed 22 bytes
```

**N3 Client:**
```
╔════════════════════════════════════════════════════════════╗
║          UDP Client (N3 Side - gNodeB Simulator)          ║
╚════════════════════════════════════════════════════════════╝

Step 1: PFCP Association Setup
Sent PFCP Association Setup Request
Received PFCP Association Setup Response - OK

Step 2: PFCP Session Establishment
  - PDR 1: Uplink (N3->N6), TEID=0x1000
  - PDR 2: Downlink (N6->N3), UE IP=10.45.0.100
  - FAR 1: Forward to N6
  - FAR 2: Forward to N3 with GTP-U encap (TEID=0x2000)
Received PFCP Session Establishment Response - OK

Step 3: Sending UDP Packets via GTP-U Tunnel
[TX 1] Sent: "Hello from UE! Packet #1" (52 bytes)
[RX 1] Received echo (TEID=0x2000): "Hello from UE! Packet #1"

Results: Sent=5, Received=5, Lost=0
```

### Build Commands

```bash
# Build everything including examples
zig build

# Build and run echo server
zig build example-echo-server -- 9999

# Build and run N3 client
zig build example-n3-client -- 127.0.0.1 9999
```

## Statistics

The UPF prints statistics every 5 seconds:

```
=== PicoUP Statistics ===
Uptime: 30s
PFCP Messages: 15, Active Sessions: 3/3
GTP-U RX: 1500, TX: 1450, Dropped: 50
GTP-U Rate: 50 pkt/s RX, 48 pkt/s TX
GTP-U Echo: Req=5, Resp=5
Interface TX: N3=500, N6=800, N9=150
QoS: Passed=1400, MBR Dropped=30, PPS Dropped=20
URR: Tracked=1350, Reports=2, Quota Exceeded=5
N6 NAT: RX=200, Active=15, Created=20, Hits=180, Misses=5
Queue Size: 0
Worker Threads: 4
========================
```

### N6 NAT Statistics Explained

- **RX**: Downlink packets received from data network
- **Active**: Currently active NAT entries
- **Created**: Total NAT entries created
- **Hits**: NAT table lookup successes
- **Misses**: NAT table lookup failures (usually dropped downlink packets)

## Current Limitations

This is a simplified UPF implementation for educational and testing purposes:

1. **Limited PFCP Support**: Session Modification is basic; URR triggers reports but PFCP Session Report messages not sent to SMF
2. **N6 NAT Only**: N6 uses internal NAT rather than relying on external routing; requires TUN interface setup
3. **Partial N9 Interface**: Basic UPF-to-UPF forwarding implemented, but no path management or QoS
4. **Partial QoS Support**: QER implemented with MBR/PPS rate limiting; QFI extraction from GTP-U extension headers supported
5. **Partial Usage Reporting**: URR tracks usage locally, but no PFCP Session Report messages sent to SMF
6. **IPv4 Only**: No IPv6 support for UE addresses or NAT

## Future Enhancements

To make this a production-ready UPF, the following features need to be added:

- [x] Basic N9 interface for UPF-to-UPF communication
- [x] Session Modification support
- [x] PFCP Association Setup
- [x] QoS enforcement (QER) with MBR and PPS rate limiting
- [x] Usage reporting (URR) with volume/time tracking and quota enforcement
- [x] N6 interface with NAT for data network connectivity
- [x] QoS flow support with QFI parsing from GTP-U extension headers
- [ ] PFCP Session Report messages (URR local tracking works, but no PFCP reports sent to SMF)
- [ ] Advanced N9 features (path management, redundancy)
- [ ] Complete PDR matching (source IP ports, enhanced SDF filters)
- [ ] Complete FAR actions (buffering, notification to SMF)
- [ ] Charging integration
- [ ] IPv6 support

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
│   ├── nat.zig               # NAT table management for N6
│   ├── checksum.zig          # IP/TCP/UDP checksum utilities
│   ├── tun.zig               # TUN interface handler for N6
│   ├── pfcp/                 # PFCP control plane modules
│   │   ├── handler.zig       # Main PFCP message router
│   │   ├── heartbeat.zig     # Heartbeat handling
│   │   ├── association.zig   # Association setup
│   │   └── session.zig       # Session lifecycle management
│   └── gtpu/                 # GTP-U data plane modules
│       ├── handler.zig       # GTP-U header parsing/creation
│       └── worker.zig        # Worker threads and packet processing pipeline
├── examples/
│   ├── echo_server_n6.zig    # UDP echo server for N6 testing
│   └── udp_client_n3.zig     # GTP-U client simulating gNodeB + UE
├── scripts/
│   └── setup_n6.sh           # N6 TUN interface setup script
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
