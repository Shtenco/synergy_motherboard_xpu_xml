#!/usr/bin/env python3
"""Bit-exact software model of hardware/rtl/eml_lane_lut.sv."""
from __future__ import annotations
from pathlib import Path
import argparse
import random

from eml_q16 import eml_q16, f

SCALE = 1 << 16
STEP_SHIFT = 9
STEP_MASK = (1 << STEP_SHIFT) - 1
LUT_INTERVALS = 1024
A_MIN_RAW = -4 * SCALE
A_MAX_RAW = 4 * SCALE
B_MIN_RAW = SCALE // 8
B_MAX_RAW = B_MIN_RAW + LUT_INTERVALS * (1 << STEP_SHIFT)
I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1


def s32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v


def load_memh(path):
    return [s32(int(line.strip(), 16)) for line in Path(path).read_text().splitlines() if line.strip()]


def interp(table, raw, min_raw):
    delta = raw - min_raw
    idx = delta >> STEP_SHIFT
    frac = delta & STEP_MASK
    if idx >= LUT_INTERVALS:
        return table[LUT_INTERVALS]
    y0, y1 = table[idx], table[idx + 1]
    return y0 + ((y1 - y0) * frac >> STEP_SHIFT)


def sat32(v):
    return I32_MIN if v < I32_MIN else I32_MAX if v > I32_MAX else int(v)


class DomainError(ValueError):
    pass


def eml_lut(a_raw, b_raw, exp_table, ln_table):
    if a_raw < A_MIN_RAW or a_raw > A_MAX_RAW or b_raw < B_MIN_RAW or b_raw > B_MAX_RAW:
        raise DomainError
    return sat32(interp(exp_table, a_raw, A_MIN_RAW) - interp(ln_table, b_raw, B_MIN_RAW))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--generated", default="hardware/rtl/generated")
    ap.add_argument("--samples", type=int, default=20000)
    args = ap.parse_args()
    exp_t = load_memh(Path(args.generated) / "exp_q16.memh")
    ln_t = load_memh(Path(args.generated) / "ln_q16.memh")
    assert len(exp_t) == 1025 and len(ln_t) == 1025

    rng = random.Random(0x58505532)
    abs_errors = []
    rel_errors = []
    worst = None
    for _ in range(args.samples):
        a_raw = rng.randint(A_MIN_RAW, A_MAX_RAW)
        b_raw = rng.randint(B_MIN_RAW, B_MAX_RAW)
        hw = eml_lut(a_raw, b_raw, exp_t, ln_t)
        ref = eml_q16(a_raw, b_raw)
        err = abs(hw - ref) / SCALE
        abs_errors.append(err)
        ref_f = abs(ref / SCALE)
        if ref_f > 1e-3:
            rel_errors.append(err / ref_f)
        if worst is None or err > worst[0]:
            worst = (err, a_raw, b_raw, hw, ref)

    mean = sum(abs_errors) / len(abs_errors)
    p99 = sorted(abs_errors)[int(0.99 * len(abs_errors)) - 1]
    maxe = max(abs_errors)
    maxrel = max(rel_errors) if rel_errors else 0.0
    print(f"samples={args.samples} mean_abs={mean:.8g} p99_abs={p99:.8g} max_abs={maxe:.8g} max_rel={maxrel:.6g}")
    print(f"worst a={f(worst[1]):.6f} b={f(worst[2]):.6f} hw={f(worst[3]):.6f} ref={f(worst[4]):.6f}")

    # Regression gate for this LUT/interpolation profile. This is an empirical
    # bound over deterministic random coverage, not a formal error proof.
    assert maxe < 0.0025, maxe
    assert p99 < 0.0010, p99


if __name__ == "__main__":
    main()
