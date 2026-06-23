#!/usr/bin/env python3
"""OpenRD video latency sidecar.

The sidecar expects a H.264 Annex-B byte stream on stdin or from ffmpeg stdout,
parses OpenRD SEI payloads, and writes the latest latency statistics to a JSON
status file.  It intentionally keeps dependencies to the Python standard
library; live RTSP/HTTP-FLV input is delegated to an installed ffmpeg binary.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from collections import deque
from pathlib import Path
from typing import BinaryIO

from openrd_sei import (
    AnnexBStreamParser,
    h264_nal_type,
    iter_openrd_payloads_from_h264_sei_nal,
)


def percentile(values: list[float], fraction: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1))
    return int(round(ordered[index]))


class StatusWriter:
    def __init__(self, path: str, vehicle_id: str) -> None:
        self.path = Path(path)
        self.vehicle_id = vehicle_id
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, payload: dict[str, object]) -> None:
        body = {
            "ok": True,
            "vehicle_id": self.vehicle_id,
            "updated_ms": int(time.time() * 1000),
            **payload,
        }
        data = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            suffix=".tmp",
            dir=str(self.path.parent),
            text=True,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(data)
            handle.write("\n")
        os.replace(tmp_name, self.path)


class LatencyAggregator:
    def __init__(self, writer: StatusWriter, window_size: int) -> None:
        self.writer = writer
        self.latencies: deque[float] = deque(maxlen=window_size)
        self.last_frame_seq = 0
        self.last_sample_ms = 0

    def add_sample(self, frame_seq: int, capture_realtime_ns: int) -> None:
        now_realtime_ns = time.time_ns()
        latency_ms = (now_realtime_ns - capture_realtime_ns) / 1_000_000
        self.latencies.append(latency_ms)
        self.last_frame_seq = frame_seq
        self.last_sample_ms = int(time.time() * 1000)
        values = list(self.latencies)
        self.writer.write(
            {
                "video_latency_state": "ok",
                "video_latency_ms": int(round(latency_ms)),
                "video_latency_avg_ms": int(round(sum(values) / len(values))),
                "video_latency_p50_ms": percentile(values, 0.50),
                "video_latency_p95_ms": percentile(values, 0.95),
                "video_frame_seq": frame_seq,
                "video_latency_updated_ms": self.last_sample_ms,
            }
        )


def ffmpeg_h264_stdout(input_url: str, ffmpeg_bin: str) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [
            ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            input_url,
            "-map",
            "0:v:0",
            "-an",
            "-c:v",
            "copy",
            "-bsf:v",
            "h264_mp4toannexb",
            "-f",
            "h264",
            "-",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def read_stream(
    stream: BinaryIO,
    aggregator: LatencyAggregator,
    writer: StatusWriter,
    *,
    stale_sec: float,
    once: bool,
) -> int:
    parser = AnnexBStreamParser()
    nal_count = 0
    sei_count = 0
    last_state_ms = 0
    writer.write({"video_latency_state": "no_sei"})

    while True:
        chunk = stream.read(64 * 1024)
        if not chunk:
            break
        for nal_unit in parser.feed(chunk):
            nal_count += 1
            if h264_nal_type(nal_unit) != 6:
                continue
            for payload in iter_openrd_payloads_from_h264_sei_nal(nal_unit):
                sei_count += 1
                aggregator.add_sample(payload.frame_seq, payload.capture_realtime_ns)
                if once:
                    return 0

        now_ms = int(time.time() * 1000)
        stale_ms = int(stale_sec * 1000)
        if (
            aggregator.last_sample_ms > 0
            and now_ms - aggregator.last_sample_ms > stale_ms
            and now_ms - last_state_ms > 1000
        ):
            writer.write(
                {
                    "video_latency_state": "stale",
                    "video_frame_seq": aggregator.last_frame_seq,
                    "video_latency_updated_ms": aggregator.last_sample_ms,
                }
            )
            last_state_ms = now_ms
        elif sei_count == 0 and nal_count >= 120 and now_ms - last_state_ms > 1000:
            writer.write({"video_latency_state": "no_sei"})
            last_state_ms = now_ms

    for nal_unit in parser.flush():
        if h264_nal_type(nal_unit) != 6:
            continue
        for payload in iter_openrd_payloads_from_h264_sei_nal(nal_unit):
            sei_count += 1
            aggregator.add_sample(payload.frame_seq, payload.capture_realtime_ns)
            if once:
                return 0
    return 0 if sei_count > 0 else 2


def run(args: argparse.Namespace) -> int:
    writer = StatusWriter(args.status_file, args.vehicle_id)
    aggregator = LatencyAggregator(writer, args.window_size)

    if args.stdin:
        return read_stream(
            sys.stdin.buffer,
            aggregator,
            writer,
            stale_sec=args.stale_sec,
            once=args.once,
        )

    process = ffmpeg_h264_stdout(args.input, args.ffmpeg)
    assert process.stdout is not None
    try:
        code = read_stream(
            process.stdout,
            aggregator,
            writer,
            stale_sec=args.stale_sec,
            once=args.once,
        )
        if args.once:
            process.terminate()
        process.wait(timeout=5)
        if code == 2:
            writer.write({"video_latency_state": "no_sei"})
        elif process.returncode not in {0, None}:
            writer.write(
                {
                    "video_latency_state": "no_stream",
                    "last_error": f"ffmpeg exited {process.returncode}",
                }
            )
            return process.returncode or 1
        return code
    except KeyboardInterrupt:
        process.terminate()
        return 0
    except Exception as exc:  # noqa: BLE001 - sidecar must publish failure state.
        writer.write({"video_latency_state": "error", "last_error": str(exc)})
        process.terminate()
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OpenRD video latency sidecar")
    parser.add_argument(
        "--input",
        default="rtsp://127.0.0.1/live/openrd",
        help="RTSP/HTTP-FLV/RTMP input URL for ffmpeg",
    )
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="read H.264 Annex-B from stdin instead of launching ffmpeg",
    )
    parser.add_argument(
        "--status-file",
        default=os.environ.get(
            "OPENRD_VIDEO_LATENCY_STATUS_FILE",
            "/tmp/openrd-video-latency.json",
        ),
    )
    parser.add_argument("--vehicle-id", default="openrd-001")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--window-size", type=int, default=120)
    parser.add_argument("--stale-sec", type=float, default=3.0)
    parser.add_argument("--once", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.window_size < 1:
        print("error: --window-size must be positive", file=sys.stderr)
        return 2
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
