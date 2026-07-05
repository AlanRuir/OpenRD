#!/usr/bin/env python3
"""Focused tests for OpenRD video latency SEI helpers."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

from openrd_sei import (
    ANNEXB_START_CODE,
    OPENRD_PAYLOAD_SIZE,
    OpenRdSeiPayload,
    build_h264_sei_nal_unit,
    extract_openrd_h264_samples,
    inject_openrd_sei_into_h264_annexb,
    iter_openrd_payloads_from_h264_sei_nal,
    source_id_hash,
)


TOOLS_DIR = Path(__file__).resolve().parent


class OpenRdSeiTests(unittest.TestCase):
    def test_payload_roundtrip(self) -> None:
        payload = OpenRdSeiPayload(
            frame_seq=42,
            capture_realtime_ns=1_780_000_000_000_000_000,
            capture_monotonic_ns=123_456_789,
            source_id_hash=source_id_hash("front"),
        )

        encoded = payload.to_bytes()
        decoded = OpenRdSeiPayload.from_bytes(encoded)

        self.assertEqual(len(encoded), OPENRD_PAYLOAD_SIZE)
        self.assertEqual(decoded, payload)

    def test_h264_sei_nal_roundtrip(self) -> None:
        payload = OpenRdSeiPayload(
            frame_seq=7,
            capture_realtime_ns=1000,
            capture_monotonic_ns=2000,
            source_id_hash=source_id_hash("openrd-test"),
        )

        nal_unit = build_h264_sei_nal_unit(payload)
        decoded = list(iter_openrd_payloads_from_h264_sei_nal(nal_unit))

        self.assertEqual(decoded, [payload])

    def test_extract_from_annexb_stream(self) -> None:
        payload = OpenRdSeiPayload(
            frame_seq=9,
            capture_realtime_ns=10_000,
            capture_monotonic_ns=20_000,
        )
        stream = ANNEXB_START_CODE + build_h264_sei_nal_unit(payload)
        stream += ANNEXB_START_CODE + bytes([0x65, 0x88, 0x84])

        samples = extract_openrd_h264_samples(stream)

        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0].payload.frame_seq, 9)

    def test_inject_before_h264_vcl_nals(self) -> None:
        stream = b"".join(
            [
                ANNEXB_START_CODE,
                bytes([0x67, 0x42, 0x00, 0x1F]),
                ANNEXB_START_CODE,
                bytes([0x68, 0xCE, 0x06]),
                ANNEXB_START_CODE,
                bytes([0x65, 0x88, 0x84]),
                ANNEXB_START_CODE,
                bytes([0x41, 0x9A, 0x22]),
            ]
        )

        output, injected = inject_openrd_sei_into_h264_annexb(
            stream,
            start_seq=100,
            fps=25,
            source_hash=source_id_hash("front"),
            base_realtime_ns=1_000_000_000,
            base_monotonic_ns=2_000_000_000,
        )
        samples = extract_openrd_h264_samples(output)

        self.assertEqual(injected, 2)
        self.assertEqual([sample.payload.frame_seq for sample in samples], [100, 101])
        self.assertEqual(samples[1].payload.capture_realtime_ns, 1_040_000_000)

    def test_live_filter_injects_openrd_sei(self) -> None:
        stream = b"".join(
            [
                ANNEXB_START_CODE,
                bytes([0x67, 0x42, 0x00, 0x1F]),
                ANNEXB_START_CODE,
                bytes([0x65, 0x88, 0x84]),
            ]
        )

        completed = subprocess.run(
            [
                sys.executable,
                str(TOOLS_DIR / "openrd_h264_sei_filter.py"),
                "--source-id",
                "openrd-test",
                "--stats-interval-sec",
                "0",
            ],
            input=stream,
            check=True,
            capture_output=True,
        )
        samples = extract_openrd_h264_samples(completed.stdout)

        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0].payload.frame_seq, 0)
        self.assertEqual(samples[0].payload.source_id_hash, source_id_hash("openrd-test"))
        self.assertIn(b"first_sei_injected_ms=", completed.stderr)


if __name__ == "__main__":
    unittest.main()
