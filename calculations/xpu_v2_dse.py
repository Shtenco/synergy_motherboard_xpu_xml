#!/usr/bin/env python3
"""Dependency-free XPU V2 design-space explorer.

Analytical architecture model only; not a silicon-performance claim.
Uncertain physical coefficients are held as a baseline and reported separately
from design variables so optimistic assumptions cannot "win" the search.
"""
from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
from pathlib import Path


def geomean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs and all(x > 0 for x in xs) else 0.0


def workload_eval(raw_teml_s, chiplets, hbm_tb_s, remote_fraction, workload, phys, sram_mib, hbm_stacks):
    hbm_b = float(workload["hbm_bytes_per_eml"])
    result_b = float(workload["result_bytes"])
    fanout = float(workload["fanout"])

    hbm_limit = math.inf if hbm_b == 0 else hbm_tb_s / hbm_b
    noc_capacity = chiplets * float(phys["noc_capacity_tb_s_per_chiplet"])
    noc_bytes_per_eml = result_b * fanout * remote_fraction
    noc_limit = math.inf if noc_bytes_per_eml == 0 else noc_capacity / noc_bytes_per_eml
    sustained = min(raw_teml_s, hbm_limit, noc_limit)

    actual_noc_tb_s = sustained * noc_bytes_per_eml
    compute_w = sustained * float(phys["eml_energy_pj"])
    noc_w = actual_noc_tb_s * float(phys["noc_energy_pj_per_byte"])
    sram_w = chiplets * sram_mib * float(phys["sram_power_w_per_mib"])
    hbm_w = hbm_stacks * float(phys["hbm_power_w_per_stack"])
    total_w = compute_w + noc_w + sram_w + hbm_w + float(phys["io_control_fixed_w"])

    if hbm_limit <= raw_teml_s and hbm_limit <= noc_limit:
        bottleneck = "hbm"
    elif noc_limit <= raw_teml_s and noc_limit <= hbm_limit:
        bottleneck = "noc"
    else:
        bottleneck = "compute"

    return {
        "sustained_teml_s": sustained,
        "hbm_limit_teml_s": hbm_limit,
        "noc_limit_teml_s": noc_limit,
        "noc_traffic_tb_s": actual_noc_tb_s,
        "power_w": total_w,
        "bottleneck": bottleneck,
    }


def enumerate_designs(cfg):
    s = cfg["search_space"]
    m = cfg["model"]
    phys = cfg["physical_assumptions"]["baseline"]
    hbm_items = list(s["hbm_types"].items())

    axes = [
        s["chiplets"], s["lanes_per_chiplet"], s["frequency_ghz"], s["utilization"],
        s["hbm_stacks"], hbm_items, s["remote_edge_fraction"], s["sram_mib_per_chiplet"],
    ]

    for chiplets, lanes_pc, freq, util, hbm_stacks, hbm_item, remote, sram_mib in itertools.product(*axes):
        hbm_name, hbm = hbm_item
        total_lanes = chiplets * lanes_pc
        raw_teml_s = total_lanes * freq * util / 1000.0
        hbm_tb_s = hbm_stacks * float(hbm["bandwidth_tb_s_per_stack"])

        die_area_each = (
            lanes_pc * float(phys["lane_area_mm2"])
            + sram_mib * float(phys["sram_area_mm2_per_mib"])
        ) * (1.0 + float(phys["routing_area_overhead_fraction"]))
        if die_area_each > float(m["max_compute_die_area_mm2_each"]):
            continue

        wr = {}
        for name, workload in cfg["workloads"].items():
            wr[name] = workload_eval(
                raw_teml_s, chiplets, hbm_tb_s, remote, workload, phys, sram_mib, hbm_stacks
            )

        throughputs = [wr[n]["sustained_teml_s"] for n in cfg["workloads"]]
        powers = [wr[n]["power_w"] for n in cfg["workloads"]]
        gm = geomean(throughputs)
        gp = geomean(powers)

        yield {
            "chiplets": chiplets,
            "lanes_per_chiplet": lanes_pc,
            "total_lanes": total_lanes,
            "frequency_ghz": freq,
            "utilization": util,
            "hbm_type": hbm_name,
            "hbm_stacks": hbm_stacks,
            "hbm_tb_s": hbm_tb_s,
            "remote_edge_fraction": remote,
            "sram_mib_per_chiplet": sram_mib,
            "raw_teml_s": raw_teml_s,
            "die_area_each_mm2": die_area_each,
            "compute_area_total_mm2": die_area_each * chiplets,
            "current_floorplan_fit": (
                chiplets <= int(m["current_floorplan_max_chiplets"])
                and hbm_stacks <= int(m["current_floorplan_max_hbm_stacks"])
            ),
            "dense_local_teml_s": wr["dense_local"]["sustained_teml_s"],
            "balanced_graph_teml_s": wr["balanced_graph"]["sustained_teml_s"],
            "state_heavy_teml_s": wr["state_heavy"]["sustained_teml_s"],
            "dense_local_power_w": wr["dense_local"]["power_w"],
            "balanced_graph_power_w": wr["balanced_graph"]["power_w"],
            "state_heavy_power_w": wr["state_heavy"]["power_w"],
            "dense_local_bottleneck": wr["dense_local"]["bottleneck"],
            "balanced_graph_bottleneck": wr["balanced_graph"]["bottleneck"],
            "state_heavy_bottleneck": wr["state_heavy"]["bottleneck"],
            "balanced_graph_noc_tb_s": wr["balanced_graph"]["noc_traffic_tb_s"],
            "geomean_teml_s": gm,
            "geomean_power_w": gp,
            "geomean_teml_per_w": gm / gp if gp else 0.0,
            "geomean_teml_per_mm2": gm / (die_area_each * chiplets),
        }


def worst_power(r):
    return max(r["dense_local_power_w"], r["balanced_graph_power_w"], r["state_heavy_power_w"])


def select_best(rows, power_budget, hbm_type=None, current_floorplan_only=True):
    out = []
    for r in rows:
        if current_floorplan_only and not r["current_floorplan_fit"]:
            continue
        if hbm_type and r["hbm_type"] != hbm_type:
            continue
        if worst_power(r) > power_budget:
            continue
        out.append(r)
    return sorted(
        out,
        key=lambda r: (r["geomean_teml_s"], r["geomean_teml_per_w"], -r["compute_area_total_mm2"]),
        reverse=True,
    )


def fmt(r):
    return (
        f'{r["chiplets"]}x{r["lanes_per_chiplet"]}, {r["frequency_ghz"]:.1f}GHz, '
        f'u={r["utilization"]:.2f}, {r["hbm_stacks"]}x{r["hbm_type"]}, '
        f'remote={100*r["remote_edge_fraction"]:.0f}%, SRAM={r["sram_mib_per_chiplet"]}MiB/chiplet'
    )


def write_markdown(path, cfg, rows):
    phys = cfg["physical_assumptions"]["baseline"]
    lines = [
        "# XPU V2 design-space search results",
        "",
        "> **Claim boundary:** analytical exploration only. Physical coefficients are model assumptions, not measured silicon.",
        "",
        f"Enumerated valid architectural designs: **{len(rows):,}**.",
        "",
        "## Baseline physical assumptions",
        "",
        "| Coefficient | Baseline |",
        "|---|---:|",
        f'| EML dynamic energy | {phys["eml_energy_pj"]} pJ/EML |',
        f'| EML lane area | {phys["lane_area_mm2"]} mm²/lane |',
        f'| NoC dynamic energy | {phys["noc_energy_pj_per_byte"]} pJ/B |',
        f'| NoC capacity | {phys["noc_capacity_tb_s_per_chiplet"]} TB/s/chiplet |',
        f'| HBM stack power model | {phys["hbm_power_w_per_stack"]} W/stack |',
        f'| Fixed I/O + control | {phys["io_control_fixed_w"]} W |',
        "",
        "## Workload contracts",
        "",
        "| Workload | HBM B/EML | Result B | Fanout |",
        "|---|---:|---:|---:|",
    ]
    for name, w in cfg["workloads"].items():
        lines.append(f'| `{name}` | {w["hbm_bytes_per_eml"]} | {w["result_bytes"]} | {w["fanout"]} |')

    lines += ["", "## Best current-floorplan candidates", ""]
    for hbm_type in ("HBM3E", "HBM4"):
        lines += [f"### {hbm_type}", ""]
        for budget in cfg["model"]["power_budgets_w"]:
            best = select_best(rows, float(budget), hbm_type, True)
            lines += [f"**<= {budget} W**", ""]
            if not best:
                lines += ["No candidate.", ""]
                continue
            lines += [
                "| Rank | Configuration | Dense T | Balanced T | State T | Geo T | Worst W | Compute area mm² |",
                "|---:|---|---:|---:|---:|---:|---:|---:|",
            ]
            for i, r in enumerate(best[:3], 1):
                lines.append(
                    f'| {i} | {fmt(r)} | {r["dense_local_teml_s"]:.3f} | '
                    f'{r["balanced_graph_teml_s"]:.3f} | {r["state_heavy_teml_s"]:.3f} | '
                    f'{r["geomean_teml_s"]:.3f} | {worst_power(r):.1f} | '
                    f'{r["compute_area_total_mm2"]:.1f} |'
                )
            lines.append("")

    lines += [
        "## Rooflines",
        "",
        "- 4 x HBM3E at 1.2 TB/s/stack = **4.8 TB/s**. At 0.75 B/EML, balanced roofline = **6.4 T EML/s**.",
        "- 4 x HBM4 at 2.8 TB/s/stack = **11.2 TB/s**. At 0.75 B/EML, balanced roofline = **14.933 T EML/s**.",
        "- State-heavy at 2 B/EML is capped at **2.4 T EML/s** on 4xHBM3E and **5.6 T EML/s** on 4xHBM4 before cache/reuse/compression.",
        "- NoC demand is `R_EML * result_bytes * fanout * remote_fraction`; lowering remote edges is equivalent to buying fabric bandwidth.",
        "",
        "## Sensitivity that must be measured",
        "",
        f'- At the V1 raw target 7.077888 T EML/s, compute-only power is **{7.077888*8:.1f}/{7.077888*12:.1f}/{7.077888*16:.1f}/{7.077888*20:.1f} W** for 8/12/16/20 pJ per EML.',
        "- Lane area sweep: 0.012 / 0.018 / 0.024 mm² per lane changes chiplet feasibility materially; synthesis must replace this placeholder.",
        "- NoC energy sweep: 4 / 8 / 12 pJ per transferred byte is tracked separately from architecture choices.",
        "",
        "## Engineering decision",
        "",
        "1. **V2-FPGA:** prove numeric correctness and scheduler semantics first; 8-64 LUT EML lanes are enough.",
        "2. **V2-HBM3E:** keep the current 4-chiplet/4-stack package. Use clock/lane gating around the ~6.4 T balanced roofline.",
        "3. **V2-HBM4:** only scale lanes toward ~15 T balanced EML/s after locality is demonstrated.",
        "4. **Compiler KPI:** remote causal edges <=5-10% on fused graphs.",
        "5. **Storage KPI:** for state-heavy workloads, reduce effective HBM bytes/EML below 1.0 using local SRAM, persistent graph reuse, compression or compute-near-state.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config/xpu_v2_dse.json")
    ap.add_argument("--csv", default="calculations/xpu_v2_dse_all.csv")
    ap.add_argument("--report", default="calculations/XPU_V2_DSE_RESULTS.md")
    args = ap.parse_args()

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    rows = list(enumerate_designs(cfg))
    if not rows:
        raise SystemExit("no valid designs")

    out_csv = Path(args.csv)
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    write_markdown(Path(args.report), cfg, rows)
    print(f"valid_designs={len(rows)}")
    for hbm in ("HBM3E", "HBM4"):
        for budget in cfg["model"]["power_budgets_w"]:
            best = select_best(rows, float(budget), hbm, True)
            if best:
                r = best[0]
                print(f"{hbm}_{budget}W={fmt(r)} geo={r['geomean_teml_s']:.3f}T worst={worst_power(r):.1f}W")


if __name__ == "__main__":
    main()
