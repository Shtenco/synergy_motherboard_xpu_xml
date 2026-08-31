# XPU V2.3 — static-wavefront / hierarchical multicast fast path

Status: **architecture contract / FPGA proof target**, not silicon evidence.

## 1. Problem being solved

A centralized dependency walker cannot be the execution backbone of a multi-terascale EML machine.

A binary EML node consumes two operands. If runtime readiness were represented as two centralized events per fired operation, the control-event rate would be approximately:

```text
R_dependency ~= 2 * R_EML
```

For the current 4-chiplet / 12,288-lane model:

```text
raw compute @ 1.2 GHz       = 14.7456 T EML/s
72% sustained               = 10.616832 T EML/s
operand-event equivalent    = 21.233664 T/s sustained
```

A single 2 GHz walker can retire at most about 2 G events/s, a gap of more than 10,000x under the strict two-operand accounting. The earlier 1.25-fanout model already showed a 4,000–9,300x gap; the binary-input lower bound makes the central-walker architecture even less plausible.

**V2.3 does not attempt to make the walker 10,000x faster. It removes dependency walking from the throughput path.**

## 2. Three execution modes

### V2.3 STATIC_WAVEFRONT — primary static EML fast path

For a pure fixed-latency DAG, the compiler resolves in advance:

```text
(node) -> tile, lane, issue_cycle, route_id
(edge) -> route tree, destination operand slot, transport time slot
```

Runtime dependency-control events are therefore **zero**. A lane consumes the next precompiled node in its schedule only at the cycle for which all input arrivals were proven by the compiler.

The hardware still moves operands physically, but it no longer asks a central structure whether a node is ready.

### V2.2 DISTRIBUTED_TOKEN — variable-latency path

When memory, remote state, dynamic loops or other operations make latency nondeterministic, the existing V2.2 model remains:

```text
token -> destination tile -> operand A/B slot -> local valid bits -> local ready bitmap
```

No global walker is involved.

### V2.1 CENTRAL_FALLBACK — bounded control/exception path

The scalar dependency engine remains useful for:

- rare dynamic graph fragments;
- host/control escapes;
- debugging and conformance;
- unsupported fanout/route cases during early FPGA development.

It is explicitly **not** a throughput path.

## 3. Physical topology

The V2.3 compute hierarchy is:

```text
4 chiplets/package
  |
  +-- 24 clusters/chiplet
        |
        +-- 16 tiles/cluster
              |
              +-- 8 EML lanes/tile
              +-- 24 routed operand ingress ports
              +-- 32 operand banks
              +-- local schedule SRAM/FIFO
              +-- local route table
```

This preserves the current 384 tiles/chiplet and 3,072 lanes/chiplet.

## 4. Local static wavefront

Each tile stores a compact per-lane sequence of local node IDs. With 256 resident nodes, the local node ID fits in 8 bits.

Conceptually:

```text
lane0 schedule:  03 08 0C -- 17 ...
lane1 schedule:  04 09 -- 11 18 ...
...
lane7 schedule:  07 0B 10 14 -- ...
```

`--` is a compiler-inserted bubble where dependency or route timing requires it.

Node metadata and routes remain resident, so the schedule need not carry full opcodes and addresses every cycle.

For 256 nodes/tile:

```text
~256 bytes schedule/tile
384 tiles/chiplet
~96 KiB schedule/chiplet
```

This is a small distributed control store compared with the existing local-state budget.

## 5. Hierarchical multicast instead of producer-side fanout walking

A result is injected **once** with a static `route_id`.

Switches replicate it at branch points:

```text
producer
   |
   +--------- route tree ----------+
   |                               |
 consumer subtree A          consumer subtree B
```

This is different from a walker enumerating every dependent node and issuing one readiness operation per edge.

The total physical link traffic still scales with edge movement, but:

- producer injection is O(1) per produced value;
- routing lookup is static/local;
- multicast replication happens spatially;
- no central dependency bookkeeping lies on the path.

High-fanout graph nodes can be lowered into balanced multicast/replication trees by the compiler.

## 6. Proposed network levels

### L0 — tile-local direct/bypass

The compiler should aggressively fuse micrographs so producer and consumer reside in the same tile. A same-tile result writes directly to one or more of the 32 operand banks.

Target locality class for initial DSE:

```text
same tile                    80%
same cluster / other tile    15%
same chiplet / other cluster  3%
remote chiplet                2%
```

These are compiler targets, not measured application facts.

### L1 — 16-tile cluster network

Use multiple statically configured multicast planes rather than a single packet router. A practical implementation candidate is a small radix-4 multistage Clos/butterfly-like network with compiler-reserved time slots.

The important property is not the marketing name of the topology; it is that routes and conflict-free slots are known before execution.

### L2 — chiplet cluster fabric

Twenty-four clusters connect through a higher-radix hierarchical fabric. Cross-cluster traffic is already expected to be a small minority after placement/fusion.

### L3 — inter-chiplet fabric

Only the remaining remote edge fraction reaches the die-to-die links. The current model uses UCIe-class links as the physical direction. UCIe 3.0 publicly specifies 48 and 64 GT/s modes, making it relevant to the eventual package interconnect, but actual lane count and usable payload bandwidth must come from a concrete PHY/package design.

## 7. Why 24 ingress ports and 32 operand banks per 8-lane tile

At full 1.2 GHz issue rate:

```text
8 lanes * 1.2 GHz = 9.6 G EML/s/tile
2 operands/op      = 19.2 G operand arrivals/s/tile
```

The proposed distributed tile fabric provides:

```text
24 ingress ports * 1.2 GHz = 28.8 G token writes/s
32 banks         * 1.2 GHz = 38.4 G bank accepts/s
```

Therefore:

```text
ingress headroom at 100% lane issue = 1.50x
bank headroom at 100% lane issue    = 2.00x
```

Across 1,536 tiles/system:

```text
24-port distributed capacity = 44.2368 T operand writes/s
32-bank physical capacity     = 58.9824 T operand writes/s
```

Against the 14.933 T EML/s HBM4 reference roofline:

```text
operand demand = 29.866 T/s
24-port headroom ~= 1.48x
32-bank headroom ~= 1.97x
```

This is the direct mathematical answer to the central-walker bottleneck: event acceptance becomes spatially replicated with the compute fabric instead of being serialized through one engine.

## 8. Static schedule correctness contract

A V2.3 graph is legal only if the compiler proves for every scheduled node:

```text
arrival(A) <= issue_cycle
arrival(B) <= issue_cycle
lane is free at issue_cycle
all route resources/time slots are reserved
all destination bank writes are conflict-free or buffered
```

Hardware should keep operand-valid bits as a safety assertion. If a scheduled operation reaches its slot with a missing operand, the tile raises a deterministic schedule fault instead of silently computing with stale state.

## 9. Graph classes

### Excellent fit

- fixed-shape neural and tensor graphs;
- symbolic EML DAGs;
- repeated transforms;
- compression/decompression micrographs;
- deterministic DSP-like pipelines;
- repeated database/vector kernels;
- loops amenable to modulo scheduling.

### V2.2 token-mode preferred

- unpredictable memory misses;
- asynchronous state arrival;
- graph structure that changes during execution;
- variable iteration count;
- external I/O dependencies.

### V2.1 fallback preferred

- rare control fragments;
- debug/reference execution;
- unsupported compiler corner cases.

## 10. Architectural invariant

The project should no longer describe the machine as:

```text
many EML lanes + one scheduler
```

The scalable definition is:

```text
many independently scheduled spatial EML tiles
+ distributed operand state
+ static multicast/wavefront routes
+ bounded dynamic fallback
```

The throughput limit should therefore be sought in:

1. EML lane Fmax/pJ;
2. local operand-bank bandwidth;
3. multicast/route energy;
4. cross-cluster link bandwidth;
5. cross-chiplet link bandwidth;
6. compiler ability to create wide conflict-free wavefronts;

—not in a central dependency walker.
