# EML Q16.16 profile V2

Status: **FROZEN FOR FPGA/QEMU CONFORMANCE / NOT FINAL ASIC SCIENTIFIC PROFILE**.

This profile freezes the first executable EML numeric contract so that the same operation can be checked bit-for-bit in the software LUT model, QEMU device model and FPGA RTL.

## 1. Mathematical oracle

The intended mathematical function is

\[
EML(a,b)=e^a-\ln(b).
\]

`software/reference/eml_q16.py` evaluates this with high-precision Decimal arithmetic and round-half-even conversion to signed Q16.16. It is the accuracy oracle, not the bit-exact FPGA implementation.

## 2. Hardware-conformance semantics

The V2 FPGA/QEMU profile is the exact integer algorithm implemented by `hardware/rtl/eml_lane_lut.sv` and `software/reference/eml_lut_model.py`.

### Representation

- signed 32-bit Q16.16;
- scale = `65536`;
- output saturates to signed 32-bit range;
- no NaN/Inf encodings exist in this profile.

### Input domain

| Quantity | Real domain | Raw Q16.16 |
|---|---:|---:|
| `a` | `[-4.0, +4.0]` | `[-262144, +262144]` |
| `b` | `[0.125, 8.125]` | `[8192, 532480]` |

An input outside either interval raises `domain_error=1`. The current proof RTL returns `y_q16=0` with the error flag set.

## 3. LUT construction

Two deterministic tables are generated:

- `exp_q16.memh`;
- `ln_q16.memh`.

Each table contains **1025 samples** defining **1024 interpolation intervals**.

Grid spacing:

```text
STEP_RAW = 512
STEP_REAL = 512 / 65536 = 1/128
```

EXP grid:

```text
-4.0 + i/128, i=0..1024
```

LN grid:

```text
0.125 + i/128, i=0..1024
```

`tools/gen_eml_lut.py` computes the table values with Decimal precision 80 and converts each sample to Q16.16 using round-half-even.

## 4. Bit-exact interpolation

For an input inside an interval:

```text
delta = raw - minimum
index = delta >> 9
frac  = delta & 0x1ff

y = y0 + (((y1 - y0) * frac) >> 9)
```

The right shift is arithmetic for signed intermediate values. This integer interpolation rule is part of the architecture contract; an FPGA or QEMU implementation that uses a different rounding rule is non-conformant even if its floating-point error is smaller.

At the exact maximum grid point, sample 1024 is returned directly.

The EML result is:

```text
exp_interp(a) - ln_interp(b)
```

followed by signed-32 saturation.

## 5. Pipeline contract

The current proof lane accepts one operation when `in_valid=1` and publishes the associated `out_valid`, `domain_error` and result after the next active clock edge.

This one-cycle proof implementation uses combinational table reads/interpolation. A BRAM/pipelined FPGA implementation may add latency in a later profile, but it must preserve numeric bits and explicit ready/valid semantics.

## 6. Accuracy evidence against Decimal oracle

Deterministic regression over **50,000 uniformly sampled raw-domain points** produced:

```text
mean absolute error = 0.000041298523
p99 absolute error  = 0.00033569336
max absolute error  = 0.00067138672
max relative error  = 0.0106383
```

The maximum relative error is dominated by cases where the true EML value is close to zero; absolute error is the primary regression metric for this fixed-point profile.

Current CI gates:

```text
max_abs < 0.0025
p99_abs < 0.0010
```

These gates are intentionally looser than the observed result so that small implementation refactors do not silently redefine the profile.

## 7. Exact regression points

| a | b | expected raw Q16.16 | real value |
|---:|---:|---:|---:|
| 0 | 1 | 65536 | 1.0 |
| 1 | 1 | 178145 | 2.7182769775 |
| 0 | 2 | 20110 | 0.3068542480 |
| -1 | 0.5 | 69535 | 1.0610198975 |
| 0.25 | 1.5 | 57577 | 0.8785552979 |

## 8. What this profile proves — and does not

It proves:

- deterministic EML semantics can be reduced to ordinary integer FPGA logic;
- table generation is reproducible;
- software and RTL can share one conformance contract;
- approximation error can be measured independently of scheduling/NoC design.

It does **not** prove:

- 1.2–1.4 GHz timing;
- 12 pJ/EML;
- 0.018 mm²/lane;
- suitability of Q16.16 for every ML/HPC workload;
- final ASIC efficiency versus CPU/GPU transcendental units.

Those numbers remain DSE assumptions until synthesis and board measurements replace them.

## 9. Next numeric profiles

After the scheduler/device path is stable:

1. Q16.16 pipelined BRAM profile with identical bits;
2. BF16/FP16 EML profile for ML workloads;
3. wider scientific profile if accuracy benchmarks justify its silicon cost.
