#!/usr/bin/env python3
"""Deterministic prototype numeric profile for an EML lane.

Architectural experiment only.  Inputs/outputs are signed Q16.16 integers.
EML(a,b) = exp(a) - ln(b), with b > 0.  Decimal arithmetic is used so the
reference does not depend on a host binary floating-point libm implementation.
"""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_EVEN, localcontext

FRAC_BITS = 16
SCALE = 1 << FRAC_BITS
I32_MIN = -(1 << 31)
I32_MAX = (1 << 31) - 1


class EMLDomainError(ValueError):
    pass


def q16_to_decimal(raw: int) -> Decimal:
    if not I32_MIN <= raw <= I32_MAX:
        raise OverflowError("input outside signed 32-bit Q16.16")
    return Decimal(raw) / Decimal(SCALE)


def decimal_to_q16(value: Decimal) -> int:
    scaled = (value * Decimal(SCALE)).to_integral_value(rounding=ROUND_HALF_EVEN)
    raw = int(scaled)
    if raw < I32_MIN:
        return I32_MIN
    if raw > I32_MAX:
        return I32_MAX
    return raw


def eml_q16(a_raw: int, b_raw: int) -> int:
    a = q16_to_decimal(a_raw)
    b = q16_to_decimal(b_raw)
    if b <= 0:
        raise EMLDomainError("EML Q16 profile requires b > 0 for ln(b)")

    # Guard precision substantially exceeds the final 16 fractional bits.
    with localcontext() as ctx:
        ctx.prec = 64
        result = a.exp() - b.ln()
        return decimal_to_q16(result)


def q(value: str | float | int) -> int:
    return decimal_to_q16(Decimal(str(value)))


def f(raw: int) -> float:
    return float(q16_to_decimal(raw))


def self_test() -> None:
    cases = [
        ("0", "1"),
        ("1", "1"),
        ("0", "2"),
        ("-1", "0.5"),
        ("0.25", "1.5"),
    ]
    for a, b in cases:
        out = eml_q16(q(a), q(b))
        print(f"EML({a},{b}) -> raw={out} value={f(out):.8f}")

    assert eml_q16(q("0"), q("1")) == q("1")
    try:
        eml_q16(q("0"), q("0"))
    except EMLDomainError:
        pass
    else:
        raise AssertionError("domain failure did not trap")


if __name__ == "__main__":
    self_test()
