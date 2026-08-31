#!/usr/bin/env python3
"""XPU V2.3 static-wavefront / distributed-match capacity model.

This model answers one specific architectural question: how to remove the
central dependency-walker bottleneck from the EML fabric.

A binary EML node consumes two operands. If every operand readiness transition
were processed by one centralized engine, the required event rate would be
O(2 * EML/s), many orders of magnitude above a multi-GHz scalar walker.

V2.3 therefore separates execution into three modes:

1. STATIC_WAVEFRONT: compile (tile, lane, cycle, route) ahead of time. Runtime
   dependency-control events are zero; operand movement still happens.
2. DISTRIBUTED_TOKEN: variable-latency nodes use tile-local operand matching.
3. CENTRAL_FALLBACK: bounded dynamic/control path only; never the throughput path.

The numeric coefficients below are architectural model values, not silicon
measurements.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Params:
    chiplets: int = 4
    lanes_per_chiplet: int = 3072
    tile_lanes: int = 8
    frequency_hz: float = 1.2e9
    sustained_utilization: float = 0.72
    central_walker_hz: float = 2.0e9

    # V2.3 distributed operand fabric.
    operand_ingress_ports_per_tile: int = 24
    operand_banks_per_slot_plane: int = 32  # 32 A banks + 32 B banks
    nodes_per_tile: int = 256
    tiles_per_cluster: int = 16

    # V2.2 values carry destination/slot metadata; V2.3 static values use
    # phase/time as the routing tag and therefore model only the Q16 payload.
    dynamic_token_bits: int = 48
    static_value_bits: int = 32

    # Compiler locality targets for the static fast path. These fractions are
    # fractions of dependency edges, not measured application properties.
    same_tile_fraction: float = 0.80
    same_cluster_cross_tile_fraction: float = 0.15
    same_chiplet_cross_cluster_fraction: float = 0.03
    remote_chiplet_fraction: float = 0.02


P = Params()


def t(x):
    return x / 1e12


def g(x):
    return x / 1e9


def main():
    tiles_per_chiplet = P.lanes_per_chiplet // P.tile_lanes
    tiles_system = tiles_per_chiplet * P.chiplets
    clusters_per_chiplet = tiles_per_chiplet // P.tiles_per_cluster

    raw_ops = P.chiplets * P.lanes_per_chiplet * P.frequency_hz
    sustained_ops = raw_ops * P.sustained_utilization
    hbm4_roofline_ops = 14.933e12

    distributed_port_capacity = (
        tiles_system * P.operand_ingress_ports_per_tile * P.frequency_hz
    )
    conservative_one_slot_bank_capacity = (
        tiles_system * P.operand_banks_per_slot_plane * P.frequency_hz
    )
    balanced_ab_bank_capacity = 2.0 * conservative_one_slot_bank_capacity

    print("XPU V2.3 WALKER ELIMINATION MODEL")
    print(f"chiplets={P.chiplets} lanes/chiplet={P.lanes_per_chiplet} tiles/chiplet={tiles_per_chiplet}")
    print(f"tiles/system={tiles_system} clusters/chiplet={clusters_per_chiplet}")
    print(f"frequency={P.frequency_hz/1e9:.3f} GHz tile_lanes={P.tile_lanes}")
    print()

    print("mode comparison")
    for name, ops in (
        ("sustained_72pct", sustained_ops),
        ("raw_100pct", raw_ops),
        ("hbm4_roofline_reference", hbm4_roofline_ops),
    ):
        operand_events = 2.0 * ops
        walker_gap = operand_events / P.central_walker_hz
        print(
            f"{name}: EML={t(ops):.6f} T/s operands={t(operand_events):.6f} T/s "
            f"single_2GHz_walker_gap={walker_gap:.1f}x"
        )
        print(
            f"  distributed-24port={t(distributed_port_capacity):.6f} T/s "
            f"headroom={distributed_port_capacity/operand_events:.3f}x"
        )
        print(
            f"  conservative-32bank-one-slot={t(conservative_one_slot_bank_capacity):.6f} T/s "
            f"headroom={conservative_one_slot_bank_capacity/operand_events:.3f}x"
        )
        print(
            f"  split-A+B-bank-physical={t(balanced_ab_bank_capacity):.6f} T/s "
            f"headroom={balanced_ab_bank_capacity/operand_events:.3f}x"
        )
        print("  static-wavefront runtime dependency-control events = 0")
    print()

    # Per-tile worst-case acceptance at raw lane throughput.
    tile_raw_ops = P.tile_lanes * P.frequency_hz
    tile_raw_operand_demand = 2.0 * tile_raw_ops
    tile_ingress_capacity = P.operand_ingress_ports_per_tile * P.frequency_hz
    tile_one_slot_bank_capacity = P.operand_banks_per_slot_plane * P.frequency_hz
    tile_ab_bank_capacity = 2.0 * tile_one_slot_bank_capacity
    print("per-tile raw bound")
    print(f"  EML={g(tile_raw_ops):.3f} G/s")
    print(f"  operand demand={g(tile_raw_operand_demand):.3f} G/s = {tile_raw_operand_demand/P.frequency_hz:.1f} operands/cycle")
    print(f"  24-port ingress={g(tile_ingress_capacity):.3f} G/s headroom={tile_ingress_capacity/tile_raw_operand_demand:.3f}x")
    print(f"  one-slot 32-bank plane={g(tile_one_slot_bank_capacity):.3f} G/s headroom={tile_one_slot_bank_capacity/tile_raw_operand_demand:.3f}x")
    print(f"  split A+B banks={g(tile_ab_bank_capacity):.3f} G/s headroom={tile_ab_bank_capacity/tile_raw_operand_demand:.3f}x")
    print()

    # Physical edge movement remains, even though dependency matching disappears.
    edge_rate = 2.0 * sustained_ops
    fractions = (
        ("same_tile", P.same_tile_fraction),
        ("same_cluster_cross_tile", P.same_cluster_cross_tile_fraction),
        ("same_chiplet_cross_cluster", P.same_chiplet_cross_cluster_fraction),
        ("remote_chiplet", P.remote_chiplet_fraction),
    )
    if abs(sum(x[1] for x in fractions) - 1.0) > 1e-12:
        raise SystemExit("locality fractions must sum to 1")

    print("sustained dependency-edge locality budget")
    for name, frac in fractions:
        events = edge_rate * frac
        tagged_tb_s = events * P.dynamic_token_bits / 8.0 / 1e12
        static_tb_s = events * P.static_value_bits / 8.0 / 1e12
        print(
            f"  {name}: {t(events):.6f} Tvalue/s, "
            f"V2.2_tagged={tagged_tb_s:.6f} TB/s, V2.3_tagless={static_tb_s:.6f} TB/s"
        )

    remote_per_chiplet = edge_rate * P.remote_chiplet_fraction / P.chiplets
    remote_tagged_tb_s = remote_per_chiplet * P.dynamic_token_bits / 8.0 / 1e12
    remote_static_tb_s = remote_per_chiplet * P.static_value_bits / 8.0 / 1e12
    print(
        f"remote per chiplet: {g(remote_per_chiplet):.6f} Gvalue/s, "
        f"tagged={remote_tagged_tb_s:.6f} TB/s, tagless={remote_static_tb_s:.6f} TB/s"
    )
    print()

    # Static scheduling storage is tiny because node id is local to a 256-node tile.
    # One byte per schedule entry is enough for the node id; metadata/routes are resident.
    schedule_bytes_per_tile = P.nodes_per_tile
    schedule_bytes_per_chiplet = schedule_bytes_per_tile * tiles_per_chiplet
    route_bytes_per_node = 8
    route_table_bytes_per_chiplet = P.nodes_per_tile * route_bytes_per_node * tiles_per_chiplet
    print("static-wavefront control storage")
    print(f"  schedule bytes/tile={schedule_bytes_per_tile}")
    print(f"  schedule bytes/chiplet={schedule_bytes_per_chiplet} ({schedule_bytes_per_chiplet/1024:.3f} KiB)")
    print(f"  route table/chiplet @8B/node={route_table_bytes_per_chiplet} ({route_table_bytes_per_chiplet/1024:.3f} KiB)")
    print()

    print("architectural conclusion")
    print("  V2.3 STATIC_WAVEFRONT removes dependency matching from the runtime critical path.")
    print("  V2.2 DISTRIBUTED_TOKEN retains local matching for variable-latency regions.")
    print("  V2.1 CENTRAL_FALLBACK is restricted to dynamic/control exceptions.")
    print("  The remaining hard problem is physical operand transport, not a central readiness walker.")


if __name__ == "__main__":
    main()
