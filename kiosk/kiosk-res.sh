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
# v7.7: the nunki screens laid out LIVE (docs/nunki-displays.md, "Live boards on HDMI"). The two-window X client calls
# it once at its start; the setup app calls it (docker exec) when the wizard changes a resolution or which monitor shows
# what, so nothing restarts but the windows whose place or job changed.
#   kiosk-res layout <extend|mirror|single> <X1> <job1> <mode1> <rot1> <X2> <job2> <mode2> <rot2>
#     X1/X2: xrandr names (HDMI-1); job: manage|hall1|hall2|off; mode: auto|WxH (one the output lists)
# Writes $RUN/win-1 and $RUN/win-2 ("job WxH+X+Y", read by the window loops before every start), $RUN/outputs (identify)
# and the layout part of $STATE; then ends each window whose line changed, and its loop starts it again where it now goes.
RUN=${KIOSK_RUN:-/run/alnasl-kiosk}
TMPD=${KIOSK_TMP:-/tmp}
STATE=$RUN/state
layout() {
  lay=$1; x1=$2; j1=$3; m1=$4; r1=$5; x2=$6; j2=$7; m2=$8; r2=$9
  case "$lay" in extend|mirror|single) ;; *) echo "bad layout"; return 2 ;; esac
  for v in "$x1" "$x2"; do case "$v" in HDMI-[0-9]|HDMI-[0-9][0-9]) ;; *) echo "bad output"; return 2 ;; esac; done
  for v in "$j1" "$j2"; do case "$v" in manage|hall1|hall2|off) ;; *) echo "bad job"; return 2 ;; esac; done
  for v in "$m1" "$m2"; do case "$v" in auto) ;; [0-9]*x[0-9]*) case "$v" in *[!0-9x]*|*x*x*|*x) echo "bad mode"; return 2 ;; esac ;; *) echo "bad mode"; return 2 ;; esac; done
  for v in "$r1" "$r2"; do case "$v" in normal|right|inverted|left) ;; *) echo "bad rotation"; return 2 ;; esac; done
  pick() { if [ "$1" = auto ]; then echo "--auto"; else echo "--mode $1"; fi; }
  case "$lay" in
    mirror) second="--output $x2 $(pick "$m2") --rotate $r1 --same-as $x1"; j2=off ;;
    single) second="--output $x2 --off"; j2=off ;;
    *) second="--output $x2 $(pick "$m2") --rotate $r2 --right-of $x1" ;;
  esac
  # shellcheck disable=SC2046,SC2086
  r=$(xrandr --output "$x1" $(pick "$m1") --rotate "$r1" --pos 0x0 --primary $second 2>&1) || { echo "xrandr could not lay out $x1 and $x2 ($lay): $r" | head -n 3; xfail=1; }
  geom() { xrandr --current 2>/dev/null | awk -v o="$1" '$1 == o && / connected/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit } }'; }
  g1=$(geom "$x1"); g2=$(geom "$x2")
  if [ -z "$g1" ]; then
    sz=$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\).*/\1x\2/p' | head -n 1)
    g1="${sz:-1920x1080}+0+0"; g2=""
    echo "xrandr does not show $x1 as connected; one window over the whole screen ($g1)"
  fi
  [ -z "$g2" ] && j2=off
  mkdir -p "$RUN"
  w1="$j1 $g1"; w2="$j2 ${g2:-none}"
  { echo "1 $x1 $j1 $g1"
    if [ "$lay" = mirror ] && [ -n "$g2" ]; then echo "2 $x2 mirror $g2"; elif [ "$j2" != off ]; then echo "2 $x2 $j2 $g2"; fi
  } > "$RUN/outputs.new" && mv -f "$RUN/outputs.new" "$RUN/outputs"
  tail=$(sed -n 's/.*\( scale=.*\)$/\1/p' "$STATE" 2>/dev/null | head -n 1)
  echo "path=x driver=modesetting layout=$lay $x1=$j1@$g1 $x2=$j2@${g2:-none}$tail" > "$STATE"
  n=1
  for w in "$w1" "$w2"; do
    old=$(cat "$RUN/win-$n" 2>/dev/null)
    echo "$w" > "$RUN/win-$n.new" && mv -f "$RUN/win-$n.new" "$RUN/win-$n"
    if [ "$old" != "$w" ] && [ -r "$TMPD/win-$n.pid" ]; then
      p=$(cat "$TMPD/win-$n.pid"); case "$p" in ''|*[!0-9]*) ;; *) kill -TERM "$p" 2>/dev/null ;; esac
    fi
    n=$((n + 1))
  done
  echo "x: $lay, $x1 $j1 ${m1}/$r1 at $g1, $x2 $j2 ${m2}/$r2 at ${g2:-none}"
  [ -z "${xfail:-}" ]
}
case "$1" in layout) shift; [ $# = 9 ] || { echo "usage: kiosk-res layout <extend|mirror|single> X1 job1 mode1 rot1 X2 job2 mode2 rot2"; exit 2; }; layout "$@"; exit $? ;; esac
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
  *) echo "usage: kiosk-res apply|wait-apply <connector|-> <WxH|auto> [normal|right|inverted|left] | layout ..."; exit 2 ;;
esac
