# CLAUDE.md - AI Assistant Guide for PicoUP

This document provides comprehensive guidance for AI assistants working on the PicoUP codebase. It covers the project structure, development workflows, coding conventions, and 5G networking context.

**Last Updated**: 2025-11-16
**Project Version**: 0.1.0
**Zig Version**: 0.14.1

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Codebase Structure](#codebase-structure)
3. [Technology Stack](#technology-stack)
4. [Architecture & Key Concepts](#architecture--key-concepts)
5. [Development Workflow](#development-workflow)
6. [Build & Test Procedures](#build--test-procedures)
7. [Code Conventions](#code-conventions)
8. [5G Networking Context](#5g-networking-context)
9. [Common Tasks](#common-tasks)
10. [Gotchas & Limitations](#gotchas--limitations)

---

## Project Overview

**PicoUP** is a lightweight, educational User Plane Function (UPF) implementation for 5G networks, written in Zig and running in user space.

### Purpose
- Educational reference for understanding 5G UPF architecture
- Testing and development platform for 5G network components
- Demonstration of high-performance network programming in Zig

### Key Features
- PFCP (Packet Forwarding Control Protocol) control plane on port 8805
- GTP-U (GPRS Tunneling Protocol - User Plane) data plane on port 2152
- Multi-threaded architecture with 4 worker threads for parallel packet processing
- Support for up to 100 concurrent PFCP sessions
- N3, N6, and N9 interface handling

### Current Status
This is a simplified implementation for educational purposes. See [Gotchas & Limitations](#gotchas--limitations) for details on what's not yet implemented.

---

## Codebase Structure

```
PicoUP/
├── src/
│   ├── upf.zig                 # Main entry point and thread orchestration (180 lines)
│   ├── types.zig              # Core types: PDR, FAR, QER, URR, constants (330 lines)
│   ├── session.zig            # Session and SessionManager (380 lines)
│   ├── stats.zig              # Statistics collection and reporting (130 lines)
│   ├── pfcp/                  # PFCP control plane modules
│   │   ├── handler.zig        # Main PFCP message router (61 lines)
│   │   ├── heartbeat.zig      # Heartbeat handling (53 lines)
│   │   ├── association.zig    # Association setup (129 lines)
│   │   └── session.zig        # Session lifecycle management (285 lines)
│   └── gtpu/                  # GTP-U data plane modules
│       ├── handler.zig        # GTP-U header parsing/creation (60 lines)
│       └── worker.zig         # Worker threads and packet queue (205 lines)
├── deps/                       # Git submodules for external dependencies
│   ├── zig-pfcp/              # PFCP protocol library (github.com/xandlom/zig-pfcp)
│   └── zig-gtp-u/             # GTP-U protocol library (github.com/xandlom/zig-gtp-u)
├── build.zig                   # Build configuration (93 lines)
├── build.zig.zon              # Package metadata and dependencies
├── echo_udp_srv.zig           # Reference UDP server implementation (338 lines)
├── test_qer_integration.zig   # QER integration test (600 lines)
├── test_urr_integration.zig   # URR integration test (620 lines)
├── README.md                   # User-facing documentation
├── CLAUDE.md                   # AI assistant guide (this file)
├── LICENSE                     # Apache 2.0 License
├── .gitignore                 # Zig-specific ignore patterns
└── .gitmodules                # Git submodule configuration

Build Artifacts (gitignored):
├── .zig-cache/                # Zig build cache
└── zig-out/                   # Build output directory
    └── bin/
        ├── picoupf                    # Main executable
        ├── test_qer_integration       # QER integration test executable
        └── test_urr_integration       # URR integration test executable
```

### File Responsibilities

| File | Lines | Purpose |
|------|-------|---------|
| **Core Modules** | | |
| `src/upf.zig` | 180 | Main entry point, thread orchestration, global state |
| `src/types.zig` | 330 | Core types (PDR, FAR, QER, URR) and configuration constants |
| `src/session.zig` | 380 | Session and SessionManager with thread-safe operations |
| `src/stats.zig` | 130 | Statistics collection, atomic counters, reporting thread |
| **PFCP Modules** | | |
| `src/pfcp/handler.zig` | 61 | Main PFCP message router (dispatches by message type) |
| `src/pfcp/heartbeat.zig` | 53 | Heartbeat Request/Response handling |
| `src/pfcp/association.zig` | 129 | Association Setup Request/Response handling |
| `src/pfcp/session.zig` | 285 | Session Establishment/Modification/Deletion handlers |
| **GTP-U Modules** | | |
| `src/gtpu/handler.zig` | 60 | GTP-U header parsing and creation functions |
| `src/gtpu/worker.zig` | 205 | Worker threads, packet queue, packet processing logic |
| **Build & Tests** | | |
| `build.zig` | 93 | Build configuration, module setup, test configuration |
| `echo_udp_srv.zig` | 338 | Reference implementation demonstrating UDP server pattern |
| `test_qer_integration.zig` | 600 | QER integration test with PFCP and GTP-U flows |
| `test_urr_integration.zig` | 620 | URR integration test with usage tracking and quotas |

### Module Organization

The codebase follows a modular architecture with clear separation of concerns:

**Core Layer** (`src/*.zig`):
- `upf.zig` - Application entry point and thread management
- `types.zig` - Shared types and constants used across all modules
- `session.zig` - PFCP session state management
- `stats.zig` - Performance monitoring and metrics

**Control Plane** (`src/pfcp/*.zig`):
- `handler.zig` - Routes incoming PFCP messages to appropriate handlers
- `heartbeat.zig` - Keeps PFCP association alive
- `association.zig` - Establishes PFCP association with SMF
- `session.zig` - Manages PFCP session lifecycle (create/modify/delete)

**Data Plane** (`src/gtpu/*.zig`):
- `handler.zig` - Low-level GTP-U protocol operations
- `worker.zig` - Multi-threaded packet processing pipeline

---

## Technology Stack

### Primary Language
- **Zig 0.14.1** (required version)
- Modern systems programming language with manual memory management
- No hidden control flow, no hidden allocations
- Compile-time code execution via `comptime`

### Core Libraries
- **Zig Standard Library** (`std`)
  - `std.net` - Networking primitives
  - `std.Thread` - Threading support
  - `std.atomic.Value` - Atomic operations
  - `std.posix` - POSIX system calls (sockets, sendto, recvfrom)
  - `std.mem` - Memory operations
  - `std.time` - Time utilities

### External Dependencies (Git Submodules)
- **zig-pfcp** - PFCP protocol implementation
  - Location: `deps/zig-pfcp/src/lib.zig`
  - Repository: https://github.com/xandlom/zig-pfcp
  - Imported as: `@import("zig-pfcp")`

- **zig-gtp-u** - GTP-U protocol implementation
  - Location: `deps/zig-gtp-u/src/lib.zig`
  - Repository: https://github.com/xandlom/zig-gtp-u
  - Imported as: `@import("zig-gtp-u")`

### Build System
- **Zig Build System** (`zig build`)
- No external build tools required (no Make, CMake, etc.)
- Declarative build configuration in `build.zig`

### Networking Stack
- **UDP** - All communication uses UDP protocol
- **IPv4** - Currently IPv4-only (no IPv6 support)
- **Raw sockets** via POSIX APIs

---

## Architecture & Key Concepts

### Threading Model

PicoUP uses a multi-threaded architecture with 7 threads:

1. **Main Thread** - Initialization and coordination
2. **PFCP Thread** (`pfcpThread`) - Control plane on port 8805
3. **GTP-U Thread** (`gtpuThread`) - Data plane receiver on port 2152
4. **Worker Threads** (4x `gtpuWorkerThread`) - Parallel packet processing
5. **Statistics Thread** (`statsThread`) - Metrics reporting every 5 seconds

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

### Core Data Structures

#### 1. PDR (Packet Detection Rule) - `types.zig:15`
Defines how to identify packets that belong to a session.

```zig
const PDR = struct {
    id: u16,                    // Unique PDR identifier
    precedence: u32,            // Matching priority (higher = first)
    source_interface: u8,       // 0=N3 (Access), 1=N6 (Core), 2=N9 (UPF-to-UPF)
    teid: u32,                  // GTP-U TEID to match
    far_id: u16,                // Associated FAR to execute
    allocated: bool,            // Whether this PDR slot is in use
};
```

#### 2. FAR (Forwarding Action Rule) - `types.zig:37`
Defines what action to take when a PDR matches.

```zig
const FAR = struct {
    id: u16,                    // Unique FAR identifier
    action: u8,                 // 0=Drop, 1=Forward, 2=Buffer
    dest_interface: u8,         // 0=N3 (Access), 1=N6 (Core), 2=N9
    outer_header_creation: bool,// Whether to create new GTP-U header
    teid: u32,                  // TEID for encapsulation (if creating header)
    ipv4: [4]u8,               // Destination IP for encapsulation
    allocated: bool,            // Whether this FAR slot is in use
};
```

#### 3. Session - `session.zig:15`
Represents a PFCP session with associated PDRs, FARs, QERs, and URRs.

```zig
const Session = struct {
    seid: u64,                  // Session Endpoint ID
    cp_fseid: u64,              // Control Plane F-SEID
    up_fseid: u64,              // User Plane F-SEID (local)
    pdrs: [16]PDR,             // Up to 16 PDRs per session
    fars: [16]FAR,             // Up to 16 FARs per session
    qers: [16]QER,             // Up to 16 QERs per session
    urrs: [16]URR,             // Up to 16 URRs per session
    pdr_count: u8,
    far_count: u8,
    qer_count: u8,
    urr_count: u8,
    allocated: bool,            // Whether this session slot is in use
    mutex: Mutex,               // Thread-safe access to PDRs/FARs/QERs/URRs
};
```

**Important**: Each session has its own mutex to protect PDR/FAR/QER/URR arrays during concurrent access.

#### 4. SessionManager - `session.zig:174`
Global manager for all PFCP sessions.

```zig
const SessionManager = struct {
    sessions: [MAX_SESSIONS]Session,    // Fixed array of 100 sessions
    session_count: Atomic(usize),       // Active session count
    mutex: Mutex,                       // Protects session creation/deletion
    next_up_seid: Atomic(u64),         // Auto-incrementing SEID generator
};
```

**Key Methods**:
- `createSession(cp_fseid)` - Create new session, returns UP F-SEID
- `findSession(seid)` - Find session by SEID
- `findSessionByTeid(teid, source_interface)` - Find session by GTP-U TEID
- `deleteSession(seid)` - Delete session and free slot

#### 5. PacketQueue - `gtpu/worker.zig:25`
Thread-safe circular buffer for distributing packets to workers.

```zig
const PacketQueue = struct {
    packets: [QUEUE_SIZE]GtpuPacket,   // 1000 packet capacity
    head: Atomic(usize),                // Dequeue position
    tail: Atomic(usize),                // Enqueue position
    count: Atomic(usize),               // Current queue size
    mutex: Mutex,                       // Protects enqueue/dequeue ops
};
```

**Pattern**: Producer-consumer queue where GTP-U thread produces and worker threads consume.

#### 6. Stats - `stats.zig:13`
Atomic statistics counters for monitoring.

```zig
const Stats = struct {
    pfcp_messages: Atomic(u64),         // Total PFCP messages received
    pfcp_sessions: Atomic(u64),         // Total sessions created (cumulative)
    gtpu_packets_rx: Atomic(u64),       // GTP-U packets received
    gtpu_packets_tx: Atomic(u64),       // GTP-U packets transmitted
    gtpu_packets_dropped: Atomic(u64),  // GTP-U packets dropped
    n3_packets_tx: Atomic(u64),         // N3 interface transmissions
    n6_packets_tx: Atomic(u64),         // N6 interface transmissions
    n9_packets_tx: Atomic(u64),         // N9 interface transmissions
    queue_size: Atomic(usize),          // Current packet queue size

    // QoS enforcement statistics
    qos_packets_passed: Atomic(u64),    // Packets that passed QoS checks
    qos_mbr_dropped: Atomic(u64),       // Packets dropped due to MBR limit
    qos_pps_dropped: Atomic(u64),       // Packets dropped due to PPS limit

    // URR statistics
    urr_packets_tracked: Atomic(u64),   // Packets with usage tracked
    urr_reports_triggered: Atomic(u64), // Number of reports triggered
    urr_quota_exceeded: Atomic(u64),    // Packets dropped due to quota

    start_time: i64,                    // Server start timestamp
};
```

**All counters are atomic** to avoid race conditions when updated from multiple threads.

#### 7. QER (QoS Enforcement Rule) - `types.zig:147`
Defines QoS parameters and rate limiting for a flow.

```zig
const QER = struct {
    id: u16,                            // Unique QER identifier
    qfi: u8,                            // QoS Flow Identifier (0-63)

    // Rate limiting parameters
    has_mbr: bool,                      // Maximum Bit Rate configured
    mbr_uplink: u64,                    // MBR uplink in bits/second
    mbr_downlink: u64,                  // MBR downlink in bits/second

    has_pps_limit: bool,                // Packets Per Second limit configured
    pps_limit: u32,                     // Maximum packets per second

    // Token bucket state for rate limiting
    mbr_tokens: Atomic(u64),            // Available bits (for MBR)
    pps_tokens: Atomic(u32),            // Available packets (for PPS)
    last_refill: Atomic(i64),           // Timestamp of last token refill (ns)

    allocated: bool,
    mutex: Mutex,                       // Protects token bucket operations
};
```

**Key Methods**:
- `setMBR(uplink, downlink)` - Configure Maximum Bit Rate limits
- `setPPS(limit)` - Configure Packets Per Second limit

**Algorithm**: Token bucket algorithm for rate limiting. Tokens are refilled based on elapsed time and consumed per packet.

#### 8. URR (Usage Reporting Rule) - `types.zig:222`
Tracks data usage and triggers reports based on quotas/thresholds.

```zig
const URR = struct {
    id: u16,                            // Unique URR identifier

    // Measurement method flags
    measure_volume: bool,               // Track volume (bytes)
    measure_duration: bool,             // Track time duration

    // Volume thresholds and quotas (in bytes)
    has_volume_threshold: bool,
    volume_threshold: u64,              // Trigger report when reached (soft limit)

    has_volume_quota: bool,
    volume_quota: u64,                  // Hard limit - drop packets when exceeded

    // Time thresholds and quotas (in seconds)
    has_time_threshold: bool,
    time_threshold: u32,                // Trigger report after duration

    has_time_quota: bool,
    time_quota: u32,                    // Hard limit - drop packets when exceeded

    // Reporting triggers
    periodic_reporting: bool,
    reporting_period: u32,              // Period in seconds

    // Current usage counters (atomic for thread safety)
    volume_uplink: Atomic(u64),         // Bytes uplink
    volume_downlink: Atomic(u64),       // Bytes downlink
    volume_total: Atomic(u64),          // Total bytes

    // Timing
    start_time: Atomic(i64),            // When measurement started (ns)
    last_report_time: Atomic(i64),      // Last report timestamp (ns)

    // Status flags
    quota_exceeded: Atomic(bool),       // Volume or time quota exceeded
    report_pending: Atomic(bool),       // Report needs to be sent to SMF

    allocated: bool,
    mutex: Mutex,                       // Protects counter updates
};
```

**Key Methods**:
- `setVolumeQuota(quota)` - Configure volume quota (hard limit)
- `setVolumeThreshold(threshold)` - Configure volume threshold (soft limit)
- `setTimeQuota(quota_seconds)` - Configure time quota
- `setPeriodicReporting(period_seconds)` - Configure periodic reporting
- `resetCounters()` - Reset usage counters (called after report is sent)

**Quota vs Threshold**:
- **Quota** (hard limit): Packets are dropped when quota is exceeded
- **Threshold** (soft limit): Triggers a report but allows packets through

### Packet Processing Flow

Complete pipeline as implemented in `gtpu/worker.zig`:

1. **Stage 1 - Parse Header** (`parseHeader`):
   - GTP-U Thread receives UDP packet on port 2152
   - Parse GTP-U header to extract TEID
   - Create `GtpuPacket` and enqueue to `PacketQueue`

2. **Stage 2 - Lookup Session** (`lookupSession`):
   - Worker Thread dequeues packet
   - Find session by TEID using `SessionManager.findSessionByTeid()`

3. **Stage 3 - Match PDR** (`matchPDR`):
   - Find matching PDR in session by TEID and source interface
   - Select highest precedence PDR if multiple matches

4. **Stage 4 - Lookup FAR** (`lookupFAR`):
   - Find associated FAR using PDR's `far_id`

5. **Stage 5 - Lookup QER** (`lookupQER`) - *Optional*:
   - If PDR has `has_qer` flag set, find associated QER using PDR's `qer_id`

6. **Stage 6 - Enforce QoS** (`enforceQoS`) - *Optional*:
   - If QER exists, apply token bucket rate limiting
   - Check MBR (Maximum Bit Rate) and PPS (Packets Per Second) limits
   - Drop packet if limits exceeded

7. **Stage 7 - Lookup URR** (`lookupURR`) - *Optional*:
   - If PDR has `has_urr` flag set, find associated URR using PDR's `urr_id`

8. **Stage 8 - Track Usage** (`trackUsage`) - *Optional*:
   - If URR exists, track volume and/or duration
   - Check volume quota (hard limit) - drop packet if exceeded
   - Check volume threshold (soft limit) - trigger report if reached
   - Check time quota and threshold
   - Handle periodic reporting triggers

9. **Stage 9 - Execute FAR** (`executeFAR`):
   - Execute FAR action based on `action` field:
     - **Drop** (0): Increment dropped counter
     - **Forward** (1): Process based on `dest_interface`:
       - **N3** (0): Re-encapsulate with GTP-U, send to gNodeB
       - **N6** (1): Decapsulate, send to data network (currently just logs)
       - **N9** (2): Re-encapsulate with GTP-U, send to peer UPF
     - **Buffer** (2): Not implemented - drops packet

**Pipeline Summary**:
```
parseHeader → lookupSession → matchPDR → lookupFAR →
lookupQER → enforceQoS → lookupURR → trackUsage → executeFAR
```

**Early Termination**: Each stage returns `bool`. If a stage returns `false`, the pipeline terminates early and the packet is dropped.

### Thread Safety

The codebase uses multiple synchronization primitives:

1. **Mutexes** - Protect critical sections:
   - `Session.mutex` - Protects PDR/FAR/QER/URR arrays
   - `SessionManager.mutex` - Protects session creation/deletion
   - `PacketQueue.mutex` - Protects queue operations
   - `QER.mutex` - Protects token bucket operations
   - `URR.mutex` - Protects usage counter updates

2. **Atomic Values** - Lock-free counters:
   - All statistics counters
   - Session count
   - Queue head/tail/count
   - QER token buckets (`mbr_tokens`, `pps_tokens`, `last_refill`)
   - URR usage counters (`volume_uplink`, `volume_downlink`, `volume_total`)
   - URR timing (`start_time`, `last_report_time`)
   - URR status flags (`quota_exceeded`, `report_pending`)
   - `should_stop` flag for graceful shutdown

**Pattern**: Use `.seq_cst` (sequentially consistent) memory ordering for all atomic operations to ensure correctness.

---

## Development Workflow

### Git Branch Strategy

**CRITICAL**: Always develop on branches starting with `claude/` and ending with the session ID.

```bash
# Branch naming pattern
claude/<feature-description>-<session-id>

# Current branch example
claude/claude-md-mhz45hc0s2wssftm-01K4qLxKcVa6WZJaTAScnENn
```

**Important**: Pushing to branches not following this pattern will fail with HTTP 403.

### Git Operations Best Practices

#### Pushing Changes
```bash
# Always use -u flag for first push
git push -u origin <branch-name>

# Retry logic for network errors
# If push fails, retry up to 4 times with exponential backoff:
# 2s, 4s, 8s, 16s
```

#### Fetching/Pulling
```bash
# Prefer fetching specific branches
git fetch origin <branch-name>

# For pulls
git pull origin <branch-name>

# Same retry logic applies (4 retries with exponential backoff)
```

#### Submodule Management
```bash
# Initialize and update submodules after cloning
git submodule update --init --recursive

# This will populate deps/zig-pfcp and deps/zig-gtp-u
```

**Note**: Submodules are required for building but not initialized by default.

### Commit Message Style

Based on recent commits in the repository:

```
# Pattern: Verb phrase describing the change

# Good examples:
Add N9 interface handling for UPF-to-UPF communication
Fix segmentation fault by reducing MAX_SESSIONS
Implement complete PFCP session management
Update worker thread packet processing logic

# Focus on:
- Start with imperative verb (Add, Fix, Implement, Update, etc.)
- Be specific about what changed
- Mention the component or area affected
- Keep under 72 characters for first line
```

### Development Environment Setup

1. **Install Zig 0.14.1**:
   ```bash
   cd /tmp
   curl -L https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz -o zig-0.14.1.tar.xz
   tar -xJf zig-0.14.1.tar.xz
   export PATH=/tmp/zig-x86_64-linux-0.14.1:$PATH
   ```

2. **Clone and setup repository**:
   ```bash
   git clone <repository-url>
   cd PicoUP
   git submodule update --init --recursive
   ```

3. **Verify installation**:
   ```bash
   zig version  # Should output: 0.14.1
   ```

---

## Build & Test Procedures

### Build Commands

```bash
# Standard build (creates zig-out/bin/picoupf)
zig build

# Build with optimizations
zig build -Doptimize=ReleaseSafe   # Safe optimizations with runtime checks
zig build -Doptimize=ReleaseFast   # Maximum performance
zig build -Doptimize=ReleaseSmall  # Optimize for binary size

# Build and run immediately
zig build run

# Clean build (remove cache)
rm -rf .zig-cache zig-out
zig build
```

### Test Commands

```bash
# Run unit tests
zig build test

# Run QER integration test
zig build test-qer

# Run URR integration test
zig build test-urr

# Note: Unit tests can be added inline in src/upf.zig using:
test "description" {
    // test code
}
```

### Integration Tests

The project includes two comprehensive integration tests that verify end-to-end functionality:

**QER Integration Test** (`test_qer_integration.zig`):
- Tests PFCP association setup
- Creates PFCP session with QER (QoS Enforcement Rules)
- Sends uplink/downlink GTP-U packets
- Verifies MBR (Maximum Bit Rate) and PPS (Packets Per Second) rate limiting
- Tests token bucket algorithm

**URR Integration Test** (`test_urr_integration.zig`):
- Tests PFCP association setup
- Creates PFCP session with URR (Usage Reporting Rules)
- Sends GTP-U packets to trigger volume tracking
- Verifies volume quota enforcement (hard limit)
- Verifies volume threshold triggers (soft limit)
- Tests time-based quota and threshold enforcement

Both tests require the UPF to be running on localhost:
```bash
# Terminal 1: Start the UPF
./zig-out/bin/picoupf

# Terminal 2: Run integration test
zig build test-qer
# or
zig build test-urr
```

### Running the UPF

```bash
# Run the built executable
./zig-out/bin/picoupf

# Expected output:
=== PicoUP - User Plane Function ===
Version: 0.1.0
Worker Threads: 4
Press Ctrl+C to stop

PFCP thread started
PFCP listening on 0.0.0.0:8805
GTP-U thread started
GTP-U listening on 0.0.0.0:2152
GTP-U worker thread 0 started
GTP-U worker thread 1 started
GTP-U worker thread 2 started
GTP-U worker thread 3 started
Statistics thread started
```

### Checking Ports

```bash
# Verify UPF is listening on correct ports
netstat -uln | grep -E '8805|2152'

# Should show:
# udp  0  0  0.0.0.0:8805  0.0.0.0:*
# udp  0  0  0.0.0.0:2152  0.0.0.0:*
```

### Build Configuration

The `build.zig` file defines the following build targets:

1. **Executable** (`picoupf`):
   - Entry point: `src/upf.zig`
   - Imports: zig-pfcp, zig-gtp-u modules
   - Output: `zig-out/bin/picoupf`

2. **Run Step** (`zig build run`):
   - Builds and executes the UPF
   - Forwards command-line arguments if provided

3. **Test Step** (`zig build test`):
   - Compiles and runs unit tests from `src/upf.zig`
   - Includes same imports as main executable

4. **QER Integration Test** (`zig build test-qer`):
   - Entry point: `test_qer_integration.zig`
   - Output: `zig-out/bin/test_qer_integration`
   - Tests QoS enforcement with MBR/PPS rate limiting

5. **URR Integration Test** (`zig build test-urr`):
   - Entry point: `test_urr_integration.zig`
   - Output: `zig-out/bin/test_urr_integration`
   - Tests usage tracking with volume/time quotas

### Debugging Build Issues

```bash
# Verbose build output
zig build --verbose

# Check build system
zig build --help

# Validate build.zig syntax
zig build-exe build.zig --check

# Common issues:
# 1. Submodules not initialized → run: git submodule update --init
# 2. Wrong Zig version → verify: zig version
# 3. Missing dependencies → check deps/ directory exists
```

---

## Code Conventions

### Zig Style Guidelines

Following standard Zig conventions as used in this codebase:

#### Naming Conventions

```zig
// Types: PascalCase
const PDR = struct { ... };
const SessionManager = struct { ... };

// Functions: camelCase
fn createSession() void { }
fn parseGtpuHeader() void { }

// Variables: snake_case
var packet_queue: PacketQueue = undefined;
const worker_threads = 4;

// Constants: SCREAMING_SNAKE_CASE
const WORKER_THREADS = 4;
const MAX_SESSIONS = 100;
const PFCP_PORT = 8805;
```

#### Struct Patterns

```zig
// Pattern 1: Constructor function named 'init'
const Session = struct {
    field1: type,
    field2: type,

    fn init(params) Session {
        return Session{
            .field1 = value,
            .field2 = value,
        };
    }
};

// Pattern 2: Methods take *Self as first parameter
fn addPDR(self: *Session, pdr: PDR) !void {
    // Implementation
}

// Pattern 3: Field initialization with undefined for arrays
var session = Session{
    .pdrs = undefined,  // Will be initialized later
    .pdr_count = 0,
};
```

#### Error Handling

```zig
// Return error union for fallible operations
fn createSession(self: *SessionManager) !u64 {
    if (count >= MAX_SESSIONS) {
        return error.TooManySessions;  // Return named error
    }
    // Success path
    return up_fseid;
}

// Use try for error propagation
const header = try parseGtpuHeader(data);

// Use catch for error handling
const bytes = std.posix.recvfrom(...) catch |err| {
    print("Error: {}\n", .{err});
    continue;
};

// Catch with specific actions
const value = parseValue(data) catch {
    print("Parse failed\n", .{});
    return;
};
```

#### Memory Management

```zig
// Use GeneralPurposeAllocator for testing/simple cases
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();  // Cleanup at scope exit
const allocator = gpa.allocator();

// Fixed-size arrays on stack (preferred when size is known)
var buffer: [2048]u8 = undefined;

// Avoid dynamic allocation when possible
// This codebase uses fixed-size arrays throughout for predictability
```

#### Thread Safety Patterns

```zig
// Pattern 1: Mutex-protected critical section
self.mutex.lock();
defer self.mutex.unlock();  // Automatic unlock at scope exit
// Critical section code

// Pattern 2: Atomic operations
const count = self.session_count.load(.seq_cst);
_ = self.session_count.fetchAdd(1, .seq_cst);
_ = self.session_count.store(new_value, .seq_cst);

// Pattern 3: Discard unused return values with _
_ = global_stats.gtpu_packets_rx.fetchAdd(1, .seq_cst);
```

#### Print Debugging

```zig
// Use std.debug.print for logging
const print = std.debug.print;

// Format specifiers
print("Value: {}\n", .{value});          // Generic formatter
print("Hex: 0x{x}\n", .{value});         // Hexadecimal
print("IP: {}.{}.{}.{}\n", .{a, b, c, d}); // Multiple values

// Common pattern: prefix with component name
print("PFCP: Message received\n", .{});
print("Worker {}: Processing packet\n", .{thread_id});
```

#### Integer Type Conversions

```zig
// Explicit casts with @intCast when changing size
const length: u16 = @intCast(payload.len);
const thread_id = @as(u32, @intCast(i));

// Use @sizeOf for getting sizes
var client_address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
```

#### Memory Operations

```zig
// Copy memory with @memcpy
@memcpy(packet.data[0..bytes_received], buffer[0..bytes_received]);

// Read/write integers with endianness
const teid = std.mem.readInt(u32, data[4..8], .big);
std.mem.writeInt(u32, buffer[4..8], teid, .big);

// Convert struct to bytes
std.mem.asBytes(&enable)
```

### Code Organization

The modular architecture follows these organizational principles:

**Per-Module Structure**:
1. **Imports First** - Standard library and local module imports
2. **Type Definitions** - Structs and enums specific to the module
3. **Public Functions** - Exported functions used by other modules
4. **Private Functions** - Internal helper functions

**Example from `types.zig`**:
```zig
const std = @import("std");                    // Imports

pub const WORKER_THREADS = 4;                  // Constants
pub const QUEUE_SIZE = 1000;

pub const PDR = struct { ... };                // Type definitions
pub const FAR = struct { ... };
```

**Example from `upf.zig`** (main entry point):
```zig
// 1. Imports (stdlib and local modules)
const std = @import("std");
const types = @import("types.zig");
const session_mod = @import("session.zig");

// 2. Global variables (initialized in main)
pub var global_stats: stats_mod.Stats = undefined;
pub var session_manager: session_mod.SessionManager = undefined;

// 3. Thread functions
fn pfcpThread(...) !void { ... }
fn gtpuThread() !void { ... }

// 4. Main function (last)
pub fn main() !void { ... }
```

**Module Dependencies**:
- `types.zig` - No dependencies (foundation)
- `session.zig` - Depends on `types.zig`
- `stats.zig` - Depends on `types.zig`, `session.zig`
- `pfcp/*.zig` - Depends on `types.zig`, `session.zig`, `stats.zig`
- `gtpu/*.zig` - Depends on `types.zig`, `session.zig`, `stats.zig`
- `upf.zig` - Depends on all modules (orchestration layer)

### Comments

```zig
// Single-line comments for brief explanations
const PFCP_PORT = 8805; // Control plane port

// Multi-line comments for complex logic
// Parse GTP-U header (simplified)
// This implementation doesn't support extension headers
// Returns the TEID and payload offset
```

**Note**: This codebase has minimal comments. Code is self-documenting through clear naming.

---

## 5G Networking Context

Understanding the 5G context is crucial for working on this codebase.

### 5G Core Network Architecture

```
┌──────────┐      N2       ┌──────────┐
│  gNodeB  │◄─────────────►│   AMF    │ (Access and Mobility Management)
│(Base Stn)│               └──────────┘
└────┬─────┘                     │
     │ N3                        │ N11
     │ (GTP-U)                   ▼
     │                     ┌──────────┐
     │                     │   SMF    │ (Session Management)
     │                     └────┬─────┘
     │                          │ N4
     │                          │ (PFCP)
     ▼                          ▼
┌─────────────┐           ┌──────────┐
│   PicoUP    │◄─────────►│ PicoUP   │ (This implementation)
│   (Peer)    │    N9     │  (UPF)   │
└─────────────┘  (GTP-U)  └────┬─────┘
                               │ N6
                               ▼
                         ┌──────────┐
                         │   Data   │ (Internet, Services)
                         │ Network  │
                         └──────────┘
```

### Interfaces Implemented in PicoUP

| Interface | Protocol | Port | Direction | Purpose |
|-----------|----------|------|-----------|---------|
| **N4** | PFCP | 8805 | SMF ↔ UPF | Control plane: session management |
| **N3** | GTP-U | 2152 | gNodeB → UPF | Uplink traffic from base station |
| **N6** | IP | N/A | UPF → DN | Downlink to data network (partial) |
| **N9** | GTP-U | 2152 | UPF ↔ UPF | Inter-UPF communication |

### PFCP (Packet Forwarding Control Protocol)

**Purpose**: Control plane protocol between SMF and UPF for session management.

**Key Message Types** (implemented in `pfcp/handler.zig:handlePfcpMessage`):

| Type | Name | Description |
|------|------|-------------|
| 1 | Heartbeat Request | SMF checks UPF liveness |
| 2 | Heartbeat Response | UPF responds to heartbeat |
| 50 | Session Establishment Request | Create new PFCP session with PDRs/FARs |
| 51 | Session Establishment Response | Acknowledge session creation |
| 53 | Session Deletion Request | Remove PFCP session |
| 54 | Session Deletion Response | Acknowledge session deletion |

**PFCP Header Format**:
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Ver|   Flags   | Message Type  |         Message Length        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Sequence Number                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        SEID (optional)                        |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Current Implementation Status**:
- ✅ Heartbeat Request/Response
- ✅ Session Establishment (simplified)
- ✅ Session Deletion (simplified)
- ❌ Session Modification
- ❌ Session Report
- ❌ Full IE (Information Element) parsing

### GTP-U (GPRS Tunneling Protocol - User Plane)

**Purpose**: Data plane protocol for tunneling user traffic over UDP.

**GTP-U Header Format** (see `gtpu/handler.zig:parseGtpuHeader`):
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Ver|PT|*|E|S|PN | Message Type  |         Length                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Tunnel Endpoint Identifier (TEID)             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Sequence Number (optional)             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   N-PDU Number  | Next Ext Hdr Type (optional)                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**Fields**:
- **Ver**: Version (always 1)
- **PT**: Protocol Type (1 for GTP)
- **E**: Extension Header flag
- **Message Type**: 0xFF for G-PDU (user data)
- **TEID**: Tunnel Endpoint Identifier (maps to session)

**TEID (Tunnel Endpoint Identifier)**:
- 32-bit value identifying a GTP-U tunnel
- Each PDR specifies which TEID to match
- Used to route packets to correct session

**Current Implementation**:
- ✅ Basic GTP-U header parsing (8 bytes, no extensions)
- ✅ G-PDU (0xFF) message type
- ✅ TEID-based session lookup
- ✅ GTP-U encapsulation (`gtpu/handler.zig:createGtpuHeader`)
- ❌ Extension header support
- ❌ Sequence number handling
- ❌ Echo Request/Response
- ❌ Error Indication

### PDR and FAR Concepts

**PDR (Packet Detection Rule)**:
- Defines **matching criteria** for incoming packets
- Multiple PDRs can exist per session
- Precedence determines evaluation order
- Each PDR points to one FAR

**FAR (Forwarding Action Rule)**:
- Defines **what to do** with matched packets
- Actions: Drop, Forward, Buffer
- Specifies destination interface
- May include outer header creation (for re-encapsulation)

**Example Flow**:
1. Packet arrives with TEID=0x100 on N3 interface
2. Find session with PDR matching TEID=0x100, source_interface=0
3. PDR has far_id=1
4. Find FAR with id=1
5. FAR specifies: action=Forward, dest_interface=1 (N6)
6. Forward decapsulated packet to data network

### Source Interface Values

| Value | Name | Description |
|-------|------|-------------|
| 0 | Access (N3) | From gNodeB/base station |
| 1 | Core (N6) | From data network |
| 2 | UPF-to-UPF (N9) | From peer UPF |

### Destination Interface Values

Same as source interface values. Determines where packet is forwarded.

### 3GPP Specifications

Reference documents for protocol details:

- **3GPP TS 29.244** - PFCP Protocol specification
- **3GPP TS 29.281** - GTP-U Protocol specification
- **3GPP TS 23.501** - 5G System Architecture

These can be found at: https://www.3gpp.org/DynaReport/29-series.htm

---

## Common Tasks

### Adding a New PFCP Message Type

1. **Identify message type code** from TS 29.244
2. **Add new message type to `pfcp/handler.zig`** switch statement
3. **Create handler function** in appropriate `pfcp/*.zig` module
4. **Parse message IEs** (Information Elements) using zig-pfcp library
5. **Update session state** via SessionManager
6. **Send response message** using zig-pfcp library

Example in `pfcp/handler.zig`:
```zig
.session_report_request => {
    pfcp_session.handleSessionReport(socket, &header, &reader, client_addr, session_manager);
},
```

Then implement handler in `pfcp/session.zig`:
```zig
pub fn handleSessionReport(
    socket: std.posix.socket_t,
    header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
) void {
    // Parse SEID and IEs
    // Update session state
    // Send response
}
```

### Adding a New FAR Action

1. **Define action code** in `types.zig` FAR struct comment (line 39)
2. **Add case in `gtpu/worker.zig`** worker thread function (around line 105)
3. **Implement forwarding logic**
4. **Update statistics** if needed

Example for "Buffer" action in `gtpu/worker.zig`:
```zig
2 => { // Buffer
    print("Worker {}: Buffering packet, TEID: 0x{x}\n", .{thread_id, header.teid});
    // Store packet in buffer
    // Increment buffer counter
    _ = stats.buffer_packets.fetchAdd(1, .seq_cst);
},
```

### Adding a New Statistic

1. **Add atomic counter** to `stats.zig` Stats struct (line 13)
2. **Initialize in Stats.init()** (line 25)
3. **Increment at appropriate location** using `.fetchAdd()`
4. **Display in statsThread** in `stats.zig` (line 43)

Example:
```zig
// In stats.zig Stats struct
buffer_packets: Atomic(u64),

// In Stats.init()
.buffer_packets = Atomic(u64).init(0),

// In gtpu/worker.zig
_ = stats.buffer_packets.fetchAdd(1, .seq_cst);

// In stats.zig statsThread function
const buffered = stats.buffer_packets.load(.seq_cst);
print("Buffered Packets: {}\n", .{buffered});
```

### Adjusting Session Limits

To change maximum sessions or PDRs/FARs per session:

```zig
// In types.zig constants section (line 11)
pub const MAX_SESSIONS = 200;  // Change from 100 to 200

// In session.zig Session struct (lines 19-20)
pdrs: [32]PDR,  // Change from 16 to 32
fars: [32]FAR,  // Change from 16 to 32

// Update checks in session.zig addPDR/addFAR (lines 49, 61)
if (self.pdr_count >= 32) {  // Update from 16
    return error.TooManyPDRs;
}
```

**Warning**: Increasing limits increases memory usage. Each session is ~2KB.

### Implementing Actual N6 Forwarding

Currently N6 forwarding only logs. To implement actual forwarding:

```zig
// In gtpu/worker.zig, N6 case (around line 138)
1 => { // Core (N6) - Forward to data network
    // 1. Create raw socket or TUN/TAP interface
    // 2. Extract inner IP packet from payload
    // 3. Send decapsulated packet to data network
    // 4. Handle routing and NAT if needed

    // Example (simplified):
    const inner_ip_packet = payload;  // payload is already IP packet
    _ = std.posix.send(n6_socket, inner_ip_packet, 0) catch |err| {
        print("Worker {}: Failed to send to N6: {}\n", .{thread_id, err});
        continue;
    };
},
```

### Adding Configuration File Support

Currently all config is hardcoded. To add config file:

1. **Define config struct**:
   ```zig
   const Config = struct {
       pfcp_port: u16,
       gtpu_port: u16,
       worker_threads: usize,
       max_sessions: usize,
       upf_ipv4: [4]u8,
   };
   ```

2. **Add JSON parsing** using `std.json`:
   ```zig
   const config_file = try std.fs.cwd().readFileAlloc(allocator, "config.json", 4096);
   defer allocator.free(config_file);
   const config = try std.json.parseFromSlice(Config, allocator, config_file, .{});
   defer config.deinit();
   ```

3. **Use config values** instead of constants

### Running Multiple UPFs

To test N9 interface with multiple UPF instances:

```bash
# Terminal 1: Run first UPF (default ports)
./zig-out/bin/picoupf

# Terminal 2: Modify and run second UPF
# Need to change ports to avoid conflicts
# Or bind to different IP addresses
```

**Note**: Current implementation binds to 0.0.0.0 (all interfaces). For testing, would need to modify to bind to specific IPs.

---

## Gotchas & Limitations

### Current Limitations

This is a simplified UPF implementation for educational and testing purposes:

1. **Limited PFCP Support**: Basic session lifecycle implemented
   - ✅ Association Setup
   - ✅ Session Establishment
   - ✅ Session Modification (basic)
   - ✅ Session Deletion
   - ⚠️ Session Report (type 56) - URR triggers reports but PFCP reporting not implemented
   - ⚠️ Usage Reporting - URR tracks usage locally, but PFCP Session Report not sent to SMF
   - ❌ Complete IE parsing

2. **Simplified Packet Processing**: Based on FAR rules
   - ✅ Forward and Drop actions
   - ❌ No actual buffering
   - ❌ No notification to SMF for non-URR events

3. **Partial N6 Interface**: Does not forward decapsulated packets to data network
   - Counts as forwarded but doesn't actually send
   - Would require raw socket or TUN/TAP interface
   - Requires routing and NAT setup

4. **Partial N9 Interface**: Basic UPF-to-UPF forwarding
   - ✅ Re-encapsulation works
   - ✅ Forwarding to peer UPF
   - ❌ No path management
   - ❌ No redundancy/failover
   - ❌ No QoS between UPFs

5. **QoS Support**: QER implemented with rate limiting and QFI extraction
   - ✅ QER (QoS Enforcement Rules) with MBR and PPS limits
   - ✅ Token bucket rate limiting
   - ✅ Traffic shaping via rate limits
   - ✅ QFI parsing from GTP-U extension headers (PDU Session Container)
   - ❌ No GBR (Guaranteed Bit Rate) enforcement

6. **Partial Usage Reporting**: URR implemented with volume/time tracking
   - ✅ URR (Usage Reporting Rules) tracks volume and duration
   - ✅ Volume quota (hard limit) enforcement
   - ✅ Volume threshold (soft limit) triggers
   - ✅ Time quota and threshold support
   - ✅ Periodic reporting triggers
   - ❌ PFCP Session Report messages not sent to SMF (reports only logged)
   - ❌ No charging integration

7. **Simplified PDR/FAR**: Basic TEID matching with extended PDI support
   - ✅ TEID matching (F-TEID)
   - ✅ Source interface matching
   - ✅ UE IP address matching
   - ✅ SDF filter (protocol, destination port range)
   - ✅ Precedence-based PDR selection
   - ⚠️ Application ID matching (PDI field exists, but no DPI logic)
   - ❌ No source port matching
   - ❌ No full 5-tuple matching

### Known Issues

1. **Fixed Session Limit**: MAX_SESSIONS reduced to 100 due to segfault (commit 42beec7)
   - Higher values cause stack overflow
   - Consider heap allocation for production

2. **Extension Header Support**: PDU Session Container parsing implemented
   - ✅ QFI extraction from extension headers
   - ✅ Echo requests with sequence numbers work correctly
   - ❌ Other extension header types not yet used (available in library)

3. **No IPv6 Support**: All addresses are IPv4
   - Hardcoded to `std.posix.AF.INET`
   - Would need dual-stack support

4. **No Graceful Shutdown**: Ctrl+C kills threads immediately
   - Could add signal handler to set `should_stop`
   - Would need proper socket closure

5. **Global State**: All major structures are global variables
   - Makes testing difficult
   - Could refactor to pass context

### Common Pitfalls

1. **Forgetting to initialize submodules**:
   ```bash
   # This fails:
   git clone <repo>
   zig build  # Error: deps/zig-pfcp/src/lib.zig not found

   # Do this instead:
   git submodule update --init
   zig build  # Success
   ```

2. **Wrong Zig version**:
   ```bash
   # build.zig.zon specifies minimum_zig_version = "0.14.1"
   # Using 0.13.0 will fail with syntax errors
   zig version  # Verify before building
   ```

3. **Port already in use**:
   ```bash
   # UPF fails to start if ports are in use
   # Check with: netstat -uln | grep -E '8805|2152'
   # Kill conflicting process or change ports
   ```

4. **Race conditions in testing**:
   - Multiple worker threads process packets concurrently
   - Order of packet processing is non-deterministic
   - Use atomic counters for verification, not exact ordering

5. **Buffer sizes**:
   - Fixed 2048-byte buffers throughout
   - Jumbo frames (>2048) will be truncated
   - MTU is typically 1500, so usually safe

6. **TEID conflicts**:
   - If two sessions have PDRs with same TEID, first match wins
   - findSessionByTeid returns first matching session
   - Ensure unique TEIDs per source interface

### Memory Considerations

Current memory usage (approximate):

```
Session struct: ~2KB (16 PDRs + 16 FARs + metadata)
SessionManager: ~200KB (100 sessions)
PacketQueue: ~2MB (1000 packets × 2KB each)
Worker thread stacks: ~8MB (4 threads × 2MB default)
Total: ~10MB working set
```

**For production**: Consider heap allocation for sessions and dynamic queue sizing.

### Testing Considerations

1. **Unit tests**: Can be added inline in source files using `test` blocks
2. **Integration tests available**:
   - `test_qer_integration.zig` - Tests QoS enforcement end-to-end
   - `test_urr_integration.zig` - Tests usage tracking end-to-end
   - Both tests require UPF to be running on localhost
3. **Use echo_udp_srv.zig as reference**: Shows UDP client/server testing pattern
4. **Statistics are key**: Use atomic counters to verify behavior
5. **Integration test pattern**: Tests send PFCP messages, create sessions, send GTP-U packets, verify behavior

### Performance Notes

1. **Lock contention**: SessionManager.mutex is global bottleneck
   - Consider lock-free hash table for session lookup
   - Or shard sessions across multiple managers

2. **Queue size**: 1000 packets may be insufficient under high load
   - Monitor queue_size statistic
   - If frequently full, increase QUEUE_SIZE

3. **Worker thread count**: 4 threads good for 4+ core systems
   - Adjust WORKER_THREADS based on CPU count
   - Too many workers = excessive context switching

4. **Copy overhead**: Packets copied into queue
   - Consider ring buffer with pointers instead
   - Would require careful lifetime management

---

## Quick Reference

### File Locations

| What | Where |
|------|-------|
| Main entry point | `src/upf.zig` |
| Core types | `src/types.zig` |
| Session management | `src/session.zig` |
| Statistics | `src/stats.zig` |
| PFCP modules | `src/pfcp/` |
| GTP-U modules | `src/gtpu/` |
| Build config | `build.zig` |
| Dependencies | `deps/` |
| Executable | `zig-out/bin/picoupf` |
| QER integration test | `test_qer_integration.zig` |
| URR integration test | `test_urr_integration.zig` |
| Documentation | `README.md`, `CLAUDE.md` |

### Port Numbers

| Port | Protocol | Purpose |
|------|----------|---------|
| 8805 | PFCP/UDP | Control plane (SMF ↔ UPF) |
| 2152 | GTP-U/UDP | Data plane (gNodeB ↔ UPF ↔ UPF) |

### Key Constants

| Constant | Value | Location | Adjustable |
|----------|-------|----------|------------|
| WORKER_THREADS | 4 | types.zig:7 | ✅ Yes |
| QUEUE_SIZE | 1000 | types.zig:8 | ✅ Yes |
| PFCP_PORT | 8805 | types.zig:9 | ✅ Yes |
| GTPU_PORT | 2152 | types.zig:10 | ✅ Yes |
| MAX_SESSIONS | 100 | types.zig:11 | ⚠️ Carefully |

### Command Cheat Sheet

```bash
# Setup
git submodule update --init --recursive

# Build
zig build                           # Debug build
zig build -Doptimize=ReleaseFast   # Release build

# Run
./zig-out/bin/picoupf              # Run UPF
zig build run                       # Build and run

# Test
zig build test                      # Run unit tests
zig build test-qer                  # Run QER integration test
zig build test-urr                  # Run URR integration test

# Clean
rm -rf .zig-cache zig-out          # Remove build artifacts

# Check
zig version                         # Verify Zig version
netstat -uln | grep -E '8805|2152' # Check ports
```

### Statistics Output Format

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

---

## Additional Resources

### External Documentation

- **Zig Language Reference**: https://ziglang.org/documentation/master/
- **Zig Standard Library**: https://ziglang.org/documentation/master/std/
- **3GPP Specifications**: https://www.3gpp.org/specifications-technologies
- **PFCP Spec (TS 29.244)**: https://www.3gpp.org/DynaReport/29244.htm
- **GTP-U Spec (TS 29.281)**: https://www.3gpp.org/DynaReport/29281.htm

### Related Repositories

- **zig-pfcp**: https://github.com/xandlom/zig-pfcp
- **zig-gtp-u**: https://github.com/xandlom/zig-gtp-u

### Community

For issues or questions:
- **PicoUP Issues**: File on main repository
- **PFCP Issues**: https://github.com/xandlom/zig-pfcp/issues
- **GTP-U Issues**: https://github.com/xandlom/zig-gtp-u/issues

---

## Change Log

| Date | Version | Changes |
|------|---------|---------|
| 2025-11-16 | 1.1 | Add QER/URR integration tests, update file structure and line counts, add integration test documentation |
| 2025-11-14 | 1.0 | Initial CLAUDE.md creation with comprehensive documentation |

---

*This document is maintained for AI assistants working on the PicoUP codebase. Please keep it updated when making significant architectural changes.*
