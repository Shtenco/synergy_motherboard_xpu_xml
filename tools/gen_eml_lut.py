#!/usr/bin/env python3
"""Generate deterministic Q16.16 EXP/LN interpolation tables for EML FPGA lane."""
from decimal import Decimal, ROUND_HALF_EVEN, localcontext
from pathlib import Path
import argparse

FRAC_BITS = 16
SCALE = 1 << FRAC_BITS
STEP_RAW = 1 << 9          # 512 raw Q16 units = 1/128
LUT_INTERVALS = 1024       # 1025 samples for linear interpolation
A_MIN_RAW = -4 * SCALE
B_MIN_RAW = SCALE // 8     # 0.125
I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1


def to_q16(x: Decimal) -> int:
    raw = int((x * Decimal(SCALE)).to_integral_value(rounding=ROUND_HALF_EVEN))
    return max(I32_MIN, min(I32_MAX, raw))


def hex32(x: int) -> str:
    return f"{x & 0xffffffff:08x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="hardware/rtl/generated")
    args = ap.parse_args()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    exp_rows = []
    ln_rows = []
    with localcontext() as ctx:
        ctx.prec = 80
        for i in range(LUT_INTERVALS + 1):
            a = Decimal(A_MIN_RAW + i * STEP_RAW) / Decimal(SCALE)
            b = Decimal(B_MIN_RAW + i * STEP_RAW) / Decimal(SCALE)
            exp_rows.append(hex32(to_q16(a.exp())))
            ln_rows.append(hex32(to_q16(b.ln())))

    (out / "exp_q16.memh").write_text("\n".join(exp_rows) + "\n")
    (out / "ln_q16.memh").write_text("\n".join(ln_rows) + "\n")
    print(f"generated={LUT_INTERVALS+1} step_raw={STEP_RAW} a=[-4,4] b=[0.125,8.125]")


if __name__ == "__main__":
    main()
