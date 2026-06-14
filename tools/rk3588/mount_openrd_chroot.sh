#!/usr/bin/env bash
set -euo pipefail

CHROOT=${CHROOT:-/opt/openrd/jammy-ros2}
HOST_PROJECT=${HOST_PROJECT:-/home/linaro/OpenRD}
CHROOT_PROJECT=${CHROOT_PROJECT:-$CHROOT/workspace/OpenRD}

for dir in dev dev/pts proc sys run workspace tmp; do
  sudo mkdir -p "$CHROOT/$dir"
done

mountpoint -q "$CHROOT/dev" || sudo mount --bind /dev "$CHROOT/dev"
mountpoint -q "$CHROOT/dev/pts" || sudo mount --bind /dev/pts "$CHROOT/dev/pts"
mountpoint -q "$CHROOT/proc" || sudo mount -t proc proc "$CHROOT/proc"
mountpoint -q "$CHROOT/sys" || sudo mount -t sysfs sys "$CHROOT/sys"
mountpoint -q "$CHROOT/run" || sudo mount --bind /run "$CHROOT/run"

sudo mkdir -p "$CHROOT_PROJECT"
mountpoint -q "$CHROOT_PROJECT" || sudo mount --bind "$HOST_PROJECT" "$CHROOT_PROJECT"

sudo chmod 1777 /dev/shm || true
sudo chmod 1777 "$CHROOT/tmp" || true
sudo mkdir -p "$CHROOT/tmp/openrd-build-home"
sudo chown 1000:1000 "$CHROOT/tmp/openrd-build-home"

sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" || true

echo "OpenRD chroot mounts are ready: $CHROOT"