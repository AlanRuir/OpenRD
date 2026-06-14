#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=${PROJECT_DIR:-/home/linaro/OpenRD}
CHROOT=${CHROOT:-/opt/openrd/jammy-ros2}
SERVICE_SRC="$PROJECT_DIR/infra/systemd/openrd-video-native.service"
SERVICE_DST=/etc/systemd/system/openrd-video-native.service
SUDOERS_SRC="$PROJECT_DIR/infra/sudoers/90-openrd-video"
SUDOERS_DST=/etc/sudoers.d/90-openrd-video
CHROOT_SUDOERS_DST="$CHROOT/etc/sudoers.d/90-openrd-video"
ENV_FILE="$PROJECT_DIR/vehicle/native_video/run/openrd-video-native-service.env"
UDEV_RULES_SRC="$PROJECT_DIR/infra/udev/99-openrd-cameras.rules"
UDEV_RULES_DST=/etc/udev/rules.d/99-openrd-cameras.rules

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "service file not found: $SERVICE_SRC" >&2
  exit 1
fi

if [[ ! -f "$SUDOERS_SRC" ]]; then
  echo "sudoers file not found: $SUDOERS_SRC" >&2
  exit 1
fi

if [[ ! -f "$UDEV_RULES_SRC" ]]; then
  echo "udev rules file not found: $UDEV_RULES_SRC" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/vehicle/native_video/run"
cat > "$ENV_FILE" <<'EOF'
OPENRD_VIDEO_MODE=rtsp
OPENRD_VIDEO_DEVICE=/dev/openrd-cam-uvc
OPENRD_VIDEO_INPUT_FORMAT=mjpg
OPENRD_VIDEO_WIDTH=1280
OPENRD_VIDEO_HEIGHT=720
OPENRD_VIDEO_FPS=30
OPENRD_VIDEO_BITRATE=2000000
OPENRD_VIDEO_GOP=30
OPENRD_VIDEO_OUTPUT=/tmp/openrd_camera_test.h264
OPENRD_VIDEO_RTSP_URL=rtsp://127.0.0.1:8554/live
OPENRD_VIDEO_RTSP_PROTOCOLS=tcp
OPENRD_VIDEO_RTSP_LATENCY_MS=100
OPENRD_VIDEO_MPEGTS_HOST=127.0.0.1
OPENRD_VIDEO_MPEGTS_PORT=5004
OPENRD_VIDEO_RTP_HOST=127.0.0.1
OPENRD_VIDEO_RTP_PORT=5004
OPENRD_VIDEO_RTP_PAYLOAD_TYPE=96
OPENRD_VIDEO_RTP_MTU=1200
OPENRD_VIDEO_HEALTHCHECK_INTERVAL_SEC=5
OPENRD_VIDEO_HEALTHCHECK_FAILURES=0
OPENRD_VIDEO_HEALTHCHECK_STARTUP_GRACE_SEC=10
OPENRD_VIDEO_RTSP_HEALTHCHECK_TIMEOUT_SEC=8
OPENRD_VIDEO_HLS_HEALTHCHECK_URL=
OPENRD_VIDEO_RESTART_DELAY_SEC=2
OPENRD_VIDEO_MAX_HEALTH_RESTARTS=1
OPENRD_VIDEO_RKAIQ_SERVICE=rkaiq_3A.service
OPENRD_VIDEO_RKAIQ_RESTART_AFTER_HEALTH_RESTARTS=1
OPENRD_VIDEO_MAX_RKAIQ_RESTARTS=1
OPENRD_VIDEO_RKAIQ_RESTART_DELAY_SEC=3
OPENRD_VIDEO_FAULT_EXIT_CODE=42
OPENRD_VIDEO_STATE_DIR=/home/linaro/OpenRD/vehicle/native_video/run
OPENRD_VIDEO_LOG=/home/linaro/OpenRD/vehicle/native_video/run/openrd-video-native.log
EOF

sudo install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
sudo install -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"
sudo install -m 0644 "$UDEV_RULES_SRC" "$UDEV_RULES_DST"
sudo visudo -cf "$SUDOERS_DST"
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux || true

if [[ -d "$CHROOT/etc" ]]; then
  if ! sudo grep -q '^linaro:' "$CHROOT/etc/group"; then
    echo 'linaro:x:1000:' | sudo tee -a "$CHROOT/etc/group" >/dev/null
  fi

  if ! sudo grep -q '^linaro:' "$CHROOT/etc/passwd"; then
    echo 'linaro:x:1000:1000:OpenRD user:/home/linaro:/bin/bash' | sudo tee -a "$CHROOT/etc/passwd" >/dev/null
  fi

  if [[ -f "$CHROOT/etc/shadow" ]] && ! sudo grep -q '^linaro:' "$CHROOT/etc/shadow"; then
    echo 'linaro:*:20000:0:99999:7:::' | sudo tee -a "$CHROOT/etc/shadow" >/dev/null
    sudo chown root:42 "$CHROOT/etc/shadow" || true
    sudo chmod 0640 "$CHROOT/etc/shadow"
  fi

  if [[ -f "$CHROOT/etc/hosts" ]] && ! sudo grep -q 'ATK-DLRK3588' "$CHROOT/etc/hosts"; then
    echo '127.0.1.1 ATK-DLRK3588' | sudo tee -a "$CHROOT/etc/hosts" >/dev/null
  fi

  sudo mkdir -p "$CHROOT/home/linaro" "$CHROOT/etc/sudoers.d"
  sudo chown 1000:1000 "$CHROOT/home/linaro"
  sudo install -m 0440 "$SUDOERS_SRC" "$CHROOT_SUDOERS_DST"
  sudo visudo -cf "$CHROOT_SUDOERS_DST"
fi

sudo systemctl daemon-reload
sudo systemctl reset-failed openrd-video-native.service >/dev/null 2>&1 || true

chmod +x "$PROJECT_DIR/vehicle/native_video/openrd-video-native"
chmod +x "$PROJECT_DIR/vehicle/native_video/openrd-video-systemd"

echo "OpenRD native video service installed: $SERVICE_DST"
echo "OpenRD camera udev rules installed: $UDEV_RULES_DST"
if [[ -d "$CHROOT/etc" ]]; then
  echo "OpenRD chroot sudoers installed: $CHROOT_SUDOERS_DST"
fi
echo "Try: sudo systemctl enable --now openrd-video-native.service"
