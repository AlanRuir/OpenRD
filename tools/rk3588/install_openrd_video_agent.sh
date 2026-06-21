#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${OPENRD_REPO_DIR:-/home/linaro/OpenRD}
SERVICE_SRC="$REPO_DIR/infra/systemd/openrd-video-agent.service"
SERVICE_DST=/etc/systemd/system/openrd-video-agent.service
ENV_DIR="$REPO_DIR/vehicle/video_agent/run"
ENV_FILE="$ENV_DIR/openrd-video-agent.env"

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "missing service file: $SERVICE_SRC" >&2
  exit 1
fi

mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Optional local overrides for openrd-video-agent.
# OPENRD_VIDEO_AGENT_TOKEN=
# OPENRD_VIDEO_AGENT_CLOUD_URL=http://43.139.25.165:8790
# OPENRD_VIDEO_AGENT_VEHICLE_ID=openrd-001
# OPENRD_VIDEO_AGENT_LOCAL_LEASE_SEC=150
EOF
fi

chmod +x "$REPO_DIR/vehicle/video_agent/openrd-video-agent"
sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
sudo systemctl daemon-reload
sudo systemctl enable openrd-video-agent.service
echo "installed $SERVICE_DST"
echo "start with: sudo systemctl start openrd-video-agent.service"
