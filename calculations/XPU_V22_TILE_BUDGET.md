# XPU V2.2 — routed-tile state, bandwidth and power budget

Status: **architectural sensitivity model / not synthesis evidence**.

## Baseline proof tile

```text
8 EML lanes / tile
32 operand banks
16 direct route-token ports
2 direct routes / producer
1.2 GHz modeled clock
72% modeled sustained lane utilization
fanout = 1.25
```

The 32-bank choice follows the deterministic routed-token cycle model: on the current 4096-node DAG, 8 lanes + 32 banks reaches about **97.49% modeled lane utilization**, while 8 banks reaches only 49.70% because of bank collisions.

## State size

Approximate per-node state for the proof architecture:

```text
operand A       32 bits
operand B       32 bits
valid A/B        2 bits
2 route records 58 bits total including route count
opcode            8 bits
ready bitmap      1 bit
result/debug      32 bits
```

| Resident nodes/tile | State/tile | 384 tiles/chiplet |
|---:|---:|---:|
| 256 | **5.156 KiB** | **1.934 MiB** |
| 512 | 10.312 KiB | 3.867 MiB |
| 1024 | 20.625 KiB | 7.734 MiB |
| 2048 | 41.250 KiB | 15.469 MiB |

With 3072 EML lanes/chiplet and 8 lanes/tile there are **384 tiles/chiplet**.

The 256-node proof point therefore fits comfortably below the earlier 12 MiB/chiplet local-SRAM envelope even with conservative metadata accounting.

## Tile throughput envelope

At 1.2 GHz:

```text
8 lanes peak accept rate        = 9.600 G EML/s
72% modeled sustained rate      = 6.912 G EML/s
route events at fanout 1.25     = 8.640 Gtoken/s
16 route ports raw capacity     = 19.200 Gtoken/s
32 one-write banks raw capacity = 38.400 Gtoken/s
```

Thus arithmetic demand, not raw route-port count, is the first-order limit in the 8-lane/32-bank proof model after bank conflicts are reduced.

With a compact **48-bit local token** envelope, sustained routed information is about:

```text
51.84 GB/s per 8-lane tile
```

This is distributed short-distance traffic, not a single centralized SRAM/NoC link.

## 3072-lane chiplet envelope

At the same 1.2 GHz / 72% modeled utilization:

```text
EML rate       = 2.654208 T EML/s/chiplet
route events   = 3.317760 Ttoken/s/chiplet
48-bit traffic = 159.252 Tb/s distributed local information flow
```

That last number is precisely why the token fabric must remain spatial and bank-local. Sending all local operand traffic through one global crossbar would simply recreate a memory wall inside the chiplet.

## Local route-energy sensitivity

No physical pJ/bit number is claimed yet. The table shows how important this coefficient becomes:

| Local token energy | Route-fabric power/chiplet |
|---:|---:|
| 0.02 pJ/bit | 3.19 W |
| 0.05 pJ/bit | 7.96 W |
| 0.10 pJ/bit | **15.93 W** |
| 0.25 pJ/bit | 39.81 W |
| 0.50 pJ/bit | **79.63 W** |

Therefore local-route physical energy is potentially as important as the EML arithmetic itself.

## EML arithmetic-energy sensitivity

At 2.654208 T EML/s/chiplet:

| EML energy | Arithmetic power/chiplet |
|---:|---:|
| 8 pJ/EML | 21.23 W |
| 12 pJ/EML | **31.85 W** |
| 16 pJ/EML | 42.47 W |
| 20 pJ/EML | 53.08 W |

At the current exploratory 12 pJ/EML coefficient, even **0.25 pJ/bit** for local token movement would make routing consume more power than EML arithmetic.

## Consequence

The next synthesis phase must measure at least two quantities together:

```text
pJ / EML primitive
pJ / local routed bit or token
```

Optimizing only EML cells can produce a globally worse XPU if operand routing becomes expensive.

## V2.2 physical design direction

Prefer:

- small 8-lane tiles;
- ~32 operand banks/tile for the first proof;
- short local token wires;
- hierarchical route aggregation only for genuinely remote destinations;
- compiler placement that co-optimizes tile, chiplet and operand-bank ids;
- local producer/consumer fusion so intermediate values do not enter higher-level NoC stages;
- per-tile counters for bank stalls, token retries, lane idle and route emissions.

The project now has three distinct bandwidth domains that must be co-designed:

```text
inside tile       tens of GB/s distributed per tile
between tiles     distributed hierarchical local NoC
between chiplets  ~1–2 TB/s/chiplet class target from the V2 NoC model
```
