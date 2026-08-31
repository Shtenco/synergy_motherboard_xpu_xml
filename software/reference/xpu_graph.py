#!/usr/bin/env python3
"""XPU V2 fixed-record graph binary + reference executor.

The binary is intentionally tiny and deterministic so the exact same object can
be consumed by software, QEMU and FPGA-facing tooling.
"""
from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from eml_q16 import q
from eml_lut_model import DomainError, eml_lut, load_memh

MAGIC = b"XPU2"
VERSION = 2
NUMERIC_PROFILE_EML_Q16_LUT_V2 = 1
NODE_BYTES = 16

OP_INPUT = 1
OP_CONST_Q16 = 2
OP_EML = 3

HEADER = struct.Struct("<4sHHIIIIII")   # 32 bytes
NODE = struct.Struct("<BBHiiI")         # 16 bytes
U32 = struct.Struct("<I")
DIGEST_BYTES = 32


@dataclass(frozen=True)
class Node:
    opcode: int
    arg0: int = 0
    arg1: int = 0
    flags: int = 0
    aux: int = 0


@dataclass(frozen=True)
class Graph:
    nodes: tuple[Node, ...]
    input_count: int
    outputs: tuple[int, ...]


class GraphFormatError(ValueError):
    pass


def validate_graph(graph: Graph) -> None:
    n = len(graph.nodes)
    if n == 0:
        raise GraphFormatError("graph must contain at least one node")
    if graph.input_count < 0:
        raise GraphFormatError("negative input count")
    if not graph.outputs:
        raise GraphFormatError("at least one output is required")
    for out in graph.outputs:
        if out < 0 or out >= n:
            raise GraphFormatError("output node out of range")

    for i, node in enumerate(graph.nodes):
        if node.opcode == OP_INPUT:
            if not 0 <= node.arg0 < graph.input_count:
                raise GraphFormatError(f"input slot out of range at node {i}")
        elif node.opcode == OP_CONST_Q16:
            if not -(1 << 31) <= node.arg0 <= (1 << 31) - 1:
                raise GraphFormatError(f"constant outside i32 at node {i}")
        elif node.opcode == OP_EML:
            # V2 graph binary is topologically ordered: both sources must
            # already exist. This removes runtime cycle detection.
            if not (0 <= node.arg0 < i and 0 <= node.arg1 < i):
                raise GraphFormatError(f"non-topological EML sources at node {i}")
        else:
            raise GraphFormatError(f"unknown opcode {node.opcode} at node {i}")


def pack_graph(graph: Graph) -> bytes:
    validate_graph(graph)
    header = HEADER.pack(
        MAGIC,
        VERSION,
        NUMERIC_PROFILE_EML_Q16_LUT_V2,
        len(graph.nodes),
        graph.input_count,
        len(graph.outputs),
        0,                  # flags
        NODE_BYTES,
        0,                  # reserved
    )
    body = bytearray(header)
    for node in graph.nodes:
        body += NODE.pack(
            node.opcode & 0xff,
            node.flags & 0xff,
            0,
            int(node.arg0),
            int(node.arg1),
            node.aux & 0xffffffff,
        )
    for out in graph.outputs:
        body += U32.pack(out)
    body += hashlib.sha256(body).digest()
    return bytes(body)


def unpack_graph(blob: bytes) -> Graph:
    if len(blob) < HEADER.size + DIGEST_BYTES:
        raise GraphFormatError("truncated graph")

    payload, digest = blob[:-DIGEST_BYTES], blob[-DIGEST_BYTES:]
    if hashlib.sha256(payload).digest() != digest:
        raise GraphFormatError("graph SHA-256 mismatch")

    magic, version, profile, node_count, input_count, output_count, flags, node_bytes, reserved = HEADER.unpack_from(payload, 0)
    if magic != MAGIC:
        raise GraphFormatError("bad magic")
    if version != VERSION:
        raise GraphFormatError("unsupported graph version")
    if profile != NUMERIC_PROFILE_EML_Q16_LUT_V2:
        raise GraphFormatError("unsupported numeric profile")
    if node_bytes != NODE_BYTES:
        raise GraphFormatError("unexpected node record size")
    if flags != 0 or reserved != 0:
        raise GraphFormatError("unsupported header flags/reserved")

    expected = HEADER.size + node_count * NODE_BYTES + output_count * U32.size
    if len(payload) != expected:
        raise GraphFormatError("graph length/header mismatch")

    nodes = []
    off = HEADER.size
    for _ in range(node_count):
        opcode, nflags, rsv, arg0, arg1, aux = NODE.unpack_from(payload, off)
        off += NODE_BYTES
        if rsv != 0:
            raise GraphFormatError("node reserved field must be zero")
        nodes.append(Node(opcode, arg0, arg1, nflags, aux))

    outputs = []
    for _ in range(output_count):
        (idx,) = U32.unpack_from(payload, off)
        off += U32.size
        outputs.append(idx)

    graph = Graph(tuple(nodes), input_count, tuple(outputs))
    validate_graph(graph)
    return graph


def execute_graph(graph: Graph, inputs: Iterable[int], exp_table, ln_table) -> tuple[int, ...]:
    validate_graph(graph)
    inputs = tuple(int(x) for x in inputs)
    if len(inputs) != graph.input_count:
        raise ValueError(f"expected {graph.input_count} inputs, got {len(inputs)}")

    values = [0] * len(graph.nodes)
    for i, node in enumerate(graph.nodes):
        if node.opcode == OP_INPUT:
            values[i] = inputs[node.arg0]
        elif node.opcode == OP_CONST_Q16:
            values[i] = node.arg0
        elif node.opcode == OP_EML:
            try:
                values[i] = eml_lut(values[node.arg0], values[node.arg1], exp_table, ln_table)
            except DomainError as exc:
                raise DomainError(f"node {i}: EML domain violation") from exc
        else:
            raise AssertionError("validated opcode became invalid")

    return tuple(values[i] for i in graph.outputs)


def demo_graph() -> Graph:
    # y0 = EML(x, b)
    # y1 = EML(y0, 1)
    return Graph(
        nodes=(
            Node(OP_INPUT, 0),
            Node(OP_INPUT, 1),
            Node(OP_CONST_Q16, q("1")),
            Node(OP_EML, 0, 1),
            Node(OP_EML, 3, 2),
        ),
        input_count=2,
        outputs=(3, 4),
    )


def self_test(generated_dir="hardware/rtl/generated", out_path=None):
    exp_t = load_memh(Path(generated_dir) / "exp_q16.memh")
    ln_t = load_memh(Path(generated_dir) / "ln_q16.memh")

    g = demo_graph()
    blob = pack_graph(g)
    decoded = unpack_graph(blob)
    assert decoded == g

    # Inputs keep intermediate y0 inside the next lane's a-domain.
    out = execute_graph(decoded, (q("0.25"), q("1.5")), exp_t, ln_t)
    assert out[0] == 57577
    assert out[1] == 157774

    tampered = bytearray(blob)
    tampered[HEADER.size + 3] ^= 0x01
    try:
        unpack_graph(bytes(tampered))
    except GraphFormatError:
        pass
    else:
        raise AssertionError("tampered graph was accepted")

    if out_path:
        Path(out_path).write_bytes(blob)
    print(f"XPU_V2_GRAPH_PASS bytes={len(blob)} sha256={hashlib.sha256(blob).hexdigest()} outputs={out}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--generated", default="hardware/rtl/generated")
    ap.add_argument("--out")
    args = ap.parse_args()
    self_test(args.generated, args.out)
