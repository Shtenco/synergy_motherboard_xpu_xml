#!/usr/bin/env python3
"""XPU V2.2 route/event throughput budget.

Shows why the V2.1 scalar CSR dependency walker is a correctness reference only
and cannot be the production scheduling architecture.
"""


def events_t_per_s(eml_t_per_s: float, average_fanout: float) -> float:
    return eml_t_per_s * average_fanout


def central_shortfall(event_t_per_s: float, engines: int, clock_ghz: float,
                      events_per_engine_cycle: float = 1.0) -> float:
    capacity = engines * clock_ghz * 1e9 * events_per_engine_cycle
    return event_t_per_s * 1e12 / capacity


def main() -> None:
    fanout = 1.25
    cases = [
        ("HBM3E balanced roofline", 6.4),
        ("V1 compute target", 7.077888),
        ("HBM4 balanced roofline", 14.9333333333),
    ]

    print(f"average_fanout={fanout}")
    for name, rate in cases:
        event_rate = events_t_per_s(rate, fanout)
        one = central_shortfall(event_rate, 1, 2.0)
        sixty_four = central_shortfall(event_rate, 64, 2.0)
        print(
            f"{name}: EML={rate:.6f} T/s route_events={event_rate:.6f} T/s "
            f"one_2GHz_engine_shortfall={one:.2f}x "
            f"64x2GHz_engine_shortfall={sixty_four:.2f}x"
        )

    print("\n8-lane tile route emission envelopes")
    for freq in (0.5, 1.0, 1.5, 2.0):
        for emissions_per_lane in (1, 2):
            cap = 8 * emissions_per_lane * freq
            print(
                f"8 lanes x {emissions_per_lane} emission/lane/cycle @ {freq:.1f}GHz "
                f"= {cap:.1f} G route events/s"
            )


if __name__ == "__main__":
    main()
