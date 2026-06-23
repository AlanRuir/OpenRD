#!/usr/bin/env python3
"""OpenRD H.264 SEI helpers for video latency measurement.

The first implementation target is H.264 Annex-B because the current OpenRD
public video path publishes H.264 through RTMP/ZLMediaKit.  The helpers here do
not decode video; they only add and parse `user_data_unregistered` SEI payloads.
"""

from __future__ import annotations

import struct
import time
import uuid
import zlib
from dataclasses import dataclass
from typing import Iterable


OPENRD_SEI_MAGIC = b"OPENRDSE"
OPENRD_SEI_VERSION = 1
OPENRD_SEI_UUID = uuid.UUID("4f70656e-5244-5345-492d-6c6174656e63").bytes
OPENRD_SEI_UUID_TEXT = str(uuid.UUID(bytes=OPENRD_SEI_UUID))
CODEC_H264 = 1
CODEC_H265 = 2
TIMEBASE_NS = 1
H264_NAL_TYPE_SEI = 6
H264_NAL_TYPE_IDR = 5
H264_VCL_NAL_TYPES = {1, 5}
ANNEXB_START_CODE = b"\x00\x00\x00\x01"

_OPENRD_PAYLOAD_STRUCT = struct.Struct("<8sBBHHBBQQQII")
OPENRD_PAYLOAD_SIZE = _OPENRD_PAYLOAD_STRUCT.size


class OpenRdSeiError(ValueError):
    """Raised when an OpenRD SEI payload is malformed."""


@dataclass(frozen=True)
class OpenRdSeiPayload:
    """Fixed OpenRD SEI payload, version 1."""

    frame_seq: int
    capture_realtime_ns: int
    capture_monotonic_ns: int
    source_id_hash: int = 0
    flags: int = 0
    codec: int = CODEC_H264
    timebase: int = TIMEBASE_NS
    reserved: int = 0

    def to_bytes(self) -> bytes:
        return _OPENRD_PAYLOAD_STRUCT.pack(
            OPENRD_SEI_MAGIC,
            OPENRD_SEI_VERSION,
            self.flags & 0xFF,
            OPENRD_PAYLOAD_SIZE,
            OPENRD_PAYLOAD_SIZE,
            self.codec & 0xFF,
            self.timebase & 0xFF,
            self.frame_seq & 0xFFFFFFFFFFFFFFFF,
            self.capture_realtime_ns & 0xFFFFFFFFFFFFFFFF,
            self.capture_monotonic_ns & 0xFFFFFFFFFFFFFFFF,
            self.source_id_hash & 0xFFFFFFFF,
            self.reserved & 0xFFFFFFFF,
        )

    @classmethod
    def from_bytes(cls, data: bytes) -> "OpenRdSeiPayload":
        if len(data) < OPENRD_PAYLOAD_SIZE:
            raise OpenRdSeiError(
                f"OpenRD SEI payload too short: {len(data)} < {OPENRD_PAYLOAD_SIZE}"
            )

        (
            magic,
            version,
            flags,
            header_size,
            payload_size,
            codec,
            timebase,
            frame_seq,
            capture_realtime_ns,
            capture_monotonic_ns,
            source_id_hash,
            reserved,
        ) = _OPENRD_PAYLOAD_STRUCT.unpack_from(data)

        if magic != OPENRD_SEI_MAGIC:
            raise OpenRdSeiError("OpenRD SEI magic mismatch")
        if version != OPENRD_SEI_VERSION:
            raise OpenRdSeiError(f"unsupported OpenRD SEI version: {version}")
        if header_size != OPENRD_PAYLOAD_SIZE:
            raise OpenRdSeiError(f"unexpected OpenRD SEI header_size: {header_size}")
        if payload_size < OPENRD_PAYLOAD_SIZE or payload_size > len(data):
            raise OpenRdSeiError(f"invalid OpenRD SEI payload_size: {payload_size}")
        if codec not in {CODEC_H264, CODEC_H265}:
            raise OpenRdSeiError(f"unsupported OpenRD SEI codec: {codec}")
        if timebase != TIMEBASE_NS:
            raise OpenRdSeiError(f"unsupported OpenRD SEI timebase: {timebase}")

        return cls(
            frame_seq=frame_seq,
            capture_realtime_ns=capture_realtime_ns,
            capture_monotonic_ns=capture_monotonic_ns,
            source_id_hash=source_id_hash,
            flags=flags,
            codec=codec,
            timebase=timebase,
            reserved=reserved,
        )

    def to_dict(self, now_realtime_ns: int | None = None) -> dict[str, int | float]:
        payload: dict[str, int | float] = {
            "frame_seq": self.frame_seq,
            "capture_realtime_ns": self.capture_realtime_ns,
            "capture_monotonic_ns": self.capture_monotonic_ns,
            "source_id_hash": self.source_id_hash,
            "flags": self.flags,
            "codec": self.codec,
            "timebase": self.timebase,
        }
        if now_realtime_ns is not None and self.capture_realtime_ns > 0:
            payload["video_latency_ms"] = round(
                (now_realtime_ns - self.capture_realtime_ns) / 1_000_000,
                3,
            )
        return payload


@dataclass(frozen=True)
class OpenRdH264Sample:
    """Parsed OpenRD SEI sample and its source NAL index."""

    nal_index: int
    payload: OpenRdSeiPayload


def source_id_hash(source_id: str) -> int:
    """Return the stable uint32 source hash used in OpenRD SEI payloads."""

    return zlib.crc32(source_id.encode("utf-8")) & 0xFFFFFFFF


def h264_nal_type(nal_unit: bytes) -> int:
    if not nal_unit:
        return -1
    return nal_unit[0] & 0x1F


def rbsp_to_ebsp(rbsp: bytes) -> bytes:
    """Insert H.264 emulation-prevention bytes."""

    output = bytearray()
    zero_count = 0
    for value in rbsp:
        if zero_count >= 2 and value <= 0x03:
            output.append(0x03)
            zero_count = 0
        output.append(value)
        if value == 0:
            zero_count += 1
        else:
            zero_count = 0
    return bytes(output)


def ebsp_to_rbsp(ebsp: bytes) -> bytes:
    """Remove H.264 emulation-prevention bytes."""

    output = bytearray()
    zero_count = 0
    for index, value in enumerate(ebsp):
        if (
            zero_count >= 2
            and value == 0x03
            and index + 1 < len(ebsp)
            and ebsp[index + 1] <= 0x03
        ):
            continue
        output.append(value)
        if value == 0:
            zero_count += 1
        else:
            zero_count = 0
    return bytes(output)


def _encode_sei_value(value: int) -> bytes:
    if value < 0:
        raise ValueError("SEI type/size values must be non-negative")
    full_chunks, remainder = divmod(value, 0xFF)
    return (b"\xFF" * full_chunks) + bytes([remainder])


def build_h264_sei_nal_unit(
    payload: OpenRdSeiPayload,
    sei_uuid: bytes = OPENRD_SEI_UUID,
) -> bytes:
    """Build a raw H.264 SEI NAL unit without an Annex-B start code."""

    if len(sei_uuid) != 16:
        raise ValueError("H.264 user_data_unregistered UUID must be 16 bytes")
    user_payload = sei_uuid + payload.to_bytes()
    rbsp = _encode_sei_value(5) + _encode_sei_value(len(user_payload)) + user_payload
    rbsp += b"\x80"
    return bytes([H264_NAL_TYPE_SEI]) + rbsp_to_ebsp(rbsp)


def build_h264_sei_nal(
    payload: OpenRdSeiPayload,
    sei_uuid: bytes = OPENRD_SEI_UUID,
    start_code: bytes = ANNEXB_START_CODE,
) -> bytes:
    """Build an Annex-B H.264 SEI NAL."""

    return start_code + build_h264_sei_nal_unit(payload, sei_uuid=sei_uuid)


def iter_openrd_payloads_from_h264_sei_nal(
    nal_unit: bytes,
    sei_uuid: bytes = OPENRD_SEI_UUID,
) -> Iterable[OpenRdSeiPayload]:
    """Yield OpenRD payloads from one raw H.264 SEI NAL unit."""

    if h264_nal_type(nal_unit) != H264_NAL_TYPE_SEI:
        return

    rbsp = ebsp_to_rbsp(nal_unit[1:])
    offset = 0
    while offset < len(rbsp):
        if rbsp[offset] == 0x80:
            break

        payload_type = 0
        while offset < len(rbsp):
            value = rbsp[offset]
            offset += 1
            payload_type += value
            if value != 0xFF:
                break
        else:
            break

        payload_size = 0
        while offset < len(rbsp):
            value = rbsp[offset]
            offset += 1
            payload_size += value
            if value != 0xFF:
                break
        else:
            break

        if payload_size < 0 or offset + payload_size > len(rbsp):
            break

        payload = rbsp[offset : offset + payload_size]
        offset += payload_size
        if payload_type != 5 or len(payload) < 16:
            continue
        if payload[:16] != sei_uuid:
            continue
        try:
            yield OpenRdSeiPayload.from_bytes(payload[16:])
        except OpenRdSeiError:
            continue


def _iter_annexb_start_codes(data: bytes) -> Iterable[tuple[int, int]]:
    i = 0
    end = len(data)
    while i <= end - 3:
        if data[i : i + 3] == b"\x00\x00\x01":
            yield i, 3
            i += 3
            continue
        if i <= end - 4 and data[i : i + 4] == b"\x00\x00\x00\x01":
            yield i, 4
            i += 4
            continue
        i += 1


def iter_annexb_nal_units(data: bytes) -> Iterable[bytes]:
    """Yield raw H.264/H.265 NAL units from an Annex-B byte stream."""

    starts = list(_iter_annexb_start_codes(data))
    for index, (start, length) in enumerate(starts):
        nal_start = start + length
        nal_end = starts[index + 1][0] if index + 1 < len(starts) else len(data)
        nal_unit = data[nal_start:nal_end]
        if nal_unit:
            yield nal_unit


class AnnexBStreamParser:
    """Incremental Annex-B NAL parser for subprocess/stdin streams."""

    def __init__(self, max_buffer_bytes: int = 8 * 1024 * 1024) -> None:
        self._buffer = bytearray()
        self._max_buffer_bytes = max_buffer_bytes

    def feed(self, chunk: bytes) -> list[bytes]:
        self._buffer.extend(chunk)
        return self._drain(final=False)

    def flush(self) -> list[bytes]:
        return self._drain(final=True)

    def _drain(self, final: bool) -> list[bytes]:
        if not self._buffer:
            return []

        starts = list(_iter_annexb_start_codes(bytes(self._buffer)))
        if not starts:
            if len(self._buffer) > self._max_buffer_bytes:
                del self._buffer[: -4]
            return []

        if starts[0][0] > 0:
            del self._buffer[: starts[0][0]]
            starts = list(_iter_annexb_start_codes(bytes(self._buffer)))

        if len(starts) < 2 and not final:
            return []

        complete_count = len(starts) if final else len(starts) - 1
        nal_units: list[bytes] = []
        for index in range(complete_count):
            start, length = starts[index]
            nal_start = start + length
            nal_end = (
                starts[index + 1][0]
                if index + 1 < len(starts)
                else len(self._buffer)
            )
            nal_unit = bytes(self._buffer[nal_start:nal_end])
            if nal_unit:
                nal_units.append(nal_unit)

        if final:
            self._buffer.clear()
        else:
            keep_from = starts[-1][0]
            del self._buffer[:keep_from]

        return nal_units


def extract_openrd_h264_samples(data: bytes) -> list[OpenRdH264Sample]:
    samples: list[OpenRdH264Sample] = []
    for nal_index, nal_unit in enumerate(iter_annexb_nal_units(data)):
        if h264_nal_type(nal_unit) != H264_NAL_TYPE_SEI:
            continue
        for payload in iter_openrd_payloads_from_h264_sei_nal(nal_unit):
            samples.append(OpenRdH264Sample(nal_index=nal_index, payload=payload))
    return samples


def inject_openrd_sei_into_h264_annexb(
    data: bytes,
    *,
    start_seq: int = 0,
    fps: float = 30.0,
    source_hash: int = 0,
    idr_only: bool = False,
    base_realtime_ns: int | None = None,
    base_monotonic_ns: int | None = None,
) -> tuple[bytes, int]:
    """Insert OpenRD H.264 SEI NALs before VCL NALs in an Annex-B stream.

    This is a Phase-1 validation helper.  It assumes each VCL NAL corresponds to
    one frame, which is true for common low-latency single-slice encoder output.
    A future GStreamer/C++ sender should attach the exact V4L2 timestamp before
    each encoded access unit.
    """

    if fps <= 0:
        raise ValueError("fps must be positive")

    realtime_ns = time.time_ns() if base_realtime_ns is None else base_realtime_ns
    monotonic_ns = (
        time.monotonic_ns() if base_monotonic_ns is None else base_monotonic_ns
    )
    frame_interval_ns = int(1_000_000_000 / fps)
    frame_seq = start_seq
    injected = 0
    output = bytearray()

    for nal_unit in iter_annexb_nal_units(data):
        nal_type = h264_nal_type(nal_unit)
        should_inject = nal_type in H264_VCL_NAL_TYPES and (
            not idr_only or nal_type == H264_NAL_TYPE_IDR
        )
        if should_inject:
            payload = OpenRdSeiPayload(
                frame_seq=frame_seq,
                capture_realtime_ns=realtime_ns + injected * frame_interval_ns,
                capture_monotonic_ns=monotonic_ns + injected * frame_interval_ns,
                source_id_hash=source_hash,
            )
            output.extend(build_h264_sei_nal(payload))
            frame_seq += 1
            injected += 1
        output.extend(ANNEXB_START_CODE)
        output.extend(nal_unit)

    return bytes(output), injected
