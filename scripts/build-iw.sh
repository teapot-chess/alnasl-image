#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Photon 5.0 has no `iw` package,
# so the userspace tool (scan fallback, `iw reg get/set`, diagnostics) is taken
# from Debian 12 "bookworm" (arm64): glibc 2.36 like Photon 5.0, and it needs
# only libnl-3 / libnl-genl-3, which Photon's own libnl package provides.
# It is a userspace binary: nothing here can pull a kernel, firmware or dtb package.
set -euo pipefail
W=/root/w-photon-img5
rm -rf $W/iw-out && mkdir -p $W/iw-out
docker run --rm --platform linux/arm64 -v $W/iw-out:/out debian:bookworm-slim sh -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends iw >/dev/null &&
  cp /usr/sbin/iw /out/iw && dpkg -s iw | grep -E "^(Package|Version)" > /out/iw.version &&
  ldd /usr/sbin/iw'
chmod 0755 $W/iw-out/iw
cat $W/iw-out/iw.version
file $W/iw-out/iw 2>/dev/null || true
