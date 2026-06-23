#!/usr/bin/env python3
"""CLI for OpenRD H.264 SEI latency metadata."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from openrd_sei import (
    OPENRD_SEI_UUID_TEXT,
    extract_openrd_h264_samples,
    inject_openrd_sei_into_h264_annexb,
    source_id_hash,
)


def _read_all(path: str) -> bytes:
    return Path(path).read_bytes()


def _write_all(path: str, data: bytes) -> None:
    Path(path).write_bytes(data)


def inspect_h264(args: argparse.Namespace) -> int:
    data = _read_all(args.input)
    now_realtime_ns = time.time_ns() if args.latency else None
    samples = extract_openrd_h264_samples(data)
    payload = {
        "ok": True,
        "codec": "h264",
        "sei_uuid": OPENRD_SEI_UUID_TEXT,
        "sample_count": len(samples),
        "samples": [
            {
                "nal_index": sample.nal_index,
                **sample.payload.to_dict(now_realtime_ns=now_realtime_ns),
            }
            for sample in samples[: args.limit]
        ],
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return 0

    print(f"OpenRD SEI UUID: {OPENRD_SEI_UUID_TEXT}")
    print(f"samples: {len(samples)}")
    for sample in samples[: args.limit]:
        data = sample.payload.to_dict(now_realtime_ns=now_realtime_ns)
        latency = data.get("video_latency_ms")
        suffix = f" latency={latency}ms" if latency is not None else ""
        print(
            "nal={nal} seq={seq} realtime_ns={realtime} monotonic_ns={monotonic}"
            " source_hash={source}{suffix}".format(
                nal=sample.nal_index,
                seq=data["frame_seq"],
                realtime=data["capture_realtime_ns"],
                monotonic=data["capture_monotonic_ns"],
                source=data["source_id_hash"],
                suffix=suffix,
            )
        )
    return 0


def inject_h264(args: argparse.Namespace) -> int:
    source_hash = args.source_hash
    if args.source_id:
        source_hash = source_id_hash(args.source_id)
    data = _read_all(args.input)
    output, injected = inject_openrd_sei_into_h264_annexb(
        data,
        start_seq=args.start_seq,
        fps=args.fps,
        source_hash=source_hash,
        idr_only=args.idr_only,
        base_realtime_ns=args.base_realtime_ns,
        base_monotonic_ns=args.base_monotonic_ns,
    )
    _write_all(args.output, output)
    print(
        json.dumps(
            {
                "ok": True,
                "codec": "h264",
                "sei_uuid": OPENRD_SEI_UUID_TEXT,
                "input": args.input,
                "output": args.output,
                "injected": injected,
                "source_id_hash": source_hash,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenRD H.264 SEI tools")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser(
        "inspect-h264",
        help="parse OpenRD SEI payloads from a H.264 Annex-B stream",
    )
    inspect_parser.add_argument("input", help="input .h264 Annex-B stream")
    inspect_parser.add_argument("--json", action="store_true", help="emit JSON")
    inspect_parser.add_argument(
        "--latency",
        action="store_true",
        help="compute now_realtime_ns - capture_realtime_ns",
    )
    inspect_parser.add_argument(
        "--limit",
        type=int,
        default=20,
        help="maximum samples to print/include",
    )
    inspect_parser.set_defaults(func=inspect_h264)

    inject_parser = subparsers.add_parser(
        "inject-h264",
        help="insert OpenRD SEI before H.264 VCL NALs in an Annex-B stream",
    )
    inject_parser.add_argument("input", help="input .h264 Annex-B stream")
    inject_parser.add_argument("output", help="output .h264 Annex-B stream")
    inject_parser.add_argument("--fps", type=float, default=30.0)
    inject_parser.add_argument("--start-seq", type=int, default=0)
    inject_parser.add_argument("--source-id", default="")
    inject_parser.add_argument("--source-hash", type=int, default=0)
    inject_parser.add_argument("--idr-only", action="store_true")
    inject_parser.add_argument("--base-realtime-ns", type=int)
    inject_parser.add_argument("--base-monotonic-ns", type=int)
    inject_parser.set_defaults(func=inject_h264)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
