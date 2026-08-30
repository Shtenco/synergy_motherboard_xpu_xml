#!/usr/bin/env python3
"""XPU V2 inter-chiplet NoC/injection budget model.

This is an architectural bandwidth model, not a claim about a concrete UCIe PHY.
It translates EML throughput and compiler remote-edge fraction into aggregate and
per-chiplet result-token traffic, then compares that traffic with simple wide
on-package datapath envelopes.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Case:
    name: str
    throughput_t_eml_s: float
    remote_fraction: float
    result_bytes: int = 4
    average_fanout: float = 1.25
    chiplets: int = 4


def remote_traffic(case: Case) -> tuple[float, float]:
    total_bytes_s = (
        case.throughput_t_eml_s
        * 1e12
        * case.result_bytes
        * case.average_fanout
        * case.remote_fraction
    )
    return total_bytes_s / 1e12, total_bytes_s / case.chiplets / 1e12


def raw_link_gbs(width_bits: int, clock_ghz: float) -> float:
    """Ideal payload datapath envelope before protocol/PHY overhead."""
    return width_bits / 8.0 * clock_ghz


def max_remote_fraction(
    throughput_t_eml_s: float,
    per_chiplet_injection_tb_s: float,
    chiplets: int = 4,
    result_bytes: int = 4,
    average_fanout: float = 1.25,
) -> float:
    local_rate = throughput_t_eml_s * 1e12 / chiplets
    denominator = local_rate * result_bytes * average_fanout
    return per_chiplet_injection_tb_s * 1e12 / denominator


def main() -> None:
    cases = [
        Case("HBM3E-balanced-local-6.84pct", 6.4, 0.0684),
        Case("HBM3E-balanced-local-11.27pct", 6.4, 0.1127),
        Case("V1-compute-7.08T-local-6.84pct", 7.077888, 0.0684),
        Case("V1-compute-7.08T-local-11.27pct", 7.077888, 0.1127),
        Case("HBM4-balanced-local-6.84pct", 14.9333333333, 0.0684),
        Case("HBM4-balanced-local-11.27pct", 14.9333333333, 0.1127),
    ]

    print("XPU V2 NoC traffic")
    for case in cases:
        total, per_chiplet = remote_traffic(case)
        print(
            f"{case.name}: aggregate={total:.3f} TB/s "
            f"per_chiplet={per_chiplet:.3f} TB/s"
        )

    print("\nIdeal on-package datapath envelopes (one link, one direction)")
    for width in (1024, 2048, 3072, 4096):
        for freq in (1.5, 2.0, 2.5):
            print(f"{width:4d}b @ {freq:.1f} GHz = {raw_link_gbs(width, freq):7.1f} GB/s")

    print("\nRemote-fraction ceilings")
    # Two ideal 2048b x 2GHz egress datapaths = 1.024 TB/s/chiplet.
    # Three = 1.536 TB/s/chiplet. These are internal architecture envelopes,
    # not UCIe lane-count claims.
    for injection in (1.024, 1.536, 2.048):
        for rate in (6.4, 14.9333333333):
            ceiling = max_remote_fraction(rate, injection)
            print(
                f"rate={rate:.3f} T EML/s injection={injection:.3f} TB/s/chiplet "
                f"remote_ceiling={100.0 * ceiling:.2f}%"
            )


if __name__ == "__main__":
    main()
