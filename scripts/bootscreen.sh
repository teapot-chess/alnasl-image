#!/bin/bash
# v6 boot screen, the boot loaders' part. Run by assemble.sh on the build VM:
#
#     bash bootscreen.sh ROOT BOOT
#
# grub: no menu, no wait, no text, and the Alnasl picture as the background of its graphics
# terminal (only when this grub can do that: gfxterm and png present, built in or as modules).
#
# u-boot: bootdelay=0 and its console on the serial port only (nothing on HDMI), written to
# uboot.env on the boot partition. The environment is u-boot's own default one (read out of
# u-boot-rpi4.bin) or the uboot.env already there, with those keys changed; if neither can be read
# with certainty, nothing is written and u-boot keeps its defaults. A uboot.env of the wrong size
# is ignored by u-boot ("bad CRC, using default environment"), so the worst case of a wrong guess
# is the v5 behaviour. ALNASL_NO_UBOOT_ENV=1 skips this part. The u-boot part is uboot-env.exs,
# run in the Elixir image on a staging copy of the two files it needs (assemble.sh's mounts live
# in a private mount namespace the docker daemon cannot see).
set -euo pipefail
[ $# -eq 2 ] || { sed -n '2,15p' "$0"; exit 1; }
ROOT=${1%/}; BOOT=${2%/}
HERE=$(cd "$(dirname "$0")" && pwd)
ELIXIR_IMAGE=${ELIXIR_IMAGE:-hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim}

say() { echo "bootscreen: $*"; }

# ------------------------------------------------------------------ grub --

# gfxterm + png: as module files grub can load, or built into the EFI image. Prints what it found.
grub_can_draw() {
  local d f
  for d in "$ROOT/boot/grub2/arm64-efi" "$ROOT/usr/lib/grub/arm64-efi"; do
    if [ -f "$d/gfxterm.mod" ] && [ -f "$d/png.mod" ] && [ -f "$d/gfxterm_background.mod" ]; then
      echo "modules in $d"; return 0
    fi
  done
  while IFS= read -r f; do
    if grep -aq gfxterm "$f" && grep -aq background_image "$f" && grep -aq png "$f"; then
      echo "built into ${f#"$BOOT"}"; return 0
    fi
  done < <(find "$BOOT" -type f -iname '*.efi')
  return 1
}

# The block put in front of the first menuentry (and the blank line after it).
block_draw() {
  cat <<'BLK'

# Alnasl v6 boot screen: no menu, no text, the same picture as every other stage.
set timeout_style=hidden
set gfxmode=auto
set gfxpayload=keep
if loadfont unicode; then true; fi
if insmod gfxterm; then
  if insmod png; then
    terminal_output gfxterm
    background_image /boot/grub2/alnasl-splash.png
  fi
fi

BLK
}
block_plain() {
  printf '\n# Alnasl v6 boot screen: no menu.\nset timeout_style=hidden\n\n'
}

grub() {
  local cfgs=() c draw before t
  [ -f "$ROOT/boot/grub2/grub.cfg" ] && cfgs+=("$ROOT/boot/grub2/grub.cfg")
  while IFS= read -r c; do cfgs+=("$c"); done < <(find "$BOOT" -type f -name grub.cfg)
  if [ ${#cfgs[@]} -eq 0 ]; then
    say "WARNING: no grub.cfg found; grub left as it is"; return 0
  fi
  if draw=$(grub_can_draw); then :; else draw=""; fi
  say "grub can draw the picture: ${draw:-no (gfxterm/png not found); timeout only}"
  t=$(mktemp)
  for c in "${cfgs[@]}"; do
    cp "$c" "$t"
    if grep -Eq '^[[:space:]]*set[[:space:]]+timeout=' "$t"; then
      sed -E -i 's/^([[:space:]]*)set[[:space:]]+timeout=[^[:space:]]*/\1set timeout=0/' "$t"
    elif grep -q menuentry "$t"; then
      { echo "set timeout=0"; cat "$t"; } > "$t.n"; cat "$t.n" > "$t"; rm -f "$t.n"
    fi
    # grub's own lines on the screen ("Loading Linux ..."): only reported. Taking them out could
    # leave an empty if-block, which grub refuses; with u-boot on serial they go there anyway.
    grep -E '^[[:space:]]*echo([^[:alnum:]_]|$)' "$t" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
      while IFS= read -r line; do say "  NOTE $(basename "$c") still has: $line"; done || true
    if grep -q menuentry "$t" && ! grep -q "Alnasl v6 boot screen" "$t"; then
      if [ -n "$draw" ]; then block_draw > "$t.b"; else block_plain > "$t.b"; fi
      awk -v bf="$t.b" '
        !done && index($0, "menuentry") { while ((getline l < bf) > 0) print l; done = 1 }
        { print }' "$t" > "$t.n"
      cat "$t.n" > "$t"; rm -f "$t.n" "$t.b"
    fi
    if ! cmp -s "$c" "$t"; then
      cat "$t" > "$c"
      case $c in "$ROOT"*) say "edited ${c#"$ROOT"}" ;; *) say "edited $c" ;; esac
    fi
    grep -E '^[[:space:]]*(set[[:space:]]+timeout|set[[:space:]]+timeout_style|terminal_output|background_image|set[[:space:]]+gfx)' "$t" |
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
      while IFS= read -r line; do say "  $(basename "$c"): $line"; done || true
  done
  rm -f "$t"
}

# ---------------------------------------------------------------- u-boot --

uboot() {
  if [ "${ALNASL_NO_UBOOT_ENV:-}" = 1 ]; then
    say "u-boot: skipped (ALNASL_NO_UBOOT_ENV=1)"; return 0
  fi
  local S; S=$(mktemp -d "${TMPDIR:-/tmp}/uboot-env.XXXXXX")
  [ -f "$BOOT/uboot.env" ] && cp "$BOOT/uboot.env" "$S/"
  [ -f "$BOOT/u-boot-rpi4.bin" ] && cp "$BOOT/u-boot-rpi4.bin" "$S/"
  if [ -n "${UBOOT_ENV_ELIXIR:-}" ]; then   # tests: a local elixir instead of docker
    elixir "$HERE/uboot-env.exs" "$S"
  else
    docker run --rm -v "$HERE:$HERE:ro" -v "$S:$S" -w "$S" "$ELIXIR_IMAGE" elixir "$HERE/uboot-env.exs" "$S"
  fi
  if [ -f "$S/uboot.env" ]; then cat "$S/uboot.env" > "$BOOT/uboot.env"; fi
  rm -rf "$S"
}

grub
uboot
