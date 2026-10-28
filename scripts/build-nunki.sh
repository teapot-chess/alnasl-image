#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Needs nunki/nunki-src.tar (git archive of the Nunki repo).
# Builds Nunki's Linux release for aarch64 in an arm64 container, like build-arkab.sh does for Arkab.
set -euo pipefail
cd /root/w-photon-img5/nunki
rm -rf src && mkdir src && tar -xf nunki-src.tar -C src
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t nunki-build:arm64 . 2>&1 | tail -n 40
id=$(docker create --platform linux/arm64 nunki-build:arm64 true)
docker cp "$id:/out/nunki-linux-aarch64.tar.gz" ../nunki-linux-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../nunki-linux-aarch64.tar.gz
