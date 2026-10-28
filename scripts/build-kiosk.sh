#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Builds the kiosk container image
# for arm64 (qemu-user) and leaves it in the local docker as alnasl-kiosk:latest.
set -euo pipefail
cd /root/w-photon-img5/kiosk
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t alnasl-kiosk:latest . 2>&1 | tail -n 40
docker image inspect alnasl-kiosk:latest --format '{{.Architecture}} {{.Size}}'
