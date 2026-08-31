#!/usr/bin/env python3
"""XPU V2.3 static-wavefront image compiler/reference executor.

`.xpu` is the portable semantic graph.
`.xpur` is the V2.2 routed-token lowering.
`.xpuw` is the V2.3 time-triggered wavefront lowering.

The V2.3 proof profile is one tile with:
- 8 EML lanes;
- 24 tagless ingress value ports;
- 32 A-banks + 32 B-banks;
- fixed one-cycle EML latency;
- compiler-selected issue phases.

The runtime reference executor performs no readiness search. It replays the
compiled ingress and issue schedule and fails if an operand is missing at its
assigned cycle.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import struct

from eml_q16 import q
from eml_lut_model import eml_lut, load_memh
from xpu_graph import (
    Graph,
    OP_INPUT,
    OP_CONST_Q16,
    OP_EML,
    NUMERIC_PROFILE_EML_Q16_LUT_V2,
    demo_graph,
    pack_graph,
    unpack_graph,
)

MAGIC = b"XPUW"
VERSION = 1
TARGET_PROFILE_V23_8L_24P_32B = 1
DIGEST_BYTES = 32
LANES = 8
PORTS = 24
BANKS = 32

# 64-byte header.
# magic, version, numeric, target, schedule_count, ingress_count, output_count,
# source-xpu-sha256, input_count, period_last
HEADER = struct.Struct("<4sHHIIII32sII")
# phase, lane, flags, node_id
SCHED = struct.Struct("<HBBI")                 # 8 bytes
# phase, port, slot, source_kind, flags, reserved, consumer, argument
INGRESS = struct.Struct("<HBBBBHIi")           # 16 bytes
U32 = struct.Struct("<I")

SRC_INPUT = 1
SRC_CONST = 2
SRC_PRODUCER = 3


class WavefrontFormatError(ValueError):
    pass


@dataclass(frozen=True)
class ScheduleEntry:
    phase: int
    lane: int
    node: int
    flags: int = 0


@dataclass(frozen=True)
class IngressEntry:
    phase: int
    port: int
    slot: int
    source_kind: int
    consumer: int
    argument: int
    flags: int = 0


@dataclass(frozen=True)
class WavefrontImage:
    source_xpu_sha256: bytes
    schedule: tuple[ScheduleEntry, ...]
    ingress: tuple[IngressEntry, ...]
    outputs: tuple[int, ...]
    input_count: int
    period_last: int
    target_profile: int = TARGET_PROFILE_V23_8L_24P_32B


def _source_descriptor(graph: Graph, source_node: int):
    src = graph.nodes[source_node]
    if src.opcode == OP_INPUT:
        return SRC_INPUT, src.arg0
    if src.opcode == OP_CONST_Q16:
        return SRC_CONST, src.arg0
    if src.opcode == OP_EML:
        return SRC_PRODUCER, source_node
    raise WavefrontFormatError(f"unsupported source opcode {src.opcode}")


def lower_graph(graph: Graph, source_blob: bytes) -> WavefrontImage:
    """Greedy single-tile static scheduler.

    Both operands for a consumer are delivered one phase before issue. A/B bank
    planes are independent, so the same bank index may accept one A and one B in
    the same phase. Same-slot bank collisions and ingress-port overcommit cause
    the node to move to a later phase.
    """
    schedule: list[ScheduleEntry] = []
    ingress: list[IngressEntry] = []
    issue_phase: dict[int, int] = {}

    lanes_used: dict[int, set[int]] = {}
    ports_used: dict[int, set[int]] = {}
    banks_a_used: dict[int, set[int]] = {}
    banks_b_used: dict[int, set[int]] = {}

    for node_id, node in enumerate(graph.nodes):
        if node.opcode != OP_EML:
            continue

        sources = (node.arg0, node.arg1)
        earliest = 1
        for src_id in sources:
            src = graph.nodes[src_id]
            if src.opcode == OP_EML:
                # Producer issues at p, result exists in p+1. Deliver in the
                # phase immediately before the consumer, so consumer >= p+2.
                earliest = max(earliest, issue_phase[src_id] + 2)

        phase = earliest
        while True:
            arrival = phase - 1
            used_lanes = lanes_used.setdefault(phase, set())
            used_ports = ports_used.setdefault(arrival, set())
            used_a = banks_a_used.setdefault(arrival, set())
            used_b = banks_b_used.setdefault(arrival, set())
            bank = node_id % BANKS

            if len(used_lanes) >= LANES:
                phase += 1
                continue
            if len(used_ports) + 2 > PORTS:
                phase += 1
                continue
            if bank in used_a or bank in used_b:
                # This node requires one A and one B. Independent planes allow
                # those two writes together, but not another same-slot write to
                # the same bank in this phase.
                phase += 1
                continue
            break

        arrival = phase - 1
        lane = min(set(range(LANES)) - lanes_used[phase])
        free_ports = sorted(set(range(PORTS)) - ports_used[arrival])
        port_a, port_b = free_ports[0], free_ports[1]

        lanes_used[phase].add(lane)
        ports_used[arrival].update((port_a, port_b))
        banks_a_used[arrival].add(node_id % BANKS)
        banks_b_used[arrival].add(node_id % BANKS)
        issue_phase[node_id] = phase
        schedule.append(ScheduleEntry(phase, lane, node_id))

        for slot, (port, source_node) in enumerate(zip((port_a, port_b), sources)):
            kind, arg = _source_descriptor(graph, source_node)
            ingress.append(
                IngressEntry(
                    phase=arrival,
                    port=port,
                    slot=slot,
                    source_kind=kind,
                    consumer=node_id,
                    argument=arg,
                )
            )

    exec_ids = set(issue_phase)
    if not exec_ids:
        raise WavefrontFormatError("no EML nodes in wavefront image")
    for out in graph.outputs:
        if out not in exec_ids:
            raise WavefrontFormatError("V2.3 proof outputs must be EML nodes")

    max_issue = max(issue_phase.values())
    period_last = max_issue + 1  # final EML result becomes visible one phase later
    image = WavefrontImage(
        source_xpu_sha256=hashlib.sha256(source_blob).digest(),
        schedule=tuple(sorted(schedule, key=lambda x: (x.phase, x.lane, x.node))),
        ingress=tuple(sorted(ingress, key=lambda x: (x.phase, x.port))),
        outputs=graph.outputs,
        input_count=graph.input_count,
        period_last=period_last,
    )
    validate_image(image)
    return image


def validate_image(image: WavefrontImage) -> None:
    if len(image.source_xpu_sha256) != 32:
        raise WavefrontFormatError("source SHA-256 must be 32 bytes")
    if image.target_profile != TARGET_PROFILE_V23_8L_24P_32B:
        raise WavefrontFormatError("unsupported V2.3 target profile")
    if image.period_last < 1 or image.period_last > 0xFFFF:
        raise WavefrontFormatError("period outside proof bounds")

    phase_lanes: dict[int, set[int]] = {}
    scheduled_nodes: set[int] = set()
    for e in image.schedule:
        if not 0 <= e.phase <= image.period_last or not 0 <= e.lane < LANES:
            raise WavefrontFormatError("bad schedule coordinate")
        used = phase_lanes.setdefault(e.phase, set())
        if e.lane in used:
            raise WavefrontFormatError("two nodes scheduled on one lane/phase")
        used.add(e.lane)
        if e.node in scheduled_nodes:
            raise WavefrontFormatError("node scheduled more than once")
        scheduled_nodes.add(e.node)

    phase_ports: dict[int, set[int]] = {}
    phase_a_banks: dict[int, set[int]] = {}
    phase_b_banks: dict[int, set[int]] = {}
    for e in image.ingress:
        if not 0 <= e.phase <= image.period_last or not 0 <= e.port < PORTS:
            raise WavefrontFormatError("bad ingress coordinate")
        if e.slot not in (0, 1):
            raise WavefrontFormatError("bad operand slot")
        if e.source_kind not in (SRC_INPUT, SRC_CONST, SRC_PRODUCER):
            raise WavefrontFormatError("bad ingress source kind")
        ports = phase_ports.setdefault(e.phase, set())
        if e.port in ports:
            raise WavefrontFormatError("ingress port collision")
        ports.add(e.port)
        banks = phase_b_banks.setdefault(e.phase, set()) if e.slot else phase_a_banks.setdefault(e.phase, set())
        bank = e.consumer % BANKS
        if bank in banks:
            raise WavefrontFormatError("same-slot bank collision")
        banks.add(bank)

    for out in image.outputs:
        if out not in scheduled_nodes:
            raise WavefrontFormatError("output is not scheduled")


def pack_image(image: WavefrontImage) -> bytes:
    validate_image(image)
    body = bytearray(
        HEADER.pack(
            MAGIC,
            VERSION,
            NUMERIC_PROFILE_EML_Q16_LUT_V2,
            image.target_profile,
            len(image.schedule),
            len(image.ingress),
            len(image.outputs),
            image.source_xpu_sha256,
            image.input_count,
            image.period_last,
        )
    )
    for e in image.schedule:
        body += SCHED.pack(e.phase, e.lane, e.flags, e.node)
    for e in image.ingress:
        body += INGRESS.pack(
            e.phase, e.port, e.slot, e.source_kind, e.flags, 0,
            e.consumer, e.argument,
        )
    for out in image.outputs:
        body += U32.pack(out)
    body += hashlib.sha256(body).digest()
    return bytes(body)


def unpack_image(blob: bytes) -> WavefrontImage:
    if len(blob) < HEADER.size + DIGEST_BYTES:
        raise WavefrontFormatError("truncated XPUW")
    payload, digest = blob[:-DIGEST_BYTES], blob[-DIGEST_BYTES:]
    if hashlib.sha256(payload).digest() != digest:
        raise WavefrontFormatError("XPUW SHA-256 mismatch")

    (
        magic, version, numeric, target, sched_count, ingress_count,
        output_count, source_sha, input_count, period_last,
    ) = HEADER.unpack_from(payload, 0)
    if magic != MAGIC or version != VERSION:
        raise WavefrontFormatError("bad XPUW magic/version")
    if numeric != NUMERIC_PROFILE_EML_Q16_LUT_V2:
        raise WavefrontFormatError("numeric profile mismatch")

    expected = HEADER.size + sched_count * SCHED.size + ingress_count * INGRESS.size + output_count * 4
    if len(payload) != expected:
        raise WavefrontFormatError("XPUW length/header mismatch")

    off = HEADER.size
    schedule = []
    for _ in range(sched_count):
        phase, lane, flags, node = SCHED.unpack_from(payload, off)
        off += SCHED.size
        schedule.append(ScheduleEntry(phase, lane, node, flags))

    ingress = []
    for _ in range(ingress_count):
        phase, port, slot, kind, flags, reserved, consumer, argument = INGRESS.unpack_from(payload, off)
        off += INGRESS.size
        if reserved:
            raise WavefrontFormatError("nonzero ingress reserved field")
        ingress.append(IngressEntry(phase, port, slot, kind, consumer, argument, flags))

    outputs = []
    for _ in range(output_count):
        (node,) = U32.unpack_from(payload, off)
        off += U32.size
        outputs.append(node)

    image = WavefrontImage(
        source_xpu_sha256=source_sha,
        schedule=tuple(schedule),
        ingress=tuple(ingress),
        outputs=tuple(outputs),
        input_count=input_count,
        period_last=period_last,
        target_profile=target,
    )
    validate_image(image)
    return image


def execute_wavefront(image: WavefrontImage, inputs, exp_table, ln_table):
    """Replay the static schedule with no ready queue/walker."""
    validate_image(image)
    inputs = tuple(int(x) for x in inputs)
    if len(inputs) != image.input_count:
        raise ValueError(f"expected {image.input_count} inputs, got {len(inputs)}")

    ingress_by_phase: dict[int, list[IngressEntry]] = {}
    schedule_by_phase: dict[int, list[ScheduleEntry]] = {}
    for e in image.ingress:
        ingress_by_phase.setdefault(e.phase, []).append(e)
    for e in image.schedule:
        schedule_by_phase.setdefault(e.phase, []).append(e)

    operands: dict[int, list[int | None]] = {e.node: [None, None] for e in image.schedule}
    values: dict[int, int] = {}
    available_phase: dict[int, int] = {}

    for phase in range(image.period_last + 1):
        for e in ingress_by_phase.get(phase, ()): 
            if e.source_kind == SRC_INPUT:
                if not 0 <= e.argument < len(inputs):
                    raise WavefrontFormatError("input binding out of range")
                value = inputs[e.argument]
            elif e.source_kind == SRC_CONST:
                value = e.argument
            else:
                if e.argument not in values:
                    raise WavefrontFormatError(
                        f"phase {phase}: producer {e.argument} value not available"
                    )
                if available_phase[e.argument] > phase:
                    raise WavefrontFormatError(
                        f"phase {phase}: producer {e.argument} violates fixed latency"
                    )
                value = values[e.argument]
            if operands[e.consumer][e.slot] is not None:
                raise WavefrontFormatError("duplicate operand in static epoch")
            operands[e.consumer][e.slot] = value

        for e in schedule_by_phase.get(phase, ()): 
            a, b = operands[e.node]
            if a is None or b is None:
                raise WavefrontFormatError(
                    f"phase {phase}: scheduled node {e.node} missing operand"
                )
            y = eml_lut(a, b, exp_table, ln_table)
            values[e.node] = y
            available_phase[e.node] = phase + 1
            operands[e.node] = [None, None]

    missing = [n for n in image.outputs if n not in values]
    if missing:
        raise WavefrontFormatError(f"missing outputs: {missing}")
    return tuple(values[n] for n in image.outputs)


def self_test(generated="hardware/rtl/generated", out_path=None):
    exp_t = load_memh(Path(generated) / "exp_q16.memh")
    ln_t = load_memh(Path(generated) / "ln_q16.memh")
    graph = demo_graph()
    xpu_blob = pack_graph(graph)
    image = lower_graph(graph, xpu_blob)
    blob = pack_image(image)
    decoded = unpack_image(blob)
    out = execute_wavefront(decoded, (q("0.25"), q("1.5")), exp_t, ln_t)
    assert out == (57577, 157774)
    assert decoded.source_xpu_sha256 == hashlib.sha256(xpu_blob).digest()

    # Demo schedule should be node3 at phase1 and node4 at phase3.
    assert [(e.node, e.phase) for e in decoded.schedule] == [(3, 1), (4, 3)]

    damaged = bytearray(blob)
    damaged[HEADER.size + 2] ^= 0x01
    try:
        unpack_image(bytes(damaged))
    except WavefrontFormatError:
        pass
    else:
        raise AssertionError("tampered XPUW accepted")

    if out_path:
        Path(out_path).write_bytes(blob)
    print(
        "XPU_V23_WAVEFRONT_PASS "
        f"bytes={len(blob)} period_last={decoded.period_last} "
        f"schedule={len(decoded.schedule)} ingress={len(decoded.ingress)} outputs={out}"
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--generated", default="hardware/rtl/generated")
    ap.add_argument("--out")
    args = ap.parse_args()
    self_test(args.generated, args.out)
