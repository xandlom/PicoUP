# PFCP QER Integration Guide

**Date**: 2025-11-16
**Status**: Phase 3 - Partial Implementation
**Branch**: `claude/gtpu-qer-handling-01WyK7dWpcrvsZaSFCwYaHw2`

---

## Current Implementation

### Session Establishment (`src/pfcp/session.zig`)

**What's Implemented**:
- ✅ QER creation during PFCP Session Establishment
- ✅ QER-PDR association using `setQER(qer_id)`
- ✅ Default QER with PPS and MBR limits
- ✅ QER logging in session creation

**Example QER Created**:
```zig
var qer = QER.init(1, 5);              // QER ID 1, QFI 5
qer.setPPS(1000);                       // 1000 packets/second
qer.setMBR(10_000_000, 10_000_000);    // 10 Mbps uplink/downlink

var pdr = PDR.init(1, 100, 0, 0x100, 1);
pdr.setQER(1);                          // Associate with QER ID 1
```

**Output**:
```
PFCP: Created session with UP SEID 0x1, PDR TEID: 0x100, QER ID: 1 (PPS: 1000, MBR: 10000000 bps)
```

---

## Full PFCP IE Parsing (Future Enhancement)

### When zig-pfcp Library Is Available

Once the zig-pfcp submodule is fully initialized with QER IE support, the implementation should be enhanced to parse Create QER IEs from PFCP messages:

### 1. Create QER IE Structure

**3GPP TS 29.244 Section 5.2.1.11**:

```zig
// Create QER IE (Type 7)
const CreateQER = struct {
    qer_id: u16,                // Mandatory: QER ID
    qfi: u8,                    // Mandatory: QoS Flow Identifier

    // Optional rate limiting parameters
    has_mbr: bool,
    mbr_uplink: u64,           // Maximum Bit Rate - Uplink
    mbr_downlink: u64,         // Maximum Bit Rate - Downlink

    has_gbr: bool,
    gbr_uplink: u64,           // Guaranteed Bit Rate - Uplink
    gbr_downlink: u64,         // Guaranteed Bit Rate - Downlink

    has_packet_delay: bool,
    packet_delay_budget: u32,  // Packet Delay Budget (ms)

    has_error_rate: bool,
    packet_error_rate: u8,     // Packet Error Rate (10^-N)
};
```

### 2. Parse Create QER IE

**In `handleSessionEstablishment()`**:

```zig
pub fn handleSessionEstablishment(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
    pfcp_association_established: *Atomic(bool),
    stats: *stats_mod.Stats,
) void {
    // ... existing code ...

    var create_qers: [16]CreateQER = undefined;
    var qer_count: u8 = 0;

    // Parse IEs from message
    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .node_id => {
                // Parse Node ID
            },
            .f_seid => {
                // Parse F-SEID
            },
            .create_pdr => {
                // Parse Create PDR IE
            },
            .create_far => {
                // Parse Create FAR IE
            },
            .create_qer => {  // NEW: Parse Create QER IE
                const qer = parseCreateQER(reader, ie_header.length) catch {
                    reader.pos += ie_header.length;
                    continue;
                };
                create_qers[qer_count] = qer;
                qer_count += 1;
            },
            else => {
                reader.pos += ie_header.length;
            },
        }
    }

    // Create session and add QERs
    if (session_manager.findSession(up_seid)) |session| {
        // Add QERs to session
        for (0..qer_count) |i| {
            const create_qer = create_qers[i];
            var qer = QER.init(create_qer.qer_id, create_qer.qfi);

            if (create_qer.has_mbr) {
                qer.setMBR(create_qer.mbr_uplink, create_qer.mbr_downlink);
            }

            if (create_qer.has_gbr) {
                qer.setGBR(create_qer.gbr_uplink, create_qer.gbr_downlink);
            }

            // Add custom PPS limit if needed (not standard PFCP)
            // qer.setPPS(1000);

            session.addQER(qer) catch {
                print("PFCP: Failed to add QER {} to session\n", .{qer.id});
            };

            print("PFCP: Added QER {} (QFI: {}) to session\n", .{qer.id, qer.qfi});
        }

        // ... create PDRs and associate with QERs ...
    }
}
```

### 3. Parse Create QER Function

```zig
fn parseCreateQER(reader: *pfcp.marshal.Reader, length: u16) !CreateQER {
    const start_pos = reader.pos;
    var create_qer = CreateQER{
        .qer_id = 0,
        .qfi = 0,
        .has_mbr = false,
        .mbr_uplink = 0,
        .mbr_downlink = 0,
        .has_gbr = false,
        .gbr_uplink = 0,
        .gbr_downlink = 0,
        .has_packet_delay = false,
        .packet_delay_budget = 0,
        .has_error_rate = false,
        .packet_error_rate = 0,
    };

    // Parse grouped IE contents
    while (reader.pos - start_pos < length) {
        const ie_header = try pfcp.marshal.decodeIEHeader(reader);
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .qer_id => {
                create_qer.qer_id = try reader.readU32();
            },
            .qfi => {
                const flags = try reader.readByte();
                create_qer.qfi = flags & 0x3F; // Lower 6 bits
            },
            .mbr => {
                // Parse MBR (40 bits uplink + 40 bits downlink)
                create_qer.mbr_uplink = try reader.readU40();
                create_qer.mbr_downlink = try reader.readU40();
                create_qer.has_mbr = true;
            },
            .gbr => {
                // Parse GBR (40 bits uplink + 40 bits downlink)
                create_qer.gbr_uplink = try reader.readU40();
                create_qer.gbr_downlink = try reader.readU40();
                create_qer.has_gbr = true;
            },
            .packet_delay_budget => {
                create_qer.packet_delay_budget = try reader.readU32();
                create_qer.has_packet_delay = true;
            },
            .packet_error_rate => {
                create_qer.packet_error_rate = try reader.readByte();
                create_qer.has_error_rate = true;
            },
            else => {
                // Skip unknown IEs
                reader.pos += ie_header.length;
            },
        }
    }

    return create_qer;
}
```

### 4. Associate QER with Create PDR

```zig
// In parseCreatePDR():
const CreatePDR = struct {
    pdr_id: u16,
    precedence: u32,
    pdi: PDI,
    far_id: u16,
    qer_id: u16,        // NEW: QER reference
    has_qer: bool,      // NEW: QER flag
    // ... other fields ...
};

// When parsing Create PDR IE:
switch (ie_type) {
    .qer_correlation_id => {  // NEW
        create_pdr.qer_id = try reader.readU32();
        create_pdr.has_qer = true;
    },
    // ... other PDR IEs ...
}

// When creating PDR from parsed IE:
var pdr = PDR.init(
    create_pdr.pdr_id,
    create_pdr.precedence,
    create_pdr.pdi.source_interface,
    create_pdr.pdi.teid,
    create_pdr.far_id
);

if (create_pdr.has_qer) {
    pdr.setQER(create_pdr.qer_id);
}
```

---

## Session Modification

### Update QER

```zig
pub fn handleSessionModification(
    socket: std.posix.socket_t,
    req_header: *const pfcp.types.PfcpHeader,
    reader: *pfcp.marshal.Reader,
    client_addr: net.Address,
    session_manager: *session_mod.SessionManager,
) void {
    const seid = req_header.seid orelse return;
    const session = session_manager.findSession(seid) orelse return;

    while (reader.remaining() > 0) {
        const ie_header = pfcp.marshal.decodeIEHeader(reader) catch break;
        const ie_type: pfcp.types.IEType = @enumFromInt(ie_header.ie_type);

        switch (ie_type) {
            .update_qer => {  // NEW: Update QER IE
                const update_qer = parseUpdateQER(reader, ie_header.length) catch {
                    reader.pos += ie_header.length;
                    continue;
                };

                // Find existing QER
                if (session.findQER(update_qer.qer_id)) |qer| {
                    // Update QER parameters
                    if (update_qer.has_mbr) {
                        qer.setMBR(update_qer.mbr_uplink, update_qer.mbr_downlink);
                    }

                    if (update_qer.has_gbr) {
                        qer.setGBR(update_qer.gbr_uplink, update_qer.gbr_downlink);
                    }

                    print("PFCP: Updated QER {} in session\n", .{qer.id});
                }
            },
            .create_qer => {  // NEW: Create QER in modification
                const create_qer = parseCreateQER(reader, ie_header.length) catch {
                    reader.pos += ie_header.length;
                    continue;
                };

                var qer = QER.init(create_qer.qer_id, create_qer.qfi);
                if (create_qer.has_mbr) {
                    qer.setMBR(create_qer.mbr_uplink, create_qer.mbr_downlink);
                }

                session.addQER(qer) catch {
                    print("PFCP: Failed to add QER to session\n", .{});
                };
            },
            .remove_qer => {  // NEW: Remove QER IE
                const qer_id = try reader.readU32();
                session.removeQER(@intCast(qer_id)) catch {
                    print("PFCP: Failed to remove QER {}\n", .{qer_id});
                };
            },
            else => {
                reader.pos += ie_header.length;
            },
        }
    }

    sendSessionModificationResponse(socket, req_header, client_addr, .request_accepted);
}
```

---

## IE Type Codes (3GPP TS 29.244)

### QER-Related IEs

| IE Name | Type | Description |
|---------|------|-------------|
| **Create QER** | 7 | Grouped IE for creating QER |
| **Update QER** | 15 | Grouped IE for updating QER |
| **Remove QER** | 16 | QER ID to remove |
| **QER ID** | 109 | QER identifier (u32) |
| **QFI** | 124 | QoS Flow Identifier (u8, lower 6 bits) |
| **MBR** | 25 | Maximum Bit Rate (uplink/downlink, 40 bits each) |
| **GBR** | 26 | Guaranteed Bit Rate (uplink/downlink, 40 bits each) |
| **Packet Delay Budget** | 198 | Maximum delay in milliseconds |
| **Packet Error Rate** | 199 | Target error rate (10^-N) |
| **QER Correlation ID** | 28 | Reference from PDR to QER |

---

## Testing

### Test Case 1: Basic QER Creation

**PFCP Message**:
```
Session Establishment Request
├─ Node ID
├─ F-SEID (CP)
├─ Create PDR
│  ├─ PDR ID: 1
│  ├─ Precedence: 100
│  ├─ PDI (source_interface=0, teid=0x100)
│  ├─ FAR ID: 1
│  └─ QER Correlation ID: 1
├─ Create FAR
│  └─ FAR ID: 1
└─ Create QER
   ├─ QER ID: 1
   ├─ QFI: 5
   ├─ MBR: 10 Mbps uplink, 10 Mbps downlink
   └─ PPS: 1000 (custom extension)
```

**Expected Result**:
```
PFCP: Created session with UP SEID 0x1, PDR TEID: 0x100
PFCP: Added QER 1 (QFI: 5) to session
PFCP: PDR 1 associated with QER 1
```

**GTP-U Behavior**:
- Packets matching PDR 1 (TEID 0x100) undergo QoS enforcement
- Rate limited to 1000 packets/second
- Rate limited to 10 Mbps
- Excess packets dropped with `qos_pps_dropped` or `qos_mbr_dropped` incremented

### Test Case 2: QER Update

**PFCP Message**:
```
Session Modification Request
└─ Update QER
   ├─ QER ID: 1
   └─ MBR: 20 Mbps uplink, 20 Mbps downlink (increased)
```

**Expected Result**:
```
PFCP: Updated QER 1 in session
```

**GTP-U Behavior**:
- MBR limit dynamically updated to 20 Mbps
- Token bucket immediately reflects new rate

---

## Current Limitations

1. **zig-pfcp Library**: Submodule not initialized, so full IE parsing not available
2. **Manual QER Creation**: Currently using hardcoded QER values
3. **PPS Not Standard**: PPS limiting is custom extension (not in 3GPP spec)
4. **No IE Validation**: Full PFCP IE validation not implemented

## Next Steps

1. ✅ **Phase 1-2 Complete**: Core QER implementation with token bucket
2. ✅ **Phase 3 Partial**: PFCP manual QER creation
3. ⏳ **Phase 3 Full**: Requires zig-pfcp library with QER IE support
4. ⏳ **Phase 4**: Integration testing with real SMF

---

## Summary

**What Works Now**:
- ✅ QER created during PFCP session establishment
- ✅ QER associated with PDR
- ✅ QoS enforcement active in GTP-U pipeline
- ✅ PPS and MBR rate limiting functional
- ✅ Statistics tracking QoS drops

**What's Missing**:
- ⏳ Full PFCP IE parsing (waiting for zig-pfcp library)
- ⏳ Dynamic QER creation from PFCP messages
- ⏳ Session modification QER support
- ⏳ QER IE encoding in responses

**Branch**: `claude/gtpu-qer-handling-01WyK7dWpcrvsZaSFCwYaHw2`
