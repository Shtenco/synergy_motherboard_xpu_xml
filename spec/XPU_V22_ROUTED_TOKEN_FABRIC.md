# XPU V2.2 — routed-token dataflow fabric

Status: **architecture pivot derived from V2.1 bottleneck analysis**.

## 1. Why the V2.1 dependency walker cannot be production architecture

The V2.1 bounded tile has a central correctness path:

```text
completion bitmap
  -> CSR outgoing-edge walker
  -> pending dependency counters
  -> ready scheduler
```

This is useful because it is simple, bounded and auditable. It is not scalable.

For useful EML rate `R` and average fanout `F`, the machine must process roughly:

```text
route/dependency events per second = R * F
```

Using the current `F = 1.25` model:

| Useful rate | Route events | 1 central engine @ 2 GHz | 64 engines @ 2 GHz |
|---:|---:|---:|---:|
| 6.4 T EML/s | 8.0 T/s | 4000x short | 62.5x short |
| 7.078 T EML/s | 8.847 T/s | 4424x short | 69.1x short |
| 14.933 T EML/s | 18.667 T/s | 9333x short | 145.8x short |

Therefore a production XPU cannot centrally walk every graph edge after every EML completion.

## 2. V2.2 execution principle

Move dependency resolution to the consumer endpoint.

Instead of:

```text
producer completes
 -> central engine looks up successors
 -> decrements global counters
 -> global ready scheduler
```

use:

```text
producer result
 -> compiled route descriptor(s)
 -> local/remote token network
 -> consumer operand slot A/B
 -> local 2-bit ready mask
 -> local ready queue
 -> lane
```

For the current binary EML primitive, each executable consumer has two operand slots:

```text
slot_valid[node] = {A_valid, B_valid}
ready[node] = A_valid && B_valid
```

No central pending-dependency decrement is needed for ordinary static EML DAG regions.

## 3. Route descriptor

A compiled route entry can be as small as:

```text
producer-local route index
consumer tile/chiplet
consumer node/local slot id
operand slot: A | B
flags: local | remote | multicast | persistent
```

The value itself travels with the token.

A first binary route token can be modeled as:

```text
value_q16      32 bits
node/slot      16 bits
endpoint       8 bits
flags          8 bits
----------------------
base token     64 bits
```

The exact physical flit width remains an implementation choice.

## 4. Local operand store

Each tile owns operand state for its resident nodes:

```text
operand_a[node]
operand_b[node]
valid_a[node]
valid_b[node]
```

Incoming token behavior:

1. capability/range check endpoint;
2. write value to A or B;
3. set corresponding valid bit;
4. if the other bit is already set, enqueue node as ready;
5. when the node issues, clear both valid bits for the next invocation/generation.

This turns dependency resolution into memory-bank-local state transitions.

## 5. Why this scales

The event handling becomes spatially distributed across the same tiles that own computation.

For an 8-lane tile:

- 1 result/lane/cycle means up to 8 producers/cycle;
- average fanout 1.25 means average demand ~10 route emissions/cycle at full utilization;
- a proof router should therefore target at least 16 local/remote route emissions/cycle or provide per-lane secondary fanout queues.

For a 64-lane tile the corresponding average is ~80 route emissions/cycle. A single centralized FIFO is again the wrong structure; routing must be banked or lane-distributed.

## 6. Local vs remote token path

### Local

```text
lane result
 -> local route entry
 -> operand-bank write
 -> ready bit/queue
```

The compiler should aggressively maximize this path.

### Remote

```text
lane result
 -> route entry
 -> injection queue
 -> chiplet link / UCIe-class PHY
 -> destination tile ingress
 -> operand-bank write
 -> ready bit/queue
```

The NoC budget in `calculations/XPU_V2_NOC_BUDGET.md` shows why remote fraction must remain a compiler objective.

## 7. Static graph and dynamic graph split

This pivot does not eliminate the scheduler.

Use two execution classes:

### STATIC_ROUTED

For ordinary topologically known EML DAG regions:

```text
compiled route descriptors + local operand readiness
```

This should be the high-throughput fast path.

### DYNAMIC_SCHEDULED

For irregular control, conditional graph expansion, resource conflicts, faults, host messages or runtime-created work:

```text
ready queues + scheduler/control cores
```

Thus the expensive general scheduler handles exceptions and dynamic work rather than every edge of every arithmetic operation.

## 8. Consequence for `.xpu` graph binary

The current XPU2 binary contains node sources. A future compiled hardware image should additionally carry a routed form:

```text
node execution table
route table
initial/source tokens
placement table
endpoint/capability table
```

The semantic graph remains portable. The routed image is a hardware-specific lowering artifact analogous to FPGA placement/routing output.

Recommended distinction:

```text
*.xpu     portable semantic DAG
*.xpur    placed+routed XPU image
```

The `.xpur` artifact must include the SHA-256 of its source `.xpu` object and the target fabric profile id.

## 9. V2.1 modules remain useful

Do not delete the scalar dependency engine. Keep it as:

- tiny-graph execution/reference path;
- correctness oracle for the routed implementation;
- fallback for dynamic/irregular nodes;
- fault/replay engine;
- FPGA bring-up implementation before the routed fabric is complete.

## 10. Next RTL blocks

V2.2 should implement, in this order:

1. `xpu_operand_store.sv` — A/B values + valid masks + ready generation;
2. `xpu_route_table.sv` — producer -> route entries;
3. `xpu_route_engine.sv` — local token emission first;
4. `xpu_local_token_crossbar.sv` — multi-producer/multi-bank writes;
5. bank-conflict counters;
6. remote injection FIFO interface;
7. `.xpu -> .xpur` lowering tool;
8. bit-exact comparison against the V2.1 scalar dependency reference.

The central design goal is now explicit:

> **XPU arithmetic is spatial; dependency resolution must be spatial too.**
