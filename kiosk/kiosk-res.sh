#!/bin/sh
# /usr/local/bin/kiosk-res (inside the kiosk container). Sets the screen mode on whichever
# display path is running (read from /run/alnasl-kiosk/state: path=cage or path=x).
#   kiosk-res apply <connector|-> <WxH|auto>   exit 0 = done; prints one line either way
#   kiosk-res wait-apply <connector|-> <WxH|auto>   (kiosk.sh at start: waits for the compositor)
# cage: wlr-randr over the Wayland socket. X: xrandr (works with the modesetting driver;
# the fbdev driver has a single mode and answers with an error, which is reported).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DISPLAY=${DISPLAY:-:0}
STATE=/run/alnasl-kiosk/state
cmd=$1; conn=$2; mode=$3
case "$mode" in auto) ;; [0-9]*x[0-9]*) case "$mode" in *[!0-9x]*) echo "bad mode"; exit 2 ;; esac ;; *) echo "bad mode"; exit 2 ;; esac
case "$conn" in *[!A-Za-z0-9-]*) echo "bad connector"; exit 2 ;; esac
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
  echo "cage: $name set to $want"
}
apply_x() {
  out=$(xrandr --current 2>&1) || { echo "xrandr failed: $out" | head -n 3; return 1; }
  name=$(echo "$out" | awk '/ connected/ {print $1; exit}')
  [ -z "$name" ] && { echo "xrandr lists no connected output"; return 1; }
  if [ "$mode" = auto ]; then r=$(xrandr --output "$name" --auto 2>&1); else r=$(xrandr --output "$name" --mode "$mode" 2>&1); fi \
    || { echo "xrandr failed: $r" | head -n 3; return 1; }
  echo "x: $name set to $mode"
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
  *) echo "usage: kiosk-res apply|wait-apply <connector|-> <WxH|auto>"; exit 2 ;;
esac
