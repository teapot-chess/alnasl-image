#!/bin/bash
# Runs on the build VM. Builds hid-multitouch, cdc-acm, ch341, ads7846 and the small SPI panels' DRM drivers
# out of tree against EXACTLY the image's kernel (linux-devel 6.1.10-11.ph5, from Photon's
# release repo), with Photon's own gcc, inside a COPY of the image's root
# (chroot, qemu-user), so glibc and toolchain match the image to the package.
# Sources: kernel.org stable tag v6.1.10 (the base of Photon's 6.1.10-11).
# Output: /root/w-photon-img5/modules-out/*.ko and *.dtbo
# v7.3: the small screens (docs/spi-screens.md). Photon's kernel has no touchscreen drivers (CONFIG_INPUT_TOUCHSCREEN
# is off) and no panel drivers, but it has everything they stand on (spi-bcm2835, DRM_KMS_HELPER, GEM_DMA_HELPER,
# backlight class, fbdev emulation, CONFIG_OF_CONFIGFS). So: ads7846 (the XPT2046 stylus), drm_mipi_dbi and the
# drm/tiny panels on top of it (ili9486, ili9341, mi0283qt, hx8357d, st7735r, ili9163, ili9225; the presets use
# the first, second and fourth, the rest cost a few hundred kB and save a rebuild). tiny/panel-mipi-dbi is left
# out: it wants DRM_PANEL symbols this kernel does not export, and modpost says so.
# And the device-tree overlays that switch them on at run time: module/*.dts as they are, module/*.dts.in once per
# rotation (@ROTATION@ = 0, 90, 180, 270; the file name gets -r<degrees>), compiled with Photon's own dtc in the
# same chroot.
set -euo pipefail
W=/root/w-photon-img5
. $W/lib-chroot.sh
R=$W/buildroot
rm -rf $W/modsrc $W/modules-out; mkdir -p $W/modsrc $W/modules-out
cd $W/modsrc
G=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
for f in drivers/hid/hid-multitouch.c drivers/hid/hid-ids.h drivers/usb/class/cdc-acm.c drivers/usb/class/cdc-acm.h drivers/usb/serial/ch341.c \
         drivers/input/touchscreen/ads7846.c drivers/gpu/drm/drm_mipi_dbi.c \
         drivers/gpu/drm/tiny/ili9486.c drivers/gpu/drm/tiny/ili9341.c drivers/gpu/drm/tiny/mi0283qt.c drivers/gpu/drm/tiny/hx8357d.c \
         drivers/gpu/drm/tiny/st7735r.c drivers/gpu/drm/tiny/ili9163.c drivers/gpu/drm/tiny/ili9225.c; do
  curl -fsSL --retry 3 -m 60 "$G/$f?h=v6.1.10" -o "$(basename $f)"
done
# v7.4: the stylus is a touchscreen, and says so. Mainline ads7846 never sets INPUT_PROP_DIRECT, so libinput can
# take it for an absolute pointer with no button: the pointer follows the stylus and a tap clicks nothing (seen on
# the first real waveshare35a). One line, after the BTN_TOUCH capability; the build stops if that line moved.
grep -q '^	input_set_capability(input_dev, EV_KEY, BTN_TOUCH);$' ads7846.c || { echo "ads7846.c: the BTN_TOUCH line moved; the INPUT_PROP_DIRECT patch needs a look"; exit 1; }
sed -i 's/^	input_set_capability(input_dev, EV_KEY, BTN_TOUCH);$/&\n	__set_bit(INPUT_PROP_DIRECT, input_dev->propbit);	\/* Alnasl: a touchscreen, not a pointer *\//' ads7846.c
[ "$(grep -c 'INPUT_PROP_DIRECT' ads7846.c)" = 1 ] || { echo "ads7846.c: INPUT_PROP_DIRECT patch did not apply once"; exit 1; }
cp $W/module-Makefile Makefile
cp $W/module-dts/*.dts .
for t in $W/module-dts/*.dts.in; do
  n=$(basename "$t" .dts.in)
  for r in 0 90 180 270; do sed "s/@ROTATION@/$r/g" "$t" > "$n-r$r.dts"; done
done
! grep -l '@ROTATION@' *.dts || { echo "a rotation placeholder is left"; exit 1; }

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
tdnf install -y --nogpgcheck --disablerepo=photon-updates --disablerepo=photon --disablerepo=photon-extras gcc make binutils glibc-devel linux-devel-6.1.10-11.ph5 elfutils-libelf-devel openssl-devel bc dtc 2>&1 | tail -15
gcc --version | head -1
cd /build
make -j8 -C /lib/modules/6.1.10-11.ph5/build M=/build modules 2>&1 | tail -30
for m in hid-multitouch cdc-acm ch341 ads7846 drm_mipi_dbi ili9486 ili9341 mi0283qt hx8357d st7735r ili9163 ili9225; do
  cp /build/$m.ko /out/; modinfo /out/$m.ko | grep -E 'vermagic|depends' | tr '\n' ' ' | sed "s/^/$m: /"; echo
done
# -@: the overlays refer to the base tree's labels (spi, gpio); the kernel resolves them against /__symbols__.
dtc --version
for d in /build/*.dts; do
  n=$(basename $d .dts)
  dtc -@ -q -I dts -O dtb -o /out/$n.dtbo $d
  echo "$n.dtbo: $(fdtdump /out/$n.dtbo 2>/dev/null | grep -c 'fragment@') fragments"
done
IN
chroot $R /bin/bash /inside.sh
ls -la $W/modules-out
