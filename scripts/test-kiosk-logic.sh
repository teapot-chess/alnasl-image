#!/bin/sh
# Runs INSIDE the kiosk container (the shipped /kiosk.sh, with stub cage / xinit / chromium first in PATH and a
# fake DRM tree). Proves the display-path logic without a Pi:
#   1. default mode = X, modesetting first when there is a KMS card, then fbdev, then vt7; cage never started
#   2. an X server that never comes up is killed after its budget and the next driver gets its turn
#   3. cage that HANGS (the real-Pi failure) is killed with its process group after its budget, X follows
#   4. cage that works (a browser appears) is left alone, X is not started
#   5. no KMS card -> fbdev straight away
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
  rm -f $T/xinit.log $T/cage.log $T/tmp/x-up
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

echo "-- 5. no KMS card"
rm -f $T/dri/card0; echo quick > $T/xmode
run x ; rc=$?
grep -q 'starting X (fbdev driver)' $T/out.log && ! grep -q 'modesetting' $T/out.log && ok "without a KMS card X goes straight to fbdev" || bad "fbdev path wrong"

pkill -KILL -f 'stubs/' 2>/dev/null
exit $fail
