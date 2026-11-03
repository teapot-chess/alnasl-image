#!/bin/sh
# Inside the kiosk container (--privileged, --network host, /dev and
# /run/udev from the host). Shows the box's own menu/setup server full screen;
# the server sends the browser to the wizard, to Alnasl or to the menu as the
# state of the box requires.
#
# v2 changes (the "half screen" bug of v1):
#  - X path: Chromium under a bare X server (no window manager) ignores
#    --kiosk/--start-fullscreen and opens at its own default size. Now the
#    real screen size is measured and passed as --window-size/--window-position,
#    and a tiny window manager (matchbox) is started when present so the
#    fullscreen request is honoured too.
#  - both paths: --force-device-scale-factor is set explicitly (default 1).
#  - the path taken and the resolutions seen are logged and written to
#    /run/alnasl-kiosk/state (shown on the System info page).
#
# v3 changes:
#  - Console: Ctrl+Alt+F2 / F3 reach the text consoles (no DontVTSwitch / -novtswitch);
#    X runs on vt1, the kiosk's own VT (vt7 only if vt1 cannot be taken).
#  - The watchdog no longer kills the browser while a menu/settings page is
#    open (heartbeat file written by the menu server), restarts it only when
#    Alnasl itself was gone for 30 s and came back, never twice within 60 s,
#    and writes the reason of every restart to /run/alnasl-kiosk/reload.log.
#
# v4 changes:
#  - Resolution: KIOSK_RES (WxH or auto) is checked against the modes the connected screen offers and
#    applied at every start (X: xrandr, cage: wlr-randr). Chromium managed policies. OSK extension.
#
# v5 changes (found on the first real Pi with working KMS graphics, vc4):
#  - X is the DEFAULT path. With vc4 up, cage as root printed "Unable to drop root ... refusing to start" and
#    then HUNG (two cage processes stayed alive) instead of exiting, so the old "fall back when cage exits"
#    logic never fired: 45 s+ of black screen. cage is now opt-in (KIOSK_MODE=cage, KIOSK_PATH=cage in
#    /etc/alnasl/kiosk.conf) and always runs under a watchdog: no chromium within 10 s -> the whole process
#    group is killed and X is started. There is no path that can wait forever on a black screen.
#  - X uses the modesetting (KMS) driver whenever the kernel has a DRM card (real mode switching for the
#    Resolution setting, full resolution); fbdev is the fallback, and so is anything that does not
#    get an X server up within 12 s.
#  - Never blank: ServerFlags (BlankTime/StandbyTime/SuspendTime/OffTime 0, DPMS off) in xorg.conf plus
#    `xset s off s noblank -dpms`; cage has no idle timer of its own (no swayidle), so that path does not blank either;
#    the kernel console is kept awake by consoleblank=0 on the kernel command line (assemble.sh).
#  - Time to picture: the menu-server wait is overlapped with the X server start (it used to come first, polled
#    every 2 s), 0.3 s polling, the matchbox start no longer sleeps a full second, timestamps (seconds since
#    boot) are logged at the milestones.
#
# v6 changes (the boot screen: no black, no text, from power to Alnasl):
#  - The first page is the menu server's /boot: the same picture the framebuffer painter (alnasl-splash)
#    has on screen, which then hands over to the wizard, the menu or Alnasl with a fade.
#  - X starts with -background none (it keeps what the framebuffer shows instead of painting its root
#    window black or grey). Not with -nocursor: that hid the mouse everywhere, for good, which is a novel
#    way to ship a box people plug a mouse into. The root window gets an empty cursor as the very first
#    thing the X client does (no X in the middle of the boot screen), the boot page says cursor: none,
#    and every other page gets Chromium's arrow back.
#
# v7.3 (small screens on the pins, alnasl-screen.txt; alnasl-kiosk passes what alnasl-small-screen wrote):
#  - KIOSK_CARD / KIOSK_FB: an SPI panel (cardN, /dev/fbN). Only that card's connector counts, X's modesetting
#    driver opens that card (kmsdev) and no other GPU is added, the fbdev fallback uses that fb. A drm/tiny panel
#    initialises only when its display pipe is enabled, so X really has to drive it: a white panel otherwise.
#    It has one mode and the driver does the rotation; the Resolution setting has no say.
#  - KIOSK_FORCE_MODE / KIOSK_ROTATE: a 3.5-inch HDMI stylus screen: that mode whether the screen lists it or
#    not, turned with xrandr.
#  The stylus is turned to match by its calibration matrix on the host (udev), which X's libinput picks up
#  from /run/udev.
URL=${KIOSK_URL:-http://localhost:4041/boot}
BASE=http://localhost:4041
MODE=${KIOSK_MODE:-x}   # x (default) | cage (with watchdog, falls back to x) | auto (= x)
RUN=${KIOSK_RUN:-/run/alnasl-kiosk}
TMPD=${KIOSK_TMP:-/tmp}
DRM=${KIOSK_DRM:-/sys/class/drm}       # (the three KIOSK_* path overrides exist for scripts/test-kiosk-logic.sh)
DEVDRI=${KIOSK_DEVDRI:-/dev/dri}
STATE=$RUN/state
PING=$RUN/ping
RELOADLOG=$RUN/reload.log

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p "$RUN"
export HOME=$TMPD/kiosk-home; mkdir -p "$HOME"
export XKB_DEFAULT_LAYOUT=${KBD_LAYOUT:-be}
export XKB_DEFAULT_VARIANT=${KBD_VARIANT:-}
# No GPU render node on this kernel: let wlroots/mesa draw in software.
export WLR_RENDERER_ALLOW_SOFTWARE=1
export WLR_NO_HARDWARE_CURSORS=1
export LIBGL_ALWAYS_SOFTWARE=1
export LIBSEAT_BACKEND=${LIBSEAT_BACKEND:-builtin}
# What libseat does about the virtual terminal (open/close/switch) ends up in the journal.
export LIBSEAT_LOGLEVEL=${LIBSEAT_LOGLEVEL:-info}

case "${KIOSK_SCALE:-100}" in
  ''|*[!0-9]*) KIOSK_SCALE=100 ;;
esac
SCALE=$(awk "BEGIN{printf \"%.2f\", ${KIOSK_SCALE:-100}/100}")

state() { echo "$*" > "$STATE"; echo "kiosk: $*"; }
upt() { cut -d' ' -f1 /proc/uptime 2>/dev/null || echo '?'; }   # seconds since boot, for the time-to-picture log

CHROMIUM_FLAGS="--kiosk --no-sandbox --user-data-dir=$TMPD/chromium --disk-cache-dir=$TMPD/chromium-cache \
 --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --noerrdialogs \
 --disable-infobars --disable-session-crashed-bubble --disable-translate \
 --load-extension=/opt/kiosk-ext \
 --check-for-update-interval=31536000 --overscroll-history-navigation=0 --touch-events=enabled \
 --password-store=basic --disable-pinch --autoplay-policy=no-user-gesture-required \
 --disable-save-password-bubble --disable-component-update --disable-sync --disable-background-networking  --num-raster-threads=4 --disable-features=Translate,MediaRouter,DisableLoadExtensionCommandLineSwitch,AutofillServerCommunication,PasswordLeakDetection  --force-device-scale-factor=$SCALE"

echo "kiosk: start at t=$(upt)s since boot, mode=$MODE"
# v7.3: an SPI panel: its card only (HDMI, connected or not, is left to the console and the boot screen).
CARDS="card*"; FBDEV=/dev/fb0
case "${KIOSK_CARD:-}" in
  '') ;;
  card[0-9]|card[0-9][0-9])
    if [ -e "$DRM/$KIOSK_CARD" ]; then
      CARDS=$KIOSK_CARD
      case "${KIOSK_FB:-}" in /dev/fb[0-9]|/dev/fb[0-9][0-9]) FBDEV=$KIOSK_FB ;; esac
      echo "kiosk: small SPI screen on $KIOSK_CARD (${FBDEV#/dev/}): the picture goes there (alnasl-screen.txt)"
    else
      echo "kiosk: small SPI screen $KIOSK_CARD is not there; the screen is HDMI"
    fi ;;
  *) echo "kiosk: ignoring a malformed KIOSK_CARD" ;;
esac
FBN=${FBDEV#/dev/}
# --- what does the hardware say the screen is? (logged for the next report) ---
drm_size=""; kms_card=""
for d in $DRM/$CARDS-*; do
  [ -r "$d/status" ] && [ "$(cat "$d/status")" = connected ] || continue
  m=$(head -n 1 "$d/modes" 2>/dev/null)
  echo "kiosk: connector ${d##*/} connected, preferred mode ${m:-unknown}"
  [ -z "$drm_size" ] && drm_size=$m
  [ -z "$kms_card" ] && { c=${d##*/}; kms_card=$DEVDRI/${c%%-*}; }
done
[ -n "$kms_card" ] && [ ! -e "$kms_card" ] && kms_card=""
fb_virtual=$(cat /sys/class/graphics/$FBN/virtual_size 2>/dev/null)
fb_modes=$(head -n 1 /sys/class/graphics/$FBN/modes 2>/dev/null)
echo "kiosk: $FBN virtual_size=${fb_virtual:-none} modes=${fb_modes:-none}; drm preferred=${drm_size:-none}; kms card=${kms_card:-none}; scale=$SCALE; kbd=$XKB_DEFAULT_LAYOUT/${XKB_DEFAULT_VARIANT:-}"
echo "kiosk: active VT $(cat /sys/class/tty/tty0/active 2>/dev/null || echo '?'); VT switching: Ctrl+Alt+F2/F3 = console, Ctrl+Alt+F1 = back to the screen"
# The connector (HDMI-A-1) and the modes it offers; KIOSK_RES must be one of them, else it is ignored.
conn_name=""; conn_modes=""
for d in $DRM/$CARDS-*; do
  [ -r "$d/status" ] && [ "$(cat "$d/status")" = connected ] || continue
  conn_name=$(echo "${d##*/}" | sed 's/^card[0-9]*-//'); conn_modes=$(cat "$d/modes" 2>/dev/null); break
done
RES=auto
case "${KIOSK_RES:-auto}" in
  auto|'') ;;
  *[!0-9x]*) echo "kiosk: ignoring a malformed KIOSK_RES" ;;
  *) if echo "$conn_modes" | grep -qx "$KIOSK_RES"; then RES=$KIOSK_RES; else echo "kiosk: saved resolution $KIOSK_RES is not offered by ${conn_name:-the screen}; using the preferred mode"; fi ;;
esac
[ "$CARDS" != "card*" ] && [ "$RES" != auto ] && { echo "kiosk: the SPI panel has one mode; saved resolution $RES not used"; RES=auto; }
# v7.3: a 3.5-inch HDMI stylus screen (alnasl-screen.txt, by way of alnasl-small-screen) fixes the mode and the rotation.
# The mode need not be one the screen lists (kiosk-res adds it); the Resolution setting has no say while it is on.
ROT=normal
case "${KIOSK_ROTATE:-normal}" in normal|right|inverted|left) ROT=${KIOSK_ROTATE:-normal} ;; *) echo "kiosk: ignoring a malformed KIOSK_ROTATE" ;; esac
case "${KIOSK_FORCE_MODE:-}" in
  '') ;;
  *[!0-9x]*|x*|*x|*x*x*) echo "kiosk: ignoring a malformed KIOSK_FORCE_MODE" ;;
  *x*) RES=$KIOSK_FORCE_MODE ;;
esac
if [ -n "${KIOSK_FORCE_MODE:-}" ] || [ "$ROT" != normal ]; then echo "kiosk: small stylus screen: mode ${KIOSK_FORCE_MODE:-auto}, rotation $ROT (alnasl-screen.txt)"; fi
echo "kiosk: resolution setting=$RES connector=${conn_name:-none}"
[ "$RES" != auto ] && drm_size=$RES
# "1920x1080" or "1920x1080i" -> "1920,1080"; fb: "1920,1080"
size_from_drm=$(echo "$drm_size" | sed -n 's/^\([0-9]\{3,5\}\)x\([0-9]\{3,5\}\).*/\1,\2/p')
# fb0 "modes" ("U:1920x1080p-0") is the visible mode; virtual_size may be taller (double buffering).
size_from_fb=$(echo "$fb_modes" | sed -n 's/^[A-Z]*:\([0-9]\{3,5\}\)x\([0-9]\{3,5\}\).*/\1,\2/p')
[ -z "$size_from_fb" ] && size_from_fb=$(echo "$fb_virtual" | sed -n 's/^\([0-9]\{3,5\}\),\([0-9]\{3,5\}\)$/\1,\2/p')

# The menu server decides what the browser shows first; it normally answers before X is even up.
wait_menu() {
  until curl -fsS -o /dev/null --max-time 2 "$BASE/healthz"; do sleep 0.3; done
  echo "kiosk: the menu server answers (t=$(upt)s)"
}

# --- watchdog ---------------------------------------------------------------
# menu_open: the menu pages write "<unix time>\t<page>" to $PING every 8 s (the
# page is empty once the browser has gone to Alnasl). Fresh + a page = a
# menu/settings/diagnostics page is on screen right now.
menu_open() {
  [ -r "$PING" ] || return 1
  ts=$(cut -f1 "$PING" | head -n 1)
  page=$(cut -f2 "$PING" | head -n 1)
  [ -n "$page" ] || return 1
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - ts )) -lt 35 ]
}
last_reload=0
reload_browser() { # reason
  now=$(date +%s)
  if [ $((now - last_reload)) -lt 60 ]; then echo "kiosk: browser restart wanted ($1) but one happened less than 60 s ago; skipped"; return; fi
  last_reload=$now
  echo "kiosk: restarting the browser: $1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$RELOADLOG"
  pkill -x chromium
}
if [ -z "${KIOSK_NO_WATCHDOG:-}" ]; then
(
  down=0; adown=0
  while sleep 10; do
    # The menu server only matters to the menu pages themselves; the Alnasl page does not use it.
    if curl -fsS -o /dev/null --max-time 8 "$BASE/healthz"; then
      [ "$down" -ge 3 ] && echo "kiosk: the menu server is back after $((down * 10)) s (browser left alone)"
      down=0
    else
      down=$((down + 1))
      [ "$down" -eq 3 ] && echo "kiosk: the menu server did not answer for 30 s"
    fi
    # v7: the box's own app, whichever role it has (alnasl-kiosk passes its port).
    if curl -fsS -o /dev/null --max-time 8 "http://localhost:${KIOSK_APP_PORT:-4040}/"; then
      if [ "$adown" -ge 3 ]; then
        if menu_open; then
          echo "kiosk: the app (port ${KIOSK_APP_PORT:-4040}) is back after $((adown * 10)) s; a menu page is open, so the browser is left alone"
        else
          reload_browser "the app (port ${KIOSK_APP_PORT:-4040}) was unreachable for $((adown * 10)) s and is back; the screen may show an error page"
        fi
      fi
      adown=0
    else
      adown=$((adown + 1))
      [ "$adown" -eq 3 ] && echo "kiosk: the app (port ${KIOSK_APP_PORT:-4040}) did not answer for 30 s"
    fi
  done
) &
fi

# --- cage (Wayland): opt-in, behind a start-up watchdog ---------------------------------------------
# Returns 0 when it ran normally and ended, 1 when it never produced a window (killed by the watchdog)
# or ended by itself. The caller then starts X.
CAGE_BUDGET=${KIOSK_CAGE_BUDGET:-20}   # half seconds: 20 = 10 s
kill_cage_group() { # pid
  kill -TERM -- "-$1" 2>/dev/null; kill -TERM "$1" 2>/dev/null
  pkill -TERM -x cage 2>/dev/null
  sleep 1
  kill -KILL -- "-$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null
  pkill -KILL -x cage 2>/dev/null; pkill -KILL -x chromium 2>/dev/null
  return 0
}
run_cage() {
  sz=$size_from_drm
  [ "$RES" != auto ] && sz=$(echo "$RES" | sed 's/x/,/')
  state "path=cage mode=${drm_size:-unknown} window-size=${sz:-auto} scale=$SCALE vt=$(cat /sys/class/tty/tty0/active 2>/dev/null)"
  extra=""
  [ -n "$sz" ] && extra="--window-size=$sz --window-position=0,0"
  wait_menu
  # Re-apply the saved resolution once the compositor is up (wlr-randr needs cage's socket).
  [ "$RES" != auto ] && /usr/local/bin/kiosk-res wait-apply "${conn_name:--}" "$RES" &
  # -s: allow VT switching (Ctrl+Alt+F2 / F3 = console, Ctrl+Alt+F1 = back)
  # setsid: cage and everything it starts get their own process group, so the watchdog can end all of it at once.
  # shellcheck disable=SC2086
  setsid cage -s -- chromium $CHROMIUM_FLAGS $extra --ozone-platform=wayland "$URL" &
  cpid=$!
  i=0; shown=0
  while [ "$i" -lt "$CAGE_BUDGET" ]; do
    kill -0 "$cpid" 2>/dev/null || break
    # A picture = the browser exists. (The Wayland socket alone proves nothing: the hang happens after it.)
    if pgrep -x chromium >/dev/null 2>&1; then shown=1; break; fi
    sleep 0.5; i=$((i + 1))
  done
  if [ "$shown" = 1 ]; then
    echo "kiosk: cage shows the browser (t=$(upt)s)"
    wait "$cpid"; return $?
  fi
  if kill -0 "$cpid" 2>/dev/null; then
    echo "kiosk: cage produced no browser within $((CAGE_BUDGET / 2)) s (hung); killing its process group and starting X"
    kill_cage_group "$cpid"
  else
    wait "$cpid"; echo "kiosk: cage ended by itself before showing anything (exit $?)"
  fi
  pkill -KILL -x cage 2>/dev/null; pkill -KILL -x chromium 2>/dev/null
  return 1
}

# --- X -----------------------------------------------------------------------------------------------------
X_BUDGET=${KIOSK_X_BUDGET:-12}   # seconds for the X server to come up before it is killed
run_x() { # $1 = virtual terminal to run X on (vt1 = the kiosk's own, vt7 = fallback); $2 = fbdev | modesetting
  vt=${1:-vt1}
  drv=${2:-fbdev}
  if [ "$drv" = modesetting ]; then
    # AccelMethod none: no glamor (there is no 3D/render node on this kernel); ShadowFB draws in software.
    printf 'Section "Device"
  Identifier "kms"
  Driver "modesetting"
  Option "kmsdev" "%s"
  Option "AccelMethod" "none"
  Option "ShadowFB" "true"
EndSection
' "$kms_card" > "$TMPD/xorg.conf"
  else
    printf 'Section "Device"
  Identifier "fb"
  Driver "fbdev"
  Option "fbdev" "%s"
EndSection
' "$FBDEV" > "$TMPD/xorg.conf"
  fi
  cat >> "$TMPD/xorg.conf" <<'XC'
Section "ServerFlags"
  Option "BlankTime" "0"
  Option "StandbyTime" "0"
  Option "SuspendTime" "0"
  Option "OffTime" "0"
  Option "DPMS" "false"
EndSection
Section "InputClass"
  Identifier "keyboard"
  MatchIsKeyboard "on"
  Option "XkbLayout" "KBDLAYOUT"
  Option "XkbVariant" "KBDVARIANT"
EndSection
Section "InputClass"
  Identifier "touchscreen"
  MatchIsTouchscreen "on"
  MatchDevicePath "/dev/input/event*"
  Driver "libinput"
EndSection
XC
  # (No DontVTSwitch / -novtswitch: Ctrl+Alt+F2 must reach the console.)
  sed -i "s/KBDLAYOUT/$XKB_DEFAULT_LAYOUT/; s/KBDVARIANT/$XKB_DEFAULT_VARIANT/" "$TMPD/xorg.conf"
  # v7.3: an SPI panel is the only screen: X must not add vc4 as a second GPU and spread the desktop over HDMI.
  [ "$CARDS" != "card*" ] && sed -i 's/^  Option "DPMS" "false"$/&\n  Option "AutoAddGPU" "false"/' "$TMPD/xorg.conf"
  rm -f "$TMPD/x-up"
  # The X client: measure the screen X really has, then size the window to it.
  # v7.3: the mode/rotation call is written only when there is one to make (an if inside the heredoc would always be
  # there as text, and a harmless call is still a call).
  apply_line=":"
  if [ "$drv" = modesetting ]; then
    { [ "$RES" != auto ] || [ "$ROT" != normal ]; } && apply_line="/usr/local/bin/kiosk-res apply - \"$RES\" \"$ROT\""
  elif [ "$ROT" != normal ]; then
    apply_line="echo 'kiosk: rotation $ROT needs the modesetting driver; the fbdev fallback shows the picture unturned'"
  fi
  cat > "$TMPD/xclient.sh" <<XCL
#!/bin/sh
printf '#define e_width 1
#define e_height 1
static unsigned char e_bits[] = { 0x00 };
' > $TMPD/empty.xbm
xsetroot -cursor $TMPD/empty.xbm $TMPD/empty.xbm 2>/dev/null
touch $TMPD/x-up
echo "kiosk: X server is up (t=\$(cut -d' ' -f1 /proc/uptime)s)"
echo "path=x driver=$drv" > $STATE
$apply_line
sz=\$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x \([0-9]*\).*/\1,\2/p' | head -n 1)
src=xrandr
[ -z "\$sz" ] && sz="$size_from_fb" && src=fb0
[ -z "\$sz" ] && sz="$size_from_drm" && src=drm-preferred-mode
[ -z "\$sz" ] && sz=1920,1080 && src=default
echo "kiosk: X screen size \$sz (from \$src)"
echo "path=x driver=$drv window-size=\$sz (from \$src) drm=${drm_size:-unknown} fb=${fb_virtual:-none} scale=$SCALE vt=$vt" > $STATE
if command -v matchbox-window-manager >/dev/null 2>&1; then
  matchbox-window-manager -use_titlebar no -use_cursor no &
  sleep 0.2
fi
# A hall display never blanks (belt and braces with the ServerFlags in xorg.conf).
xset s off s noblank -dpms 2>/dev/null
until curl -fsS -o /dev/null --max-time 2 $BASE/healthz; do sleep 0.3; done
echo "kiosk: starting the browser (t=\$(cut -d' ' -f1 /proc/uptime)s)"
exec /usr/bin/chromium $CHROMIUM_FLAGS --window-position=0,0 --window-size=\$sz --start-fullscreen "$URL"
XCL
  chmod 0755 "$TMPD/xclient.sh"
  echo "kiosk: starting X ($drv driver${kms_card:+, $kms_card}), on $vt (VT switching allowed), t=$(upt)s"
  # An X server that has not come up within X_BUDGET seconds is killed, so the next driver gets its turn.
  ( sleep "$X_BUDGET"; [ -e "$TMPD/x-up" ] || { echo "kiosk: X ($drv) was not up after ${X_BUDGET} s; killing it"; pkill -KILL -x Xorg; pkill -KILL -x xinit; } ) &
  xchk=$!
  xinit "$TMPD/xclient.sh" -- /usr/bin/Xorg :0 -config "$TMPD/xorg.conf" -nolisten tcp -noreset -background none "$vt"
  rc=$?
  kill "$xchk" 2>/dev/null
  return $rc
}

run_x_any() {
  t0=$(date +%s)
  if [ -n "$kms_card" ]; then
    # Real KMS graphics (vc4): modesetting gives the full resolution and real mode switching (xrandr).
    run_x vt1 modesetting
    rc=$?
    if [ $(( $(date +%s) - t0 )) -lt 15 ]; then
      echo "kiosk: X with the modesetting driver ended after less than 15 s (exit $rc); falling back to fbdev"
      t0=$(date +%s)
      run_x vt1 fbdev
      rc=$?
    fi
  else
    run_x vt1 fbdev
    rc=$?
  fi
  if [ $(( $(date +%s) - t0 )) -lt 15 ]; then
    echo "kiosk: X on vt1 ended after less than 15 s (exit $rc); trying vt7 (then Ctrl+Alt+F7 returns to the screen)"
    run_x vt7 fbdev
    rc=$?
  fi
  return $rc
}

started=$(date +%s)
case "$MODE" in
  cage)
    if run_cage; then exit 0; fi
    echo "kiosk: cage did not work; X instead"
    started=$(date +%s)
    ;;
esac
run_x_any
rc=$?
[ $(( $(date +%s) - started )) -lt 25 ] && { echo "kiosk: X failed too (exit $rc)"; exit 1; }
exit 0
