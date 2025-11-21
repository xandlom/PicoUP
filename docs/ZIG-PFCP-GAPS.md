# zig-pfcp Library Gaps for PicoUP

This document analyzes what features are missing in the zig-pfcp library that PicoUP needs for a complete 5G UPF implementation.

## Current Usage in PicoUP

PicoUP uses zig-pfcp in 5 files with ~35 API references:

| File | Usage |
|------|-------|
| `src/upf.zig` | Import only |
| `src/pfcp/handler.zig` | Message routing by type |
| `src/pfcp/heartbeat.zig` | Heartbeat Request/Response |
| `src/pfcp/association.zig` | Association Setup |
| `src/pfcp/session.zig` | Session lifecycle |

### What's Currently Used

- **Types**: `PfcpHeader`, `MessageType`, `IEType`, `CauseValue`, `NodeIdType`
- **Marshaling**: `Reader.init()`, `Writer.init()`, `decodePfcpHeader()`, `decodeIEHeader()`
- **Basic IEs**: `Cause`, `NodeId`, `FSEID`, `RecoveryTimeStamp`

## Critical Missing Features

### 1. Grouped IE Encoding/Decoding

The library lacks support for nested/grouped Information Elements required for session management:

| IE Type | Name | Purpose | Status |
|---------|------|---------|--------|
| 1 | CreatePDR | Create Packet Detection Rule | Missing |
| 3 | CreateFAR | Create Forwarding Action Rule | Missing |
| 6 | CreateURR | Create Usage Reporting Rule | Missing |
| 7 | CreateQER | Create QoS Enforcement Rule | Missing |
| 8 | CreateBAR | Create Buffering Action Rule | Missing |
| 9 | UpdatePDR | Update Packet Detection Rule | Missing |
| 11 | UpdateFAR | Update Forwarding Action Rule | Missing |
| 13 | UpdateURR | Update Usage Reporting Rule | Missing |
| 14 | UpdateQER | Update QoS Enforcement Rule | Missing |
| 16 | RemovePDR | Remove Packet Detection Rule | Missing |
| 18 | RemoveFAR | Remove Forwarding Action Rule | Missing |
| 20 | RemoveURR | Remove Usage Reporting Rule | Missing |
| 21 | RemoveQER | Remove QoS Enforcement Rule | Missing |

#### Example: CreatePDR Structure Needed

```
CreatePDR (Grouped IE)
├── PDR ID (Mandatory)
├── Precedence (Mandatory)
├── PDI - Packet Detection Information (Mandatory, Grouped)
│   ├── Source Interface (Mandatory)
│   ├── F-TEID (Optional)
│   ├── UE IP Address (Optional)
│   ├── SDF Filter (Optional)
│   └── Application ID (Optional)
├── FAR ID (Optional)
├── URR ID (Optional)
├── QER ID (Optional)
└── Activate Predefined Rules (Optional)
```

### 2. Session Report Messages

PicoUP's URR implementation tracks usage but cannot report it to the SMF:

| Message Type | Name | Purpose | Status |
|--------------|------|---------|--------|
| 56 | Session Report Request | Report usage/events to SMF | Missing |
| 57 | Session Report Response | Acknowledge report | Missing |

#### Required IEs for Session Report

- Usage Report (Grouped IE)
  - URR ID
  - UR-SEQN (Usage Report Sequence Number)
  - Usage Report Trigger
  - Volume Measurement
  - Duration Measurement
  - Time of First/Last Packet
  - Start/End Time

### 3. PDI (Packet Detection Information) Parsing

The PDI grouped IE contains critical matching criteria:

| IE | Purpose | Status |
|----|---------|--------|
| Source Interface | N3/N6/N9 identification | Missing |
| F-TEID | Local F-TEID for matching | Missing |
| UE IP Address | UE's IP for matching | Missing |
| SDF Filter | 5-tuple filter | Missing |
| Application ID | DPI-based matching | Missing |
| QFI | QoS Flow Identifier | Missing |

### 4. FAR Action Parameters

| IE | Purpose | Status |
|----|---------|--------|
| Apply Action | Forward/Drop/Buffer flags | Missing |
| Forwarding Parameters (Grouped) | Where to forward | Missing |
| Outer Header Creation | GTP-U encapsulation | Missing |
| Destination Interface | N3/N6/N9 target | Missing |

### 5. QER Parameters

| IE | Purpose | Status |
|----|---------|--------|
| QER ID | Identifier | Missing |
| QER Correlation ID | Correlation | Missing |
| Gate Status | UL/DL gate open/close | Missing |
| MBR | Maximum Bit Rate | Missing |
| GBR | Guaranteed Bit Rate | Missing |
| QFI | QoS Flow Identifier | Missing |

### 6. URR Parameters

| IE | Purpose | Status |
|----|---------|--------|
| URR ID | Identifier | Missing |
| Measurement Method | Volume/Duration/Event | Missing |
| Reporting Triggers | When to report | Missing |
| Volume Threshold | Soft limit | Missing |
| Volume Quota | Hard limit | Missing |
| Time Threshold | Time-based soft limit | Missing |
| Time Quota | Time-based hard limit | Missing |
| Measurement Period | Periodic reporting | Missing |

## Evidence of Gap in PicoUP Code

### Session Handler TODO

From `src/pfcp/session.zig:87`:
```zig
// TODO: Parse Create PDR, Create FAR, Create QER IEs from PFCP message when zig-pfcp is available
```

### Manual Encoding Workarounds

The integration tests contain extensive manual binary encoding:

**test_qer_integration.zig** (~200 lines of manual encoding):
```zig
// Note: zig-pfcp doesn't have encode functions for CreatePDR/FAR/QER yet
// Manual IE encoding for CreatePDR
fn encodeCreatePDR(buffer: []u8, pdr_id: u16, ...) usize {
    // Manual byte-by-byte encoding
}
```

**test_urr_integration.zig** (~200 lines of manual encoding):
```zig
// Note: zig-pfcp doesn't have encode functions for CreatePDR/FAR/URR yet
// Manual IE encoding for CreateURR
fn encodeCreateURR(buffer: []u8, urr_id: u16, ...) usize {
    // Manual byte-by-byte encoding
}
```

## Recommended Library Enhancements

### Priority 1: Grouped IE Support

Add builder pattern for grouped IEs:

```zig
// Proposed API
const create_pdr = pfcp.ie.CreatePDR.init()
    .setPdrId(1)
    .setPrecedence(100)
    .setPdi(pfcp.ie.PDI.init()
        .setSourceInterface(.access)
        .setFTeid(teid, ipv4)
        .build())
    .setFarId(1)
    .build();

writer.writeGroupedIE(create_pdr);
```

### Priority 2: Session Report Support

Add Session Report Request/Response message builders:

```zig
// Proposed API
const report = pfcp.messages.SessionReportRequest.init()
    .setSeid(session_seid)
    .addUsageReport(pfcp.ie.UsageReport.init()
        .setUrrId(1)
        .setVolumeMeasurement(uplink, downlink, total)
        .setDuration(duration_seconds)
        .build())
    .build();
```

### Priority 3: Complete IE Decoder

Add decode functions for all IEs:

```zig
// Proposed API
const pdi = try pfcp.ie.PDI.decode(reader);
const f_teid = pdi.getFTeid();
const ue_ip = pdi.getUeIpAddress();
const sdf_filter = pdi.getSdfFilter();
```

## Impact Assessment

| Feature Gap | Impact on PicoUP |
|-------------|------------------|
| CreatePDR/FAR/QER/URR encoding | Must manually encode in tests |
| Session Report Request | Cannot report usage to SMF |
| PDI parsing | Cannot parse real SMF messages |
| Complete IE decode | Limited interoperability |

**Estimated Missing Functionality**: ~30% of required PFCP features for production UPF

## References

- 3GPP TS 29.244 - PFCP Protocol Specification
- zig-pfcp repository: https://github.com/xandlom/zig-pfcp
