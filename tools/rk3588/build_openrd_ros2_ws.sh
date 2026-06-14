#!/usr/bin/env bash
set -euo pipefail

CHROOT=${CHROOT:-/opt/openrd/jammy-ros2}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$SCRIPT_DIR/mount_openrd_chroot.sh"

sudo chroot --userspec=1000:1000 "$CHROOT" /bin/bash -c '
set -e
export HOME=/tmp/openrd-build-home
export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
source /opt/ros/humble/setup.bash
cd /workspace/OpenRD/vehicle/ros2_ws
colcon build --symlink-install --parallel-workers 2
'