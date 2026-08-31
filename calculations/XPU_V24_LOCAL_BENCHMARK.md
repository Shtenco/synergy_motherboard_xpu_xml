# XPU V2.4 local global-wavefront benchmark

> Claim boundary: the compiler wall-clock numbers below were measured locally in the ChatGPT execution environment on 2026-08-31. The T EML/s numbers are architecture-cycle-model outputs for the modeled 12,288-lane XPU at 1.2 GHz. They are **not** FPGA/ASIC measurements.

## Fabric under test

```text
4 chiplets
24 clusters/chiplet
16 tiles/cluster
8 EML lanes/tile
1,536 tiles/system
12,288 EML lanes/system
1.2 GHz modeled clock
24 external operand ingress positions/tile
32 A banks + 32 B banks/tile
```

Raw arithmetic ceiling:

```text
12,288 * 1.2 GHz = 14.7456 T EML/s
```

V2.4 uses compile-time bank coloring rather than `node_id % 32`. The naive modulo mapping was tested and found to alias the 1,536-tile / 24,576-chain strides badly, producing artificial multi-cycle bank waits even for a 100% same-tile graph.

## Workload envelope

No large application EML corpus exists in this repository yet. Therefore these are deterministic topology envelopes, not claimed real applications:

- `all_local`: producer/consumer edges remain in one tile;
- `target_80_15_3_2`: edge locality is 80% same tile, 15% same cluster, 3% same chiplet across clusters, 2% remote chiplet;
- `cluster_heavy`: 50% same tile, 50% same cluster;
- `global_shuffle`: deliberately hostile cross-chiplet graph;
- `reduction_tree`: deliberately narrow dependency tail.

## 1. Initial 245,760-node baseline

With the corrected compile-time bank coloring and local-forward bypass:

| Workload | Utilization | Modeled rate | Compile rate | Avg route wait/edge | Measured cut |
|---|---:|---:|---:|---:|---:|
| all_local | 90.91% | 13.405 T/s | 1.3 Mnode/s | 0.000 | 100/0/0/0% |
| target 80/15/3/2 | 24.69% | 3.641 T/s | 0.9 Mnode/s | 0.008 | 80/15/3/2% |
| cluster-heavy | 50.00% | 7.373 T/s | 2.8 Mnode/s | 0.056 | 50/50/0/0% |
| global-shuffle | 5.35% | 0.789 T/s | 0.3 Mnode/s | 12.965 | 50/0.3/8.0/41.7% |
| reduction-tree | 11.98% | 1.766 T/s | 3.0 Mnode/s | 0.003 | 50/46.9/2.9/0.2% |

This experiment separated three limitations:

1. `all_local` proves the lane/tile scheduler itself can exceed 90%.
2. `target_80_15_3_2` had almost no capacity wait but low utilization, showing the next bottleneck was route **latency / synchronized wavefront depth**, not bandwidth.
3. `global_shuffle` is dominated by real bisection pressure; no compiler can make an arbitrary high-cut graph cheap without replication or much larger inter-chiplet bandwidth.

## 2. Super-wavefront / independent-epoch interleaving

The target `80/15/3/2` graph was recompiled with progressively wider independent wavefronts. The original hierarchical `2/7/11`-stage route model produced:

| Interleave multiplier | Nodes | Utilization | Modeled rate | Avg route wait/edge |
|---:|---:|---:|---:|---:|
| 2x | 491,520 | 49.38% | 7.282 T/s | 0.061 |
| 4x | 983,040 | 77.67% | 11.453 T/s | 0.416 |
| 6x | 1,474,560 | 83.33% | 12.288 T/s | 0.641 |
| 8x | 1,966,080 | 85.56% | 12.617 T/s | 0.874 |
| 12x | 2,949,120 | 87.91% | 12.963 T/s | 1.341 |
| 16x | 3,932,160 | 88.89% | 13.107 T/s | 1.891 |

The key point is that multiple independent graph epochs hide transport latency without reintroducing a runtime dependency walker.

## 3. Express topology

The static network was then changed from the conservative hierarchy:

```text
same-cluster       2 stages
cross-cluster      7 stages
cross-chiplet     11 stages
```

to a compile-time circuit/express model:

```text
same-cluster       1 stage
cross-cluster      3 stages
cross-chiplet      5 stages
```

while keeping four route planes and 128 package words/output/cycle.

Target `80/15/3/2` results:

| Interleave | Utilization | Modeled rate |
|---:|---:|---:|
| 4x | 85.11% | 12.549 T/s |
| 6x | 86.96% | 12.822 T/s |
| 8x | 88.40% | 13.035 T/s |
| 12x | 89.89% | 13.254 T/s |
| 16x | **90.40%** | **13.329 T/s** |
| 24x | 91.08% | 13.431 T/s |

At high interleave, route wait begins rising again, so route-plane capacity becomes the next limit.

## 4. Eight-plane express fabric

Doubling static circuit planes and package output capacity:

```text
radix/circuit planes                 8
package scheduled words/output/cycle 256
route depth                           1 / 3 / 5
```

changes the target graph result substantially:

| Interleave | Nodes | Utilization | Makespan | Modeled rate | Avg wait/edge | Local measured compiler rate |
|---:|---:|---:|---:|---:|---:|---:|
| 8x | 1,966,080 | **100.00%** | 160 cycles | **14.7456 T/s** | 0.218 | ~0.67 Mnode/s |
| 12x | 2,949,120 | **100.00%** | 240 cycles | **14.7456 T/s** | 0.334 | ~0.7 Mnode/s |
| 16x | 3,932,160 | **100.00%** | 320 cycles | **14.7456 T/s** | 0.547 | ~0.6 Mnode/s |

For this deterministic locality envelope the V2.4 compiler therefore reaches all requested utilization gates:

```text
>=70% PASS
>=80% PASS
>=90% PASS
>=95% PASS
```

This is **not** a statement that arbitrary graphs achieve 100%. The adversarial global-shuffle and narrow reduction-tree examples explicitly show they do not.

## 5. Real local host EML speed

`bench/eml_q16_host_bench.cpp` loads the same generated `exp_q16.memh` / `ln_q16.memh` tables used by the RTL profile and executes the integer interpolation kernel.

Seven local 50,000,000-operation repetitions with five OpenMP threads produced:

```text
scalar median        193.237 M EML/s
scalar observed      172.559 .. 221.319 M EML/s
5-thread median      602.461 M EML/s
5-thread observed    466.615 .. 606.488 M EML/s
```

The environment is shared, so the range is reported rather than treating one run as a stable hardware benchmark.

The modeled full XPU ceiling divided by the measured 5-thread median is approximately:

```text
14.7456e12 / 602.461e6 ~= 24,476x
```

Again: this ratio compares a **future-XPU architectural model** with a **measured current-host software kernel**. It is not an accelerator speedup claim until FPGA/ASIC hardware measures the XPU side.

## 6. V2.4 conclusion

The central walker is no longer the scaling limit. V2.4 reveals the new hierarchy of constraints:

```text
1. graph intrinsic parallelism
2. compiler locality / graph cut
3. route latency
4. static route-plane capacity
5. operand-bank coloring
6. inter-chiplet bisection bandwidth
7. route energy
```

For the target `80/15/3/2` locality envelope, the combination that currently clears 95% in the model is:

```text
STATIC_WAVEFRONT
+ compile-time bank coloring
+ local-forward bypass
+ super-wavefront epoch interleaving
+ 1/3/5-stage express paths
+ 8 static circuit planes
+ 256 scheduled package words/output/cycle
```

The next proof must replace aggregate stage capacities with exact per-switch radix/Clos coloring and then synthesize the route/schedule SRAM + switch plane RTL on FPGA.
