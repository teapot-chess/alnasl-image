#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Needs arkab/arkab-src.tar (git archive of the Arkab repo).
# Builds Arkab's Linux release for aarch64 in an arm64 container, like build-alnasl.sh does for Alnasl.
set -euo pipefail
cd /root/w-photon-img5/arkab
rm -rf src && mkdir src && tar -xf arkab-src.tar -C src
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t arkab-build:arm64 . 2>&1 | tail -n 40
id=$(docker create --platform linux/arm64 arkab-build:arm64 true)
docker cp "$id:/out/arkab-linux-aarch64.tar.gz" ../arkab-linux-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../arkab-linux-aarch64.tar.gz
