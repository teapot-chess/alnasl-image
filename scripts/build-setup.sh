#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Needs setup/setup-src.tar (git archive HEAD:setup-app of this
# repository, made by build.ps1). Builds the box's own programs (setup-app) for aarch64, tests included.
set -euo pipefail
cd /root/w-photon-img5/setup
rm -rf src && mkdir src && tar -xf setup-src.tar -C src
# The tests read a few repository files (../../overlay/..., ../../scripts/grub-ab.cfg): stage them in the build context.
rm -rf overlay scripts
for f in boot-efi/alnasl-hotspot.txt etc/alnasl/update-key.pub; do mkdir -p "overlay/$(dirname "$f")"; cp "../overlay/$f" "overlay/$f"; done
mkdir -p overlay/usr/share/alnasl scripts
cp -r ../overlay/usr/share/alnasl/splash overlay/usr/share/alnasl/
cp ../grub-ab.cfg scripts/grub-ab.cfg
docker build --platform linux/arm64 --cpu-quota 800000 --cpu-period 100000 -t alnasl-setup-build:arm64 -f src/Dockerfile . 2>&1 | tail -n 60
id=$(docker create --platform linux/arm64 alnasl-setup-build:arm64 true)
docker cp "$id:/out/alnasl-setup-linux-aarch64.tar.gz" ../alnasl-setup-linux-aarch64.tar.gz
docker rm "$id" >/dev/null
ls -la ../alnasl-setup-linux-aarch64.tar.gz
