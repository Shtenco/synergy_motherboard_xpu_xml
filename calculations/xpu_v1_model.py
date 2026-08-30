#!/usr/bin/env python3
"""Reproducible first-order model for SHTENCO XPU V1.

This is an architecture model, not a silicon sign-off model.  Every coefficient
that has not yet been measured from synthesis or hardware is kept explicit.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CFG = ROOT / "config" / "xpu_v1_baseline.json"


def load_cfg() -> dict:
    return json.loads(CFG.read_text(encoding="utf-8"))


def derive(c: dict) -> dict:
    comp = c["compute"]
    io = c["io_control"]
    mem = c["memory"]
    pmem = c["persistent_state"]
    pkg = c["package"]

    eml_s = (
        comp["eml_lanes_total"]
        * comp["target_frequency_hz"]
        * comp["modeled_sustained_utilization"]
    )
    hbm_Bs = mem["hbm_stacks"] * mem["hbm3e_bandwidth_gbs_per_stack"] * 1e9
    pcie5_Bs = io["pcie5_x16_effective_gbs_per_direction"] * 1e9
    pcie6_Bs = io["pcie6_x16_model_gbs_per_direction"] * 1e9
    pmem_Bs = pmem["modeled_bandwidth_gbs"] * 1e9

    compute_area = comp["compute_chiplets"] * comp["compute_die_area_mm2_each"]
    active_area = compute_area + io["io_die_area_mm2"]
    package_area_cm2 = pkg["interposer_x_mm"] * pkg["interposer_y_mm"] / 100.0

    return {
        "eml_primitives_per_s": eml_s,
        "teml_per_s": eml_s / 1e12,
        "hbm_bytes_per_s": hbm_Bs,
        "hbm_tb_per_s": hbm_Bs / 1e12,
        "hbm_bytes_per_eml": hbm_Bs / eml_s,
        "balance_eml_per_byte_hbm": eml_s / hbm_Bs,
        "balance_eml_per_byte_pcie5": eml_s / pcie5_Bs,
        "balance_eml_per_byte_pcie6": eml_s / pcie6_Bs,
        "balance_eml_per_byte_persistent": eml_s / pmem_Bs,
        "compute_silicon_mm2": compute_area,
        "active_silicon_mm2": active_area,
        "local_sram_mib_total": comp["compute_chiplets"] * comp["local_sram_mib_per_chiplet"],
        "average_mm2_per_lane_inside_compute_die": comp["compute_die_area_mm2_each"] / comp["eml_lanes_per_chiplet"],
        "package_area_cm2": package_area_cm2,
    }


def energy_sweep(c: dict, d: dict) -> list[tuple[float, float]]:
    out = []
    for pj in c["energy_sweep"]["eml_primitive_energy_pj"]:
        watts = d["eml_primitives_per_s"] * pj * 1e-12
        out.append((float(pj), watts))
    return out


def scale_sweep(c: dict) -> list[dict]:
    base = c["compute"]
    rows = []
    for n in (1, 2, 4, 8):
        lanes = n * base["eml_lanes_per_chiplet"]
        eml_s = lanes * base["target_frequency_hz"] * base["modeled_sustained_utilization"]
        rows.append({"chiplets": n, "lanes": lanes, "teml_s": eml_s / 1e12})
    return rows


def main() -> None:
    c = load_cfg()
    d = derive(c)
    print(json.dumps(d, indent=2, sort_keys=True))
    print("\nEnergy sensitivity (compute primitive only):")
    for pj, watts in energy_sweep(c, d):
        print(f"  {pj:5.1f} pJ/EML -> {watts:8.2f} W")
    print("\nChiplet scaling at fixed clock/utilization:")
    for row in scale_sweep(c):
        print(f"  {row['chiplets']} chiplet(s): {row['lanes']:5d} lanes -> {row['teml_s']:.6f} T EML/s")
    print("\nPackage-average heat flux sensitivity:")
    for watts in c["package"]["target_power_envelope_w"]:
        flux = watts / d["package_area_cm2"]
        print(f"  {watts:3d} W -> {flux:.3f} W/cm^2 over interposer footprint")


if __name__ == "__main__":
    main()
