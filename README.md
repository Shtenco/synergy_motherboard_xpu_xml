# SHTENCO Motherboard XPU / EML

Research and engineering repository for a **persistent programmable dataflow XPU** built around EML computational primitives.

The current development line is **XPU V2.4 Global Wavefront**: the fixed-latency throughput path has no runtime dependency walker. The compiler assigns `(chiplet, cluster, tile, lane, phase, operand banks)` and reserves static transport ahead of execution. Variable-latency regions use distributed operand-token matching; the old central walker remains only as a bounded debug/control fallback.

The long-term hypothesis is that workloads traditionally split across **CPU, GPU, RAM and SSD** can be mapped onto one capability-addressed fabric with three state classes:

- **Value State** — active scalar/vector/tensor values;
- **Graph State** — executable EML/dataflow graphs;
- **Persistent State** — content-addressed programs, models, files and snapshots.

The repository deliberately separates **measured software facts**, **parameterized architecture models**, **FPGA targets**, and **future ASIC hypotheses**.

## Current V2.4 modeled package

The active V2.4 compiler model uses:

- 4 compute chiplets;
- 3,072 EML lanes/chiplet;
- 12,288 EML lanes/package;
- 384 tiles/chiplet;
- 8 lanes/tile;
- 24 clusters/chiplet;
- 16 tiles/cluster;
- 1.2 GHz modeled lane clock;
- 32 A banks + 32 B banks/tile;
- tagless static wavefront transport for fixed-latency regions;
- distributed-token fallback for variable-latency regions.

The raw model ceiling is **14.7456 T EML/s**. This is **not measured silicon performance, FLOPS, or GPU TOPS**.

## V2.4 local compiler result

For a deterministic graph envelope with edge locality:

```text
same tile                    80%
same cluster                 15%
same chiplet / other cluster  3%
remote chiplet                 2%
```

the local V2.4 C++ compiler reached a model point of **100% issue utilization / 14.7456 T EML/s** using an 8x super-wavefront, compile-time bank coloring, local forwarding, 1/3/5-stage express paths, eight static circuit planes and 256 scheduled package words/output/cycle.

That is architecture-cycle-model evidence, **not FPGA/ASIC evidence**. Adversarial high-cut and narrow reduction graphs remain explicit negative controls.

A separate exact-LUT host benchmark measured the current CPU software kernel in the hundreds of millions of EML/s; see the benchmark report for the observed range and methodology.

## Repository layout

```text
config/                 machine-readable assumptions
spec/                   architecture + ISA/dataflow contracts
calculations/           reproducible area/power/bandwidth/compiler models
compiler/               placement, routing and global wavefront compilers
bench/                  host-side measured benchmarks
hardware/3d/            package/chiplet OpenSCAD models
hardware/rtl/           RTL/FPGA proof implementation
software/               reference executors, XPU/XPUR/XPUW and device models
```

## Current claim boundary

Implemented or modeled here now:

- Q16.16 EML reference + LUT hardware semantics;
- `.xpu` semantic graph format;
- `.xpur` distributed routed-token lowering;
- `.xpuw` walker-free static wavefront lowering;
- V2.1 central fallback RTL;
- V2.2 distributed routed-token RTL;
- V2.3 walker-free tile RTL;
- V2.4 package-scale C++ placement/route/time-slot compiler model;
- 2.5D package and compute-chiplet 3D floorplans;
- bounded capability/device ABI model.

Not claimed yet:

- timing-closed V2.4 switch fabric;
- measured FPGA/ASIC Fmax, pJ/EML or pJ/routed-bit;
- exact per-switch global route coloring proof for the full package;
- physical HBM/CXL/UCIe controller implementation;
- CPU/GPU replacement benchmark equivalence.

## Immediate roadmap

1. V2.5 exact per-switch Clos/radix/flattened-butterfly coloring rather than aggregate stage capacity.
2. Emit real switch SRAM/time-slot images from the compiler.
3. Synthesize route plane + schedule SRAM + 8-lane tile on FPGA.
4. Replace modeled route latency/capacity/energy with measured values.
5. Feed real application-emitted EML DAGs into the V2.4/V2.5 compiler corpus.

Start with:

- `spec/XPU_V24_GLOBAL_WAVEFRONT.md`
- `calculations/XPU_V24_LOCAL_BENCHMARK.md`
- `compiler/xpu_v24_global_wavefront.cpp`
- `bench/eml_q16_host_bench.cpp`
