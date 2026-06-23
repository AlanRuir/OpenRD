#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${OPENRD_REPO_DIR:-/home/ubuntu/OpenRD}
SERVICE_SRC="$REPO_DIR/infra/systemd/openrd-video-latency-sidecar.service"
SERVICE_DST=/etc/systemd/system/openrd-video-latency-sidecar.service
ENV_DIR="$REPO_DIR/tools/video_latency/run"
ENV_FILE="$ENV_DIR/openrd-video-latency-sidecar.env"

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "missing service file: $SERVICE_SRC" >&2
  exit 1
fi

mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Optional local overrides for openrd-video-latency-sidecar.
# OPENRD_VIDEO_LATENCY_INPUT=rtsp://127.0.0.1/live/openrd
# OPENRD_VIDEO_LATENCY_STATUS_FILE=/tmp/openrd-video-latency.json
EOF
fi

chmod +x "$REPO_DIR/tools/video_latency/openrd_video_latency_sidecar.py"
sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
sudo systemctl daemon-reload
sudo systemctl enable openrd-video-latency-sidecar.service
echo "installed $SERVICE_DST"
echo "start with: sudo systemctl start openrd-video-latency-sidecar.service"
