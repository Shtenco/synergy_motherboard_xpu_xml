# XPU Device ABI V2.2 — bounded XPUR submission contract

Status: **host-model / QEMU / FPGA bridge contract**.

V2.2 replaces raw graph execution in the fast path with a placed+routed `.xpur` image while preserving the V1 capability and reset-generation security direction.

## 1. Device invariants

The device must never accept unrestricted host physical addresses as authority. Every descriptor references runtime-installed object IDs. The runtime resolves those objects to an IOMMU/PASID-constrained window on hardware or to a bounded object table in QEMU/host tests.

Every submission is tied to the current reset generation. Reset invalidates device-side object authority and makes every earlier descriptor stale.

## 2. Feature bits

```text
bit 0  XPU2 semantic graph validation
bit 1  XPUR1 routed image execution
bit 2  EML_Q16_LUT_V2 numeric profile
bit 3  RESET_GENERATION
bit 4  CAPABILITY_OBJECT_IDS
bit 5  ROUTE_COUNTERS
bit 6  BANK_STALL_COUNTERS
```

V2.2 proof implementations may expose additional experimental bits but must not silently change the meaning of these bits.

## 3. MMIO register map

```text
0x0000  ID_MAGIC              RO  0x58505532 ('XPU2')
0x0004  ABI_VERSION           RO  0x00020002
0x0008  FEATURES_LO           RO
0x000C  FEATURES_HI           RO
0x0010  DEVICE_STATUS         RO/RW1C
0x0014  RESET_GENERATION      RO
0x0018  CONTROL               WO

0x0100  SQ_BASE_LO            RW
0x0104  SQ_BASE_HI            RW
0x0108  SQ_SIZE               RW
0x010C  SQ_HEAD               RO
0x0110  SQ_TAIL_DOORBELL      WO

0x0200  CQ_BASE_LO            RW
0x0204  CQ_BASE_HI            RW
0x0208  CQ_SIZE               RW
0x020C  CQ_HEAD_DOORBELL      WO
0x0210  CQ_TAIL               RO

0x0300  FAULT_CODE            RO
0x0304  FAULT_DETAIL          RO
0x0308  FAULT_OBJECT_ID       RO
0x030C  FAULT_NODE_ID         RO

0x0400  PERF_EML_OPS_LO       RO
0x0408  PERF_ROUTE_TOKENS_LO  RO
0x0410  PERF_REMOTE_TOKENS_LO RO
0x0418  PERF_BANK_STALLS_LO   RO
0x0420  PERF_LANE_IDLE_LO     RO
```

The exact 64-bit split-register convention is implementation-specific until QEMU/FPGA integration, but the semantic counters are frozen here.

## 4. 64-byte submission descriptor

Little-endian layout:

```c
struct xpu_submit_v22 {
    uint64_t image_object;       // READ object containing XPUR bytes
    uint32_t image_offset;
    uint32_t image_length;

    uint64_t input_object;       // READ object, packed little-endian int32 inputs
    uint32_t input_count;
    uint32_t flags;

    uint64_t output_object;      // WRITE object, packed little-endian int32 outputs
    uint32_t output_count;
    uint32_t target_profile;

    uint64_t user_cookie;
    uint32_t reset_generation;
    uint32_t capability_manifest_id;
};
```

Size is exactly **64 bytes**.

V2.2 flags are zero. Unknown flags fail closed.

## 5. 64-byte completion descriptor

```c
struct xpu_completion_v22 {
    uint64_t user_cookie;
    uint32_t status;
    uint32_t reset_generation;

    uint64_t cycles;             // 0 when implementation does not model cycles
    uint64_t eml_ops;
    uint64_t route_tokens;
    uint64_t local_tokens;
    uint64_t remote_tokens;

    uint32_t bank_stalls;
    uint32_t fault_code;
};
```

Size is exactly **64 bytes**.

## 6. Status/fault classes

```text
0   OK
1   BAD_DESCRIPTOR
2   STALE_GENERATION
3   OBJECT_NOT_FOUND
4   CAPABILITY_DENIED
5   IMAGE_BOUNDS
6   XPUR_INVALID
7   PROFILE_MISMATCH
8   INPUT_COUNT_MISMATCH
9   OUTPUT_COUNT_MISMATCH
10  EXEC_DOMAIN
11  EXEC_DEADLOCK
12  OUTPUT_BOUNDS
13  INTERNAL_FAULT
```

The same broad fault class should be returned by host model, QEMU and FPGA for the conformance corpus.

## 7. Capability rights

Proof rights:

```text
READ   = 1 << 0
WRITE  = 1 << 1
```

Submission requires:

```text
image_object:  READ
input_object:  READ
output_object: WRITE
```

Future graph state and persistent objects will extend the rights set rather than bypassing object authorization.

## 8. Submission validation order

To avoid inconsistent fault behavior, implementations validate in this order:

1. descriptor size/version/flags;
2. reset generation;
3. object existence;
4. capability rights;
5. object offset/length bounds;
6. XPUR hash/header/profile;
7. input/output counts;
8. execute;
9. output write bounds;
10. completion publication.

No output bytes are committed before all descriptor/image/input/output structural checks pass.

## 9. Reset rule

On reset:

```text
stop new submissions
revoke/disable DMA
clear device-side object/capability table
increment reset_generation
clear pending SQ/CQ execution state
clear routed/token state
retain only architectural identity registers
```

A descriptor carrying any earlier generation returns `STALE_GENERATION` even if its object IDs happen to be reused after reset.

## 10. V2.2 development limits

```text
max XPUR image        2 MiB
max input scalars     65536
max output scalars    65536
max object length     64 MiB in host/QEMU proof
max SQ entries        1024
max CQ entries        1024
```

These are bounded development limits, not final architecture maxima.

## 11. Conformance target

For every frozen test object:

```text
XPUR functional reference
== host device model
== QEMU device
== FPGA tile/device
```

The comparison includes output bytes, status/fault class, reset-generation behavior and deterministic structural rejection of corrupted XPUR images.
