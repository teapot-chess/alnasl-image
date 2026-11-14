#!/bin/sh
# Runs INSIDE the kiosk container (the shipped /kiosk.sh, with stub cage / xinit / chromium first in PATH and a
# fake DRM tree). Proves the display-path logic without a Pi:
#   1. default mode = X, modesetting first when there is a KMS card, then fbdev, then vt7; cage never started
#   2. an X server that never comes up is killed after its budget and the next driver gets its turn
#   3. cage that HANGS (the real-Pi failure) is killed with its process group after its budget, X follows
#   4. cage that works (a browser appears) is left alone, X is not started
#   5. no KMS card -> fbdev straight away
#   6. (v7.3) a 3.5-inch HDMI stylus screen: forced mode and xrandr rotation
#   7. (v7.3) an SPI panel: its card only, no second GPU, its fb for the fallback
# Prints "ok"/"FAIL" lines; exit status 1 on any failure.
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
T=/tmp/kt; rm -rf $T; mkdir -p $T/stubs $T/drm/card0-HDMI-A-1 $T/dri $T/run $T/tmp
echo connected > $T/drm/card0-HDMI-A-1/status
printf '1920x1080\n1280x720\n' > $T/drm/card0-HDMI-A-1/modes
: > $T/dri/card0
cat > $T/stubs/curl <<'EOF'
#!/bin/sh
exit 0
EOF
# xinit stubs: "quick" returns at once (X dies), "hang" never touches x-up and never returns, "up" touches x-up then lives 3 s
cat > $T/stubs/xinit <<'EOF'
#!/bin/sh
echo "XINIT $*" >> /tmp/kt/xinit.log
cp /tmp/kt/tmp/xorg.conf /tmp/kt/xorg.$(wc -l < /tmp/kt/xinit.log).conf
cp /tmp/kt/tmp/xclient.sh /tmp/kt/xclient.$(wc -l < /tmp/kt/xinit.log).sh 2>/dev/null
case "$(cat /tmp/kt/xmode 2>/dev/null)" in
  hang) trap 'exit 0' TERM; while :; do sleep 1; done ;;
  up) touch /tmp/kt/tmp/x-up; sleep 3; exit 0 ;;
  *) exit 0 ;;
esac
EOF
# cage stubs: "hang" = prints the real message and hangs, "works" = starts a chromium stub and runs 3 s
cat > $T/stubs/cage <<'EOF'
#!/bin/sh
echo "CAGE $*" >> /tmp/kt/cage.log
case "$(cat /tmp/kt/cagemode 2>/dev/null)" in
  works) cp /tmp/kt/stubs/chromium-stub /tmp/kt/stubs/chromium 2>/dev/null; /tmp/kt/stubs/chromium & sleep 3; kill $! 2>/dev/null; exit 0 ;;
  *) echo "Unable to drop root (we shouldn't be able to restore it after setuid), refusing to start"; trap '' TERM; while :; do sleep 1; done ;;
esac
EOF
cat > $T/stubs/chromium-stub <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
chmod 755 $T/stubs/*

run() { # $1 = KIOSK_MODE, rest = extra env; log -> $T/out.log; returns kiosk.sh's exit status
  m=$1; shift
  rm -f $T/xinit.log $T/cage.log $T/tmp/x-up $T/xclient.*.sh
  env PATH=$T/stubs:$PATH KIOSK_MODE=$m KIOSK_RUN=$T/run KIOSK_TMP=$T/tmp KIOSK_DRM=$T/drm KIOSK_DEVDRI=$T/dri \
      KIOSK_NO_WATCHDOG=1 XDG_RUNTIME_DIR=$T/xdg "$@" sh /kiosk.sh > $T/out.log 2>&1
  return $?
}
count() { # pattern file
  c=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${c:-0}"
}

echo quick > $T/xmode
echo "-- 1. default mode"
run "" ; rc=$?
grep -q 'mode=x' $T/out.log && ok "default KIOSK_MODE is x" || bad "default mode is not x"
[ "$(count CAGE $T/cage.log)" = 0 ] && ok "cage was never started" || bad "cage was started by default"
grep -q 'starting X (modesetting driver, .*/card0)' $T/out.log && ok "X starts with the modesetting driver on the KMS card" || bad "no modesetting start"
grep -q 'falling back to fbdev' $T/out.log && grep -q 'starting X (fbdev driver' $T/out.log && ok "fallback to fbdev when modesetting ends early" || bad "no fbdev fallback"
grep -q 'trying vt7' $T/out.log && ok "vt7 is the last resort" || bad "no vt7 step"
[ "$rc" = 1 ] && ok "all X attempts failing exits 1 (supervisor backs off, no hang)" || bad "exit status $rc"
grep -q 'Driver "modesetting"' $T/xorg.1.conf && grep -q 'kmsdev" ".*/card0"' $T/xorg.1.conf && grep -q 'AccelMethod" "none"' $T/xorg.1.conf && ok "xorg.conf of attempt 1: modesetting + kmsdev + no glamor" || bad "attempt 1 xorg.conf"
grep -q 'Driver "fbdev"' $T/xorg.2.conf && ok "xorg.conf of attempt 2: fbdev" || bad "attempt 2 xorg.conf"
grep -q 'BlankTime" "0"' $T/xorg.1.conf && grep -q 'OffTime" "0"' $T/xorg.1.conf && grep -q 'DPMS" "false"' $T/xorg.1.conf && grep -q 'BlankTime" "0"' $T/xorg.2.conf && ok "xorg.conf (both drivers) turns screen blanking and DPMS off" || bad "no ServerFlags"
grep -q 'xset s off s noblank -dpms' $T/tmp/xclient.sh && ok "xclient.sh runs xset s off s noblank -dpms before the browser" || bad "no xset"
grep -q 'XkbLayout" "be"' $T/xorg.1.conf && grep -q 'MatchIsTouchscreen' $T/xorg.1.conf && ok "keyboard layout and touch InputClass are in the X config" || bad "InputClass"
grep -q 'xclient.sh' $T/xinit.log && grep -q -- '-config' $T/xinit.log && ok "xinit starts the client and Xorg with -config" || bad "xinit arguments"
grep -q 'until curl' $T/tmp/xclient.sh && grep -q 'exec /usr/bin/chromium' $T/tmp/xclient.sh && ok "the X client waits for the menu server itself (overlapped with X start) and execs chromium" || bad "xclient content"

echo "-- 2. X that never comes up"
echo hang > $T/xmode
s0=$(date +%s)
run x KIOSK_X_BUDGET=2 ; rc=$?
s1=$(date +%s)
grep -q 'was not up after 2 s; killing it' $T/out.log && ok "an X server that does not come up is killed after its budget" || bad "no X kill message"
[ "$(count 'starting X' $T/out.log)" -ge 2 ] && ok "next driver got its turn ($(count 'starting X' $T/out.log) X starts)" || bad "no second X start"
[ $((s1 - s0)) -lt 25 ] && ok "whole sequence took $((s1 - s0)) s with a 2 s budget (no endless wait)" || bad "took $((s1 - s0)) s"
pkill -KILL -f 'stubs/xinit' 2>/dev/null

echo "-- 3. cage that hangs"
echo quick > $T/xmode; echo hang > $T/cagemode
s0=$(date +%s)
run cage KIOSK_CAGE_BUDGET=4 ; rc=$?
s1=$(date +%s)
grep -q 'cage produced no browser within 2 s (hung)' $T/out.log && ok "hung cage detected" || bad "hang not detected"
sleep 1
if pgrep -f 'stubs/cage' >/dev/null; then bad "cage still alive after the watchdog"; pkill -KILL -f 'stubs/cage'; else ok "cage process (and its group) is gone"; fi
grep -q 'cage did not work; X instead' $T/out.log && grep -q 'starting X' $T/out.log && ok "X started after the hung cage" || bad "no X after cage"
[ $((s1 - s0)) -lt 30 ] && ok "hung cage to X in $((s1 - s0)) s" || bad "took $((s1 - s0)) s"

echo "-- 4. cage that works"
echo works > $T/cagemode
run cage KIOSK_CAGE_BUDGET=10 ; rc=$?
grep -q 'cage shows the browser' $T/out.log && ok "working cage recognised" || bad "working cage not recognised"
[ "$(count XINIT $T/xinit.log)" = 0 ] && ok "no X started when cage works" || bad "X started although cage worked"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
pkill -KILL -f 'stubs/chromium' 2>/dev/null

echo "-- 7. an SPI panel (v7.3: KIOSK_CARD / KIOSK_FB from alnasl-small-screen), HDMI connected as well"
echo quick > $T/xmode
mkdir -p $T/drm/card1 $T/drm/card1-SPI-1; echo connected > $T/drm/card1-SPI-1/status; echo 480x320 > $T/drm/card1-SPI-1/modes; : > $T/dri/card1
run x KIOSK_CARD=card1 KIOSK_FB=/dev/fb1 KIOSK_RES=1280x720 ; rc=$?
grep -q 'small SPI screen on card1 (fb1)' $T/out.log && grep -q 'starting X (fbdev driver' $T/out.log && ! grep -q 'starting X (modesetting' $T/out.log && ok "the SPI panel is the screen although HDMI is connected (v7.4.1: X on its framebuffer, not modesetting)" || bad "SPI card not chosen"
grep -q 'Option "fbdev" "/dev/fb1"' $T/xorg.1.conf && grep -q 'AutoAddGPU" "false"' $T/xorg.1.conf && [ "$(grep -c 'Section "ServerFlags"' $T/xorg.1.conf)" = 1 ] && ok "xorg.conf: fbdev on the panel's fb1, no second GPU, one ServerFlags section" || bad "SPI xorg.conf"
grep -q 'connector card1-SPI-1 connected' $T/out.log && ! grep -q 'connector card0-HDMI-A-1' $T/out.log && grep -q 'resolution setting=auto connector=SPI-1' $T/out.log && ok "only the panel's connector counts; a saved HDMI resolution is not used" || bad "HDMI connector or resolution leaked in"
run x KIOSK_CARD=card7 KIOSK_FB=/dev/fb7 ; rc=$?
grep -q 'small SPI screen card7 is not there; the screen is HDMI' $T/out.log && grep -q 'kmsdev" ".*/card0"' $T/xorg.1.conf && ! grep -q AutoAddGPU $T/xorg.1.conf && ok "a card that is not there: HDMI as before" || bad "missing card not handled"
run x 'KIOSK_CARD=card1;reboot' ; rc=$?
grep -q 'ignoring a malformed KIOSK_CARD' $T/out.log && grep -q 'kmsdev" ".*/card0"' $T/xorg.1.conf && ok "a malformed KIOSK_CARD is ignored" || bad "malformed KIOSK_CARD got through"
rm -rf $T/drm/card1 $T/drm/card1-SPI-1 $T/dri/card1
pkill -KILL -f 'stubs/' 2>/dev/null

echo "-- 6. a 3.5-inch HDMI stylus screen (v7.3: KIOSK_FORCE_MODE / KIOSK_ROTATE from alnasl-small-screen)"
echo quick > $T/xmode
run x KIOSK_FORCE_MODE=640x480 KIOSK_ROTATE=right ; rc=$?
grep -q 'small stylus screen: mode 640x480, rotation right' $T/out.log && grep -q 'resolution setting=640x480' $T/out.log && ok "forced mode 640x480 wins although the screen does not list it; rotation right" || bad "forced mode/rotation not taken"
grep -q 'kiosk-res apply - "640x480" "right"' $T/xclient.1.sh && ok "the X client sets the mode and the rotation (kiosk-res apply - 640x480 right)" || bad "xclient lacks the rotation apply"
run x KIOSK_FORCE_MODE='1;reboot' KIOSK_ROTATE=sideways ; rc=$?
grep -q 'ignoring a malformed KIOSK_FORCE_MODE' $T/out.log && grep -q 'ignoring a malformed KIOSK_ROTATE' $T/out.log && ! cat $T/xclient.*.sh | grep -q 'kiosk-res apply' && ok "malformed mode and rotation are ignored (auto, normal; no kiosk-res call)" || bad "malformed values got through"
run x ; rc=$?
! grep -q 'small stylus screen' $T/out.log && ! cat $T/xclient.*.sh | grep -q 'kiosk-res apply' && ok "without them nothing changes (no small-screen line, no kiosk-res call)" || bad "default run changed"
pkill -KILL -f 'stubs/' 2>/dev/null

echo "-- 8. (v7.5) a nunki box's monitors: layouts, swap, the touch panel beside them, a monitor pulled out"
echo quick > $T/xmode
mkdir -p $T/drm/card0-HDMI-A-2; echo disconnected > $T/drm/card0-HDMI-A-2/status; echo 1920x1080 > $T/drm/card0-HDMI-A-2/modes
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 ; rc=$?
grep -q 'nunki screens: layout single' $T/out.log && grep -q 'to=hall1&where=hdmi&solo=1' $T/xclient.1.sh && grep -q 'exec /usr/bin/chromium' $T/xclient.1.sh && ok "nunki, one monitor: the broadcast (hall1) full screen, the only screen (solo)" || bad "nunki single monitor"
echo connected > $T/drm/card0-HDMI-A-2/status
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 ; rc=$?
grep -q 'nunki screens: layout manage (asked auto' $T/out.log && grep -q "^U1='http://localhost:4041/boot?to=manage&where=hdmi'" $T/xclient.1.sh && grep -q "^U2='http://localhost:4041/boot?to=hall1&where=hdmi'" $T/xclient.1.sh && ok "nunki, two monitors, nothing chosen: management on the first, broadcast on the second" || bad "nunki auto with two monitors"
grep -q "^X1='HDMI-1'" $T/xclient.1.sh && grep -q -- '--right-of' $T/xclient.1.sh && ! grep -q matchbox $T/xclient.1.sh && grep -q 'chromium-\$1' $T/xclient.1.sh && ok "one X screen over both (right-of), one profile per window, no window manager" || bad "two-window X client"
grep -q 'kmsdev" ".*/card0"' $T/xorg.1.conf && grep -q 'AutoAddGPU" "false"' $T/xorg.1.conf && ! grep -q ADS7846 $T/xorg.1.conf && ok "X :0 on the HDMI card only; no stylus rule without a panel" || bad "nunki xorg.conf"
grep -q 'two monitors need the modesetting driver' $T/out.log && grep -q 'to=hall1&where=hdmi&solo=1' $T/xclient.2.sh && ok "the fbdev fallback shows one broadcast (not the management page)" || bad "fbdev fallback of two monitors"
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 KIOSK_SWAP=1 ; rc=$?
grep -q "^X1='HDMI-2'" $T/xclient.1.sh && grep -q "^X2='HDMI-1'" $T/xclient.1.sh && ok "swap: HDMI-2 is the first output" || bad "swap"
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 KIOSK_LAYOUT=mirror ; rc=$?
grep -q "^LAY='mirror'" $T/xclient.1.sh && grep -q -- '--same-as' $T/xclient.1.sh && grep -q "^WIN1='hall1'" $T/xclient.1.sh && ok "mirror: the same broadcast on both" || bad "mirror"
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 KIOSK_LAYOUT=two KIOSK_ROT2=left ; rc=$?
grep -q "^WIN1='hall1'" $T/xclient.1.sh && grep -q "^WIN2='hall2'" $T/xclient.1.sh && grep -q "^ROT2='left'" $T/xclient.1.sh && ok "two tournaments: hall1 and hall2, the second turned left" || bad "two broadcasts"
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 KIOSK_LAYOUT=single ; rc=$?
grep -q 'nunki screens: layout single' $T/out.log && grep -q -- '--output HDMI-2 --off' $T/xclient.1.sh && grep -q 'matchbox' $T/xclient.1.sh && ok "single with two connected: the second output dark, the old one-window client" || bad "single with two monitors"
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 'KIOSK_LAYOUT=two;reboot' KIOSK_ROT1=sideways ; rc=$?
grep -q 'ignoring a malformed KIOSK_LAYOUT' $T/out.log && grep -q 'ignoring a malformed KIOSK_ROT1' $T/out.log && grep -q 'layout manage (asked auto' $T/out.log && ok "a malformed layout or rotation means the default" || bad "malformed layout got through"
run x KIOSK_ROLE=alnasl ; rc=$?
! grep -q 'nunki screens' $T/out.log && grep -q '"http://localhost:4041/boot"$' $T/xclient.1.sh && grep -q matchbox $T/xclient.1.sh && ok "another role with two monitors: exactly as before (one window, /boot)" || bad "a non-nunki box changed"
echo "-- 8b. nunki with the touch panel beside two monitors"
echo up > $T/xmode
mkdir -p $T/drm/card1 $T/drm/card1-SPI-1 $T/input/event3/device; echo connected > $T/drm/card1-SPI-1/status; : > $T/dri/card1
echo "ADS7846 Touchscreen" > $T/input/event3/device/name
run x KIOSK_ROLE=nunki KIOSK_NO_HOTPLUG=1 KIOSK_CARD=card1 KIOSK_FB=/dev/fb1 KIOSK_INPUT=$T/input ; rc=$?
sleep 1
grep -q 'touch panel: the menu' $T/out.log && grep -q 'kmsdev" ".*/card0"' $T/xorg.1.conf && grep -q 'MatchProduct "ADS7846"' $T/xorg.1.conf && ok "panel present: X :0 on HDMI, the stylus ignored there" || bad "companion :0"
grep -q 'Xorg :1 -config .*xorg-panel.conf.*-sharevts -novtswitch vt1' $T/xinit.log && grep -q 'fbdev" "/dev/fb1"' $T/tmp/xorg-panel.conf && grep -q 'AutoAddDevices" "false"' $T/tmp/xorg-panel.conf && grep -q 'Device" "/dev/input/event3"' $T/tmp/xorg-panel.conf && ok "X :1 on the panel's fb1, sharing vt1, the stylus its only input" || bad "companion :1"
grep -q 'to=compact&where=panel' $T/tmp/xclient-panel.sh && ok "the panel shows the menu (compact)" || bad "panel URL"
rm -rf $T/drm/card1 $T/drm/card1-SPI-1 $T/dri/card1 $T/input
pkill -KILL -f 'stubs/' 2>/dev/null
echo "-- 8c. a monitor pulled out"
echo hang > $T/xmode
( sleep 3; echo disconnected > $T/drm/card0-HDMI-A-2/status ) &
s0=$(date +%s)
run x KIOSK_ROLE=nunki KIOSK_X_BUDGET=60 ; rc=$?
s1=$(date +%s)
grep -q 'HDMI monitors changed (card0-HDMI-A-1 card0-HDMI-A-2 -> card0-HDMI-A-1)' $T/out.log && grep -q 'screens end here for a new layout' $T/out.log && [ "$rc" = 0 ] && ok "pulled monitor: the screens end within $((s1 - s0)) s for a new layout (exit 0)" || bad "hotplug (rc $rc, $((s1 - s0)) s)"
rm -rf $T/drm/card0-HDMI-A-2
pkill -KILL -f 'stubs/' 2>/dev/null

echo "-- 5. no KMS card"
rm -f $T/dri/card0; echo quick > $T/xmode
run x ; rc=$?
grep -q 'starting X (fbdev driver)' $T/out.log && ! grep -q 'modesetting' $T/out.log && ok "without a KMS card X goes straight to fbdev" || bad "fbdev path wrong"

pkill -KILL -f 'stubs/' 2>/dev/null
exit $fail
