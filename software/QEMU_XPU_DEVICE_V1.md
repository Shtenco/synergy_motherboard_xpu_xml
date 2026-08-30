# QEMU XPU Device V1 — software/hardware bridge

Goal: make one graph binary execute through the same queue/device contract in software emulation and later FPGA hardware.

## 1. Device principle

The earlier TURBO XPU work used a bounded four-sector / 2048-byte transport with post-reset generation checks and IOMMU containment. V1 generalizes that idea into bounded submission/completion queues while preserving fail-closed behavior.

## 2. MMIO register draft

```text
0x0000 ID_MAGIC          RO
0x0004 ABI_VERSION       RO
0x0008 FEATURES          RO
0x0010 DEVICE_STATUS     RW
0x0018 RESET_GENERATION  RO

0x0100 SQ_BASE_LO        RW
0x0104 SQ_BASE_HI        RW
0x0108 SQ_SIZE           RW
0x010C SQ_HEAD           RO
0x0110 SQ_TAIL           RW / doorbell

0x0200 CQ_BASE_LO        RW
0x0204 CQ_BASE_HI        RW
0x0208 CQ_SIZE           RW
0x020C CQ_HEAD           RW
0x0210 CQ_TAIL           RO

0x0300 FAULT_CODE        RO
0x0308 FAULT_ADDRESS     RO
0x0310 FAULT_GRAPH_ID    RO
```

All queue sizes are powers of two and capped by the ABI. Invalid descriptors fail closed.

## 3. Submission descriptor

Suggested 64-byte descriptor:

```text
u64 graph_object;
u64 graph_offset;
u32 graph_length;
u32 flags;

u64 state_table_object;
u32 state_count;
u32 capability_manifest_id;

u64 user_cookie;
u32 reset_generation;
u32 reserved0;
u64 reserved1;
```

A descriptor never carries unrestricted host physical memory authority. Object IDs are resolved through a host/runtime capability table and, on real hardware, IOMMU/PASID mappings.

## 4. Completion descriptor

```text
u64 user_cookie;
u32 status;
u32 reset_generation;
u64 cycles;
u64 eml_ops;
u64 bytes_hbm;
u64 bytes_noc_remote;
u64 bytes_persistent;
u64 fault_info;
```

The counters are architecturally useful because the XPU project optimizes movement as strongly as arithmetic throughput.

## 5. Reset/TOCTOU rule

Every accepted descriptor captures `reset_generation`.

On device reset:

1. DMA is disabled/revoked;
2. queue mappings are invalidated;
3. generation increments;
4. stale descriptors/completions are rejected;
5. capabilities must be reinstalled explicitly.

This carries forward the post-reset TOCTOU defense direction from the TURBO batch-XPU work.

## 6. QEMU implementation stages

### Stage Q0 — register skeleton

- PCI function or sysbus proof;
- MMIO identity/version/status;
- reset generation;
- no DMA.

### Stage Q1 — bounded queues

- fixed maximum SQ/CQ sizes;
- descriptor validation;
- interrupt/completion path;
- malformed descriptor fuzzing.

### Stage Q2 — graph DMA

- capability-authorized guest/host memory window;
- copy graph binary into device-owned buffer;
- validate hash/header/limits;
- execute through `software/reference` evaluator.

### Stage Q3 — state objects

- multiple bounded state objects;
- read/write rights;
- graph capability manifest;
- deterministic teardown.

### Stage Q4 — performance counters

Expose:

```text
EML ops
local edges
remote edges
HBM bytes
persistent bytes
queue stalls
critical path cycles
```

These counters allow the analytical model to be replaced by measured emulator/FPGA evidence.

## 7. Conformance invariant

For every frozen graph test vector:

```text
software reference output
== QEMU device output
== FPGA output
```

and the completion status/fault class must also agree for malformed and domain-error cases.

## 8. Initial graph limits

Keep the first ABI deliberately bounded:

```text
max graph image:       2 MiB
max nodes:             65536
max edges:             262144
max state objects:     64
max queue entries:     1024
max descriptor size:   64 B
```

These are development limits, not final architectural maxima. Bounded limits make fuzzing, hardware allocation and security review tractable.
