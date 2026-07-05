#!/usr/bin/env python3
"""Live H.264 Annex-B SEI injector for OpenRD video latency.

This filter reads H.264 Annex-B bytes from stdin and writes H.264 Annex-B bytes
to stdout.  It inserts an OpenRD `user_data_unregistered` SEI NAL before each
VCL NAL using the local realtime/monotonic clock at the moment the encoded NAL
is observed.

In the current shell/GStreamer runtime this timestamp is encoder-output time,
not the original V4L2 buffer timestamp.  It is still useful for proving that SEI
survives RTMP/ZLMediaKit and for visualizing live media-path latency.  A future
GStreamer API runtime can replace this timestamp with the actual capture time.
"""

from __future__ import annotations

import argparse
import sys
import time
from typing import BinaryIO

from openrd_sei import (
    ANNEXB_START_CODE,
    H264_NAL_TYPE_IDR,
    H264_VCL_NAL_TYPES,
    AnnexBStreamParser,
    OpenRdSeiPayload,
    build_h264_sei_nal,
    h264_nal_type,
    source_id_hash,
)


def should_inject(nal_unit: bytes, *, idr_only: bool) -> bool:
    nal_type = h264_nal_type(nal_unit)
    if nal_type not in H264_VCL_NAL_TYPES:
        return False
    return not idr_only or nal_type == H264_NAL_TYPE_IDR


def write_nal_with_optional_sei(
    output: BinaryIO,
    nal_unit: bytes,
    *,
    frame_seq: int,
    source_hash: int,
    idr_only: bool,
) -> tuple[int, bool]:
    injected = should_inject(nal_unit, idr_only=idr_only)
    if injected:
        payload = OpenRdSeiPayload(
            frame_seq=frame_seq,
            capture_realtime_ns=time.time_ns(),
            capture_monotonic_ns=time.monotonic_ns(),
            source_id_hash=source_hash,
        )
        output.write(build_h264_sei_nal(payload))
        frame_seq += 1

    output.write(ANNEXB_START_CODE)
    output.write(nal_unit)
    output.flush()
    return frame_seq, injected


def run_filter(args: argparse.Namespace) -> int:
    parser = AnnexBStreamParser()
    frame_seq = args.start_seq
    source_hash = args.source_hash
    if args.source_id:
        source_hash = source_id_hash(args.source_id)

    nal_count = 0
    injected_count = 0
    last_stats_at = time.monotonic()
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer

    def note_injected() -> None:
        nonlocal injected_count
        injected_count += 1
        if injected_count == 1:
            print(
                "openrd-h264-sei-filter "
                f"first_sei_injected_ms={int(time.time() * 1000)} "
                f"frame_seq={frame_seq - 1} nal={nal_count}",
                file=sys.stderr,
                flush=True,
            )

    try:
        while True:
            chunk = input_stream.read(args.chunk_size)
            if not chunk:
                break

            for nal_unit in parser.feed(chunk):
                nal_count += 1
                frame_seq, injected = write_nal_with_optional_sei(
                    output_stream,
                    nal_unit,
                    frame_seq=frame_seq,
                    source_hash=source_hash,
                    idr_only=args.idr_only,
                )
                if injected:
                    note_injected()

            now = time.monotonic()
            if args.stats_interval_sec > 0 and now - last_stats_at >= args.stats_interval_sec:
                print(
                    f"openrd-h264-sei-filter nal={nal_count} injected={injected_count} "
                    f"next_seq={frame_seq}",
                    file=sys.stderr,
                    flush=True,
                )
                last_stats_at = now

        for nal_unit in parser.flush():
            nal_count += 1
            frame_seq, injected = write_nal_with_optional_sei(
                output_stream,
                nal_unit,
                frame_seq=frame_seq,
                source_hash=source_hash,
                idr_only=args.idr_only,
            )
            if injected:
                note_injected()
    except BrokenPipeError:
        return 0

    print(
        f"openrd-h264-sei-filter stopped nal={nal_count} injected={injected_count} "
        f"next_seq={frame_seq}",
        file=sys.stderr,
        flush=True,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenRD live H.264 SEI injector")
    parser.add_argument("--source-id", default="openrd-uvc")
    parser.add_argument("--source-hash", type=int, default=0)
    parser.add_argument("--start-seq", type=int, default=0)
    parser.add_argument("--idr-only", action="store_true")
    parser.add_argument("--chunk-size", type=int, default=64 * 1024)
    parser.add_argument("--stats-interval-sec", type=float, default=5.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.chunk_size <= 0:
        print("error: --chunk-size must be positive", file=sys.stderr)
        return 2
    return run_filter(args)


if __name__ == "__main__":
    raise SystemExit(main())
