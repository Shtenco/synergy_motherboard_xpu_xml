#!/usr/bin/env python3
"""XPU V2.2 placed+routed image compiler and reference executor.

`.xpu` remains the portable semantic graph. `.xpur` is the target-fabric
lowering artifact for the STATIC_ROUTED fast path.

V2.2 proof restrictions:
- EML is the only executable arithmetic node;
- INPUT/CONST sources lower into initial operand-token descriptors;
- direct EML producer fanout must be <= 2;
- all executable nodes are placed on tile 0;
- binary EML nodes use operand slots A=0/B=1.
"""
from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
import hashlib
from pathlib import Path
import struct
from typing import Iterable

from xpu_graph import (
    Graph,
    Node,
    OP_INPUT,
    OP_CONST_Q16,
    OP_EML,
    NUMERIC_PROFILE_EML_Q16_LUT_V2,
    demo_graph,
    execute_graph,
    pack_graph,
    unpack_graph,
)
from eml_q16 import q
from eml_lut_model import eml_lut, load_memh

MAGIC = b"XPUR"
VERSION = 1
TARGET_PROFILE_V22_SINGLE_TILE = 1
DIGEST_BYTES = 32

# 64-byte header.
HEADER = struct.Struct("<4sHHIIIII32sI")
# node_id, opcode, tile, flags
EXEC = struct.Struct("<IBBH")                    # 8 bytes
# kind, slot, reserved, consumer, argument, reserved2
INIT = struct.Struct("<BBHIiI")                 # 16 bytes
# producer, consumer, slot, target_tile, flags, reserved
ROUTE = struct.Struct("<IIBBHI")                # 16 bytes
U32 = struct.Struct("<I")

INIT_INPUT = 1
INIT_CONST = 2


class RoutedFormatError(ValueError):
    pass


@dataclass(frozen=True)
class ExecNode:
    node_id: int
    opcode: int
    tile: int = 0
    flags: int = 0


@dataclass(frozen=True)
class InitialToken:
    kind: int
    consumer: int
    slot: int
    argument: int  # INPUT: input slot; CONST: raw signed Q16.16


@dataclass(frozen=True)
class Route:
    producer: int
    consumer: int
    slot: int
    target_tile: int = 0
    flags: int = 0


@dataclass(frozen=True)
class RoutedImage:
    source_xpu_sha256: bytes
    exec_nodes: tuple[ExecNode, ...]
    initial_tokens: tuple[InitialToken, ...]
    routes: tuple[Route, ...]
    outputs: tuple[int, ...]
    input_count: int
    target_profile: int = TARGET_PROFILE_V22_SINGLE_TILE


def _consumers(graph: Graph):
    out = [[] for _ in graph.nodes]
    for dst, node in enumerate(graph.nodes):
        if node.opcode == OP_EML:
            out[node.arg0].append((dst, 0))
            out[node.arg1].append((dst, 1))
    return out


def lower_graph(graph: Graph, source_blob: bytes) -> RoutedImage:
    consumers = _consumers(graph)
    exec_nodes: list[ExecNode] = []
    initial: list[InitialToken] = []
    routes: list[Route] = []

    for node_id, node in enumerate(graph.nodes):
        if node.opcode == OP_EML:
            exec_nodes.append(ExecNode(node_id=node_id, opcode=OP_EML))
            direct = consumers[node_id]
            if len(direct) > 2:
                raise RoutedFormatError(
                    f"node {node_id}: direct EML fanout {len(direct)} exceeds V2.2 limit 2"
                )
            for consumer, slot in direct:
                routes.append(Route(node_id, consumer, slot))
        elif node.opcode == OP_INPUT:
            for consumer, slot in consumers[node_id]:
                initial.append(InitialToken(INIT_INPUT, consumer, slot, node.arg0))
        elif node.opcode == OP_CONST_Q16:
            for consumer, slot in consumers[node_id]:
                initial.append(InitialToken(INIT_CONST, consumer, slot, node.arg0))
        else:
            raise RoutedFormatError(f"node {node_id}: unsupported opcode {node.opcode}")

    exec_ids = {x.node_id for x in exec_nodes}
    for out in graph.outputs:
        if out not in exec_ids:
            raise RoutedFormatError(
                f"output node {out} is not an EML execution node in V2.2 fast path"
            )

    return RoutedImage(
        source_xpu_sha256=hashlib.sha256(source_blob).digest(),
        exec_nodes=tuple(exec_nodes),
        initial_tokens=tuple(initial),
        routes=tuple(routes),
        outputs=graph.outputs,
        input_count=graph.input_count,
    )


def validate_image(image: RoutedImage) -> None:
    if len(image.source_xpu_sha256) != 32:
        raise RoutedFormatError("source SHA-256 must be 32 bytes")
    if image.target_profile != TARGET_PROFILE_V22_SINGLE_TILE:
        raise RoutedFormatError("unsupported target profile")
    if not image.exec_nodes:
        raise RoutedFormatError("no executable nodes")
    exec_ids = [x.node_id for x in image.exec_nodes]
    if len(exec_ids) != len(set(exec_ids)):
        raise RoutedFormatError("duplicate executable node")
    exec_set = set(exec_ids)

    fanout = {n: 0 for n in exec_ids}
    for route in image.routes:
        if route.producer not in exec_set or route.consumer not in exec_set:
            raise RoutedFormatError("route endpoint not executable")
        if route.slot not in (0, 1):
            raise RoutedFormatError("route slot must be A/B")
        if route.target_tile != 0:
            raise RoutedFormatError("single-tile profile requires tile 0")
        fanout[route.producer] += 1
    if any(v > 2 for v in fanout.values()):
        raise RoutedFormatError("direct fanout exceeds two")

    for token in image.initial_tokens:
        if token.kind not in (INIT_INPUT, INIT_CONST):
            raise RoutedFormatError("bad initial token kind")
        if token.consumer not in exec_set or token.slot not in (0, 1):
            raise RoutedFormatError("bad initial token destination")
        if token.kind == INIT_INPUT and not 0 <= token.argument < image.input_count:
            raise RoutedFormatError("input binding out of range")

    for out in image.outputs:
        if out not in exec_set:
            raise RoutedFormatError("output not executable")


def pack_image(image: RoutedImage) -> bytes:
    validate_image(image)
    body = bytearray(
        HEADER.pack(
            MAGIC,
            VERSION,
            NUMERIC_PROFILE_EML_Q16_LUT_V2,
            image.target_profile,
            len(image.exec_nodes),
            len(image.initial_tokens),
            len(image.routes),
            len(image.outputs),
            image.source_xpu_sha256,
            image.input_count,
        )
    )
    for n in image.exec_nodes:
        body += EXEC.pack(n.node_id, n.opcode, n.tile, n.flags)
    for t in image.initial_tokens:
        body += INIT.pack(t.kind, t.slot, 0, t.consumer, t.argument, 0)
    for r in image.routes:
        body += ROUTE.pack(r.producer, r.consumer, r.slot, r.target_tile, r.flags, 0)
    for out in image.outputs:
        body += U32.pack(out)
    body += hashlib.sha256(body).digest()
    return bytes(body)


def unpack_image(blob: bytes) -> RoutedImage:
    if len(blob) < HEADER.size + DIGEST_BYTES:
        raise RoutedFormatError("truncated routed image")
    payload, digest = blob[:-DIGEST_BYTES], blob[-DIGEST_BYTES:]
    if hashlib.sha256(payload).digest() != digest:
        raise RoutedFormatError("XPUR SHA-256 mismatch")

    (
        magic,
        version,
        numeric_profile,
        target_profile,
        exec_count,
        init_count,
        route_count,
        output_count,
        source_sha,
        input_count,
    ) = HEADER.unpack_from(payload, 0)

    if magic != MAGIC or version != VERSION:
        raise RoutedFormatError("unsupported XPUR magic/version")
    if numeric_profile != NUMERIC_PROFILE_EML_Q16_LUT_V2:
        raise RoutedFormatError("numeric profile mismatch")

    expected = (
        HEADER.size
        + exec_count * EXEC.size
        + init_count * INIT.size
        + route_count * ROUTE.size
        + output_count * U32.size
    )
    if len(payload) != expected:
        raise RoutedFormatError("XPUR length/header mismatch")

    off = HEADER.size
    exec_nodes = []
    for _ in range(exec_count):
        node_id, opcode, tile, flags = EXEC.unpack_from(payload, off)
        off += EXEC.size
        exec_nodes.append(ExecNode(node_id, opcode, tile, flags))

    initial = []
    for _ in range(init_count):
        kind, slot, reserved, consumer, argument, reserved2 = INIT.unpack_from(payload, off)
        off += INIT.size
        if reserved or reserved2:
            raise RoutedFormatError("initial-token reserved field nonzero")
        initial.append(InitialToken(kind, consumer, slot, argument))

    routes = []
    for _ in range(route_count):
        producer, consumer, slot, tile, flags, reserved = ROUTE.unpack_from(payload, off)
        off += ROUTE.size
        if reserved:
            raise RoutedFormatError("route reserved field nonzero")
        routes.append(Route(producer, consumer, slot, tile, flags))

    outputs = []
    for _ in range(output_count):
        (node_id,) = U32.unpack_from(payload, off)
        off += U32.size
        outputs.append(node_id)

    image = RoutedImage(
        source_xpu_sha256=source_sha,
        exec_nodes=tuple(exec_nodes),
        initial_tokens=tuple(initial),
        routes=tuple(routes),
        outputs=tuple(outputs),
        input_count=input_count,
        target_profile=target_profile,
    )
    validate_image(image)
    return image


def execute_routed(image: RoutedImage, inputs: Iterable[int], exp_table, ln_table):
    """Functional routed-token executor; ignores cycle/bank timing."""
    validate_image(image)
    inputs = tuple(int(x) for x in inputs)
    if len(inputs) != image.input_count:
        raise ValueError(f"expected {image.input_count} inputs, got {len(inputs)}")

    routes: dict[int, list[Route]] = {n.node_id: [] for n in image.exec_nodes}
    for r in image.routes:
        routes[r.producer].append(r)

    operands: dict[int, list[int | None]] = {
        n.node_id: [None, None] for n in image.exec_nodes
    }
    ready = deque()
    enqueued: set[int] = set()
    values: dict[int, int] = {}

    def deliver(node: int, slot: int, value: int):
        pair = operands[node]
        if pair[slot] is not None:
            raise RoutedFormatError(f"duplicate operand token for node {node} slot {slot}")
        pair[slot] = int(value)
        if pair[0] is not None and pair[1] is not None and node not in enqueued:
            ready.append(node)
            enqueued.add(node)

    for t in image.initial_tokens:
        value = inputs[t.argument] if t.kind == INIT_INPUT else t.argument
        deliver(t.consumer, t.slot, value)

    while ready:
        node = ready.popleft()
        a, b = operands[node]
        assert a is not None and b is not None
        y = eml_lut(a, b, exp_table, ln_table)
        values[node] = y
        for route in routes[node]:
            deliver(route.consumer, route.slot, y)

    missing = [n.node_id for n in image.exec_nodes if n.node_id not in values]
    if missing:
        raise RoutedFormatError(f"routed execution deadlocked/missing nodes: {missing[:8]}")
    return tuple(values[n] for n in image.outputs)


def lower_blob(xpu_blob: bytes) -> bytes:
    graph = unpack_graph(xpu_blob)
    image = lower_graph(graph, xpu_blob)
    return pack_image(image)


def self_test(generated="hardware/rtl/generated", xpur_out=None, xpu_out=None):
    exp_t = load_memh(Path(generated) / "exp_q16.memh")
    ln_t = load_memh(Path(generated) / "ln_q16.memh")

    graph = demo_graph()
    xpu_blob = pack_graph(graph)
    semantic = execute_graph(graph, (q("0.25"), q("1.5")), exp_t, ln_t)

    image = lower_graph(graph, xpu_blob)
    xpur_blob = pack_image(image)
    decoded = unpack_image(xpur_blob)
    routed = execute_routed(decoded, (q("0.25"), q("1.5")), exp_t, ln_t)
    assert routed == semantic == (57577, 157774)
    assert decoded.source_xpu_sha256 == hashlib.sha256(xpu_blob).digest()

    damaged = bytearray(xpur_blob)
    damaged[HEADER.size + 1] ^= 0x80
    try:
        unpack_image(bytes(damaged))
    except RoutedFormatError:
        pass
    else:
        raise AssertionError("tampered XPUR image accepted")

    if xpur_out:
        Path(xpur_out).write_bytes(xpur_blob)
    if xpu_out:
        Path(xpu_out).write_bytes(xpu_blob)

    print(
        "XPU_V22_XPUR_PASS "
        f"xpu_bytes={len(xpu_blob)} xpur_bytes={len(xpur_blob)} "
        f"exec={len(image.exec_nodes)} initial={len(image.initial_tokens)} "
        f"routes={len(image.routes)} outputs={routed} "
        f"source_sha256={hashlib.sha256(xpu_blob).hexdigest()}"
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--generated", default="hardware/rtl/generated")
    ap.add_argument("--xpur-out")
    ap.add_argument("--xpu-out")
    args = ap.parse_args()
    self_test(args.generated, args.xpur_out, args.xpu_out)
