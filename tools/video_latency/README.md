# OpenRD Video Latency Tools

These tools implement the first code slice of `docs/10_video_latency_measurement.md`.
They focus on H.264 Annex-B SEI generation/parsing and a small sidecar status
writer.  They do not replace the current `openrd-video-native` GStreamer shell
runtime yet.

## What Is Implemented

- OpenRD SEI payload packing/parsing with UUID `4f70656e-5244-5345-492d-6c6174656e63`.
- H.264 `user_data_unregistered` SEI NAL generation.
- H.264 Annex-B file injection before VCL NALs for local validation.
- Live H.264 Annex-B `stdin -> stdout` SEI injection for `rtmp-sei` mode.
- H.264 Annex-B parsing and OpenRD SEI extraction.
- Optional sidecar that reads Annex-B from stdin or ffmpeg output and writes
  `/tmp/openrd-video-latency.json`.

## Local File Validation

Capture a short H.264 Annex-B file on the RK3588 host:

```bash
cd /home/linaro/OpenRD/vehicle/native_video
./openrd-video-native start --mode file --output /tmp/openrd-camera.h264
sleep 5
./openrd-video-native stop
```

Inject synthetic timestamps for parser validation:

```bash
cd /home/linaro/OpenRD
python3 tools/video_latency/openrd_video_sei.py inject-h264 \
  /tmp/openrd-camera.h264 /tmp/openrd-camera-sei.h264 \
  --fps 30 --source-id openrd-uvc
```

Inspect the result:

```bash
python3 tools/video_latency/openrd_video_sei.py inspect-h264 \
  /tmp/openrd-camera-sei.h264 --json --latency
```

This proves the payload format, H.264 SEI wrapping, and parser.  It does not
prove that the current RTMP/ZLMediaKit path preserves SEI; that is the next
integration test after sender-side live injection exists.

## Sidecar

For a live stream that already contains OpenRD SEI, run:

```bash
python3 tools/video_latency/openrd_video_latency_sidecar.py \
  --input rtsp://127.0.0.1/live/openrd \
  --status-file /tmp/openrd-video-latency.json
```

The sidecar requires `ffmpeg` for live URL input.  For tests, pipe Annex-B data
directly:

```bash
cat /tmp/openrd-camera-sei.h264 | \
  python3 tools/video_latency/openrd_video_latency_sidecar.py \
    --stdin --once --status-file /tmp/openrd-video-latency.json
```

The JSON status file is intended to be merged by `openrd-control-service` into:

```text
GET /api/vehicles/openrd-001/video/status
```

Install it as a Tencent Cloud systemd service:

```bash
cd /home/ubuntu/OpenRD
bash tools/video_latency/install_openrd_video_latency_sidecar.sh
sudo systemctl start openrd-video-latency-sidecar.service
systemctl status openrd-video-latency-sidecar.service --no-pager
```

Optional local overrides are written to:

```text
/home/ubuntu/OpenRD/tools/video_latency/run/openrd-video-latency-sidecar.env
```

## RK3588 Live Injection

`vehicle/native_video/openrd-video-native` supports an optional `rtmp-sei` mode:

```bash
cd /home/linaro/OpenRD/vehicle/native_video
./openrd-video-native run --mode rtmp-sei \
  --rtmp-url rtmp://43.139.25.165:1935/live/openrd
```

The live path is:

```text
GStreamer mpph264enc byte-stream
  -> tools/video_latency/openrd_h264_sei_filter.py
  -> ffmpeg -c:v copy -f flv
  -> ZLMediaKit RTMP
```

This mode timestamps the encoded H.264 VCL NAL when the filter sees it. It is
good enough to prove the live SEI path and show media relay latency in the UI,
but it does not yet include camera exposure, V4L2 buffering, or encoder latency.
