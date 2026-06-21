#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=${OPENRD_REPO_DIR:-/home/ubuntu/OpenRD}
SERVICE_SRC="$REPO_DIR/infra/systemd/openrd-control.service"
SERVICE_DST=/etc/systemd/system/openrd-control.service
ENV_DIR="$REPO_DIR/server/openrd_control_service/run"
ENV_FILE="$ENV_DIR/openrd-control.env"

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "missing service file: $SERVICE_SRC" >&2
  exit 1
fi

mkdir -p "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Optional local overrides for openrd-control-service.
# OPENRD_CONTROL_VIEWER_TOKEN=
# OPENRD_CONTROL_AGENT_TOKEN=
# OPENRD_CONTROL_ALLOW_ORIGIN=*
# OPENRD_CONTROL_PORT=8790
# OPENRD_CONTROL_AGENT_TIMEOUT_SEC=45
EOF
fi

chmod +x "$REPO_DIR/server/openrd_control_service/openrd_control_service.py"
sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
sudo systemctl daemon-reload
sudo systemctl enable openrd-control.service
echo "installed $SERVICE_DST"
echo "start with: sudo systemctl start openrd-control.service"
