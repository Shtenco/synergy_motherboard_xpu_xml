#!/usr/bin/env python3
"""XPU Device ABI V2.2 host reference model.

Models object-ID capabilities, reset generations, bounded XPUR submission and
completion semantics without raw host addresses. This is the executable oracle
for a later QEMU PCI device and FPGA control plane.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct
from pathlib import Path

from eml_q16 import q
from eml_lut_model import DomainError, load_memh
from xpu_graph import demo_graph, pack_graph
from xpur_image import (
    RoutedFormatError,
    execute_routed,
    lower_graph,
    pack_image,
    unpack_image,
)

RIGHT_READ = 1 << 0
RIGHT_WRITE = 1 << 1

STATUS_OK = 0
STATUS_BAD_DESCRIPTOR = 1
STATUS_STALE_GENERATION = 2
STATUS_OBJECT_NOT_FOUND = 3
STATUS_CAPABILITY_DENIED = 4
STATUS_IMAGE_BOUNDS = 5
STATUS_XPUR_INVALID = 6
STATUS_PROFILE_MISMATCH = 7
STATUS_INPUT_COUNT_MISMATCH = 8
STATUS_OUTPUT_COUNT_MISMATCH = 9
STATUS_EXEC_DOMAIN = 10
STATUS_EXEC_DEADLOCK = 11
STATUS_OUTPUT_BOUNDS = 12
STATUS_INTERNAL_FAULT = 13

TARGET_PROFILE_V22_SINGLE_TILE = 1
MAX_IMAGE = 2 * 1024 * 1024
MAX_SCALARS = 65536

SUBMIT = struct.Struct("<QIIQIIQIIQII")      # 64 bytes
COMPLETION = struct.Struct("<QIIQQQQQII")   # 64 bytes
I32 = struct.Struct("<i")


@dataclass
class ObjectEntry:
    data: bytearray
    rights: int
    generation: int


@dataclass(frozen=True)
class Submit:
    image_object: int
    image_offset: int
    image_length: int
    input_object: int
    input_count: int
    flags: int
    output_object: int
    output_count: int
    target_profile: int
    user_cookie: int
    reset_generation: int
    capability_manifest_id: int = 0

    def pack(self) -> bytes:
        return SUBMIT.pack(
            self.image_object,
            self.image_offset,
            self.image_length,
            self.input_object,
            self.input_count,
            self.flags,
            self.output_object,
            self.output_count,
            self.target_profile,
            self.user_cookie,
            self.reset_generation,
            self.capability_manifest_id,
        )

    @staticmethod
    def unpack(blob: bytes) -> "Submit":
        if len(blob) != SUBMIT.size:
            raise ValueError("submission must be exactly 64 bytes")
        return Submit(*SUBMIT.unpack(blob))


@dataclass(frozen=True)
class Completion:
    user_cookie: int
    status: int
    reset_generation: int
    cycles: int = 0
    eml_ops: int = 0
    route_tokens: int = 0
    local_tokens: int = 0
    remote_tokens: int = 0
    bank_stalls: int = 0
    fault_code: int = 0

    def pack(self) -> bytes:
        return COMPLETION.pack(
            self.user_cookie,
            self.status,
            self.reset_generation,
            self.cycles,
            self.eml_ops,
            self.route_tokens,
            self.local_tokens,
            self.remote_tokens,
            self.bank_stalls,
            self.fault_code,
        )


class XPUDeviceModel:
    def __init__(self, exp_table, ln_table):
        self.exp_table = exp_table
        self.ln_table = ln_table
        self.reset_generation = 1
        self.objects: dict[int, ObjectEntry] = {}

    def install_object(self, object_id: int, payload: bytes | bytearray, rights: int) -> None:
        if object_id <= 0:
            raise ValueError("object id zero is reserved")
        if rights & ~(RIGHT_READ | RIGHT_WRITE):
            raise ValueError("unknown rights")
        self.objects[object_id] = ObjectEntry(
            bytearray(payload), rights, self.reset_generation
        )

    def reset(self) -> None:
        self.objects.clear()
        self.reset_generation = (self.reset_generation + 1) & 0xFFFFFFFF
        if self.reset_generation == 0:
            self.reset_generation = 1

    def _completion(self, sub: Submit, status: int, **kwargs) -> Completion:
        return Completion(
            user_cookie=sub.user_cookie,
            status=status,
            reset_generation=self.reset_generation,
            fault_code=status if status != STATUS_OK else 0,
            **kwargs,
        )

    def _get_object(self, object_id: int, right: int):
        obj = self.objects.get(object_id)
        if obj is None:
            return None, STATUS_OBJECT_NOT_FOUND
        if obj.generation != self.reset_generation:
            return None, STATUS_STALE_GENERATION
        if not (obj.rights & right):
            return None, STATUS_CAPABILITY_DENIED
        return obj, STATUS_OK

    def submit_blob(self, descriptor: bytes) -> Completion:
        try:
            sub = Submit.unpack(descriptor)
        except (ValueError, struct.error):
            dummy = Submit(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, self.reset_generation, 0)
            return self._completion(dummy, STATUS_BAD_DESCRIPTOR)
        return self.submit(sub)

    def submit(self, sub: Submit) -> Completion:
        # Frozen V2.2 validation order.
        if sub.flags != 0 or sub.capability_manifest_id != 0:
            return self._completion(sub, STATUS_BAD_DESCRIPTOR)
        if sub.reset_generation != self.reset_generation:
            return self._completion(sub, STATUS_STALE_GENERATION)
        if sub.target_profile != TARGET_PROFILE_V22_SINGLE_TILE:
            return self._completion(sub, STATUS_PROFILE_MISMATCH)
        if sub.image_length == 0 or sub.image_length > MAX_IMAGE:
            return self._completion(sub, STATUS_IMAGE_BOUNDS)
        if sub.input_count > MAX_SCALARS or sub.output_count > MAX_SCALARS:
            return self._completion(sub, STATUS_BAD_DESCRIPTOR)

        image_obj, status = self._get_object(sub.image_object, RIGHT_READ)
        if status:
            return self._completion(sub, status)
        input_obj, status = self._get_object(sub.input_object, RIGHT_READ)
        if status:
            return self._completion(sub, status)
        output_obj, status = self._get_object(sub.output_object, RIGHT_WRITE)
        if status:
            return self._completion(sub, status)

        assert image_obj and input_obj and output_obj
        end = sub.image_offset + sub.image_length
        if end < sub.image_offset or end > len(image_obj.data):
            return self._completion(sub, STATUS_IMAGE_BOUNDS)
        if sub.input_count * I32.size > len(input_obj.data):
            return self._completion(sub, STATUS_INPUT_COUNT_MISMATCH)
        if sub.output_count * I32.size > len(output_obj.data):
            return self._completion(sub, STATUS_OUTPUT_BOUNDS)

        xpur_blob = bytes(image_obj.data[sub.image_offset:end])
        try:
            image = unpack_image(xpur_blob)
        except RoutedFormatError:
            return self._completion(sub, STATUS_XPUR_INVALID)

        if image.target_profile != sub.target_profile:
            return self._completion(sub, STATUS_PROFILE_MISMATCH)
        if image.input_count != sub.input_count:
            return self._completion(sub, STATUS_INPUT_COUNT_MISMATCH)
        if len(image.outputs) != sub.output_count:
            return self._completion(sub, STATUS_OUTPUT_COUNT_MISMATCH)

        inputs = tuple(
            I32.unpack_from(input_obj.data, i * I32.size)[0]
            for i in range(sub.input_count)
        )
        try:
            outputs = execute_routed(image, inputs, self.exp_table, self.ln_table)
        except DomainError:
            return self._completion(sub, STATUS_EXEC_DOMAIN)
        except RoutedFormatError:
            return self._completion(sub, STATUS_EXEC_DEADLOCK)
        except Exception:
            return self._completion(sub, STATUS_INTERNAL_FAULT)

        # Commit outputs only after structural and execution success.
        packed = b"".join(I32.pack(x) for x in outputs)
        output_obj.data[: len(packed)] = packed
        return self._completion(
            sub,
            STATUS_OK,
            cycles=0,
            eml_ops=len(image.exec_nodes),
            route_tokens=len(image.routes),
            local_tokens=len(image.routes),
            remote_tokens=0,
            bank_stalls=0,
        )


def self_test(generated="hardware/rtl/generated") -> None:
    assert SUBMIT.size == 64
    assert COMPLETION.size == 64

    exp_t = load_memh(Path(generated) / "exp_q16.memh")
    ln_t = load_memh(Path(generated) / "ln_q16.memh")

    graph = demo_graph()
    xpu_blob = pack_graph(graph)
    image = lower_graph(graph, xpu_blob)
    xpur_blob = pack_image(image)

    dev = XPUDeviceModel(exp_t, ln_t)
    dev.install_object(1, xpur_blob, RIGHT_READ)
    dev.install_object(2, I32.pack(q("0.25")) + I32.pack(q("1.5")), RIGHT_READ)
    dev.install_object(3, bytes(8), RIGHT_WRITE)

    sub = Submit(
        image_object=1,
        image_offset=0,
        image_length=len(xpur_blob),
        input_object=2,
        input_count=2,
        flags=0,
        output_object=3,
        output_count=2,
        target_profile=TARGET_PROFILE_V22_SINGLE_TILE,
        user_cookie=0x58505522,
        reset_generation=dev.reset_generation,
    )
    completion = dev.submit_blob(sub.pack())
    assert completion.status == STATUS_OK
    out0 = I32.unpack_from(dev.objects[3].data, 0)[0]
    out1 = I32.unpack_from(dev.objects[3].data, 4)[0]
    assert (out0, out1) == (57577, 157774)
    assert completion.eml_ops == 2 and completion.route_tokens == 1

    # Tamper image after installation: XPUR hash validation must catch it and
    # output bytes must remain unchanged.
    before = bytes(dev.objects[3].data)
    dev.objects[1].data[70] ^= 0x01
    bad = dev.submit(sub)
    assert bad.status == STATUS_XPUR_INVALID
    assert bytes(dev.objects[3].data) == before

    # Restore through a fresh object install, capture an old descriptor, reset,
    # and verify stale generation wins before any reused object id is trusted.
    old_sub = sub
    dev.reset()
    dev.install_object(1, xpur_blob, RIGHT_READ)
    dev.install_object(2, I32.pack(q("0.25")) + I32.pack(q("1.5")), RIGHT_READ)
    dev.install_object(3, bytes(8), RIGHT_WRITE)
    stale = dev.submit(old_sub)
    assert stale.status == STATUS_STALE_GENERATION

    fresh_sub = Submit(**{**old_sub.__dict__, "reset_generation": dev.reset_generation})
    denied_dev = XPUDeviceModel(exp_t, ln_t)
    denied_dev.reset_generation = dev.reset_generation
    denied_dev.install_object(1, xpur_blob, RIGHT_READ)
    denied_dev.install_object(2, I32.pack(q("0.25")) + I32.pack(q("1.5")), RIGHT_READ)
    denied_dev.install_object(3, bytes(8), RIGHT_READ)  # no WRITE
    denied = denied_dev.submit(fresh_sub)
    assert denied.status == STATUS_CAPABILITY_DENIED

    fresh = dev.submit(fresh_sub)
    assert fresh.status == STATUS_OK

    print(
        "XPU_V22_DEVICE_MODEL_PASS "
        f"submit_bytes={SUBMIT.size} completion_bytes={COMPLETION.size} "
        f"generation={dev.reset_generation} outputs={out0},{out1} "
        f"eml_ops={completion.eml_ops} routes={completion.route_tokens}"
    )


if __name__ == "__main__":
    self_test()
