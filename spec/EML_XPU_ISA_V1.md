# EML-XPU ISA v1 — draft architectural contract

Status: **DRAFT / reference semantics before RTL**.

The mathematical core is intentionally tiny. System behavior is expressed through state/routing primitives rather than by reproducing a large CPU ISA.

## 1. Architectural state classes

1. `VALUE` — scalar/vector/tensor active values.
2. `GRAPH` — immutable or versioned executable DAG objects.
3. `PERSIST` — crash-persistent content-addressed state.
4. `CAP` — authority token describing which graph/domain can access which state object.

## 2. Core operations

```text
EML        dst, a, b          ; dst = exp(a) - ln(b) under frozen numeric semantics
SELECT     dst, pred, a, b    ; branch-free conditional selection
LOAD_STATE dst, object, off   ; read capability-addressed state
STORE_STATE object, off, src  ; update active state
ROUTE      src, endpoint      ; enqueue value/token to graph endpoint
REDUCE     dst, op, group     ; bounded reduction primitive
SYNC       event              ; bounded dependency/event synchronization
PERSIST    object             ; commit persistent-state generation
MESSAGE    endpoint, payload  ; capability-mediated control message
```

`EML` is the universal mathematical primitive. The remaining operations are machine/fabric primitives, not a conventional arithmetic zoo.

## 3. Why SELECT exists

A strictly branch-free dataflow substrate still needs predicates. `SELECT` makes conditional computation explicit and enables the compiler to lower control flow into predicated regions, token routing, or host/control-core escape paths.

## 4. Numeric semantics to freeze before hardware

The first RTL milestone must decide:

- representation: fixed Q format, FP16/BF16/FP32, posit, logarithmic, or mixed;
- valid domain for `ln(b)`;
- NaN/Inf/underflow/overflow behavior if floating point is used;
- rounding mode;
- saturation vs trap policy;
- deterministic approximation error bound;
- whether `exp`/`ln` are exact architectural functions or bounded approximations.

No ASIC performance claim is valid until these are frozen because the cost of an EML lane depends heavily on the chosen semantics.

## 5. Graph binary

A graph image should contain:

```text
header
  magic/version
  numeric-semantics id
  required capabilities
  node count / edge count
  state-object table
  persistent-object table

node table
  opcode
  destination endpoint
  source endpoint(s)
  immediate/metadata

edge/routing table
  producer
  consumer
  locality hint
  queue depth

integrity
  content hash
  optional signature
```

The same binary must be executable by:

```text
software reference evaluator
== QEMU XPU model
== FPGA implementation
== future ASIC
```

with a bit-exact conformance suite for the selected numeric profile.

## 6. Suggested first numeric profile

For early FPGA work, start with a fixed-point profile such as `Q16.16` or `Q8.24` plus bounded LUT/polynomial range reduction. This is not expected to be the final scientific/AI profile; it is a tractable way to validate graph scheduling, deterministic semantics, DMA and device protocol before solving the hardest transcendental datapath problem.

A second profile can target BF16/FP16 for ML workloads.

## 7. Capability contract

Every state reference is resolved through a capability object. A graph cannot issue a raw physical address. Hardware-visible translation should reduce to a bounded descriptor containing at least:

```text
base / object id
length
rights: READ | WRITE | EXEC_GRAPH | PERSIST
owner/domain
lifetime/generation
IOMMU/PASID binding when applicable
```

This preserves the security direction already used by the TURBO XPU device work.

## 8. Execution model

The execution engine is token/dataflow driven:

1. ready input tokens make a node eligible;
2. scheduler assigns eligible node to a compatible lane/tile;
3. EML/other primitive executes;
4. result is forwarded locally where possible;
5. remote edges use NoC queues;
6. state/persistent writes are capability checked;
7. completion event is emitted to the graph owner.

The compiler, not the hardware instruction fetch loop, should perform most expensive placement decisions ahead of time.
