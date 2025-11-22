# zig-pfcp Library Integration Status for PicoUP

**Last Updated**: 2025-11-22

This document tracks the integration status of the zig-pfcp library with PicoUP. The previously identified gaps have been addressed in the zig-pfcp library.

## Current Status: ✅ Grouped IE Support Implemented

The zig-pfcp library now provides full encoding and decoding support for grouped Information Elements:

### Implemented Features

| IE Type | Name | Encode | Decode | Status |
|---------|------|--------|--------|--------|
| 1 | CreatePDR | ✅ `encodeCreatePDR` | ✅ `decodeCreatePDR` | Implemented |
| 3 | CreateFAR | ✅ `encodeCreateFAR` | ✅ `decodeCreateFAR` | Implemented |
| 6 | CreateURR | ✅ `encodeCreateURR` | ✅ `decodeCreateURR` | Implemented |
| 7 | CreateQER | ✅ `encodeCreateQER` | ✅ `decodeCreateQER` | Implemented |
| 2 | PDI | ✅ `encodePDI` | ✅ `decodePDI` | Implemented |
| 4 | ForwardingParameters | ✅ `encodeForwardingParameters` | ✅ `decodeForwardingParameters` | Implemented |

### PicoUP Integration

PicoUP now uses the zig-pfcp library's grouped IE functions:

**Session Handler (`src/pfcp/session.zig`)**:
- Uses `decodeCreatePDR()`, `decodeCreateFAR()`, `decodeCreateQER()` for parsing Session Establishment Request
- Uses `decodeCreateQER()` for parsing Update QER in Session Modification Request
- Converts decoded IEs to PicoUP's internal PDR/FAR/QER types

**Integration Tests**:
- `test_qer_integration.zig`: Uses `encodeCreatePDR()`, `encodeCreateFAR()`, `encodeCreateQER()`
- `test_urr_integration.zig`: Uses `encodeCreatePDR()`, `encodeCreateFAR()`, `encodeCreateURR()`

### API Usage Example

```zig
// Decoding (in session handler)
const create_pdr = try pfcp.marshal.decodeCreatePDR(reader, ie_length, allocator);
const pdr_id = create_pdr.pdr_id.rule_id;
const teid = if (create_pdr.pdi.f_teid) |fteid| fteid.teid else 0;

// Encoding (in tests)
const create_far = pfcp.ie.CreateFAR.forward(
    pfcp.ie.FARID.init(1),
    pfcp.ie.DestinationInterface.init(.core),
);
try pfcp.marshal.encodeCreateFAR(writer, create_far);
```

## Remaining Gaps

The following features are still pending in the zig-pfcp library:

### Session Report Messages (Priority 1)

| Message Type | Name | Purpose | Status |
|--------------|------|---------|--------|
| 56 | Session Report Request | Report usage/events to SMF | Not Implemented |
| 57 | Session Report Response | Acknowledge report | Not Implemented |

**Impact**: PicoUP's URR implementation tracks usage locally but cannot report to SMF.

### Update/Remove IEs (Priority 2)

| IE Type | Name | Status |
|---------|------|--------|
| 9 | UpdatePDR | Not Implemented |
| 11 | UpdateFAR | Not Implemented |
| 13 | UpdateURR | Not Implemented |
| 16 | RemovePDR | Not Implemented |
| 18 | RemoveFAR | Not Implemented |
| 20 | RemoveURR | Not Implemented |
| 21 | RemoveQER | Not Implemented |

**Workaround**: Update QER currently uses `decodeCreateQER()` since the structure is identical.

### CreateBAR (Priority 3)

| IE Type | Name | Status |
|---------|------|--------|
| 8 | CreateBAR | Not Implemented |

**Impact**: Buffering action rules not supported.

## References

- 3GPP TS 29.244 - PFCP Protocol Specification
- zig-pfcp repository: https://github.com/xandlom/zig-pfcp
- PicoUP repository: https://github.com/xandlom/PicoUP

## Changelog

- **2025-11-22**: Updated to reflect implemented grouped IE support (CreatePDR, CreateFAR, CreateQER, CreateURR)
- **2025-11-16**: Initial gap analysis document
