# XPU V2 — inter-chiplet NoC budget

Status: **architectural model / not PHY or silicon evidence**.

## External anchors

- UCIe 3.0 supports 48 GT/s and 64 GT/s data rates and explicitly targets higher bandwidth density for scalable chiplet systems: https://www.uciexpress.org/specifications
- Micron HBM4 is publicly specified at greater than 2.8 TB/s per stack with a 2048-pin interface: https://www.micron.com/products/memory/hbm/hbm4
- Micron HBM3E is publicly specified at greater than 1.2 TB/s per stack: https://www.micron.com/products/memory/hbm

The internal datapath widths below are **XPU architecture envelopes**, not claims about a particular UCIe lane count, PHY efficiency or package implementation.

## Traffic equation

For useful EML rate `R`, result width `B`, average result fanout `F`, and remote-edge fraction `r`:

```text
NoC_remote_bytes_per_second = R * B * F * r
```

With four compute chiplets, average injection per chiplet is one quarter of the aggregate result-token traffic.

V2 uses the current experimental assumptions:

```text
result = 4 bytes
average fanout = 1.25
compute chiplets = 4
```

## Measured placement points from the synthetic compiler benchmark

The existing deterministic placement study produced two useful locality points:

```text
2% hidden cross-links  -> 6.84% remote edges
5% hidden cross-links  -> 11.27% remote edges
round-robin            -> about 75% remote edges
```

## Required injection bandwidth

| Useful rate | Remote edges | Aggregate remote result traffic | Average per compute chiplet |
|---:|---:|---:|---:|
| 6.4 T EML/s | 6.84% | 2.189 TB/s | 0.547 TB/s |
| 6.4 T EML/s | 11.27% | 3.606 TB/s | 0.902 TB/s |
| 7.078 T EML/s | 6.84% | 2.421 TB/s | 0.605 TB/s |
| 7.078 T EML/s | 11.27% | 3.988 TB/s | 0.997 TB/s |
| 14.933 T EML/s | 6.84% | 5.107 TB/s | 1.277 TB/s |
| 14.933 T EML/s | 11.27% | 8.415 TB/s | 2.104 TB/s |

The 14.933 T point is the current four-stack HBM4 balanced-workload roofline at 0.75 external bytes/EML. It is not a measured XPU throughput.

## Ideal internal datapath envelopes

Ignoring coding, packet headers, credit returns, retries, clock-domain crossings and PHY overhead:

| Datapath | Ideal one-direction payload envelope |
|---|---:|
| 1024 bit @ 2.0 GHz | 256 GB/s |
| 2048 bit @ 2.0 GHz | 512 GB/s |
| 3072 bit @ 2.0 GHz | 768 GB/s |
| 4096 bit @ 2.0 GHz | 1.024 TB/s |
| 2048 bit @ 2.5 GHz | 640 GB/s |
| 4096 bit @ 2.5 GHz | 1.280 TB/s |

These are intentionally simple internal fabric envelopes. A concrete PHY must apply its own encoding, protocol and implementation efficiency.

## Architectural consequence

### HBM3E class

At ~6.4 T EML/s, the current compiler-locality region of 6.84–11.27% produces ~0.55–0.90 TB/s average egress per chiplet. A chiplet fabric with roughly 1 TB/s usable injection per compute die is therefore a meaningful V2 design target.

### HBM4 class

At ~14.93 T EML/s, 6.84% remote already requires ~1.28 TB/s per chiplet, while 11.27% requires ~2.10 TB/s. Therefore HBM4 scaling cannot come from memory replacement alone. At least one of these must improve:

1. lower remote-edge fraction;
2. lower transported result width through packing/compression;
3. producer/consumer fusion so intermediate results never enter the global NoC;
4. more direct die-to-die injection capacity;
5. replicated/recomputed cheap values instead of transporting them;
6. hierarchical scheduling that keeps subgraphs tile-local.

## Remote-fraction ceilings

For four chiplets, 4-byte results and fanout 1.25:

- at 6.4 T EML/s, 1.024 TB/s/chiplet ideal injection permits about **12.8% remote**;
- at 14.933 T EML/s, the same injection permits only about **5.49% remote**;
- 1.536 TB/s/chiplet raises the HBM4-class ceiling to about **8.23% remote**;
- 2.048 TB/s/chiplet raises it to about **10.97% remote**.

This makes `remote_fraction` a first-class compiler/hardware co-design parameter. A compiler placement that is acceptable for HBM3E can become physically invalid after an HBM4 memory upgrade even if the EML lanes themselves do not change.

## V2.1 design target

For the next tile/chiplet model:

```text
HBM3E profile:
  target usable injection >= 1.0 TB/s/chiplet
  target remote fraction <= 10%

HBM4 profile:
  target usable injection >= 1.5 TB/s/chiplet
  preferred remote fraction <= 7%
  hard modeled ceiling around 8% for the 1.536 TB/s envelope
```

The RTL scheduler should therefore expose counters for:

```text
local_issues
remote_token_in
remote_token_out
injection_stall_cycles
ready_queue_stall_cycles
operand_wait_cycles
lane_idle_cycles
```

Without these counters, a future FPGA run cannot distinguish arithmetic under-utilization from NoC starvation.
