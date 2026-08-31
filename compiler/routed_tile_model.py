#!/usr/bin/env python3
"""Cycle model comparing V2.1 central edge release with V2.2 routed tokens.

Synthetic deterministic binary-input DAG. Source nodes are lowered to initial
completion/tokens. Compute nodes are unit-latency. The routed model has a bounded
number of route-event ports and one accepted token write per operand bank/cycle.
This is an architectural model, not RTL timing.
"""
from __future__ import annotations

from collections import deque
import json
import random
from pathlib import Path


def generate_graph(n=4096, sources=64, window=256, seed=0x58505522):
    rng = random.Random(seed)
    parents = [[] for _ in range(n)]
    children = [[] for _ in range(n)]
    for v in range(sources, n):
        lo = max(0, v - window)
        a, b = rng.sample(range(lo, v), 2)
        parents[v] = [a, b]
        children[a].append(v)
        children[b].append(v)
    return parents, children


def simulate(parents, children, lanes=8, event_ports=1, banks=None,
             max_cycles=10_000_000):
    n = len(parents)
    remaining = [len(p) for p in parents]
    ready = deque(i for i, r in enumerate(remaining) if r == 0)
    routeq = deque()
    done = 0
    cycle = 0
    bank_stalls = 0
    lane_idle = 0
    events = 0

    # Source nodes become initial events, not arithmetic lane work.
    sources = list(ready)
    ready.clear()
    for source in sources:
        done += 1
        routeq.extend(children[source])

    while done < n:
        cycle += 1
        if cycle > max_cycles:
            raise RuntimeError("simulation timeout")

        accepted = []
        if banks is None:
            for _ in range(min(event_ports, len(routeq))):
                accepted.append(routeq.popleft())
        else:
            used_banks = set()
            rejected = deque()
            while routeq and len(accepted) < event_ports:
                dst = routeq.popleft()
                bank = dst % banks
                if bank in used_banks:
                    rejected.append(dst)
                    bank_stalls += 1
                else:
                    used_banks.add(bank)
                    accepted.append(dst)
            rejected.extend(routeq)
            routeq = rejected

        for dst in accepted:
            events += 1
            remaining[dst] -= 1
            if remaining[dst] == 0:
                ready.append(dst)
            elif remaining[dst] < 0:
                raise AssertionError("dependency underflow")

        issued = []
        for _ in range(min(lanes, len(ready))):
            issued.append(ready.popleft())
        lane_idle += lanes - len(issued)

        for node in issued:
            done += 1
            routeq.extend(children[node])

    compute_nodes = n - len(sources)
    return {
        "cycles": cycle,
        "events": events,
        "bank_stalls": bank_stalls,
        "lane_utilization": compute_nodes / (cycle * lanes),
        "sources": len(sources),
        "lane_idle_slots": lane_idle,
    }


def main():
    parents, children = generate_graph()
    edge_count = sum(len(x) for x in parents)
    result = {
        "schema": "shtenco.xpu.routed_tile_model.v22",
        "claim_boundary": "synthetic cycle model, not RTL/silicon timing",
        "nodes": len(parents),
        "edges": edge_count,
        "cases": {},
    }

    for lanes in (8, 32, 64):
        central1 = simulate(parents, children, lanes=lanes, event_ports=1, banks=None)
        central8 = simulate(parents, children, lanes=lanes, event_ports=8, banks=None)
        bank_cases = {}
        for banks in (lanes, 2 * lanes, 4 * lanes):
            bank_cases[str(banks)] = simulate(
                parents, children, lanes=lanes,
                event_ports=2 * lanes, banks=banks
            )
        result["cases"][str(lanes)] = {
            "central_1_event_per_cycle": central1,
            "central_8_events_per_cycle": central8,
            "routed_2x_lane_ports": bank_cases,
        }

    Path("compiler/ROUTED_TILE_RESULTS.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# XPU V2.2 routed-token tile cycle model",
        "",
        "> Synthetic deterministic 4096-node binary-input DAG; not RTL or silicon timing.",
        "",
        f"Nodes: **{len(parents)}**, edges: **{edge_count}**.",
        "",
        "| Lanes | Architecture | Banks | Cycles | Lane util | Bank conflict retries |",
        "|---:|---|---:|---:|---:|---:|",
    ]
    for lanes_s, row in result["cases"].items():
        lanes = int(lanes_s)
        c1 = row["central_1_event_per_cycle"]
        c8 = row["central_8_events_per_cycle"]
        lines.append(f'| {lanes} | central walker 1 event/cycle | - | {c1["cycles"]} | {100*c1["lane_utilization"]:.2f}% | 0 |')
        lines.append(f'| {lanes} | central walker 8 events/cycle | - | {c8["cycles"]} | {100*c8["lane_utilization"]:.2f}% | 0 |')
        for banks_s, routed in row["routed_2x_lane_ports"].items():
            lines.append(f'| {lanes} | routed, {2*lanes} token ports | {banks_s} | {routed["cycles"]} | {100*routed["lane_utilization"]:.2f}% | {routed["bank_stalls"]} |')

    lines += [
        "",
        "## Main findings",
        "",
        "1. A one-event/cycle centralized dependency walker completely dominates runtime as lanes scale.",
        "2. Merely adding routed token ports is not enough: too few operand banks serialize otherwise-independent consumer writes.",
        "3. In this graph family, about four operand banks per arithmetic lane moves the 8-lane and 32-lane cases close to arithmetic-limited utilization.",
        "4. The bank index must become a compiler placement constraint; random node numbering is not a final placement strategy.",
        "",
        "The next model should replace `node % banks` with compiler-assigned operand-bank placement and add remote-token latency/injection queues.",
    ]
    Path("compiler/ROUTED_TILE_RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    for lanes_s, row in result["cases"].items():
        best = row["routed_2x_lane_ports"][str(4 * int(lanes_s))]
        base = row["central_1_event_per_cycle"]
        print(
            f"lanes={lanes_s}: central1={base['cycles']} routed4xbank={best['cycles']} "
            f"speedup={base['cycles']/best['cycles']:.2f}x util={100*best['lane_utilization']:.2f}%"
        )


if __name__ == "__main__":
    main()
