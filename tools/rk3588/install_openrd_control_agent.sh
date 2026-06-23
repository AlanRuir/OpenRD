#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${OPENRD_REPO_DIR:-/home/linaro/OpenRD}
SERVICE_SRC="$REPO_DIR/infra/systemd/openrd-control-agent.service"
SERVICE_DST=/etc/systemd/system/openrd-control-agent.service
ENV_DIR="$REPO_DIR/vehicle/control_agent/run"
ENV_FILE="$ENV_DIR/openrd-control-agent.env"

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "missing service file: $SERVICE_SRC" >&2
  exit 1
fi

mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Optional local overrides for openrd-control-agent.
# OPENRD_DRIVE_AGENT_TOKEN=
# OPENRD_DRIVE_AGENT_CLOUD_URL=http://43.139.25.165:8790
# OPENRD_DRIVE_AGENT_VEHICLE_ID=openrd-001
# OPENRD_DRIVE_AGENT_DRIVER_URL=http://192.168.100.114
# OPENRD_DRIVE_AGENT_MAX_SPEED=300
# OPENRD_DRIVE_AGENT_COMMAND_TIMEOUT_SEC=0.35
# OPENRD_DRIVE_AGENT_POLL_WAIT_SEC=0.12
EOF
fi

chmod +x "$REPO_DIR/vehicle/control_agent/openrd-control-agent"
sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
sudo systemctl daemon-reload
sudo systemctl enable openrd-control-agent.service
echo "installed $SERVICE_DST"
echo "start with: sudo systemctl start openrd-control-agent.service"
