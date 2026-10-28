#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Needs alnasl/alnasl-src.tar.
set -euo pipefail
cd /root/w-photon-img5/alnasl
rm -rf src && mkdir src && tar -xf alnasl-src.tar -C src
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t alnasl-build:arm64 . 2>&1 | tail -n 60
id=$(docker create --platform linux/arm64 alnasl-build:arm64 true)
docker cp "$id:/out/alnasl-linux-aarch64.tar.gz" ../alnasl-linux-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../alnasl-linux-aarch64.tar.gz
