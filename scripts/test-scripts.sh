#!/bin/bash
# Local checks for the shell and Elixir replacements of the build's old Python helpers:
#   bash scripts/test-scripts.sh        (Git Bash on the PC, or on the build VM; needs coreutils, sed, awk, gzip
#                                        and either a local `elixir` or docker for the .exs parts)
# It runs the same snippets assemble.sh uses (the PNG magic check, the tdnf.conf append, the grubenv),
# bootscreen.sh on a fake root and boot partition, uboot-env.exs and release-index.exs, on temp files, and
# compares bytes. If you change one of those snippets in assemble.sh, change it here too.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXIR_IMAGE=${ELIXIR_IMAGE:-hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', wanted '$2')"; fi; }
sum() { cksum < "$1" | cut -d' ' -f1,2; }
rep() { local i s=""; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }

if command -v elixir >/dev/null; then
  export UBOOT_ENV_ELIXIR=1
  exs() { elixir "$@"; }
elif command -v docker >/dev/null; then
  exs() { docker run --rm -v "$HERE:$HERE:ro" -v "$T:$T" -w "$T" "$ELIXIR_IMAGE" elixir "$@"; }
else
  exs() { echo "no elixir, no docker"; return 1; }
fi

# --- the PNG magic check of assemble.sh -------------------------------------------------
png_ok() { [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; }
printf '\x89PNG\r\n\x1a\nrest' > "$T/good.png"; printf '\x89PNG\n\x1a\nrest' > "$T/crlf.png"
if png_ok "$T/good.png"; then ok "png check accepts a PNG"; else bad "png check accepts a PNG"; fi
if png_ok "$T/crlf.png"; then bad "png check refuses a CR-stripped PNG"; else ok "png check refuses a CR-stripped PNG"; fi
: > "$T/empty.png"
if png_ok "$T/empty.png"; then bad "png check refuses an empty file"; else ok "png check refuses an empty file"; fi

# --- the tdnf.conf append ---------------------------------------------------------------
tdnf_append() {
  local s; s=$(cat "$1")
  { printf '%s\n' "$s"; cat <<'EOT'

# Alnasl hall box: the kernel, its device trees, the GPU/driver packages, the
# firmware, the boot loaders and the Raspberry Pi firmware are matched to each
# other and must not be updated one at a time (a 6.12 kernel with 6.1 device
# trees left the Ethernet and Wi-Fi dead). To update them on purpose, in one go:
#   tdnf --disableexcludes=all update linux linux-drivers-gpu dtb-rpi4 ...
# and rebuild the out-of-tree modules for the new kernel (see README).
excludepkgs=linux linux-* dtb-* raspberrypi-firmware* u-boot* grub2* initramfs
EOT
  } > "$1.new"
  cat "$1.new" > "$1"; rm -f "$1.new"
}
printf '[main]\ngpgcheck=1\n\n\n' > "$T/tdnf.conf"; tdnf_append "$T/tdnf.conf"
check "$(head -n 4 "$T/tdnf.conf" | tr '\n' '|')" "[main]|gpgcheck=1||# Alnasl hall box: the kernel, its device trees, the GPU/driver packages, the|" "tdnf.conf: trailing blank lines collapsed to one, then the block"
check "$(tail -n 1 "$T/tdnf.conf")" "excludepkgs=linux linux-* dtb-* raspberrypi-firmware* u-boot* grub2* initramfs" "tdnf.conf: excludepkgs last"
check "$(wc -l < "$T/tdnf.conf" | tr -d ' ')" 10 "tdnf.conf: 10 lines in all"
printf '[main]' > "$T/tdnf2.conf"; tdnf_append "$T/tdnf2.conf"
check "$(head -n 3 "$T/tdnf2.conf" | tr '\n' '|')" "[main]||# Alnasl hall box: the kernel, its device trees, the GPU/driver packages, the|" "tdnf.conf without a final newline"

# --- the grubenv ------------------------------------------------------------------------
{ printf '# GRUB Environment Block\nalnasl_slot=A\nalnasl_try=none\nalnasl_tries=0\nalnasl_failed=none\n'; head -c 1024 /dev/zero | tr '\0' '#'; } | head -c 1024 > "$T/grubenv"
check "$(wc -c < "$T/grubenv" | tr -d ' ')" 1024 "grubenv is 1024 bytes"
check "$(head -c 89 "$T/grubenv" | tr '\n' '|')" '# GRUB Environment Block|alnasl_slot=A|alnasl_try=none|alnasl_tries=0|alnasl_failed=none|' "grubenv text"
check "$(tail -c +90 "$T/grubenv" | tr -d '#' | wc -c | tr -d ' ')" 0 "grubenv: only '#' after the text"

# --- bootscreen.sh: grub ----------------------------------------------------------------
mkdir -p "$T/r/boot/grub2" "$T/b/boot/grub2" "$T/b/EFI/BOOT"
printf 'set default=0\nset timeout=5\nmenuentry "x" {\n  echo Loading\n  linux /vmlinuz\n}\n' > "$T/r/boot/grub2/grub.cfg"
printf 'set timeout=0\nmenuentry "Alnasl" {\n  linux /vmlinuz\n}\n' > "$T/b/boot/grub2/grub.cfg"
out=$(ALNASL_NO_UBOOT_ENV=1 bash "$HERE/bootscreen.sh" "$T/r" "$T/b" 2>&1); rc=$?
check "$rc" 0 "bootscreen.sh exits 0"
if echo "$out" | grep -q 'grub can draw the picture: no (gfxterm/png not found); timeout only'; then ok "bootscreen: no gfxterm found, said so"; else bad "bootscreen: no gfxterm message"; fi
if echo "$out" | grep -q 'NOTE grub.cfg still has: echo Loading'; then ok "bootscreen: echo line noted"; else bad "bootscreen: echo note"; fi
check "$(sed -n '1,7p' "$T/r/boot/grub2/grub.cfg" | tr '\n' '|')" 'set default=0|set timeout=0||# Alnasl v6 boot screen: no menu.|set timeout_style=hidden||menuentry "x" {|' "bootscreen: timeout 0, plain block and a blank line in front of the menuentry"
check "$(grep -c 'Alnasl v6 boot screen' "$T/r/boot/grub2/grub.cfg")" 1 "bootscreen: block inserted once"
before=$(sum "$T/r/boot/grub2/grub.cfg"); ALNASL_NO_UBOOT_ENV=1 bash "$HERE/bootscreen.sh" "$T/r" "$T/b" >/dev/null 2>&1
check "$(sum "$T/r/boot/grub2/grub.cfg")" "$before" "bootscreen: idempotent"
# with the modules present: the picture block; a cfg with no timeout line gets one first
mkdir -p "$T/r/boot/grub2/arm64-efi"
for m in gfxterm png gfxterm_background; do : > "$T/r/boot/grub2/arm64-efi/$m.mod"; done
printf 'menuentry "x" {\n}\n' > "$T/b/boot/grub2/grub.cfg"
out=$(ALNASL_NO_UBOOT_ENV=1 bash "$HERE/bootscreen.sh" "$T/r" "$T/b" 2>&1)
check "$(sed -n '1,4p' "$T/b/boot/grub2/grub.cfg" | tr '\n' '|')" 'set timeout=0||# Alnasl v6 boot screen: no menu, no text, the same picture as every other stage.|set timeout_style=hidden|' "bootscreen: no timeout line, so one is put first; picture block follows"
if grep -q '^    background_image /boot/grub2/alnasl-splash.png$' "$T/b/boot/grub2/grub.cfg"; then ok "bootscreen: background_image line"; else bad "bootscreen: background_image line"; fi
check "$(tail -n 5 "$T/b/boot/grub2/grub.cfg" | head -n 3 | tr '\n' '|')" '  fi|fi||' "bootscreen: blank line between the block and the menuentry"
if echo "$out" | grep -q 'grub can draw the picture: modules in '; then ok "bootscreen: modules found"; else bad "bootscreen: modules message"; fi

# --- bootscreen: u-boot (uboot-env.exs) -------------------------------------------------
mkdir -p "$T/u"
{ head -c 3000 /dev/urandom | tr -d '\0'; printf '\0'
  printf 'arch=arm\0baudrate=115200\0board=rpi\0bootcmd=run distro_bootcmd\0bootdelay=2\0boot_targets=mmc0 usb0\0cpu=armv8\0fdtfile=x.dtb\0stderr=serial,vidconsole\0stdin=serial,usbkbd\0stdout=serial,vidconsole\0vendor=raspberrypi\0\0'
  printf 'tail junk\0'; } > "$T/u/u-boot-rpi4.bin"
exs "$HERE/uboot-env.exs" "$T/u" > "$T/u.out" 2>&1
check "$(wc -c < "$T/u/uboot.env" | tr -d ' ')" 16384 "uboot.env is 16384 bytes"
# the CRC32 of a body is in a gzip trailer: independent of the Elixir that wrote it
crc_hex() { tail -c +5 "$1" | gzip -c | tail -c 8 | head -c 4 | od -An -tx1 | tr -d ' \n'; }
check "$(head -c 4 "$T/u/uboot.env" | od -An -tx1 | tr -d ' \n')" "$(crc_hex "$T/u/uboot.env")" "uboot.env: CRC32 (little endian) of the rest"
check "$(tail -c +5 "$T/u/uboot.env" | tr '\0' '\n' | grep -v '^$' | tr '\n' ' ')" "arch=arm baudrate=115200 board=rpi bootcmd=run distro_bootcmd bootdelay=0 boot_targets=mmc0 usb0 cpu=armv8 fdtfile=x.dtb stderr=serial stdin=serial,usbkbd stdout=serial vendor=raspberrypi silent=1 " "uboot.env: defaults, four keys changed, order kept, silent appended"
if grep -q 'bootdelay: 2 -> 0' "$T/u.out" && grep -q 'silent: None -> 1' "$T/u.out"; then ok "uboot-env.exs: reports the changes"; else bad "uboot-env.exs: report"; fi
cp "$T/u/uboot.env" "$T/u/first.env"; rm "$T/u/u-boot-rpi4.bin"
exs "$HERE/uboot-env.exs" "$T/u" > "$T/u2.out" 2>&1
check "$(sum "$T/u/uboot.env")" "$(sum "$T/u/first.env")" "uboot.env: rerun from the existing file gives the same bytes"
if grep -q 'from the uboot.env already there' "$T/u2.out"; then ok "uboot-env.exs: reuses a valid uboot.env"; else bad "uboot-env.exs: reuse"; fi
printf 'garbage' > "$T/u/uboot.env"; exs "$HERE/uboot-env.exs" "$T/u" > "$T/u3.out" 2>&1
if grep -q 'bad CRC' "$T/u3.out" && grep -q 'no u-boot-rpi4.bin' "$T/u3.out"; then ok "uboot-env.exs: bad CRC and no binary: warned, nothing written"; else bad "uboot-env.exs: bad CRC path"; fi
# the whole of bootscreen.sh, u-boot included (staging copy, local elixir)
mkdir -p "$T/b2"; head -c 3000 /dev/urandom | tr -d '\0' > "$T/b2/u-boot-rpi4.bin"; printf '\0arch=arm\0bootcmd=x\0boot_targets=mmc0\0a1=1\0a2=2\0a3=3\0a4=4\0a5=5\0a6=6\0a7=7\0a8=8\0\0' >> "$T/b2/u-boot-rpi4.bin"
mkdir -p "$T/r2"
if [ -n "${UBOOT_ENV_ELIXIR:-}" ]; then
  bash "$HERE/bootscreen.sh" "$T/r2" "$T/b2" > "$T/bs.out" 2>&1
  check "$(wc -c < "$T/b2/uboot.env" 2>/dev/null | tr -d ' ')" 16384 "bootscreen.sh: uboot.env lands on the boot partition"
  if grep -q 'WARNING: no grub.cfg found' "$T/bs.out"; then ok "bootscreen.sh: no grub.cfg is a warning, not an error"; else bad "bootscreen.sh: no grub.cfg"; fi
fi

# --- make-release's index writer (release-index.exs) ---------------------------------------
mkdir -p "$T/rel"
A=$(rep a 64); B=$(rep b 64); C=$(rep c 64); D=$(rep d 64)
exs "$HERE/release-index.exs" "$T/rel" alnasl-system-v7.1.img.zst v7 7.1 https://example.org/dl/v7.1/ 1234 "$A" 5678 "$B" "" "first release" "" > "$T/ri.out" 2>&1
if grep -q '^index.json: 1 image(s): 7.1$' "$T/ri.out"; then ok "release-index.exs: first index"; else bad "release-index.exs: first index ($(cat "$T/ri.out"))"; fi
check "$(head -n 4 "$T/rel/index.json" | tr '\n' '|')" '{| "format": 1,| "images": [|  {|' "index.json layout (indent 1)"
check "$(head -n 1 "$T/rel/alnasl-system-v7.1.json")" '{' "the entry file is written too"
if grep -q '"min_from": null' "$T/rel/index.json"; then ok "min_from is null when empty"; else bad "min_from null"; fi
cp "$T/rel/index.json" "$T/old-index.json"
exs "$HERE/release-index.exs" "$T/rel" alnasl-system-v7.0.img.zst v7 7.0 https://example.org/dl/v7.0/ 1 "$C" 2 "$D" 7.0 "older, sorted first" "$T/old-index.json" > "$T/ri2.out" 2>&1
if grep -q '^index.json: 2 image(s): 7.0, 7.1$' "$T/ri2.out"; then ok "release-index.exs: merged and sorted by version"; else bad "release-index.exs: merge ($(cat "$T/ri2.out"))"; fi
cp "$T/rel/index.json" "$T/i1"
exs "$HERE/release-index.exs" "$T/rel" alnasl-system-v7.1.img.zst v7 7.1 https://example.org/dl/v7.1/ 9 "$A" 9 "$B" "" "again" "$T/i1" > "$T/ri3.out" 2>&1
if grep -q '^index.json: 2 image(s): 7.0, 7.1$' "$T/ri3.out"; then ok "release-index.exs: same version replaced, not duplicated"; else bad "release-index.exs: replace"; fi
exs "$HERE/release-index.exs" "$T/rel" alnasl-system-v7.1.img.zst v7 7.1 https://example.org/dl/v7.1/ 9 "$A" 9 "$B" "" "again" "$T/rel/index.json" > /dev/null 2>&1
cp "$T/rel/index.json" "$T/i2"
exs "$HERE/release-index.exs" "$T/rel" alnasl-system-v7.1.img.zst v7 7.1 https://example.org/dl/v7.1/ 9 "$A" 9 "$B" "" "again" "$T/i2" > /dev/null 2>&1
check "$(sum "$T/rel/index.json")" "$(sum "$T/i2")" "index.json: same inputs, same bytes (signature-stable)"


# --- the compact-screen CSS checks (test-compact-css.sh) -----------------------------------
if bash "$HERE/test-compact-css.sh" > "$T/css.out" 2>&1; then ok "test-compact-css.sh passes"; else bad "test-compact-css.sh ($(grep FAIL "$T/css.out" | head -n 2 | tr '\n' ' '))"; fi

# --- alnasl-cmdline-check (v7.4.2: the initrd gives up and restarts) -----------------------
CC="$HERE/../overlay/usr/local/sbin/alnasl-cmdline-check"
FIX="rd.timeout=90 rd.shell=0 rd.emergency=reboot"
cc() { ALNASL_CMDLINE="$T/cmdline" ALNASL_SYSTEMD_CFG="$T/systemd.cfg" bash "$CC"; }
printf '# GRUB Environment Block\nsystemd_cmdline=net.ifnames=0 quiet\n' > "$T/systemd.cfg"
echo "root=PARTUUID=416c6e73-02 rw quiet" > "$T/cmdline"
out=$(cc); rc=$?
check "$rc" 0 "cmdline-check exits 0 when the options are missing"
case $out in *"<3>alnasl-cmdline-check: this boot's kernel command line lacks $FIX"*) ok "cmdline-check: an error-priority line names what the running kernel lacks" ;; *) bad "cmdline-check error line ($out)" ;; esac
check "$(sed -n 2p "$T/systemd.cfg")" "systemd_cmdline=net.ifnames=0 quiet $FIX" "cmdline-check appends the missing options to systemd_cmdline"
check "$(sed -n 1p "$T/systemd.cfg")" "# GRUB Environment Block" "cmdline-check keeps the environment block header"
cp "$T/systemd.cfg" "$T/after1"; cc > /dev/null
check "$(sum "$T/systemd.cfg")" "$(sum "$T/after1")" "cmdline-check: a second run changes nothing"
printf '# GRUB Environment Block\nsystemd_cmdline=a rd.timeout=90 b\n' > "$T/systemd.cfg"; cc > /dev/null
check "$(sed -n 2p "$T/systemd.cfg")" "systemd_cmdline=a rd.timeout=90 b rd.shell=0 rd.emergency=reboot" "cmdline-check adds only what is missing"
printf '# GRUB Environment Block\nsystemd_cmdline=a rd.timeout=900 b\n' > "$T/systemd.cfg"; cc > /dev/null
case " $(sed -n 2p "$T/systemd.cfg") " in *" rd.timeout=90 "*) ok "cmdline-check matches whole words (rd.timeout=900 is not rd.timeout=90)" ;; *) bad "cmdline-check took rd.timeout=900 for rd.timeout=90" ;; esac
echo "BOOT_IMAGE=x $FIX" > "$T/cmdline"; printf '# GRUB Environment Block\nsystemd_cmdline=q %s\n' "$FIX" > "$T/systemd.cfg"
out=$(cc)
case $out in *"<3>"*) bad "cmdline-check reports an error with everything in place ($out)" ;; *) ok "cmdline-check: everything in place, no error" ;; esac
rm -f "$T/systemd.cfg"; out=$(cc); rc=$?
case $out in *"<3>"*"is missing"*) check "$rc$( [ -e "$T/systemd.cfg" ] && echo made)" 0 "cmdline-check: no systemd.cfg is reported, not made" ;; *) bad "cmdline-check without systemd.cfg ($out)" ;; esac
for f in "$HERE/grub-ab.cfg" "$HERE/assemble.sh" "$HERE/verify.sh" "$CC"; do
  grep -q -F "$FIX" "$f" && ok "$(basename "$f") names the same option list" || bad "$(basename "$f") does not have the option list '$FIX'"
done
echo
if [ $fails -eq 0 ]; then echo "all scripts checks passed"; else echo "$fails failed"; fi
exit $((fails > 0))
