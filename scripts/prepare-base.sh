#!/bin/bash
# Runs on the build VM: docker up, aarch64 emulation registered, Photon's
# official Raspberry Pi 5.0 image downloaded and unpacked (once).
set -euo pipefail
W=/root/w-photon-img5
cd $W
systemctl is-active docker >/dev/null || systemctl start docker
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  docker run --privileged --rm tonistiigi/binfmt --install arm64
fi
if ! ls base/rpi/photon-rpi-5.0-*.raw >/dev/null 2>&1; then
  [ -f rpi.aarch64.tar.xz ] || curl -fsSL -m 900 -O https://packages.broadcom.com/artifactory/photon/5.0/GA/rpi/rpi.aarch64.tar.xz
  mkdir -p base && tar -xf rpi.aarch64.tar.xz -C base
fi
ls -la base/rpi/
