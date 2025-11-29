# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build
zig build                           # Debug build
zig build -Doptimize=ReleaseFast    # Release build

# Run
./zig-out/bin/picoupf               # Run UPF
zig build run                        # Build and run

# Test
zig build test                       # Unit tests
zig build test-qer                   # QER integration test (requires UPF running)
zig build test-urr                   # URR integration test (requires UPF running)

# Examples - UDP
zig build example-echo-server -- 9999          # N6 UDP echo server
zig build example-n3-client -- 127.0.0.1 9999  # N3 UDP client (gNodeB simulator)

# Examples - TCP
zig build example-tcp-echo-server -- 9999      # N6 TCP echo server
zig build example-tcp-n3-client -- 127.0.0.1 9999  # N3 TCP client

# Docker Compose (alternative to native build)
docker-compose up                              # Start all services
docker-compose up upf echo-server              # Start UPF and echo server
docker-compose run --rm n3-client              # Run N3 client test
docker-compose --profile tcp up upf tcp-echo-server  # TCP test setup

# Setup
git submodule update --init --recursive   # Required: initialize deps
```

**Zig Version**: 0.14.1 (required)

## Architecture Overview

PicoUP is a lightweight 5G User Plane Function (UPF) in Zig. It handles:
- **N4 (PFCP)**: Control plane on port 8805 - session management with SMF
- **N3 (GTP-U)**: Data plane on port 2152 - uplink from gNodeB
- **N6**: Data network interface with NAT via TUN device
- **N9 (GTP-U)**: UPF-to-UPF forwarding

### Threading Model (7 threads)

```
SMF ←→ PFCP Thread (8805) ←→ SessionManager
gNodeB → GTP-U Thread (2152) → PacketQueue → Worker Threads (4x)
                                                    ↓
Statistics Thread (every 5s)                   TUN (upf0) → Internet
                                               N6 Receiver Thread ↑
```

### Core Data Flow

```
Packet arrives → Parse GTP-U → Lookup Session by TEID → Match PDR →
Find FAR → [Optional: QER rate limit] → [Optional: URR track usage] →
Execute FAR action (Forward/Drop)
```

## Key Source Files

| Path | Purpose |
|------|---------|
| `src/upf.zig` | Entry point, thread orchestration, global state |
| `src/types.zig` | Core types: PDR, FAR, QER, URR, constants |
| `src/session.zig` | SessionManager with thread-safe PFCP session handling |
| `src/stats.zig` | Atomic statistics counters |
| `src/nat.zig` | NAT table for N6 interface |
| `src/tun.zig` | TUN interface handler for N6 |
| `src/checksum.zig` | IP/TCP/UDP checksum utilities |
| `src/pfcp/handler.zig` | PFCP message router |
| `src/pfcp/session.zig` | Session Establishment/Modification/Deletion |
| `src/gtpu/worker.zig` | Worker threads, packet processing pipeline |

**Dependencies** (git submodules in `deps/`):
- `zig-pfcp` - PFCP protocol (import as `@import("zig-pfcp")`)
- `zig-gtp-u` - GTP-U protocol (import as `@import("zig-gtp-u")`)

## Key Concepts

### 5G UPF Terminology

- **PDR** (Packet Detection Rule): Matches packets by TEID, source interface, UE IP
- **FAR** (Forwarding Action Rule): Defines action (Forward/Drop) and destination
- **QER** (QoS Enforcement Rule): Rate limiting via token bucket (MBR, PPS)
- **URR** (Usage Reporting Rule): Volume/time tracking with quotas
- **TEID**: Tunnel Endpoint Identifier - 32-bit value identifying GTP-U tunnels
- **F-SEID**: Session Endpoint Identifier for PFCP sessions

### Interface Values

| Value | Interface | Description |
|-------|-----------|-------------|
| 0 | N3 (Access) | From/to gNodeB |
| 1 | N6 (Core) | From/to data network |
| 2 | N9 | UPF-to-UPF |

### Thread Safety Patterns

```zig
// Mutex pattern (always use defer)
self.mutex.lock();
defer self.mutex.unlock();

// Atomic pattern (always use .seq_cst)
const count = self.counter.load(.seq_cst);
_ = self.counter.fetchAdd(1, .seq_cst);
```

## Code Conventions

- **Types**: PascalCase (`SessionManager`, `PDR`)
- **Functions**: camelCase (`createSession`, `parseGtpuHeader`)
- **Variables**: snake_case (`packet_queue`, `worker_threads`)
- **Constants**: SCREAMING_SNAKE_CASE (`MAX_SESSIONS`, `PFCP_PORT`)

Fixed-size arrays used throughout for predictable memory. All counters are atomic.

## Common Tasks

### Adding a PFCP Message Type

1. Add case to switch in `src/pfcp/handler.zig`
2. Create handler function in appropriate `src/pfcp/*.zig` module
3. Use zig-pfcp library for parsing/marshaling

### Adding a Statistic

1. Add `Atomic(u64)` field to `Stats` struct in `src/stats.zig`
2. Initialize in `Stats.init()`
3. Increment with `fetchAdd(1, .seq_cst)`
4. Display in `statsThread()`

### Testing N6 End-to-End

**Native Build:**
```bash
# Terminal 1: Set up TUN and start UPF
sudo ./scripts/setup_n6.sh setup
./zig-out/bin/picoupf

# Terminal 2: Start echo server
./zig-out/bin/echo_server_n6 9999

# Terminal 3: Run N3 client
./zig-out/bin/udp_client_n3 127.0.0.1 9999
```

**Docker Compose:**
```bash
# Terminal 1: Start UPF and echo server
docker-compose up upf echo-server

# Terminal 2: Run N3 client
docker-compose run --rm n3-client
```

## Key Constants (in `src/types.zig`)

| Constant | Value | Notes |
|----------|-------|-------|
| `WORKER_THREADS` | 4 | Adjustable |
| `QUEUE_SIZE` | 1000 | Adjustable |
| `PFCP_PORT` | 8805 | Standard |
| `GTPU_PORT` | 2152 | Standard |
| `MAX_SESSIONS` | 100 | Limited due to stack size |
| `N6_TUN_DEVICE` | "upf0" | TUN device name |
| `N6_EXTERNAL_IP` | 10.45.0.1 | UPF's NAT IP |
| `N6_UE_POOL_PREFIX` | 10.45.0.0/16 | UE IP pool |

## Known Limitations

- **MAX_SESSIONS capped at 100**: Higher values cause stack overflow (uses fixed arrays)
- **IPv4 only**: No IPv6 support
- **N6 requires TUN**: Without TUN device, runs in stub mode (counts but doesn't forward)
- **URR reports logged only**: PFCP Session Report not sent to SMF
- **No graceful shutdown**: Ctrl+C kills threads immediately

## Port Usage

| Port | Protocol | Purpose |
|------|----------|---------|
| 8805 | PFCP/UDP | Control plane (SMF ↔ UPF) |
| 2152 | GTP-U/UDP | Data plane (gNodeB ↔ UPF) |
