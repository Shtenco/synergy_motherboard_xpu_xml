# XPU V2.2 routed-token tile cycle model

> Synthetic deterministic 4096-node binary-input DAG; not RTL or silicon timing.

Nodes: **4096**, edges: **8064**.

| Lanes | Architecture | Banks | Cycles | Lane util | Bank conflict retries |
|---:|---|---:|---:|---:|---:|
| 8 | central walker 1 event/cycle | - | 8064 | 6.25% | 0 |
| 8 | central walker 8 events/cycle | - | 1010 | 49.90% | 0 |
| 8 | routed, 16 token ports | 8 | 1014 | 49.70% | 106886 |
| 8 | routed, 16 token ports | 16 | 525 | 96.00% | 33021 |
| 8 | routed, 16 token ports | 32 | 517 | **97.49%** | 3101 |
| 32 | central walker 1 event/cycle | - | 8064 | 1.56% | 0 |
| 32 | central walker 8 events/cycle | - | 1010 | 12.48% | 0 |
| 32 | routed, 64 token ports | 32 | 279 | 45.16% | 19328 |
| 32 | routed, 64 token ports | 64 | 165 | 76.36% | 8470 |
| 32 | routed, 64 token ports | 128 | 134 | **94.03%** | 2522 |
| 64 | central walker 1 event/cycle | - | 8064 | 0.78% | 0 |
| 64 | central walker 8 events/cycle | - | 1010 | 6.24% | 0 |
| 64 | routed, 128 token ports | 64 | 167 | 37.72% | 8349 |
| 64 | routed, 128 token ports | 128 | 120 | 52.50% | 3202 |
| 64 | routed, 128 token ports | 256 | 96 | **65.62%** | 1228 |

## Speedup against scalar central dependency release

Using four operand banks per arithmetic lane:

```text
8 lanes:  8064 / 517 = 15.60x
32 lanes: 8064 / 134 = 60.18x
64 lanes: 8064 / 96  = 84.00x
```

These are synthetic cycle-model ratios. They are not measured FPGA/application speedups.

## Main findings

1. A one-event/cycle centralized dependency walker completely dominates runtime as arithmetic width grows.
2. Merely adding routed-token ports is not enough: too few operand banks serialize otherwise-independent consumers.
3. In this graph family, approximately **four operand banks per arithmetic lane** moves the 8-lane and 32-lane configurations close to arithmetic-limited utilization.
4. The 64-lane case still reaches only 65.6% with 256 banks, showing that DAG critical-path/ready-width becomes the next limit after bank conflicts are reduced.
5. `node % banks` is only a test mapping. The production compiler must assign operand banks deliberately together with tile/chiplet placement.

## V2.2 architectural target

For the first FPGA routed tile:

```text
LANES = 8
OPERAND_BANKS = 32
ROUTE_PORTS = 16
DIRECT_FANOUT = 2
```

For fanout greater than two, the compiler should construct local replication trees or use the dynamic/fallback execution class instead of hiding unbounded multicast inside the router.

## Next model

Replace modulo bank mapping with compiler-assigned bank placement and add:

- local token pipeline latency;
- remote-token latency and injection queues;
- finite route retry FIFOs;
- output port serialization;
- multicast/replication lowering;
- graph critical-path-aware bank assignment;
- power/area cost per bank and token port.
