#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)

RTP_PATH=${RTP_PATH:-live-rtp}
RTSP_URL=${RTSP_URL:-rtsp://127.0.0.1:8554/${RTP_PATH}}
PUBLIC_RTSP_URL=${PUBLIC_RTSP_URL:-rtsp://$(hostname -I | awk '{print $1}'):8554/${RTP_PATH}}
RTP_HOST=${RTP_HOST:-127.0.0.1}
RTP_PORT=${RTP_PORT:-5004}
RTP_PAYLOAD_TYPE=${RTP_PAYLOAD_TYPE:-96}
RTP_MTU=${RTP_MTU:-1200}

OPENRD_MEDIAMTX_ENABLE_LEGACY_RTP_PATH=true \
  OPENRD_MEDIAMTX_LEGACY_RTP_PATH="$RTP_PATH" \
  "$SCRIPT_DIR/configure_openrd_mediamtx.sh" >/dev/null
"$SCRIPT_DIR/install_openrd_video_service.sh" >/dev/null

sudo systemctl stop openrd-video-native.service >/dev/null 2>&1 || true
pkill -TERM -f '[g]st-launch-1.0' >/dev/null 2>&1 || true
sleep 1

cd "$PROJECT_DIR/vehicle/native_video"

echo "--- MediaMTX status ---"
systemctl is-active mediamtx.service || true

echo "--- RTP pipeline ---"
./openrd-video-native pipeline \
  --mode rtp \
  --rtsp-url "$RTSP_URL" \
  --rtp-host "$RTP_HOST" \
  --rtp-port "$RTP_PORT" \
  --rtp-pt "$RTP_PAYLOAD_TYPE" \
  --rtp-mtu "$RTP_MTU"

echo "--- Start RTP publisher ---"
./openrd-video-native start \
  --mode rtp \
  --rtsp-url "$RTSP_URL" \
  --rtp-host "$RTP_HOST" \
  --rtp-port "$RTP_PORT" \
  --rtp-pt "$RTP_PAYLOAD_TYPE" \
  --rtp-mtu "$RTP_MTU"

cleanup() {
  ./openrd-video-native stop >/dev/null 2>&1 || true
  sudo systemctl stop openrd-video-native.service >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 5

echo "--- Native status ---"
./openrd-video-native status --json

echo "--- ffprobe playback ---"
if command -v ffprobe >/dev/null 2>&1; then
  timeout 10 ffprobe -hide_banner -loglevel error -rtsp_transport tcp \
    -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate \
    -of default=noprint_wrappers=1 "$RTSP_URL"
else
  echo "ffprobe not found; open this URL from VLC/ffplay/browser-side client instead: $PUBLIC_RTSP_URL"
fi

echo "--- MediaMTX recent log ---"
journalctl -u mediamtx.service --no-pager -n 40 || true

echo "--- Playback URL ---"
echo "$PUBLIC_RTSP_URL"
