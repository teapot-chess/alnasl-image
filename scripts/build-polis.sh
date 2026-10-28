#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Needs polis/polis-src.tar (git archive of the Polis repo).
# Builds Polis's Linux release for aarch64 in an arm64 container, like build-arkab.sh does for Arkab.
set -euo pipefail
cd /root/w-photon-img5/polis
rm -rf src && mkdir src && tar -xf polis-src.tar -C src
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t polis-build:arm64 . 2>&1 | tail -n 40
id=$(docker create --platform linux/arm64 polis-build:arm64 true)
docker cp "$id:/out/polis-linux-aarch64.tar.gz" ../polis-linux-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../polis-linux-aarch64.tar.gz
