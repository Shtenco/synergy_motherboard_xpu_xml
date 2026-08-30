# SHTENCO XPU V1 architecture

## 1. Thesis

XPU V1 is a **persistent programmable dataflow machine**. The central design objective is to reduce boundaries between arithmetic execution, active memory and persistent state rather than merely adding another accelerator behind a host CPU.

The machine is divided into four physical roles:

```text
+----------------------+     +----------------------+
| EML compute chiplets |<--->| HBM / active state   |
+----------+-----------+     +----------------------+
           |
           v
+----------------------+     +----------------------+
| I/O + control die    |<--->| persistent state     |
| scheduler / NoC      |     | content-addressed    |
| host/CXL/PCIe edge   |     | generations/lineage  |
+----------+-----------+     +----------------------+
           |
           v
      host / fabric
```

## 2. Compute chiplet

Baseline compute chiplet:

- 2,048 EML lanes;
- 60 mm² architectural area envelope;
- 12 MiB local SRAM;
- local ready-node queues;
- producer-consumer forwarding;
- tile NoC routers;
- capability tag propagation;
- thermal/power telemetry.

The chiplet should be tiled. A first RTL decomposition could use 32 tiles x 64 lanes = 2,048 lanes/chiplet.

Each tile owns a local scratch/state bank so most graph edges never enter the global NoC.

## 3. Tile sketch

```text
                 ingress tokens
                      |
               +------v------+
               | ready queue |
               +------+------+
                      |
          +-----------v------------+
          | 64 x EML execution     |
          | lanes + SELECT support |
          +-----------+------------+
                      |
        +-------------+--------------+
        | local forwarding / reduce |
        +------+---------------+-----+
               |               |
        local SRAM           NoC router
```

The exact lane count per tile must be re-optimized after synthesis because the transcendental datapath may dominate both area and power.

## 4. I/O + control die

The control die is not intended to become a conventional large CPU. It provides:

- graph admission;
- capability validation;
- placement metadata distribution;
- global queue arbitration;
- inter-chiplet NoC;
- HBM controllers;
- persistent-state controllers;
- PCIe/CXL host edge;
- boot/recovery/debug;
- small embedded control cores for exceptions and legacy/control-heavy paths.

A small RISC-V control cluster is a reasonable implementation candidate, while bulk arithmetic remains dataflow.

## 5. Memory hierarchy

The hierarchy is explicit rather than transparently cache-centric:

```text
lane state/registers
    -> tile SRAM
    -> chiplet SRAM
    -> HBM active state
    -> persistent state
    -> host/fabric fallback
```

Objects move between these levels under compiler/runtime policy. Persistent objects can be materialized lazily through content-addressed chunks, lineage XOR/delta reconstruction or other exact representations.

## 6. Persistent-state role

The SSD-replacement claim is not "put NAND next to the GPU". Persistent state is an addressable machine resource whose objects may be:

- raw blocks;
- content-addressed chunks;
- graph + residual representations;
- model/tensor generations;
- immutable snapshots;
- COW lineages.

The fabric should allow kernels to execute directly against persistent object generations without forcing all data through host DRAM.

## 7. Host interface

V1 begins as a host-attached device because that is buildable before a complete motherboard replacement.

Recommended progression:

1. QEMU MMIO device + DMA queues;
2. PCIe FPGA endpoint;
3. PCIe 5 x16 hardware prototype;
4. CXL memory/device experiments;
5. motherboard-native XPU boot/control architecture.

The analytical model shows why the final architecture cannot remain host-streaming: PCIe 5 x16 is ~75x lower bandwidth than the 4-stack HBM baseline.

## 8. Security/isolation

Inherited design rules from the TURBO XPU work:

- no raw arbitrary physical addresses from a graph;
- all DMA/state access is capability constrained;
- IOMMU/PASID binding when host attached;
- bounded queues;
- reset rotates generations and invalidates stale descriptors;
- malformed graph/device input fails closed;
- rich driver/device logic stays outside the privileged kernel where possible.

## 9. Compiler responsibilities

The compiler must do much more than instruction selection:

- lower source IR to EML/dataflow IR;
- numeric-profile selection;
- graph fusion;
- tile/chiplet partitioning;
- locality optimization;
- state object allocation;
- queue-depth planning;
- critical-path scheduling;
- persistent-object placement;
- capability manifest generation.

The primary optimization metric is **bytes moved per useful EML primitive**, not only operation count.

## 10. First hardware proof

The first meaningful FPGA proof is not "8192 lanes". It is a small system that proves the contracts:

```text
host graph compiler
      |
      v
bit-exact graph binary
      |
      +-> software evaluator
      +-> QEMU XPU model
      +-> FPGA: 1 tile / 8-64 lanes

all outputs identical
```

Once equivalence is closed, scaling becomes an engineering problem rather than a semantic one.
