#!/usr/bin/env bash
set -euo pipefail

RTSP_URL=${RTSP_URL:-rtsp://127.0.0.1:8554/live}
PUBLIC_RTSP_URL=${PUBLIC_RTSP_URL:-rtsp://$(hostname -I | awk '{print $1}'):8554/live}
PUBLIC_HLS_URL=${PUBLIC_HLS_URL:-http://$(hostname -I | awk '{print $1}'):8888/live/index.m3u8}
PUBLIC_WEBRTC_URL=${PUBLIC_WEBRTC_URL:-http://$(hostname -I | awk '{print $1}'):8889/live}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)

"$SCRIPT_DIR/configure_openrd_mediamtx.sh" >/dev/null
"$SCRIPT_DIR/install_openrd_video_service.sh" >/dev/null

sudo systemctl stop openrd-video-native.service >/dev/null 2>&1 || true
pkill -TERM -f '[g]st-launch-1.0' >/dev/null 2>&1 || true
sleep 1

cd "$PROJECT_DIR/vehicle/native_video"

echo "--- MediaMTX status ---"
systemctl is-active mediamtx.service || true

echo "--- RTSP pipeline ---"
./openrd-video-native pipeline --mode rtsp --rtsp-url "$RTSP_URL"

echo "--- Start RTSP publisher ---"
./openrd-video-native start --mode rtsp --rtsp-url "$RTSP_URL"
sleep 5
./openrd-video-native status --json

echo "--- ffprobe playback ---"
if command -v ffprobe >/dev/null 2>&1; then
  timeout 10 ffprobe -hide_banner -loglevel error -rtsp_transport tcp \
    -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate \
    -of default=noprint_wrappers=1 "$RTSP_URL" || true
else
  echo "ffprobe not found; open this URL from VLC/ffplay instead: $PUBLIC_RTSP_URL"
fi

echo "--- HLS playlist ---"
if command -v curl >/dev/null 2>&1; then
  curl -L -s -o /tmp/openrd-live.m3u8 -w 'http=%{http_code} bytes=%{size_download}\n' \
    --max-time 8 http://127.0.0.1:8888/live/index.m3u8
  head -n 8 /tmp/openrd-live.m3u8 || true
else
  echo "curl not found; open this URL from browser instead: $PUBLIC_HLS_URL"
fi

echo "--- MediaMTX recent log ---"
journalctl -u mediamtx.service --no-pager -n 30 || true

echo "--- Playback URL ---"
echo "$PUBLIC_RTSP_URL"
echo "$PUBLIC_HLS_URL"
echo "$PUBLIC_WEBRTC_URL"

echo "--- Stop publisher ---"
./openrd-video-native stop
