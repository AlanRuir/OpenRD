#!/usr/bin/env bash
set -euo pipefail

CHROOT=${CHROOT:-/opt/openrd/jammy-ros2}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$SCRIPT_DIR/install_openrd_video_service.sh" >/dev/null
"$SCRIPT_DIR/mount_openrd_chroot.sh" >/dev/null

sudo systemctl stop openrd-video-native.service >/dev/null 2>&1 || true

sudo chroot --userspec=1000:1000 "$CHROOT" /bin/bash -s <<'CHROOT_SCRIPT'
set -eo pipefail

export HOME=/tmp/openrd-build-home
export FASTDDS_BUILTIN_TRANSPORTS=UDPv4

source /opt/ros/humble/setup.bash
cd /workspace/OpenRD/vehicle/ros2_ws
source install/setup.bash
ros2 daemon stop >/dev/null 2>&1 || true

rm -f /tmp/openrd_video_launch.log /tmp/openrd_video_state.log \
  /tmp/openrd_video_start.log /tmp/openrd_video_stop.log

setsid ros2 launch openrd_bringup openrd_vehicle.launch.py \
  > /tmp/openrd_video_launch.log 2>&1 &
launch_pid=$!

cleanup() {
  kill -INT -- "-$launch_pid" 2>/dev/null || true
  sleep 1
  kill -TERM -- "-$launch_pid" 2>/dev/null || true
  wait "$launch_pid" 2>/dev/null || true
  ros2 daemon stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 30); do
  if ros2 service list --no-daemon | grep -q '^/openrd/start_runtime$'; then
    break
  fi
  sleep 0.5
done

echo '--- video_state before start ---' > /tmp/openrd_video_state.log
timeout 5 ros2 topic echo /openrd/video_state --once --no-daemon >> /tmp/openrd_video_state.log 2>&1 || true

ros2 service call /openrd/start_runtime std_srvs/srv/Trigger '{}' \
  > /tmp/openrd_video_start.log 2>&1 || true
sleep 4

echo '--- video_state after start ---' >> /tmp/openrd_video_state.log
timeout 5 ros2 topic echo /openrd/video_state --once --no-daemon >> /tmp/openrd_video_state.log 2>&1 || true

ros2 service call /openrd/stop_runtime std_srvs/srv/Trigger '{}' \
  > /tmp/openrd_video_stop.log 2>&1 || true
sleep 1

echo '--- video_state ---'
cat /tmp/openrd_video_state.log

echo '--- start service response ---'
cat /tmp/openrd_video_start.log

echo '--- stop service response ---'
cat /tmp/openrd_video_stop.log

echo '--- launch log tail ---'
tail -n 80 /tmp/openrd_video_launch.log
CHROOT_SCRIPT

sudo systemctl stop openrd-video-native.service >/dev/null 2>&1 || true
