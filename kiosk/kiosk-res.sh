#!/bin/sh
# /usr/local/bin/kiosk-res (inside the kiosk container). Sets the screen mode on whichever
# display path is running (read from /run/alnasl-kiosk/state: path=cage or path=x).
#   kiosk-res apply <connector|-> <WxH|auto> [normal|right|inverted|left]   exit 0 = done; prints one line either way
#   kiosk-res wait-apply <connector|-> <WxH|auto> [rotation]   (kiosk.sh at start: waits for the compositor)
# cage: wlr-randr over the Wayland socket. X: xrandr (works with the modesetting driver;
# the fbdev driver has a single mode and answers with an error, which is reported).
# v7.3: a mode the screen does not list (a 3.5-inch screen's 480x320, or 640x480 from a screen whose EDID
# forgot it) is added first (xrandr --newmode/--addmode; gtf computes the timings, 640x480 gets the VGA
# standard ones); the rotation is X's (xrandr --rotate; right = 90 degrees clockwise). cage: no rotation.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DISPLAY=${DISPLAY:-:0}
STATE=/run/alnasl-kiosk/state
cmd=$1; conn=$2; mode=$3; rot=${4:-normal}
case "$mode" in auto) ;; [0-9]*x[0-9]*) case "$mode" in *[!0-9x]*) echo "bad mode"; exit 2 ;; esac ;; *) echo "bad mode"; exit 2 ;; esac
case "$conn" in *[!A-Za-z0-9-]*) echo "bad connector"; exit 2 ;; esac
case "$rot" in normal|right|inverted|left) ;; *) echo "bad rotation"; exit 2 ;; esac
[ "$conn" = "-" ] && conn=""

apply_cage() {
  out=$(wlr-randr 2>&1) || { echo "wlr-randr failed: $out" | head -n 3; return 1; }
  name=$(echo "$out" | awk -v c="$conn" '/^[^ ]/ && (c=="" || $1==c) {print $1; exit}')
  [ -z "$name" ] && name=$(echo "$out" | awk '/^[^ ]/ {print $1; exit}')
  [ -z "$name" ] && { echo "wlr-randr lists no output"; return 1; }
  if [ "$mode" = auto ]; then
    want=$(echo "$out" | awk -v n="$name" '/^[^ ]/ {on=($1==n)} on && /preferred/ {print $1; exit}')
    [ -z "$want" ] && { echo "no preferred mode listed for $name"; return 1; }
  else want=$mode; fi
  r=$(wlr-randr --output "$name" --mode "$want" 2>&1) || { echo "wlr-randr --mode $want failed: $r" | head -n 3; return 1; }
  [ "$rot" != normal ] && echo "cage: rotation $rot is not done on this path (X only)"
  echo "cage: $name set to $want"
}
# The timings of a mode the screen did not offer: VGA's own for 640x480 (every HDMI sink must take it),
# gtf's for anything else.
modeline() { # WxH
  if [ "$1" = 640x480 ]; then echo "25.175 640 656 752 800 480 490 492 525 -hsync -vsync"; return; fi
  gtf "${1%x*}" "${1#*x}" 60 2>/dev/null | sed -n 's/^ *Modeline "[^"]*" *//p' | head -n 1
}
apply_x() {
  out=$(xrandr --current 2>&1) || { echo "xrandr failed: $out" | head -n 3; return 1; }
  name=$(echo "$out" | awk '/ connected/ {print $1; exit}')
  [ -z "$name" ] && { echo "xrandr lists no connected output"; return 1; }
  use=$mode
  if [ "$mode" != auto ] && ! echo "$out" | awk -v n="$name" -v m="$mode" '/^[^ ]/ {on=($1==n)} on && /^   / && $1==m {f=1} END {exit !f}'; then
    ml=$(modeline "$mode")
    [ -z "$ml" ] && { echo "no timings for $mode"; return 1; }
    use="${mode}_alnasl"
    # shellcheck disable=SC2086
    xrandr --newmode "$use" $ml >/dev/null 2>&1   # already there after a browser restart: fine
    r=$(xrandr --addmode "$name" "$use" 2>&1) || { echo "xrandr --addmode $use failed: $r" | head -n 3; return 1; }
    echo "x: $mode is not in the screen's list; added ($ml)"
  fi
  if [ "$mode" = auto ]; then r=$(xrandr --output "$name" --auto --rotate "$rot" 2>&1); else r=$(xrandr --output "$name" --mode "$use" --rotate "$rot" 2>&1); fi \
    || { echo "xrandr failed: $r" | head -n 3; return 1; }
  echo "x: $name set to $mode, rotation $rot"
}
apply() {
  if grep -q '^path=x' "$STATE" 2>/dev/null; then apply_x; else apply_cage; fi
}
case "$cmd" in
  apply) apply ;;
  wait-apply)
    i=0
    while [ $i -lt 40 ]; do
      if grep -q '^path=x' "$STATE" 2>/dev/null; then xrandr --current >/dev/null 2>&1 && break
      else wlr-randr >/dev/null 2>&1 && break; fi
      i=$((i+1)); sleep 1
    done
    apply ;;
  *) echo "usage: kiosk-res apply|wait-apply <connector|-> <WxH|auto> [normal|right|inverted|left]"; exit 2 ;;
esac
