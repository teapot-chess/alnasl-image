#!/bin/bash
# Runs on the build VM. Builds hid-multitouch, cdc-acm and ch341 out of tree
# against EXACTLY the image's kernel (linux-devel 6.1.10-11.ph5, from Photon's
# release repo), with Photon's own gcc, inside a COPY of the image's root
# (chroot, qemu-user), so glibc and toolchain match the image to the package.
# Sources: kernel.org stable tag v6.1.10 (the base of Photon's 6.1.10-11).
# Output: /root/w-photon-img5/modules-out/*.ko
set -euo pipefail
W=/root/w-photon-img5
. $W/lib-chroot.sh
R=$W/buildroot
rm -rf $W/modsrc $W/modules-out; mkdir -p $W/modsrc $W/modules-out
cd $W/modsrc
G=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
for f in drivers/hid/hid-multitouch.c drivers/hid/hid-ids.h drivers/usb/class/cdc-acm.c drivers/usb/class/cdc-acm.h drivers/usb/serial/ch341.c; do
  curl -fsSL --retry 3 -m 60 "$G/$f?h=v6.1.10" -o "$(basename $f)"
done
cp $W/module-Makefile Makefile

if [ ! -d $R/usr ]; then
  mkdir -p $R
  BL=$(losetup -f --show -P -r $(ls $W/base/rpi/photon-rpi-5.0-*.raw))
  mkdir -p $W/mnt-ro && mount -o ro ${BL}p2 $W/mnt-ro
  cp -a $W/mnt-ro/. $R/
  umount $W/mnt-ro; losetup -d $BL
fi
cp /etc/resolv.conf $R/etc/resolv.conf 2>/dev/null || echo 'nameserver 1.1.1.1' > $R/etc/resolv.conf
cat > $R/etc/yum.repos.d/zz-release-only.repo <<'REPO'
[zz-release]
name=Photon release (pinned)
baseurl=https://packages.broadcom.com/photon/5.0/photon_release_5.0_aarch64
gpgkey=file:///etc/pki/rpm-gpg/VMWARE-RPM-GPG-KEY-4096
gpgcheck=1
enabled=1
REPO
mkdir -p $R/build $R/out
mount --bind $W/modsrc $R/build; mount --bind $W/modules-out $R/out
cmount $R
trap 'umount -l $R/build $R/out 2>/dev/null; cumount $R' EXIT
cat > $R/inside.sh <<'IN'
set -euo pipefail
tdnf install -y --nogpgcheck --disablerepo=photon-updates --disablerepo=photon --disablerepo=photon-extras gcc make binutils glibc-devel linux-devel-6.1.10-11.ph5 elfutils-libelf-devel openssl-devel bc 2>&1 | tail -15
gcc --version | head -1
cd /build
make -j8 -C /lib/modules/6.1.10-11.ph5/build M=/build modules 2>&1 | tail -30
for m in hid-multitouch cdc-acm ch341; do cp /build/$m.ko /out/; modinfo /out/$m.ko | grep -E 'vermagic|depends'; done
IN
chroot $R /bin/bash /inside.sh
ls -la $W/modules-out
