# XPU V1 — deep quantitative baseline

Status: **analytical architecture model / not silicon evidence**.

This document freezes the first reproducible numerical baseline for the Motherboard XPU. It is intentionally explicit about assumptions so that every coefficient can later be replaced by FPGA/ASIC measurements.

## 1. Baseline configuration

| Parameter | Value |
|---|---:|
| Compute chiplets | 4 |
| EML lanes / chiplet | 2,048 |
| Total EML lanes | 8,192 |
| Target clock | 1.2 GHz |
| Sustained utilization model | 72% |
| Compute die area / chiplet | 60 mm² |
| I/O + control die area | 90 mm² |
| Local SRAM / chiplet | 12 MiB |
| HBM3E stacks | 4 |
| HBM3E bandwidth / stack | 1,180 GB/s |
| Persistent-state modeled bandwidth | 256 GB/s |
| PCIe 5.0 x16 effective bandwidth / direction | 63.02 GB/s |
| PCIe 6 / CXL-class model | 128 GB/s |
| Interposer footprint | 55 x 55 mm |

The HBM3E coefficient comes from a public Samsung HBM3E figure of up to 1,180 GB/s per stack. The PCIe 5 coefficient follows PCI-SIG public speeds-and-feeds material. These are interface reference values, not a claim that the XPU implementation has completed those PHYs.

## 2. EML throughput equation

We define one **EML primitive** as one completed architectural EML operation according to the future frozen numeric semantics. It is not a FLOP and is not directly comparable to GPU TFLOPS/TOPS.

For `N` lanes, frequency `f`, and sustained issue utilization `u`:

```text
R_EML = N * f * u
```

Baseline:

```text
R_EML = 8192 * 1.2e9 * 0.72
      = 7.077888e12 EML/s
      = 7.077888 T EML/s
```

Per compute chiplet:

```text
2048 * 1.2e9 * 0.72 = 1.769472 T EML/s
```

Scaling at fixed clock/utilization:

| Compute chiplets | Lanes | Modeled throughput |
|---:|---:|---:|
| 1 | 2,048 | 1.769472 T EML/s |
| 2 | 4,096 | 3.538944 T EML/s |
| 4 | 8,192 | 7.077888 T EML/s |
| 8 | 16,384 | 14.155776 T EML/s |

This table is only linear until NoC, memory, timing, power or placement constraints become dominant.

## 3. HBM bandwidth balance

Four HBM3E stacks at 1,180 GB/s each give:

```text
B_HBM = 4 * 1180 GB/s = 4720 GB/s = 4.72 TB/s
```

The compute-to-memory balance is:

```text
I_HBM = R_EML / B_HBM
      = 7.077888e12 / 4.72e12
      = 1.49955 EML/byte
```

Equivalent byte budget:

```text
B_HBM / R_EML = 0.66687 byte / EML
```

Interpretation: a kernel that consumes substantially more than ~0.667 HBM bytes for every EML primitive will become bandwidth-bound before the modeled compute fabric reaches 72% utilization. Reuse in local SRAM and graph locality are therefore central architectural requirements.

## 4. Why host-offload alone is the wrong XPU architecture

For PCIe 5.0 x16 at 63.02 GB/s per direction:

```text
I_PCIe5 = 7.077888e12 / 63.02e9
        = 112.312 EML/byte
```

For a 128 GB/s PCIe 6/CXL-class host link model:

```text
I_PCIe6 = 7.077888e12 / 128e9
        = 55.296 EML/byte
```

So a conventional accelerator that repeatedly imports state from a host must expose roughly **55–112 useful EML primitives per transferred byte** to keep the compute fabric busy. By contrast, resident HBM only requires ~1.5 EML/byte.

This is the strongest quantitative argument for the Motherboard-XPU concept:

```text
host-centric accelerator:
CPU memory -> PCIe/CXL -> accelerator -> PCIe/CXL -> CPU memory

XPU persistent-dataflow model:
persistent state -> resident active state -> EML graph -> persistent state
```

The architecture is not merely "a faster PCIe card". It needs long-lived state residency.

## 5. Persistent-state balance

A deliberately abstract first persistent-tier coefficient is 256 GB/s:

```text
I_PERSIST = 7.077888e12 / 256e9
          = 27.648 EML/byte
```

This number is not tied to a chosen MRAM/ReRAM/NAND technology yet. It defines a design requirement: if a future persistent tier is much slower, more aggressive caching, graph compression, lineage/delta reconstruction and near-data primitives become mandatory.

## 6. Local SRAM

Baseline local SRAM:

```text
4 chiplets * 12 MiB = 48 MiB
```

A practical tile hierarchy should partition this into at least:

- lane-local register/state files;
- graph microcode / routing descriptors;
- scratchpad blocks;
- producer-consumer FIFOs;
- small persistent-object metadata cache.

The design should prefer explicitly managed scratchpad/state objects over pretending that the fabric is a conventional coherent CPU cache hierarchy.

## 7. First-order area envelope

Compute silicon:

```text
4 * 60 mm² = 240 mm²
```

I/O/control die:

```text
90 mm²
```

Total active logic silicon in the baseline package:

```text
A_active = 240 + 90 = 330 mm²
```

Average compute-die budget per lane, including its share of SRAM, NoC, clock/power infrastructure and control:

```text
60 mm² / 2048 = 0.029296875 mm²/lane
```

This is a **budget**, not an EML-cell area measurement. The actual lane feasibility will be known only after synthesizing a frozen numeric implementation of `exp(x) - ln(y)` or an equivalent transformed datapath.

## 8. Energy sensitivity

Because EML is a compound transcendental primitive, energy is currently the largest unknown. We therefore sweep cell energy rather than invent a single value.

```text
P_compute = R_EML * E_EML
```

| Primitive energy | Compute-only power at 7.077888 T EML/s |
|---:|---:|
| 5 pJ | 35.39 W |
| 10 pJ | 70.78 W |
| 20 pJ | 141.56 W |
| 40 pJ | 283.12 W |

This table excludes HBM, NoC, SerDes, SRAM leakage/dynamic power, control die, persistent tier and regulators.

Therefore:

- <=10 pJ/EML makes the baseline very attractive;
- ~20 pJ/EML is still compatible with an accelerator-class package if the rest of the system is efficient;
- ~40 pJ/EML makes 8,192 lanes at 1.2 GHz thermally difficult and forces lower frequency/lane count or a different EML implementation.

A central milestone is thus **measured pJ per exact EML primitive**, not just Fmax.

## 9. Package-level thermal envelope

55 x 55 mm interposer footprint:

```text
A_package = 3025 mm² = 30.25 cm²
```

Package-average heat flux:

| Package power | Average over 55x55 mm footprint |
|---:|---:|
| 200 W | 6.612 W/cm² |
| 250 W | 8.264 W/cm² |
| 300 W | 9.917 W/cm² |

This average hides hotspot concentration on compute chiplets. For example, 140 W spread only over the four 60 mm² compute dies is:

```text
140 W / 2.4 cm² = 58.33 W/cm²
```

Floorplanning and thermal coupling to HBM are therefore first-class constraints.

## 10. Latency-hiding requirement

A dataflow machine gains efficiency only if sufficient independent graph nodes are ready. For a lane pipeline latency `L` cycles and `N` physical lanes, full occupancy needs on the order of:

```text
ready_nodes >= N * L
```

Example sensitivity:

| EML pipeline latency | Ready nodes to cover 8,192 lanes |
|---:|---:|
| 4 cycles | 32,768 |
| 8 cycles | 65,536 |
| 16 cycles | 131,072 |
| 32 cycles | 262,144 |

Thus the compiler must expose broad parallel DAG frontiers or fuse/reuse operations locally. A very deep exact transcendental pipeline without enough graph concurrency can destroy utilization even when nominal throughput is high.

## 11. NoC traffic equation

If each completed EML result is `W` bytes and an average result fans out to `F` remote consumers with remote fraction `r`, rough fabric payload demand is:

```text
B_NoC ~= R_EML * W * F * r
```

For a 4-byte result, fanout 1.25 and only 20% remote edges:

```text
B_NoC ~= 7.077888e12 * 4 * 1.25 * 0.20
      ~= 7.08 TB/s
```

This is already larger than HBM bandwidth. Therefore **placement locality is not optional**. The compiler must aggressively place producer-consumer subgraphs in the same tile/chiplet and use local scratchpad forwarding rather than route every architectural edge globally.

## 12. Graph placement objective

The first placement cost function should minimize a weighted sum:

```text
Cost = a * remote_edge_bytes
     + b * critical_path_cycles
     + c * SRAM_spill_bytes
     + d * HBM_bytes
     + e * persistent_bytes
     + f * thermal_hotspot_penalty
```

subject to:

```text
lane_capacity(tile)
SRAM_capacity(tile)
NoC_link_capacity(edge)
power_domain_limit(chiplet)
capability/isolation constraints
```

This makes graph placement closer to FPGA/CGA compilation than to conventional CPU instruction scheduling.

## 13. CPU/GPU/SSD replacement must be measured separately

The project should not claim one synthetic number for "replacing CPU + GPU + SSD". Three independent evidence tracks are required:

### CPU track

- branch-heavy scalar control;
- system calls / exceptions;
- pointer chasing;
- general application kernels;
- translation from conventional IR to graph form.

### GPU track

- matrix/tensor kernels;
- reductions;
- activation/nonlinear math;
- graph/attention kernels;
- throughput per watt and per mm².

### SSD/persistent track

- random/sustained read-write latency;
- crash consistency;
- endurance;
- persistent-object reconstruction;
- content-addressed/delta/lineage formats;
- computation performed without materializing full objects through the host.

Only after all three tracks exist can the unified-XPU claim be quantified.

## 14. Immediate measurable milestones

1. Freeze EML numeric domain and exception rules.
2. Implement exact software reference.
3. Implement synthesizable lane candidate A (LUT/polynomial/range reduction).
4. Implement lane candidate B (CORDIC/log-domain or other transformed datapath).
5. Measure Fmax, LUT/DSP/BRAM on FPGA.
6. Synthesize against at least one standard-cell library to estimate mm² and pJ/op.
7. Build 64-lane tile and measure routing overhead.
8. Build multi-tile NoC and measure remote-edge energy.
9. Extend TURBO four-sector XPU transport to MMIO/DMA queues.
10. Prove software == QEMU == FPGA bit-exact execution for the same graph binary.

Until step 6, **7.077888 T EML/s is an architecture target derived from explicit parameters, not a silicon performance claim**.
