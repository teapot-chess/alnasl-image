#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. espeak-ng for the nunki role (espeak/Dockerfile says how).
set -euo pipefail
cd /root/w-photon-img5/espeak
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t espeak-build:arm64 . 2>&1 | tail -n 40
id=$(docker create --platform linux/arm64 espeak-build:arm64 true)
docker cp "$id:/out/espeak-ng-aarch64.tar.gz" ../espeak-ng-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../espeak-ng-aarch64.tar.gz
