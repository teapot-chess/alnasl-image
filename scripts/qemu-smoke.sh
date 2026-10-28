#!/bin/bash
# Runs on the build VM. Boots the finished image's kernel+initrd+root under
# QEMU's raspi4b machine (TCG, no KVM) for a few minutes and keeps the serial
# console log. QEMU's raspi4b models neither Ethernet nor USB nor the GPU, so
# this proves: kernel+dtb+initrd+root mount, systemd boots, our units start or
# fail the way we expect, the firewall unit runs. It cannot prove HDMI/Wi-Fi/USB.
# Needs docker image qemu-sys:trixie (Debian trixie + qemu-system-arm).
set -euo pipefail
W=/root/w-photon-img5
T=${1:-480}
# Host CPUs for the TCG guest (raspi4b insists on exactly 4 vCPUs). On a loaded build host a 4-CPU quota
# throttled the vCPU threads mid-IRQ-setup (2026-10-27: soft lockups in __setup_irq while mmc_block loaded):
# QEMU_CPUS=8 gives them headroom.
CPUS=${QEMU_CPUS:-4}
cd $W
# QEMU_SECOND_BOOT=1: boot the disk the previous run left (first-boot work done: data grown, hwdb
# rebuilt, docker store loaded): what every later boot of a box looks like. Its serial logs replace the first run's.
# QEMU_MODE_TXT=slave (or master) with QEMU_SECOND_BOOT=1: first puts alnasl-mode.txt with that word on the card's
# boot (FAT) partition, as a person would from a PC, so the box comes up in that mode (docs/v6-plan.md section 1).
# The card is flattened to raw, the file put on partition 1 through a loop device, and converted back (the host has
# no nbd module and no qemu-nbd).
if [ "${QEMU_SECOND_BOOT:-0}" = 1 ] && [ -f qemu/sd.qcow2 ]; then
  SECOND=1; rm -f qemu/ttyAMA0.log qemu/ttyS0.log; touch qemu/ttyAMA0.log qemu/ttyS0.log
  if [ -n "${QEMU_MODE_TXT:-}" ]; then
    case "$QEMU_MODE_TXT" in master|slave) ;; *) echo "QEMU_MODE_TXT must be master or slave"; exit 1 ;; esac
    docker run --rm -v $W:/w qemu-sys:trixie qemu-img convert -O raw /w/qemu/sd.qcow2 /w/qemu/sd.raw
    L=$(losetup -f --show -P qemu/sd.raw)
    mkdir -p qm; mount ${L}p1 qm
    printf '%s\r\n' "$QEMU_MODE_TXT" > qm/alnasl-mode.txt
    ls -la qm/alnasl-mode.txt
    umount qm; losetup -d $L
    docker run --rm -v $W:/w qemu-sys:trixie qemu-img convert -f raw -O qcow2 /w/qemu/sd.raw /w/qemu/sd-mode.qcow2
    mv -f qemu/sd-mode.qcow2 qemu/sd.qcow2; rm -f qemu/sd.raw
  fi
else
SECOND=0
rm -rf qemu && mkdir qemu && touch qemu/ttyAMA0.log qemu/ttyS0.log
L=$(losetup -f --show -P -r photon-alnasl-v6.img)
mkdir -p qm
mount -o ro,noload ${L}p2 qm; cp qm/boot/vmlinuz-6.1.10-11.ph5 qm/boot/initrd.img-6.1.10-11.ph5 qemu/; umount qm
mount -o ro ${L}p1 qm; cp qm/bcm2711-rpi-4-b.dtb qemu/; umount qm
losetup -d $L
docker run --rm -v $W:/w qemu-sys:trixie qemu-img create -f qcow2 -b /w/photon-alnasl-v6.img -F raw /w/qemu/sd.qcow2 8G >/dev/null   # v6 A/B: 8G (a power of two, as raspi4b wants) > the 6.6 GB image, so alnasl-data has room to grow the data partition
fi
# modprobe.blacklist=bcm2835_wdt: QEMU's bcm2835 power manager does not model the watchdog's countdown; it
# resets the machine the moment the driver arms it, which systemd does right after switch-root (v6 enables
# the watchdog). Without this the smoke test only boot-loops. The real Pi counts down 15 s as it should.
CMD="modprobe.blacklist=bcm2835_wdt root=PARTUUID=416c6e73-02 alnasl.slot=A rootwait rw panic=10 init=/lib/systemd/systemd net.ifnames=0 systemd.unified_cgroup_hierarchy=yes console=ttyAMA0,115200 console=ttyS0,115200 earlycon=pl011,mmio32,0xfe201000 ignore_loglevel loglevel=7 systemd.log_target=console systemd.log_level=info systemd.show_status=1"
timeout $((T+30)) docker run --rm --cpus $CPUS -v $W:/w qemu-sys:trixie timeout $T qemu-system-aarch64 \
  -M raspi4b -m 2G -smp 4 -display none -monitor none -serial file:/w/qemu/ttyAMA0.log -serial file:/w/qemu/ttyS0.log \
  -kernel /w/qemu/vmlinuz-6.1.10-11.ph5 -initrd /w/qemu/initrd.img-6.1.10-11.ph5 \
  -dtb /w/qemu/bcm2711-rpi-4-b.dtb -append "$CMD" \
  -drive file=/w/qemu/sd.qcow2,if=sd,format=qcow2 \
  > $W/qemu-boot.log 2>&1 || true
wc -l $W/qemu-boot.log $W/qemu/ttyAMA0.log $W/qemu/ttyS0.log
