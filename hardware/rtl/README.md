# XPU RTL plan

The first RTL objective is **semantic and transport equivalence**, not maximum lane count.

## Phase A — one EML lane

Candidate modules:

```text
eml_lane_q16.sv
range_reduce_exp.sv
poly_exp.sv
range_reduce_ln.sv
poly_ln.sv
round_saturate_q16.sv
```

Required evidence:

- exact agreement with `software/reference/eml_q16.py` on the frozen test domain;
- Fmax;
- pipeline latency;
- LUT/DSP/BRAM usage;
- dynamic power estimate;
- error/trap behavior at boundaries.

## Phase B — one tile

First scalable target:

```text
8 lanes -> 16 -> 32 -> 64 lanes
```

Tile modules:

```text
xpu_tile.sv
ready_queue.sv
local_state_sram.sv
local_forward.sv
reduce_unit.sv
noc_endpoint.sv
capability_checker.sv
```

Measure the point at which lane replication becomes limited by routing, local SRAM ports or clock distribution.

## Phase C — device endpoint

```text
xpu_mmio_regs.sv
xpu_submission_queue.sv
xpu_completion_queue.sv
xpu_dma_engine.sv
xpu_iommu_tag.sv
xpu_reset_generation.sv
```

The descriptor protocol should evolve from the earlier bounded four-sector XPU batch transport rather than invent an unconstrained DMA API.

## Phase D — multi-tile NoC

Start with a mesh or hierarchical mesh and instrument:

- local vs remote edge count;
- bytes/edge;
- queue occupancy;
- hop distribution;
- critical-path stalls;
- energy estimate per remote edge.

The quantitative baseline shows that even 20% remote traffic can create multi-TB/s internal demand, so placement-aware locality is a hard requirement.

## FPGA proof target

A useful first board target is intentionally modest:

```text
1 tile
8-64 EML lanes
local BRAM/URAM state
PCIe or simple host bridge
same graph binary as software reference
```

Only after this proof should the project scale toward thousands of lanes.
