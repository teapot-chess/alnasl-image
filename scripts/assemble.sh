#!/bin/bash
# Runs on the build VM, in /root/w-photon-img5. Builds the final SD image from
#   base/rpi/photon-rpi-5.0-*.raw       Photon's own Raspberry Pi image
#   alnasl-linux-aarch64.tar.gz         build-alnasl.sh
#   arkab-linux-aarch64.tar.gz          build-arkab.sh
#   polis-linux-aarch64.tar.gz          build-polis.sh   (v7)
#   nunki-linux-aarch64.tar.gz          build-nunki.sh   (v7)
#   espeak-ng-aarch64.tar.gz            build-espeak.sh  (v7: Nunki's voice)
#   modules-out/*.ko                    build-modules.sh
#   kiosk image (docker, alnasl-kiosk:latest)   build-kiosk.sh
#   overlay/                            files laid over the root
# Everything inside the image's root is done in a chroot through qemu-user, so
# scripts of the packages run for real (as they would on the Pi).
set -euo pipefail
# All mounts live in a private mount namespace: nothing leaks into the VM's services.
if [ -z "${ALNASL_UNSHARED:-}" ]; then export ALNASL_UNSHARED=1; exec unshare -m --propagation private bash "$0" "$@"; fi
W=/root/w-photon-img5
cd $W
. $W/lib-chroot.sh
IMG=$W/photon-alnasl-v7.img
KVER=6.1.10-11.ph5
# v6 A/B (docs/v6-plan.md, "Updates without reflashing"): boot (FAT) | system A | system B | data.
# Each system slot is SLOT_MB; data starts at DATA_MB and grows to the end of the card at the first
# boot. The image file is ~6.6 GB, mostly zeros (slot B, data): it compresses to next to nothing. The
# card must be 16 GB or larger. Every v6+ image has the same MBR disk identifier: grub and the kernel
# find the slots by it (root=PARTUUID=416c6e73-02 / -03), and so do the updates.
ALNASL_TRAIN=${ALNASL_TRAIN:-v7}
ALNASL_VERSION=${ALNASL_VERSION:-7.0}
SLOT_MB=${SLOT_MB:-3072}
DATA_MB=${DATA_MB:-512}
DISK_ID=416c6e73
if ! [[ "$ALNASL_TRAIN" =~ ^v[0-9]+$ && "$ALNASL_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [ "${ALNASL_VERSION%%.*}" != "${ALNASL_TRAIN#v}" ]; then
  echo "ALNASL_TRAIN=$ALNASL_TRAIN ALNASL_VERSION=$ALNASL_VERSION: the version must be <train number>.<n> (v6 -> 6.0, 6.1 ...)"; exit 1
fi
echo "building train $ALNASL_TRAIN, version $ALNASL_VERSION (slots $SLOT_MB MiB, data $DATA_MB MiB to start)"
# v6: no ssh key any more. Nobody logs in to this box from elsewhere (docs/v6-plan.md, section 2).

# --- 0. clean up whatever an earlier run left mounted --------------------------
for d in $W/mnt/root $W/mnt/boot; do umount -R -l $d 2>/dev/null || true; done
[ -f $W/loopdev ] && losetup -d "$(cat $W/loopdev)" 2>/dev/null || true
for l in $(losetup -j $IMG -O NAME -n 2>/dev/null); do losetup -d $l 2>/dev/null || true; done

# --- 1. the official image, laid out A/B -----------------------------------------
# Photon's image is p1 FAT (firmware, u-boot, grub) + p2 root. p1 stays exactly as it is; p2 becomes
# system A (its file system exactly SLOT_MB), p3 system B (empty until the first update), p4 data.
BASE=$(ls $W/base/rpi/photon-rpi-5.0-*.raw)
rm -f $IMG
cp --sparse=always "$BASE" $IMG
P1=$(sfdisk -d $IMG | grep -E "^${IMG}1 :" | sed 's/^[^:]*: *//')
P2S=$(sfdisk -d $IMG | grep -E "^${IMG}2 :" | sed -n 's/.*start= *\([0-9]*\).*/\1/p')
[ -n "$P1" ] && [ -n "$P2S" ] || { echo "base image: could not read its partitions"; sfdisk -d $IMG; exit 1; }
SLOT=$((SLOT_MB * 2048)); DATAS=$((DATA_MB * 2048))
P3S=$((P2S + SLOT)); P4S=$((P3S + SLOT)); END=$((P4S + DATAS))
# A root file system larger than a slot is shrunk first, while its partition is still the old one.
L=$(losetup -f --show -P $IMG); echo $L > $W/loopdev
e2fsck -fy ${L}p2 >/dev/null || true
fsbytes=$(dumpe2fs -h ${L}p2 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{b=$2} END{printf "%d", c*b}')
if [ "$fsbytes" -gt $((SLOT_MB << 20)) ]; then resize2fs ${L}p2 ${SLOT_MB}M; fi
losetup -d $L
truncate -s $((END * 512)) $IMG
sfdisk --no-reread -q $IMG <<EOT
label: dos
label-id: 0x$DISK_ID
unit: sectors

$P1
start=$P2S, size=$SLOT, type=83
start=$P3S, size=$SLOT, type=83
start=$P4S, size=$DATAS, type=83
EOT
sfdisk -d $IMG | sed 's/^/  layout: /'
L=$(losetup -f --show -P $IMG); echo $L > $W/loopdev
trap 'cumount $W/mnt/root 2>/dev/null; umount -R -l $W/mnt/root $W/mnt/boot 2>/dev/null; losetup -d $L 2>/dev/null' EXIT
e2fsck -fy ${L}p2 >/dev/null || true
resize2fs ${L}p2 >/dev/null
e2label ${L}p2 ALNASL_A
# Slot B: nothing on it, not even a stale signature that grub or blkid could take for a system.
wipefs -a -q ${L}p3 2>/dev/null || true
dd if=/dev/zero of=${L}p3 bs=1M count=16 conv=fsync status=none
# Data: an empty ext4, made further down with the IMAGE's own mke2fs (not this VM's): alnasl-data grows
# it with the image's resize2fs/e2fsck at the first boot.
mkdir -p $W/mnt/root $W/mnt/boot
mount ${L}p2 $W/mnt/root
mount ${L}p1 $W/mnt/boot
R=$W/mnt/root
B=$W/mnt/boot

# --- 2. packages (from Photon's RELEASE repo only: the versions the image was made with)
cp /etc/resolv.conf $R/etc/resolv.conf.build 2>/dev/null || echo 'nameserver 1.1.1.1' > $R/etc/resolv.conf.build
rm -f $R/etc/resolv.conf; cp $R/etc/resolv.conf.build $R/etc/resolv.conf
cat > $R/etc/yum.repos.d/zz-build-release.repo <<'REPO'
[zz-build-release]
name=Photon release (build time)
baseurl=https://packages.broadcom.com/photon/5.0/photon_release_5.0_aarch64
gpgcheck=0
enabled=1
REPO
cmount $R
# The data file system, with the image's mke2fs. The VM's e2fsprogs (1.47) turns on orphan_file and
# metadata_csum_seed; Photon's (1.46.5) then refuses to resize2fs or e2fsck it, so the first boot left the
# data partition at 512 MiB on any card (seen in the first v6 qemu boot).
chroot $R mkfs.ext4 -q -F -L ALNASL_DATA ${L}p4
cat > $R/inside-pkgs.sh <<'IN'
set -euo pipefail
tdnf install -y --nogpgcheck --disablerepo=photon-updates \
  linux-drivers-gpu-6.1.10-11.ph5 docker-23.0.2-1.ph5 docker-engine-23.0.2-1.ph5 docker-cli-23.0.2-1.ph5 tar diffutils kbd \
  cups alsa-lib alsa-utils dnsmasq 2>&1 | tail -25
tdnf clean all || true
# v7.3: dnsmasq is the setup hotspot's DHCP and catch-all DNS (docs/captive-portal.md); nothing else uses it.
# v7: cups (Polis prints through lp), alsa-lib + alsa-utils (Nunki: aplay, amixer; espeak-ng's audio).
rpm -q tar diffutils kbd cups alsa-lib alsa-utils dnsmasq linux linux-drivers-gpu docker containerd runc dtb-rpi4 u-boot-rpi4 grub2-efi-image raspberrypi-firmware linux-firmware
IN
chroot $R /bin/bash /inside-pkgs.sh
rm -f $R/inside-pkgs.sh $R/etc/yum.repos.d/zz-build-release.repo

# The plan above must not have moved the kernel (kbd/iw pull in nothing of the sort).
[ "$(chroot $R rpm -q linux)" = "linux-6.1.10-11.ph5.aarch64" ] || { echo "KERNEL PACKAGE CHANGED: $(chroot $R rpm -q linux)"; exit 1; }
[ "$(ls $R/lib/modules/)" = "$KVER" ] || { echo "modules dir changed: $(ls $R/lib/modules/)"; exit 1; }

# --- 2b. linux-drivers-sound, EXACTLY the kernel's version (v5) ----------------------------------------
# vc4 uses the ALSA SoC core for HDMI audio (devm_snd_soc_register_component ...). Without the sound modules
# vc4 fails to load ("Unknown symbol") and the box has no KMS graphics. Fetched by exact file name from
# Photon's release repo, signature checked against the VMware keys that ship in the image, and installed with
# rpm (it Requires linux = 6.1.10-11.ph5 and nothing else, so nothing can be pulled in or moved).
SND=linux-drivers-sound-$KVER.aarch64.rpm
SNDURL=https://packages.vmware.com/photon/5.0/photon_release_5.0_aarch64/aarch64/$SND
curl -fsSL --retry 3 -m 300 -o $W/$SND "$SNDURL"
install -m 0644 $W/$SND $R/tmp/$SND
echo "sound rpm: $(sha256sum $W/$SND)"
cat > $R/inside-snd.sh <<IN
set -euo pipefail
SND=$SND
KVER=$KVER
IN
cat >> $R/inside-snd.sh <<'IN'
rm -rf /tmp/kdb; mkdir /tmp/kdb
rpm --dbpath /tmp/kdb --initdb
n=0
for k in /etc/pki/rpm-gpg/VMWARE-RPM-GPG-KEY*; do rpm --dbpath /tmp/kdb --import "$k" && n=$((n+1)); done
echo "imported $n VMware key file(s) into a scratch rpm database"
out=$(rpm --dbpath /tmp/kdb -K "/tmp/$SND" 2>&1); echo "$out"
echo "$out" | grep -q 'signatures OK' || { echo "SIGNATURE CHECK FAILED for $SND"; exit 1; }
echo "$out" | grep -q -i -E 'NOT OK|NOKEY|BAD' && { echo "SIGNATURE CHECK FAILED for $SND"; exit 1; }
rpm -qp --requires "/tmp/$SND" | sed 's/^/  requires: /'
# v7: alsa-utils (Nunki) pulls this very package in from the same release repository; then it is there
# already, and must be exactly this version.
if rpm -q "linux-drivers-sound-$KVER" >/dev/null 2>&1; then
  echo "linux-drivers-sound-$KVER already installed (pulled in by alsa-utils): the same package, kept"
else
  rpm -ivh "/tmp/$SND"
fi
rm -rf /tmp/kdb "/tmp/$SND"
depmod -a "$KVER"
rpm -q "linux-drivers-sound-$KVER" linux
IN
chroot $R /bin/bash /inside-snd.sh
rm -f $R/inside-snd.sh
[ "$(chroot $R rpm -q linux)" = "linux-6.1.10-11.ph5.aarch64" ] || { echo "KERNEL PACKAGE CHANGED by the sound package"; exit 1; }
[ "$(ls $R/lib/modules/)" = "$KVER" ] || { echo "modules dir changed: $(ls $R/lib/modules/)"; exit 1; }

# --- 3. modules built out of tree (exactly this kernel) ---------------------------
install -d $R/lib/modules/$KVER/extra
install -m 0644 $W/modules-out/*.ko $R/lib/modules/$KVER/extra/
chroot $R depmod -a $KVER
chroot $R modinfo -k $KVER vc4 hid-multitouch cdc-acm ch341 2>&1 | grep -E '^(filename|vermagic)' || true
# vc4 and everything it needs must resolve (v4 shipped without the sound modules: "Unknown symbol devm_snd_soc_register_component").
chroot $R modprobe -n -v -S $KVER vc4 2>&1 | tee $W/vc4-chain.txt | sed 's/^/  vc4 chain: /'
grep -q 'snd-soc-core\|snd_soc_core' $W/vc4-chain.txt || { echo "vc4 chain lacks snd-soc-core"; exit 1; }
unres=$(chroot $R depmod -a -e -F /boot/System.map-$KVER $KVER 2>&1 | grep -E 'vc4|snd_soc|snd-soc' || true)
[ -z "$unres" ] || { echo "UNRESOLVED SYMBOLS in the vc4 chain: $unres"; exit 1; }

# --- 3b. iw (userspace; Photon 5.0 has no package for it, see build-iw.sh) -----------
install -m 0755 $W/iw-out/iw $R/usr/sbin/iw
echo "iw: $(cat $W/iw-out/iw.version | tr '\n' ' ')"
chroot $R /bin/bash -c 'ldd /usr/sbin/iw; if ldd /usr/sbin/iw | grep -q "not found"; then echo "iw: MISSING LIBRARY"; exit 1; fi; iw --version'
# --- 3c. hostapd (v7.3, the setup hotspot; Photon has none and its wpa_supplicant has no AP mode) ----
install -m 0755 $W/hostapd-out/hostapd $R/usr/sbin/hostapd
install -m 0755 $W/hostapd-out/hostapd_cli $R/usr/sbin/hostapd_cli
echo "hostapd: $(cat $W/hostapd-out/hostapd.version | tr '\n' ' ')"
chroot $R /bin/bash -c 'for b in /usr/sbin/hostapd /usr/sbin/hostapd_cli; do ldd $b; if ldd $b | grep -q "not found"; then echo "$b: MISSING LIBRARY"; exit 1; fi; done; hostapd -v 2>&1 | head -1'

# --- 4. (v1-v5: Tailscale. Gone in v6: no VPN, no remote shell.) ---------------------

# --- 5. overlay (units, scripts, network, modules-load, ...) ------------------------
# --mode: the overlay was copied from a Windows PC over scp, so its directories
# arrive as 0700 and would be applied to /, /etc, /usr ... (services running as
# non-root users then fail with 200/CHDIR). Fixed modes: dirs 755, files 644,
# executables keep their x bit; assemble sets the real scripts' modes below.
(cd $W/overlay && tar --owner=0 --group=0 --mode='u=rwX,go=rX' -cf - --exclude=boot-efi .) | tar -xf - -C $R
chmod 0755 $R
chmod 0755 $R/usr/local/sbin/alnasl-*
[ -x $R/usr/local/sbin/alnasl-mode ] || { echo "alnasl-mode missing from the overlay"; exit 1; }
chmod 0644 $R/etc/alnasl/hotspot-dnsmasq.conf
# The box's own programs: one Elixir release (setup-app, build-setup.sh) at /opt/alnasl-setup. The setup server,
# the hotspot and its portal run from it as units; alnasl-splash and alnasl-system-update are shell wrappers
# around its eval. Root owns it, everyone may read it (the portal runs as a throwaway user), nobody writes it.
mkdir -p $R/opt
rm -rf $R/opt/alnasl-setup
tar -xzf $W/alnasl-setup-linux-aarch64.tar.gz -C $R/opt
chown -R 0:0 $R/opt/alnasl-setup
chmod -R u=rwX,go=rX $R/opt/alnasl-setup
[ -x $R/opt/alnasl-setup/bin/alnasl_setup ] && [ -x $R/opt/alnasl-setup/bin/alnasl-fbtool ] || { echo "setup-app release incomplete"; exit 1; }
chroot $R /opt/alnasl-setup/bin/alnasl_setup eval 'IO.puts("setup-app runs in the image: " <> System.otp_release())' || { echo "setup-app does not start in the image"; exit 1; }
# v7.3: the hotspot file's template, for when someone deletes it from the card (alnasl-hotspot re-creates it).
install -D -m 0644 $W/overlay/boot-efi/alnasl-hotspot.txt $R/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt
chmod 0755 $R/usr/local/bin/espeak-ng
chmod 0600 $R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
# Console keyboard: Belgian by default (the setup pages change it later).
KM=$(find $R/usr/share/keymaps $R/usr/lib/kbd $R/lib/kbd -name 'be-latin1.map*' 2>/dev/null | head -n 1 || true)
if [ -n "$KM" ]; then echo 'KEYMAP=be-latin1' > $R/etc/vconsole.conf; echo "console keymap: be-latin1 ($KM)"; else echo "WARNING: no be-latin1 keymap in the image"; fi
for k in be-latin1 fr-latin9 nl us-acentos de-latin1-nodeadkeys us uk es it pt-latin1; do
  f=$(find $R/usr/share/keymaps $R/usr/lib/kbd $R/lib/kbd -name "$k.map*" 2>/dev/null | head -n 1 || true); echo "  keymap $k: ${f:+yes}${f:-MISSING}"
done
rm -f $R/etc/systemd/network/99-dhcp-en.network
ln -sf ../run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
rm -f $R/etc/resolv.conf.build
# v6: what a reset (alnasl-reset) puts back: the settings files exactly as this image ships them.
for f in etc/alnasl/keyboard.conf etc/alnasl/kiosk.conf etc/vconsole.conf etc/hostname etc/wpa_supplicant/wpa_supplicant-wlan0.conf; do
  [ -f $R/$f ] && install -D -m 0644 $R/$f $R/usr/share/alnasl/defaults/$f
done
# v7: CUPS's settings as this image ships them. /etc/cups itself lives on the data partition (the printers
# a Polis box was given survive updates); alnasl-data fills it from here and puts the image's own
# configuration back over it at every boot, printers.conf/ppd/classes/subscriptions excepted.
[ -d $R/etc/cups ] || { echo "no /etc/cups: the cups package did not install"; exit 1; }
rm -rf $R/usr/share/alnasl/defaults/etc/cups
cp -a $R/etc/cups $R/usr/share/alnasl/defaults/etc/cups
chmod 0600 $R/usr/share/alnasl/defaults/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
# v6 A/B: what the box keeps lives on the data partition (alnasl-data binds it over these directories
# at boot); the slot has only the mount points, and the two settings files point there. That way a slot
# can be replaced whole by an update. PID 1 reads /etc/machine-id, /etc/hostname and /etc/vconsole.conf
# before anything is mounted, so those stay in the slot (the updater copies them into the new one).
install -d -m 0755 $R/data
for d in var/lib/arkab var/lib/polis var/lib/polis-update var/lib/nunki var/lib/nunki-update etc/cups var/lib/alnasl-setup var/lib/alnasl-update var/lib/alnasl-os-update var/lib/docker var/lib/containerd \
         var/log/journal etc/systemd/network/10-wired.network.d etc/systemd/network/20-wireless.network.d; do
  install -d -m 0755 $R/$d
done
for f in keyboard.conf kiosk.conf; do rm -f $R/etc/alnasl/$f; ln -s /data/etc/alnasl/$f $R/etc/alnasl/$f; done
cat > $R/etc/alnasl/image-release <<REL
# Which image this system slot holds (v6 A/B updates); written by assemble.sh. A train is a major
# image line: within it updates install by themselves at night; another train only when asked for.
ALNASL_TRAIN=$ALNASL_TRAIN
ALNASL_VERSION=$ALNASL_VERSION
REL
if grep -q 'ALNASL-PLACEHOLDER' $R/etc/alnasl/update-key.pub; then
  echo "WARNING: update-key.pub is the PLACEHOLDER: a box with this image installs no system update"
  [ "${ALNASL_RELEASE:-0}" = 1 ] && { echo "ALNASL_RELEASE=1 needs the real public key in overlay/etc/alnasl/update-key.pub"; exit 1; }
fi
# / has no line: it is whichever slot grub started (root=PARTUUID=... on the kernel's command line).
# /data is alnasl-data's (grow, wipe, check, bind), not this file's. No swap (resizefs is masked).
cat > $R/etc/fstab <<FST
#system	mnt-pt	type	options	dump	fsck
# v6 A/B: / is the slot grub started (root=PARTUUID=$DISK_ID-02 or -03); /data is mounted by alnasl-data.service.
PARTUUID=$DISK_ID-01	/boot/efi	vfat	defaults,nofail	0	2
FST
# v6: the boot screen's pictures are binary; nothing above may have touched them (CR stripping).
[ "$(head -c 8 $R/usr/share/alnasl/splash/alnasl-splash.png | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] || { echo "alnasl-splash.png is damaged"; exit 1; }

# --- 6. Alnasl: the release's own install.sh ----------------------------------------
rm -rf $R/tmp/alnasl-rel; mkdir -p $R/tmp/alnasl-rel
tar -xzf $W/alnasl-linux-aarch64.tar.gz -C $R/tmp/alnasl-rel
# install.sh talks to a running systemd (restart, daemon-reload); in a chroot
# there is none. A shim passes `enable` through (symlinks only) and ignores the rest.
mkdir -p $R/tmp/shim
cat > $R/tmp/shim/systemctl <<'SH'
#!/bin/sh
case "$1" in
  enable|disable|mask|unmask|is-enabled) exec /usr/bin/systemctl "$@" ;;
  *) exit 0 ;;
esac
SH
chmod +x $R/tmp/shim/systemctl
cat > $R/inside-alnasl.sh <<'IN'
set -euo pipefail
export PATH=/tmp/shim:$PATH
sh /tmp/alnasl-rel/alnasl/install.sh --lan
ls -la /opt/alnasl /opt/alnasl/current/ | head -30
cat /etc/alnasl/alnasl.env
IN
chroot $R /bin/bash /inside-alnasl.sh
rm -rf $R/tmp/alnasl-rel $R/tmp/shim $R/inside-alnasl.sh
# The data directory is created by install.sh; make sure it belongs to alnasl.
chroot $R chown alnasl:alnasl /var/lib/alnasl

# --- 6b. Arkab: the slave mode's program (docs/v6-plan.md section 1) ---------------------------------
# The same way as Alnasl: the release's own install.sh, in the chroot, with the systemctl shim. It makes the
# user "arkab" (group dialout: the serial ports), /opt/arkab, /etc/arkab/arkab.env (PORT=4050, the hall's
# network may look) and the units. The image ships it DISABLED: a new box is a master; alnasl-mode enables
# it (and disables Alnasl and the screen) on a slave. Its data, /var/lib/arkab, is on the data partition.
rm -rf $R/tmp/arkab-rel; mkdir -p $R/tmp/arkab-rel $R/tmp/shim
tar -xzf $W/arkab-linux-aarch64.tar.gz -C $R/tmp/arkab-rel
cat > $R/tmp/shim/systemctl <<'SH'
#!/bin/sh
case "$1" in
  enable|disable|mask|unmask|is-enabled) exec /usr/bin/systemctl "$@" ;;
  *) exit 0 ;;
esac
SH
chmod +x $R/tmp/shim/systemctl
cat > $R/inside-arkab.sh <<'IN'
set -euo pipefail
export PATH=/tmp/shim:$PATH
sh /tmp/arkab-rel/arkab/install.sh
systemctl disable arkab.service arkab-update.path
ls -la /opt/arkab /opt/arkab/current/ | head -20
cat /etc/arkab/arkab.env
getent passwd arkab
id arkab
IN
chroot $R /bin/bash /inside-arkab.sh
echo "Arkab in the image: $(cat $R/opt/arkab/current/VERSION 2>/dev/null || echo MISSING)"
rm -rf $R/tmp/arkab-rel $R/tmp/shim $R/inside-arkab.sh
chroot $R chown arkab:arkab /var/lib/arkab

# --- 6c. Polis and Nunki (v7, docs/v7-plan.md section 1): the print station and the announcer ---------
# The same way again: each release's own install.sh in the chroot with the systemctl shim, WITHOUT --lan
# (their pages are for this box's own screen; nothing in the hall connects to them, and the firewall has no
# port for them anyway). Both are shipped DISABLED; alnasl-mode enables the one this box is.
#   polis: user polis, /opt/polis, /etc/polis/polis.env (PORT=4061); prints with `lp` through CUPS
#   nunki: user nunki in group audio, /opt/nunki, /etc/nunki/nunki.env (PORT=4062); speaks with espeak-ng
# espeak-ng is not a Photon package: build-espeak.sh builds it (Debian's, with an ALSA-only pcaudiolib)
# into /opt/espeak-ng, and /usr/local/bin/espeak-ng (overlay) runs it from there.
rm -rf $R/opt/espeak-ng
tar -xzf $W/espeak-ng-aarch64.tar.gz -C $R/opt
chown -R 0:0 $R/opt/espeak-ng
for app in polis nunki; do
  rm -rf $R/tmp/$app-rel; mkdir -p $R/tmp/$app-rel $R/tmp/shim
  tar -xzf $W/$app-linux-aarch64.tar.gz -C $R/tmp/$app-rel
  cat > $R/tmp/shim/systemctl <<'SH'
#!/bin/sh
case "$1" in
  enable|disable|mask|unmask|is-enabled) exec /usr/bin/systemctl "$@" ;;
  *) exit 0 ;;
esac
SH
  chmod +x $R/tmp/shim/systemctl
  cat > $R/inside-app.sh <<IN
set -euo pipefail
export PATH=/tmp/shim:\$PATH
getent group audio >/dev/null || groupadd -r audio
sh /tmp/$app-rel/$app/install.sh
systemctl disable $app.service $app-update.path
ls -la /opt/$app /opt/$app/current/ | head -20
cat /etc/$app/$app.env
id $app
IN
  chroot $R /bin/bash /inside-app.sh
  echo "$app in the image: $(cat $R/opt/$app/current/VERSION 2>/dev/null || echo MISSING)"
  [ -x $R/opt/$app/current/bin/$app ] || { echo "$app did not install"; exit 1; }
  rm -rf $R/tmp/$app-rel $R/tmp/shim $R/inside-app.sh
  chroot $R chown $app:$app /var/lib/$app
done
chroot $R id -nG nunki | grep -qw audio || { echo "nunki is not in the group audio"; exit 1; }
chroot $R /usr/local/bin/espeak-ng --voices=nl | head -n 3
chroot $R /usr/local/bin/espeak-ng -v nl -w /tmp/espeak-test.wav "Ronde drie begint nu" && [ -s $R/tmp/espeak-test.wav ] ||
  { echo "espeak-ng does not speak in the image"; exit 1; }
rm -f $R/tmp/espeak-test.wav

# --- 7. v6 lockdown: no ssh server, no baked key, no host keys ---------------------------
# Photon's base image comes with sshd. It goes; if something insists on keeping the package,
# the units are masked so nothing can start it.
chroot $R /bin/bash <<'IN'
if rpm -q openssh-server >/dev/null 2>&1; then
  rpm -e openssh-server 2>&1 || tdnf -y --disablerepo='*' erase openssh-server 2>&1 || echo "openssh-server could not be removed; masked instead"
fi
for u in sshd.service sshd.socket sshd-keygen.service sshd@.service; do systemctl mask "$u" >/dev/null 2>&1 || true; done
rpm -q openssh-server 2>&1 | sed 's/^/  ssh server package: /'
IN
rm -f $R/root/.ssh/authorized_keys $R/etc/ssh/ssh_host_* $R/etc/ssh/alnasl-sshd.conf
[ "$(chroot $R rpm -q linux)" = "linux-6.1.10-11.ph5.aarch64" ] || { echo "KERNEL PACKAGE CHANGED by the ssh removal"; exit 1; }

# --- 7b. no Python on the box --------------------------------------------------------------------
# Photon's base image ships python3; nothing of ours uses it any more (setup-app replaced the last of it).
# Every package that is Python (python3, python3-*, *-python) or owns a file under a python3 directory goes,
# in one rpm -e. If anything that is NOT Python still needs one of them, the build stops and names it:
# that is a decision for a person, not for this script.
chroot $R /bin/bash <<'IN'
set -euo pipefail
pys=$( { rpm -qa --qf '%{NAME}\n' | grep -E '^python3($|-)|-python3?$' || true
         for d in /usr/lib/python3* /usr/lib64/python3* /usr/bin/python3*; do [ -e "$d" ] && rpm -qf --qf '%{NAME}\n' "$d" 2>/dev/null; done || true
       } | grep -v 'not owned' | sort -u)
if [ -z "$pys" ]; then echo "  python: none in the base"; exit 0; fi
echo "  python packages to remove: $(echo $pys)"
# Photon's motd package is a Python script (motdgen) for login banners; the box has no login. It goes with Python.
if rpm -q motd >/dev/null 2>&1; then
  [ -z "$(rpm -q --whatrequires motd 2>/dev/null | grep -v '^no package requires')" ] || { echo "something needs motd"; exit 1; }
  rpm -e motd; echo "  removed motd (Python script, login banner)"
fi
# alsa-lib carries a bare "Requires: python3" in Photon 5 although it ships no Python file (checked: no script,
# no python import). That one dependency is waived (rpm -e --nodeps); anything else still stops the build.
waived='alsa-lib'
if ! out=$(rpm -e --test $pys 2>&1); then
  others=$(echo "$out" | grep -E 'is needed by' | grep -v -E "needed by \(installed\) ($waived)-[0-9]" || true)
  if [ -n "$others" ]; then
    echo "$out" | sed 's/^/  /'
    echo "PYTHON IS STILL NEEDED by the packages above (not Python themselves); decide what to do with them"; exit 1
  fi
  echo "  waived: python3 required by $waived only"
  rpm -e --nodeps $pys
else
  rpm -e $pys
fi
# rpm leaves the (now empty) site-packages directories of other packages behind; empty ones go, anything with a file in it stays and fails the check.
find /usr/lib/python3* /usr/lib64/python3* -depth -type d -empty -delete 2>/dev/null || true
left=$(ls -d /usr/bin/python* /usr/lib/python3* /usr/lib64/python3* 2>/dev/null || true)
[ -z "$left" ] || { echo "python files left behind: $left"; exit 1; }
! rpm -qa | grep -q -E '^python3' || { echo "a python3 package is still installed"; exit 1; }
echo "  python: removed"
IN
[ "$(chroot $R rpm -q linux)" = "linux-6.1.10-11.ph5.aarch64" ] || { echo "KERNEL PACKAGE CHANGED by the python removal"; exit 1; }

# --- 8. services: enable ours, silence the ones that would wait for a network --------
chroot $R /bin/bash -e <<'IN'
systemctl disable iptables.service || true
# v7: CUPS is Polis's, and alnasl-mode enables it only on a Polis box.
systemctl disable cups.service >/dev/null 2>&1 || true
# v7.3: dnsmasq runs only as alnasl-hotspot-dns, on the hotspot, while it is up. The stock unit would
# answer DNS on every interface, Ethernet included; it does not get the chance.
systemctl disable dnsmasq.service >/dev/null 2>&1 || true
systemctl mask dnsmasq.service
[ "$(systemctl is-enabled cups.service 2>/dev/null)" != enabled ] || { echo "cups.service is still enabled"; exit 1; }
systemctl mask systemd-networkd-wait-online.service
rm -f /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
systemctl enable alnasl-firewall.service alnasl-firstboot.service alnasl-wifi.service \
  alnasl-kiosk-load.service alnasl-kiosk.service alnasl-setup.service \
  docker.service containerd.service alnasl.service alnasl-update.path wpa_supplicant@wlan0.service \
  systemd-networkd.service systemd-resolved.service systemd-timesyncd.service \
  getty@tty2.service getty@tty3.service \
  alnasl-splash.service alnasl-splash-reboot.service alnasl-splash-poweroff.service \
  alnasl-os-update.timer alnasl-reset-boot.service \
  alnasl-data.service alnasl-slot-check.service alnasl-upgrade-boot.service alnasl-mode.service \
  alnasl-arkab-pin.service alnasl-system-update-check.timer alnasl-hotspot.service
# v6 A/B: Photon's first-boot resizefs grows / to 90 % of the card and adds a swap partition; both
# would wreck the slot/data layout. The data partition grows instead (alnasl-data).
systemctl mask resizefs.service
# v6 boot screen: tty1 is the picture's and then X's. No login prompt there, ever (logind would
# start one on a switch to tty1 through autovt@); the consoles stay on tty2 and tty3.
systemctl disable getty@tty1.service >/dev/null 2>&1 || true
systemctl mask getty@tty1.service autovt@tty1.service
IN
mkdir -p $R/var/log/journal
# machine-id: empty file, filled in by systemd on the first boot (one id per card)
: > $R/etc/machine-id

# --- 9. updates must never move the kernel or the boot chain -----------------------
# (the file's trailing newlines are replaced by exactly one, then the block is appended)
TDNF_CONF=$R/etc/tdnf/tdnf.conf
{ printf '%s\n' "$(cat $TDNF_CONF)"; cat <<'TDNF'

# Alnasl hall box: the kernel, its device trees, the GPU/driver packages, the
# firmware, the boot loaders and the Raspberry Pi firmware are matched to each
# other and must not be updated one at a time (a 6.12 kernel with 6.1 device
# trees left the Ethernet and Wi-Fi dead). To update them on purpose, in one go:
#   tdnf --disableexcludes=all update linux linux-drivers-gpu dtb-rpi4 ...
# and rebuild the out-of-tree modules for the new kernel (see README).
excludepkgs=linux linux-* dtb-* raspberrypi-firmware* u-boot* grub2* initramfs
TDNF
} > $TDNF_CONF.new
cat $TDNF_CONF.new > $TDNF_CONF; rm -f $TDNF_CONF.new
grep -n excludepkgs $R/etc/tdnf/tdnf.conf

# --- 10. kiosk container image, baked in ---------------------------------------------
install -d $R/var/lib/alnasl-image
docker save alnasl-kiosk:latest | gzip -3 > $R/var/lib/alnasl-image/alnasl-kiosk.tar.gz
# v6 A/B: docker's store is on the data partition and outlives slots. alnasl-kiosk-load loads the
# tarball whenever the store's image is not this one (a new slot with a new kiosk, after a reset).
docker image inspect alnasl-kiosk:latest --format '{{.Id}}' > $R/usr/share/alnasl/kiosk-image-id
ls -la $R/var/lib/alnasl-image/

# --- 11. the boot (FAT) partition: templates + a note ------------------------------------
cp $W/overlay/boot-efi/* $B/
# v7.3: the hotspot file is for Notepad, so CRLF (the build stripped it with everything else).
sed -i 's/\r*$/\r/' $B/alnasl-hotspot.txt
# v6 A/B: grub's config on this partition chooses the slot (scripts/grub-ab.cfg; no slot's own
# grub.cfg is read any more). Its environment block, 1024 bytes written in place by grub's save_env
# and by alnasl-system-update, starts on slot A.
[ -f $B/boot/grub2/grub.cfg ] || { echo "no grub.cfg on the boot partition"; exit 1; }
sed "s/@DISKID@/$DISK_ID/g" $W/grub-ab.cfg > $B/boot/grub2/grub.cfg
! grep -q '@DISKID@' $B/boot/grub2/grub.cfg || { echo "grub-ab.cfg: @DISKID@ left"; exit 1; }
install -d $B/alnasl
{ printf '# GRUB Environment Block\nalnasl_slot=A\nalnasl_try=none\nalnasl_tries=0\nalnasl_failed=none\n'; head -c 1024 /dev/zero | tr '\0' '#'; } | head -c 1024 > $B/alnasl/grubenv
[ "$(stat -c %s $B/alnasl/grubenv)" = 1024 ] || { echo "grubenv is not 1024 bytes"; exit 1; }
install -D -m 0644 $R/usr/share/alnasl/splash/alnasl-splash.png $B/boot/grub2/alnasl-splash.png
# The picture is now drawn from this partition's grub.cfg: the font gfxterm loads must be here too.
if [ -d $R/boot/grub2/fonts ]; then cp -r $R/boot/grub2/fonts $B/boot/grub2/; else echo "NOTE: no grub fonts in the slot; gfxterm runs without one"; fi
# v5: config.txt. disable_overscan=1: the firmware's default overscan made the framebuffer 1824x984 on a 1920x1080 screen.
# core_freq_min=500 (Pi 4 only): the HDMI/KMS driver changes the core clock, which also clocks peripherals; one
# "mmc: Timeout waiting for hardware cmd interrupt" hang was seen at the first boot with vc4. See README (v5).
# v5: the text console must not blank either (a hall display never sleeps)
sed -i "/^systemd_cmdline=/ s/$/ consoleblank=0/" $R/boot/systemd.cfg
grep -q consoleblank=0 $R/boot/systemd.cfg || { echo "consoleblank=0 not set"; exit 1; }
# v6 boot screen: nothing from the kernel, systemd or udev reaches tty1; no cursor, no penguin. The
# kernel's console moves to tty3 (the serial console stays for debugging). loglevel=0: not even an
# error line on the picture; ignore_loglevel on a serial boot brings them all back.
BOOTQ="quiet loglevel=0 vt.global_cursor_default=0 logo.nologo console=tty3 systemd.show_status=false rd.systemd.show_status=false rd.udev.log_level=0 udev.log_level=0"
sed -i "/^systemd_cmdline=/ s/$/ $BOOTQ/" $R/boot/systemd.cfg
grep -q 'vt.global_cursor_default=0 logo.nologo console=tty3' $R/boot/systemd.cfg || { echo "boot screen cmdline not set"; exit 1; }
# Every console= gets the kernel's messages, so Photon's own console=tty0/tty1 must not stay either.
sed -i -E '/^photon_cmdline=/ { s/(^|[= ])console=tty[01]( |$)/\1\2/g; s/(^|[= ])console=tty[01]( |$)/\1\2/g; s/  +/ /g }' $R/boot/photon.cfg
grep '^photon_cmdline=' $R/boot/photon.cfg | sed 's/^/  /'
! grep -E '^photon_cmdline=.*console=tty[01]( |$)' $R/boot/photon.cfg || { echo "photon_cmdline still sends the console to tty0/tty1"; exit 1; }
cat $R/boot/systemd.cfg
# grub (no menu, no wait, the picture as background) and u-boot (no delay, its text on serial only).
install -D -m 0644 $R/usr/share/alnasl/splash/alnasl-splash.png $R/boot/grub2/alnasl-splash.png
bash $W/bootscreen.sh $R $B
sed -i 's/\r$//' $B/config.txt
! grep -q 'disable_overscan\|core_freq_min' $B/config.txt || { echo "config.txt already has overscan/core_freq_min lines"; exit 1; }
awk '
  { print }
  /^\[pi4\]/ { print "# Keep the core clock (shared with peripherals) at 500 MHz: no scaling while the display driver reprograms it."; print "core_freq_min=500" }
  /^\[all\]/ { print "# No overscan: use the whole screen (the default made the framebuffer 1824x984 on a 1920x1080 display)."; print "disable_overscan=1"
               print "# v6 boot screen: no rainbow square at power-on."; print "disable_splash=1" }
' $B/config.txt > $W/config.txt.new
cat $W/config.txt.new > $B/config.txt
grep -q '^disable_overscan=1' $B/config.txt && grep -q '^core_freq_min=500' $B/config.txt && grep -q '^disable_splash=1' $B/config.txt || { echo "config.txt edit failed"; exit 1; }
cat $B/config.txt

# --- 12. close up -----------------------------------------------------------------------
cumount $R
rm -rf $R/var/cache/tdnf/* $R/tmp/* $R/root/.bash_history 2>/dev/null || true
sync
fstrim -v $R || true
umount $B $R
e2fsck -fn ${L}p2 | tail -2
e2fsck -fn ${L}p4 | tail -1
losetup -d $L; trap - EXIT
echo "image: $(ls -la $IMG)"
