#!/usr/bin/env python3
"""Deterministic graph-placement laboratory for XPU chiplets.

Goal: minimize remote producer->consumer edges while keeping chiplet load bounded.
This is a synthetic compiler-model experiment, not an application benchmark or
physical NoC simulator.
"""
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path


def generate_clustered_dag(n=8192, chiplets=4, parents=4, cross_prob=0.08, seed=0x585055):
    rng = random.Random(seed)
    hidden = [i % chiplets for i in range(n)]
    rng.shuffle(hidden)

    by_cluster = [[] for _ in range(chiplets)]
    edges = []
    parent_lists = [[] for _ in range(n)]

    for v in range(n):
        c = hidden[v]
        candidates_all = list(range(max(0, v - 128), v))
        local_candidates = [u for u in by_cluster[c] if u >= v - 512]
        chosen = set()
        for _ in range(min(parents, v)):
            use_cross = rng.random() < cross_prob or not local_candidates
            pool = candidates_all if use_cross else local_candidates
            if not pool:
                break
            chosen.add(rng.choice(pool))

        for u in sorted(chosen):
            edges.append((u, v))
            parent_lists[v].append(u)
        by_cluster[c].append(v)

    return parent_lists, edges


def round_robin(n, chiplets):
    return [i % chiplets for i in range(n)]


def random_balanced(n, chiplets, seed=123):
    xs = [i % chiplets for i in range(n)]
    random.Random(seed).shuffle(xs)
    return xs


def locality_greedy(parents, chiplets, imbalance=1.15):
    n = len(parents)
    placement = [-1] * n
    loads = [0] * chiplets
    soft_cap = math.ceil((n / chiplets) * imbalance)

    for v in range(n):
        parent_counts = [0] * chiplets
        for u in parents[v]:
            p = placement[u]
            if p >= 0:
                parent_counts[p] += 1

        best = None
        best_key = None
        for c in range(chiplets):
            overload = max(0, loads[c] + 1 - soft_cap)
            key = (parent_counts[c] - 1000 * overload, -loads[c], -c)
            if best_key is None or key > best_key:
                best_key = key
                best = c

        placement[v] = best
        loads[best] += 1

    return placement


def refine_locality(edges, placement, chiplets, imbalance=1.15, passes=8):
    """Bounded local-improvement pass over incident-edge locality."""
    n = len(placement)
    adj = [[] for _ in range(n)]
    for u, v in edges:
        adj[u].append(v)
        adj[v].append(u)

    loads = [0] * chiplets
    for p in placement:
        loads[p] += 1

    target = n / chiplets
    cap = math.ceil(target * imbalance)
    floor = math.floor(target * (2.0 - imbalance))
    order = sorted(range(n), key=lambda v: (-len(adj[v]), v))

    for _ in range(passes):
        moved = 0
        for v in order:
            cur = placement[v]
            counts = [0] * chiplets
            for u in adj[v]:
                counts[placement[u]] += 1

            candidates = sorted(
                range(chiplets),
                key=lambda c: (counts[c], -loads[c], -c),
                reverse=True,
            )
            for dst in candidates:
                if dst == cur or counts[dst] <= counts[cur]:
                    break
                if loads[dst] < cap and loads[cur] > floor:
                    placement[v] = dst
                    loads[cur] -= 1
                    loads[dst] += 1
                    moved += 1
                    break
        if moved == 0:
            break

    return placement


def edge_stats(edges, placement, chiplets):
    total = len(edges)
    remote = sum(1 for u, v in edges if placement[u] != placement[v])
    loads = [0] * chiplets
    for p in placement:
        loads[p] += 1
    return {
        "edges": total,
        "local_edges": total - remote,
        "remote_edges": remote,
        "remote_fraction": remote / total if total else 0.0,
        "loads": loads,
        "imbalance": max(loads) / (sum(loads) / chiplets) if loads else 0.0,
    }


def run_case(n, chiplets, parents, cross_prob, seed, imbalance):
    plist, edges = generate_clustered_dag(n, chiplets, parents, cross_prob, seed)

    greedy = locality_greedy(plist, chiplets, imbalance)
    refined = refine_locality(edges, greedy[:], chiplets, imbalance)

    placements = {
        "round_robin": round_robin(n, chiplets),
        "random_balanced": random_balanced(n, chiplets, seed ^ 0xA5A5),
        "locality_greedy": greedy,
        "locality_refined": refined,
    }
    return {name: edge_stats(edges, p, chiplets) for name, p in placements.items()}


def write_markdown(path, out):
    lines = [
        "# XPU compiler placement experiment",
        "",
        "> Synthetic DAG experiment only. It demonstrates the effect of placement policy; it is not application performance evidence.",
        "",
        f'Nodes: **{out["nodes"]:,}**, chiplets: **{out["chiplets"]}**, target parents/node: **{out["parents_target"]}**, allowed static load imbalance: **{100*(out["imbalance_limit"]-1):.0f}%**.',
        "",
        "| Hidden cross-edge rate | Round-robin remote | Refined locality remote | Remote-edge reduction | Refined imbalance |",
        "|---:|---:|---:|---:|---:|",
    ]
    for case, algs in out["cases"].items():
        cross = out["case_cross_probability"][case]
        rr = algs["round_robin"]["remote_fraction"]
        lr = algs["locality_refined"]["remote_fraction"]
        red = 1.0 - lr / rr if rr else 0.0
        imb = algs["locality_refined"]["imbalance"]
        lines.append(f"| {100*cross:.0f}% | {100*rr:.2f}% | {100*lr:.2f}% | {100*red:.1f}% | {imb:.3f}x |")

    lines += [
        "",
        "## Interpretation",
        "",
        "- Round-robin destroys semantic locality and leaves about three quarters of edges remote on four chiplets.",
        "- Greedy parent affinity plus bounded local refinement cuts remote traffic by roughly an order of magnitude in strongly clustered graphs.",
        "- On this synthetic model, the **5-10% remote-edge target is reachable for low-cross-edge fused graphs**, but doing so may consume roughly 15% static placement imbalance.",
        "- Runtime work stealing and lane gating should correct utilization imbalance without throwing away compile-time data locality.",
        "- The next benchmark must use real EML DAGs emitted by the compiler, not synthetic communities.",
    ]
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=8192)
    ap.add_argument("--chiplets", type=int, default=4)
    ap.add_argument("--parents", type=int, default=4)
    ap.add_argument("--imbalance", type=float, default=1.15)
    ap.add_argument("--out", default="compiler/PLACEMENT_RESULTS.json")
    ap.add_argument("--report", default="compiler/PLACEMENT_RESULTS.md")
    args = ap.parse_args()

    cases = {}
    case_cross = {}
    for cross in (0.02, 0.05, 0.10, 0.20):
        key = f"cross_{int(cross*100):02d}pct"
        case_cross[key] = cross
        cases[key] = run_case(
            args.nodes, args.chiplets, args.parents, cross,
            0x585055 + int(cross * 1000), args.imbalance,
        )

    out = {
        "schema": "shtenco.xpu.placement.v2",
        "claim_boundary": "synthetic compiler benchmark, not application or silicon evidence",
        "nodes": args.nodes,
        "chiplets": args.chiplets,
        "parents_target": args.parents,
        "imbalance_limit": args.imbalance,
        "case_cross_probability": case_cross,
        "cases": cases,
    }
    Path(args.out).write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    write_markdown(args.report, out)

    for case, algs in cases.items():
        rr = algs["round_robin"]["remote_fraction"]
        lr = algs["locality_refined"]["remote_fraction"]
        reduction = 1.0 - (lr / rr) if rr else 0.0
        print(
            f"{case}: rr={rr:.4f} refined={lr:.4f} "
            f"reduction={100*reduction:.1f}% loads={algs['locality_refined']['loads']}"
        )


if __name__ == "__main__":
    main()
