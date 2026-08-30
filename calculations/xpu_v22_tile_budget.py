#!/usr/bin/env python3
"""XPU V2.2 routed-tile memory/bandwidth/power sensitivity model.

All physical energy coefficients are explicit sensitivities, not measured values.
"""
from __future__ import annotations


def tile_state_bytes(nodes: int, node_id_bits: int = 16, endpoint_bits: int = 8):
    operand_bits = nodes * (32 + 32 + 1 + 1)  # A/B Q16 + valid A/B
    # Two direct route records. Approx route payload in local metadata:
    # node id + endpoint + slot + 3 flag bits. Plus a two-bit route count.
    route_bits = nodes * (2 + 2 * (node_id_bits + endpoint_bits + 1 + 3))
    opcode_bits = nodes * 8
    ready_bits = nodes
    result_bits = nodes * 32
    total = operand_bits + route_bits + opcode_bits + ready_bits + result_bits
    return {
        "operand": operand_bits // 8,
        "route": route_bits // 8,
        "opcode": opcode_bits // 8,
        "ready": (ready_bits + 7) // 8,
        "result": result_bits // 8,
        "total": (total + 7) // 8,
    }


def main() -> None:
    lanes_per_tile = 8
    lanes_per_chiplet = 3072
    tiles = lanes_per_chiplet // lanes_per_tile
    frequency_ghz = 1.2
    utilization = 0.72
    fanout = 1.25
    local_token_bits = 48

    print("XPU V2.2 tile state")
    for nodes in (256, 512, 1024, 2048):
        state = tile_state_bytes(nodes)
        print(
            f"nodes={nodes}: tile_total={state['total']/1024:.3f} KiB "
            f"chiplet_total={state['total']*tiles/1024/1024:.3f} MiB"
        )

    peak_lane_ops_g = lanes_per_tile * frequency_ghz
    sustained_lane_ops_g = peak_lane_ops_g * utilization
    route_events_g = sustained_lane_ops_g * fanout
    route_port_capacity_g = lanes_per_tile * 2 * frequency_ghz
    bank_write_capacity_g = 32 * frequency_ghz
    local_token_gbs = route_events_g * local_token_bits / 8.0

    print("\n8-lane tile throughput envelope")
    print(f"peak EML accept={peak_lane_ops_g:.3f} G/s")
    print(f"modeled sustained EML={sustained_lane_ops_g:.3f} G/s")
    print(f"route events at fanout {fanout}={route_events_g:.3f} G/s")
    print(f"16 route ports capacity={route_port_capacity_g:.3f} Gtoken/s")
    print(f"32 operand banks capacity={bank_write_capacity_g:.3f} Gtoken/s")
    print(f"48-bit local token traffic={local_token_gbs:.3f} GB/s/tile")

    chiplet_eml_t = lanes_per_chiplet * frequency_ghz * utilization / 1000.0
    chiplet_route_t = chiplet_eml_t * fanout
    print("\n3072-lane chiplet")
    print(f"modeled sustained EML={chiplet_eml_t:.6f} T/s")
    print(f"local route events={chiplet_route_t:.6f} T/s")
    print(f"48-bit routed information={chiplet_route_t*48:.3f} Tb/s distributed")

    print("\nLocal routing energy sensitivity")
    for pj_per_bit in (0.02, 0.05, 0.10, 0.25, 0.50):
        watts = chiplet_route_t * 1e12 * local_token_bits * pj_per_bit * 1e-12
        print(f"{pj_per_bit:.2f} pJ/bit -> {watts:.3f} W/chiplet")

    print("\nEML arithmetic energy sensitivity")
    for pj_per_eml in (8, 12, 16, 20):
        watts = chiplet_eml_t * 1e12 * pj_per_eml * 1e-12
        print(f"{pj_per_eml:2d} pJ/EML -> {watts:.3f} W/chiplet")


if __name__ == "__main__":
    main()
