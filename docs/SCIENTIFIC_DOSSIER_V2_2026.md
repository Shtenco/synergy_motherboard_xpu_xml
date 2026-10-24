# EML XPU — persistent, programmable dataflow machine research

## Distinctive architecture hypothesis

The project investigates whether active values, executable graphs and persistent content-addressed state could share a programmable fabric, reducing costs of repeatedly moving data between CPU, GPU and storage. The proposed XPU uses **Value State**, **Graph State** and **Persistent State** as distinct classes of operation and resource.

The actual repository includes parametric package models, an analytical compute/memory/energy model, configuration, an EML instruction draft and a deterministic reference evaluator. It does not claim fabricated silicon, verified ASIC throughput or completed FPGA timing closure.

## Quantitative baseline

The [first-order model](../calculations/xpu_v1_model.py) estimates primitives per second from lane count N, target clock f and modeled utilization u:

$$
T_{\mathrm{EML}}=Nfu.
$$

For the recorded design of 8,192 lanes, 1.2 GHz and u=0.72, this gives **7.077888 trillion EML primitive evaluations per second as an analytical target**, not GPU-equivalent FLOPS. Four 1,180 GB/s HBM3E stacks provide 4.72 TB/s **modeled raw bandwidth**.

The arithmetic intensity needed to avoid bandwidth bottlenecks is

$$
I_{\mathrm{balance}}=\frac{T_{\mathrm{EML}}}{B_{\mathrm{memory}}},
$$

in EML operations per byte. For HBM this is approximately 1.50 EML/byte; for PCIe 5.0 x16 at 63.02 GB/s per direction it is approximately 112.3 EML/byte. This motivates data residency and a near-data graph.

## Reference instruction semantics

[eml_q16.py](../software/reference/eml_q16.py) defines a signed Q16.16 test function

$$
\operatorname{EML}(a,b)=e^a-\ln b,\qquad b>0.
$$

The reference uses Decimal precision 64, round-half-even conversion to Q16.16 and saturates to signed 32-bit output limits. It is a **numeric ISA hypothesis**, not a physical instruction. Exponential/logarithm costs and approximation bounds need to be demonstrated before treating a primitive as single-cycle hardware.

## Proposed scientific validation

1. Fix bit-exact input/output tables including overflow and invalid logarithm domain.
2. Build RTL for one lane and characterize area, Fmax and energy in a specified library.
3. Match software reference, QEMU functional device and synthesizable RTL on the same vectors.
4. Build SRAM/NoC and HBM traffic models; compare memory-bound and compute-bound kernels.
5. Publish power, thermal and bandwidth sensitivity by chiplet count.

## Product potential

Persistent graph/dataflow engines could support local inference, analytics accelerators and low-latency data-processing appliances. The project is strongest as an **experimentally testable accelerator design**, not an unverified claim of replacing general CPUs or GPUs.

[EML reference](../software/reference/eml_q16.py) · [Quantitative model](../calculations/xpu_v1_model.py) · [ISA](../spec/EML_XPU_ISA_V1.md)
