# XPU V2.3 walker-elimination capacity proof

> Architectural calculation only. Rates are derived from the current XPU model; they are not measured FPGA/ASIC performance.

## Baseline fabric

```text
chiplets                         4
lanes/chiplet                    3072
lanes/system                     12288
EML lanes/tile                   8
tiles/chiplet                    384
tiles/system                     1536
clock                            1.2 GHz
modeled sustained utilization    72%
V2.3 operand ingress/tile        24 values/cycle
V2.3 operand banks/tile          32 A banks + 32 B banks
```

## 1. Why the central walker is removed, not optimized

The original estimate used an average outgoing fanout of 1.25 and already required trillions of edge-release events/s.

For a binary EML DAG, a stricter upper-bound engineering model is two operand arrivals per fired EML node:

```text
R_operand ~= 2 * R_EML
```

| Compute point | EML rate | Operand-arrival equivalent | Gap vs one 2-GHz walker |
|---|---:|---:|---:|
| 72% sustained 12,288-lane fabric | 10.616832 T/s | 21.233664 T/s | 10,616.8x |
| 100% raw 12,288-lane fabric | 14.745600 T/s | 29.491200 T/s | 14,745.6x |
| 14.933 T/s HBM4 reference roofline | 14.933000 T/s | 29.866000 T/s | 14,933.0x |

A 10,000x-class throughput gap is not a reasonable target for a centralized metadata engine. The architecture must change.

## 2. V2.3 distributed acceptance capacity

Each 8-lane tile has 24 operand ingress positions/cycle. Operand A and operand B use separate 32-bank planes, matching the fact that the EML lane consumes two distinct operand arrays.

System-wide capacity:

```text
1536 tiles * 24 ports * 1.2 GHz = 44.2368 T operand writes/s
1536 tiles * 32 banks * 1.2 GHz = 58.9824 T writes/s per slot plane
A+B physical bank endpoints       = 117.9648 T writes/s combined
```

The 24 ingress ports remain the intended front-door limit; the split banks prevent false A-vs-B conflicts and leave the SRAM side comfortably overprovisioned.

Headroom:

| Compute point | Operand demand | 24-port headroom | Conservative one-slot 32-bank headroom | Split A+B physical headroom |
|---|---:|---:|---:|---:|
| 10.616832 T EML/s | 21.233664 T/s | 2.083x | 2.778x | 5.556x |
| 14.745600 T EML/s | 29.491200 T/s | 1.500x | 2.000x | 4.000x |
| 14.933000 T EML/s | 29.866000 T/s | 1.481x | 1.975x | 3.950x |

Thus even the distributed dynamic V2.2/V2.3 operand fabric can match the event class that the centralized walker cannot.

## 3. V2.3 static-wavefront goes further

For fixed-latency static EML regions the compiler resolves readiness before execution:

```text
node -> tile/lane/cycle
edge -> path/time-slot/operand-slot
```

Therefore:

```text
runtime dependency-control events = 0
```

This does **not** mean data movement becomes zero. It means there is no readiness walker or matching lookup in the execution critical path.

The physical work becomes:

```text
scheduled producer
 -> scheduled/static multicast fabric
 -> distributed operand slot
 -> scheduled consumer
```

## 4. Per-tile proof

At 100% issue:

```text
8 lanes * 1.2 GHz = 9.6 G EML/s
binary operands    = 19.2 G operand arrivals/s
```

V2.3 tile capacity:

```text
24 ingress * 1.2 GHz       = 28.8 G/s = 1.50x headroom
32 A banks * 1.2 GHz       = 38.4 G/s
32 B banks * 1.2 GHz       = 38.4 G/s
combined A+B bank endpoints = 76.8 G/s = 4.00x raw operand demand
```

This is why the scaling unit is the **tile**, not a global scheduler.

## 5. Time-triggered routing removes token addresses

In V2.2 a routed token conceptually carries payload plus destination/slot metadata.

In the V2.3 deterministic fast path, the route and destination are already encoded in the switch schedule for cycle/phase `t`. The time slot is the tag.

Therefore a static data transfer can approach:

```text
payload = Q16.16 value = 32 bits
```

instead of the current 48-bit tagged-token model, before optional ECC/parity.

For the 72%-sustained model and a compiler target of only 2% inter-chiplet edges:

```text
2 * 10.616832 T * 0.02 / 4
= 106.16832 G remote values/s/chiplet
```

Payload requirement:

```text
48-bit tagged token:    0.6370 TB/s/chiplet
32-bit scheduled value: 0.4247 TB/s/chiplet
```

The static topology therefore reduces modeled remote payload by one third before protocol/ECC overhead.

## 6. Hierarchical route depth

A candidate deterministic topology uses radix-4 multistage routing:

```text
16 tiles/cluster:        2 radix-4 addressing stages
24 clusters/chiplet:     3 radix-4 addressing stages (64-code space)
```

This gives a natural hierarchy of about five on-die routing stages for an arbitrary cross-cluster path, with separate die-to-die transport for remote chiplets. The exact Clos/butterfly implementation is not frozen yet.

The topology is attractive because the compiler can reserve switch masks and time slots offline. A result is injected once and multicast replication occurs at branch points.

## 7. Control-store cost

With 256 resident nodes/tile, the local node id fits in 8 bits. A simple one-byte schedule entry per resident node costs:

```text
256 B/tile
384 tiles/chiplet
= 98,304 B/chiplet
= 96 KiB/chiplet
```

An illustrative 8-byte route record for every resident node costs about:

```text
256 * 8 * 384 = 786,432 B ~= 768 KiB/chiplet
```

The schedule/control storage is therefore small compared with the existing multi-MiB distributed-state budget.

## 8. Final V2.3 answer

The walker bottleneck is solved structurally:

```text
V2.1 central walker
  -> fallback/debug only

V2.2 distributed token match
  -> variable-latency execution
  -> ~44.24 T operand-ingress events/s modeled capacity

V2.3 static wavefront
  -> fixed-latency EML fast path
  -> zero runtime dependency-control events
  -> static circuit/multicast routes
  -> time slot acts as routing tag
```

The new primary bottlenecks are now **physical operand movement, bank conflicts, multicast switch capacity, route energy and compiler wavefront width** — which are the correct scaling problems for a spatial processor.
