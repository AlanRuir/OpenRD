#!/usr/bin/env bash
set -euo pipefail

CHROOT=${CHROOT:-/opt/openrd/jammy-ros2}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$SCRIPT_DIR/mount_openrd_chroot.sh"

sudo rm -f "$CHROOT/tmp/publish_drive.py"
sudo dd of="$CHROOT/tmp/publish_drive.py" status=none <<'PY'
import time
import rclpy
from openrd_msgs.msg import DriveCommand

rclpy.init()
node = rclpy.create_node("openrd_test_drive_publisher")
publisher = node.create_publisher(DriveCommand, "/openrd/drive_cmd", 1)
time.sleep(0.5)
for index in range(40):
    message = DriveCommand()
    message.seq = 42 + index
    message.stamp = node.get_clock().now().to_msg()
    message.throttle = 0.3
    message.steering = 0.1
    message.brake = 0.0
    message.enable = True
    message.estop = False
    message.source = "test_cli"
    publisher.publish(message)
    rclpy.spin_once(node, timeout_sec=0.0)
    time.sleep(0.05)
node.destroy_node()
rclpy.shutdown()
PY
sudo chown 1000:1000 "$CHROOT/tmp/publish_drive.py"

sudo chroot --userspec=1000:1000 "$CHROOT" /bin/bash -c '
set -e
export HOME=/tmp/openrd-build-home
export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
source /opt/ros/humble/setup.bash
cd /workspace/OpenRD/vehicle/ros2_ws
source install/setup.bash
ros2 daemon stop >/dev/null 2>&1 || true
rm -f /tmp/openrd_launch.log /tmp/openrd_esp32.log
setsid ros2 launch openrd_bringup openrd_vehicle.launch.py > /tmp/openrd_launch.log 2>&1 &
LAUNCH_PID=$!
cleanup() {
  kill -INT -- "-$LAUNCH_PID" 2>/dev/null || true
  sleep 1
  kill -TERM -- "-$LAUNCH_PID" 2>/dev/null || true
  wait $LAUNCH_PID 2>/dev/null || true
  ros2 daemon stop >/dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 4
(timeout 6 ros2 topic echo /openrd/esp32_state --no-daemon > /tmp/openrd_esp32.log 2>&1 || true) &
ECHO_PID=$!
sleep 1
python3 /tmp/publish_drive.py
wait $ECHO_PID 2>/dev/null || true

echo "--- ESP32 dry-run state lines ---"
grep -A7 -B1 DRIVE /tmp/openrd_esp32.log | head -80 || cat /tmp/openrd_esp32.log | head -80

echo "--- launch log tail ---"
tail -n 40 /tmp/openrd_launch.log
'
