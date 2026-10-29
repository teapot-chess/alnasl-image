#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. The setup hotspot (docs/captive-portal.md) needs an
# access point, and Photon 5.0 has no hostapd package; its wpa_supplicant was built without AP mode
# ("AP mode support not included in the build"), so that door is shut too. Same trick as build-iw.sh:
# Debian 12 "bookworm" (arm64), glibc 2.36 like Photon 5.0, and it needs only libnl-3/-genl/-route and
# OpenSSL 3, which Photon ships. assemble.sh ldd-checks it inside the image and refuses a missing library.
# Userspace only: nothing here can pull a kernel, firmware or dtb package.
set -euo pipefail
W=/root/w-photon-img5
rm -rf $W/hostapd-out && mkdir -p $W/hostapd-out
docker run --rm --platform linux/arm64 -v $W/hostapd-out:/out debian:bookworm-slim sh -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends hostapd >/dev/null &&
  cp /usr/sbin/hostapd /usr/sbin/hostapd_cli /out/ &&
  dpkg -s hostapd | grep -E "^(Package|Version)" > /out/hostapd.version &&
  ldd /usr/sbin/hostapd'
chmod 0755 $W/hostapd-out/hostapd $W/hostapd-out/hostapd_cli
cat $W/hostapd-out/hostapd.version
file $W/hostapd-out/hostapd 2>/dev/null || true
