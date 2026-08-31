# XPU V2.4 — Global Wavefront Compiler and Express Static Fabric

## 1. Purpose

V2.4 converts the V2.3 walker-free tile into a package-scale compilation target.

The throughput path remains static:

```text
semantic EML DAG
  -> hierarchical placement
  -> compile-time bank coloring
  -> lane/phase schedule
  -> static circuit reservation
  -> tagless value transport
  -> scheduled EML issue
```

There is no runtime dependency walker in this path.

## 2. Physical hierarchy

```text
4 chiplets/package
24 clusters/chiplet
16 tiles/cluster
8 EML lanes/tile

= 384 tiles/chiplet
= 1,536 tiles/package
= 12,288 EML lanes/package
```

The modeled clock remains 1.2 GHz, giving a raw arithmetic ceiling of 14.7456 T EML/s.

## 3. Global compiler coordinates

Every static EML operation receives:

```text
(chiplet, cluster, tile, lane, phase, bankA, bankB)
```

Every non-local edge receives a compile-time circuit reservation through the fabric.

The destination identity is implicit in the phase-programmed switch/ingress tables. Static values therefore do not require a runtime node/route tag.

## 4. Compiler locality objective

The current target envelope is:

```text
same tile                  80%
same cluster, other tile   15%
same chiplet, other cluster 3%
remote chiplet               2%
```

This is a compiler target, not an assertion about all applications.

A useful placement objective is:

```text
Cost =
    a * remote_chiplet_edges
  + b * cross_cluster_edges
  + c * cross_tile_edges
  + d * critical_route_depth
  + e * route_slot_conflicts
  + f * operand_bank_conflicts
  + g * load_imbalance
  + h * replicated_compute_cost
```

## 5. Compile-time bank coloring

`node_id % bank_count` is prohibited as a physical mapping rule.

Local V2.4 tests showed catastrophic aliasing because important graph strides are multiples of 32. Bank assignment is therefore a compiler decision.

The proof compiler currently uses deterministic coloring to spread resident generations across 32 A banks and 32 B banks. A and B are physically separate planes, so one A and one B write for the same bank number may occur in the same cycle.

## 6. Local forwarding

Same-tile producer/consumer traffic does not consume an external ingress port.

It still consumes the destination operand-bank write, but the value is forwarded inside the tile. This separates local dataflow from cluster/chiplet ingress pressure.

## 7. Super-wavefront execution

A single DAG instance may have insufficient width to hide route latency.

V2.4 therefore permits several independent epochs/microbatches to be compiled together. They share the same physical lanes but occupy different route, bank and issue slots.

This is static software pipelining, not runtime dependency scheduling.

## 8. Network variants

### Conservative radix hierarchy

The initial model uses approximately:

```text
same-cluster route        2 stages
cross-cluster route       7 stages
cross-chiplet route      11 stages
```

### V2.4 express static fabric

For fixed routes, V2.4 evaluates bypass/flattened paths:

```text
same-cluster route        1 stage
cross-cluster route       3 stages
cross-chiplet route       5 stages
```

The current 95%-class model point uses eight static circuit planes and 256 scheduled package words/output/cycle.

This is a topology/model target. Physical wire count, retiming, area and energy are not yet proven.

## 9. Utilization gate

For each workload, report:

```text
nodes
makespan cycles
global issue utilization
modeled EML/s
edge locality cut
route wait/edge
compiler wall-clock nodes/s
```

Required benchmark thresholds are 70%, 80%, 90% and 95%.

Passing one locality envelope does not imply universal coverage. Narrow reductions and adversarial high-cut graphs must remain in the suite as negative controls.

## 10. Current local result

The deterministic `80/15/3/2` topology envelope with:

```text
1,966,080 EML nodes
196,608 independent roots
8x super-wavefront width
express 1/3/5 paths
8 static circuit planes
256 package words/output/cycle
```

compiled to:

```text
160 cycles
100.00% modeled lane utilization
14.7456 T modeled EML/s
~0.218 route wait cycles/edge
~0.67 Mnode/s local compiler throughput
```

This is architecture-cycle-model evidence, not FPGA/ASIC speed evidence.

## 11. Next proof

V2.5 should remove the remaining relaxed assumption: aggregate stage capacity.

The compiler must perform exact per-switch/per-output time-slot coloring for a concrete radix-4 / Clos / flattened-butterfly RTL topology, emit switch SRAM images, and prove that every accepted global schedule is conflict-free under the exact switch graph.
