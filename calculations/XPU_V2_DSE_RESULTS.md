# XPU V2 design-space search results

> **Claim boundary:** analytical exploration only. Physical coefficients are model assumptions, not measured silicon.

Enumerated valid architectural designs: **6,480**.

## Baseline physical assumptions

| Coefficient | Baseline |
|---|---:|
| EML dynamic energy | 12.0 pJ/EML |
| EML lane area | 0.018 mm²/lane |
| NoC dynamic energy | 8.0 pJ/B |
| NoC capacity | 2.0 TB/s/chiplet |
| HBM stack power model | 12.0 W/stack |
| Fixed I/O + control | 35.0 W |

## Workload contracts

| Workload | HBM B/EML | Result B | Fanout |
|---|---:|---:|---:|
| `dense_local` | 0.25 | 4.0 | 1.15 |
| `balanced_graph` | 0.75 | 4.0 | 1.25 |
| `state_heavy` | 2.0 | 8.0 | 1.1 |

## Best current-floorplan candidates

### HBM3E

**<= 200 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 2x4096, 1.4GHz, u=0.72, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 8.258 | 6.400 | 2.400 | 5.024 | 198.9 | 197.3 |
| 2 | 2x4096, 1.4GHz, u=0.72, 4xHBM3E, remote=5%, SRAM=12MiB/chiplet | 8.258 | 6.400 | 2.400 | 5.024 | 199.7 | 203.8 |
| 3 | 4x3072, 1.0GHz, u=0.65, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 7.987 | 6.400 | 2.400 | 4.969 | 196.7 | 302.5 |

**<= 250 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 4x3072, 1.2GHz, u=0.80, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 11.796 | 6.400 | 2.400 | 5.659 | 249.5 | 302.5 |
| 2 | 4x4096, 1.0GHz, u=0.72, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 11.796 | 6.400 | 2.400 | 5.659 | 249.5 | 394.6 |
| 3 | 4x3072, 1.4GHz, u=0.65, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 11.182 | 6.400 | 2.400 | 5.559 | 241.0 | 302.5 |

**<= 300 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 4x4096, 1.4GHz, u=0.65, 4xHBM3E, remote=5%, SRAM=8MiB/chiplet | 14.909 | 6.400 | 2.400 | 6.118 | 292.5 | 394.6 |
| 2 | 4x4096, 1.4GHz, u=0.65, 4xHBM3E, remote=5%, SRAM=12MiB/chiplet | 14.909 | 6.400 | 2.400 | 6.118 | 294.1 | 407.6 |
| 3 | 4x4096, 1.4GHz, u=0.65, 4xHBM3E, remote=5%, SRAM=16MiB/chiplet | 14.909 | 6.400 | 2.400 | 6.118 | 295.7 | 420.6 |

### HBM4

**<= 200 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 4x3072, 1.0GHz, u=0.65, 4xHBM4, remote=5%, SRAM=8MiB/chiplet | 7.987 | 7.987 | 5.600 | 7.096 | 198.0 | 302.5 |
| 2 | 4x3072, 1.0GHz, u=0.65, 4xHBM4, remote=5%, SRAM=12MiB/chiplet | 7.987 | 7.987 | 5.600 | 7.096 | 199.6 | 315.5 |
| 3 | 2x4096, 1.2GHz, u=0.80, 4xHBM4, remote=5%, SRAM=8MiB/chiplet | 7.864 | 7.864 | 5.600 | 7.023 | 194.7 | 197.3 |

**<= 250 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 4x3072, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=8MiB/chiplet | 11.182 | 11.182 | 5.600 | 8.880 | 242.7 | 302.5 |
| 2 | 4x3072, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=12MiB/chiplet | 11.182 | 11.182 | 5.600 | 8.880 | 244.3 | 315.5 |
| 3 | 4x3072, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=16MiB/chiplet | 11.182 | 11.182 | 5.600 | 8.880 | 245.9 | 328.5 |

**<= 300 W**

| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 4x4096, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=8MiB/chiplet | 14.909 | 14.909 | 5.600 | 10.757 | 294.9 | 394.6 |
| 2 | 4x4096, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=12MiB/chiplet | 14.909 | 14.909 | 5.600 | 10.757 | 296.5 | 407.6 |
| 3 | 4x4096, 1.4GHz, u=0.65, 4xHBM4, remote=5%, SRAM=16MiB/chiplet | 14.909 | 14.909 | 5.600 | 10.757 | 298.1 | 420.6 |

## Rooflines

- 4 x HBM3E at 1.2 TB/s/stack = **4.8 TB/s**. At 0.75 B/EML, balanced roofline = **6.4 T EML/s**.
- 4 x HBM4 at 2.8 TB/s/stack = **11.2 TB/s**. At 0.75 B/EML, balanced roofline = **14.933 T EML/s**.
- State-heavy at 2 B/EML is capped at **2.4 T EML/s** on 4xHBM3E and **5.6 T EML/s** on 4xHBM4 before cache/reuse/compression.
- NoC demand is `R_EML * result_bytes * fanout * remote_fraction`; lowering remote edges is equivalent to buying fabric bandwidth.

## Sensitivity that must be measured

- At the V1 raw target 7.077888 T EML/s, compute-only power is **56.6/84.9/113.2/141.6 W** for 8/12/16/20 pJ per EML.
- Lane area sweep: 0.012 / 0.018 / 0.024 mm² per lane changes chiplet feasibility materially; synthesis must replace this placeholder.
- NoC energy sweep: 4 / 8 / 12 pJ per transferred byte is tracked separately from architecture choices.

## Engineering decision

1. **V2-FPGA:** prove numeric correctness and scheduler semantics first; 8-64 LUT EML lanes are enough.
2. **V2-HBM3E:** keep the current 4-chiplet/4-stack package. Use clock/lane gating around the ~6.4 T balanced roofline.
3. **V2-HBM4:** only scale lanes toward ~15 T balanced EML/s after locality is demonstrated.
4. **Compiler KPI:** remote causal edges <=5-10% on fused graphs.
5. **Storage KPI:** for state-heavy workloads, reduce effective HBM bytes/EML below 1.0 using local SRAM, persistent graph reuse, compression or compute-near-state.
