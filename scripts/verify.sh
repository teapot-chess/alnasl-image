#!/bin/bash
# Runs on the build VM: loop-mounts the finished (uncompressed) image read-write
# and checks it without hardware. Cleans up what the Alnasl test start leaves
# behind (its data dir), so the image ships with a fresh one.
set -uo pipefail
# All mounts live in a private mount namespace: nothing leaks into the VM's services.
if [ -z "${ALNASL_UNSHARED:-}" ]; then export ALNASL_UNSHARED=1; exec unshare -m --propagation private bash "$0" "$@"; fi
W=/root/w-photon-img5
. $W/lib-chroot.sh
IMG=$W/photon-alnasl-v6.img
KVER=6.1.10-11.ph5
fail=0
ok()  { echo "  ok   $*"; }
# Byte-for-byte compare without cmp (the build VM has no diffutils, so cmp was "command not found" = always different).
same() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }
bad() { echo "  FAIL $*"; fail=1; }

for d in $W/vmnt/root $W/vmnt/boot; do umount -R -l $d 2>/dev/null; done
L=$(losetup -f --show -P $IMG)
mkdir -p $W/vmnt/root $W/vmnt/boot
mount ${L}p2 $W/vmnt/root; mount ${L}p1 $W/vmnt/boot
R=$W/vmnt/root; B=$W/vmnt/boot
trap 'cumount $R 2>/dev/null; umount -R -l $R $B 2>/dev/null; losetup -d $L 2>/dev/null' EXIT

echo "== kernel / modules / dtbs"
ls $R/lib/modules/ | tr '\n' ' '; echo
[ "$(ls $R/lib/modules/)" = "$KVER" ] && ok "one modules dir: $KVER" || bad "modules dirs: $(ls $R/lib/modules/)"
[ -f $R/boot/vmlinuz-$KVER ] && [ -f $R/boot/initrd.img-$KVER ] && ok "kernel+initrd in /boot ($KVER)" || bad "kernel files"
grep -q "vmlinuz-$KVER" $R/boot/photon.cfg && ok "grub env points at $KVER" || bad "photon.cfg"
rpm --root=$R -q linux linux-drivers-gpu dtb-rpi4 dtb-rpi-overlay dtb-raspberrypi raspberrypi-firmware-pi4 u-boot-rpi4 grub2-efi-image linux-firmware docker | sed 's/^/       /'
vc4=$(find $R/lib/modules/$KVER -name 'vc4.ko*'); [ -n "$vc4" ] && ok "vc4: ${vc4#$R}" || bad "no vc4 module"
for m in vc4 hid-multitouch cdc-acm ch341 drm_kms_helper; do
  chroot $R modinfo -k $KVER $m 2>/dev/null | grep -E '^(filename|vermagic)' | tr '\n' ' ' | sed 's/^/       /'; echo
done
stock=$(chroot $R modinfo -k $KVER ftdi_sio | awk '/^vermagic/{$1="";print}')
ours=$(chroot $R modinfo -k $KVER hid-multitouch | awk '/^vermagic/{$1="";print}')
[ "$stock" = "$ours" ] && ok "vermagic of out-of-tree module equals stock module's:$ours" || bad "vermagic differs: [$stock] vs [$ours]"
chroot $R modprobe -n -v -d / -S $KVER hid-multitouch 2>&1 | sed 's/^/       /'
chroot $R modprobe -n -v -S $KVER vc4 2>&1 | sed 's/^/       /'
for f in bcm2711-rpi-4-b.dtb overlays/upstream-pi4.dtbo config.txt start4.elf fixup4.dat u-boot-rpi4.bin EFI/BOOT/bootaa64.efi; do [ -e $B/$f ] && ok "boot partition has $f" || bad "boot partition lacks $f"; done
grep -E 'dtoverlay|kernel=' $B/config.txt | sed 's/^/       /'
# dtbs on the FAT partition are byte-identical to those of the installed dtb package
for f in bcm2711-rpi-4-b.dtb; do
  if same $B/$f $R/boot/dtb/$f || [ -z "$(ls $R/boot/dtb 2>/dev/null)" ]; then ok "dtb $f consistent (or no second copy)"; else bad "dtb $f differs from /boot/dtb"; fi
done
find $R/boot $R/usr/share -name 'bcm2711-rpi-4-b.dtb' 2>/dev/null | sed 's/^/       /'

echo "== update lock"
grep -n '^excludepkgs' $R/etc/tdnf/tdnf.conf && ok "excludepkgs present" || bad "no excludepkgs"
cp /etc/resolv.conf $R/etc/resolv.conf.v 2>/dev/null; mv $R/etc/resolv.conf $R/etc/resolv.conf.keep; cp /etc/resolv.conf $R/etc/resolv.conf
cmount $R
echo "  -- tdnf --assumeno update (dry run) --"
chroot $R tdnf --refresh --assumeno update > $W/dryrun.txt 2>&1
sed 's/^/       /' $W/dryrun.txt | head -n 12; echo '       ... ('$(grep -c aarch64 $W/dryrun.txt)' packages in the whole plan)'
if grep -E '^\s*(linux|linux-[a-z-]+|dtb-[a-z0-9-]+|u-boot[a-z0-9-]*|grub2[a-z0-9-]*|raspberrypi-firmware[a-z0-9-]*|initramfs)\s+(aarch64|noarch)' $W/dryrun.txt ; then bad "dry-run would update locked packages"; else ok "dry-run touches none of kernel/dtb/firmware/u-boot/grub"; fi
chroot $R tdnf --assumeno install linux 2>&1 | tail -4 | sed 's/^/       /'
cumount $R
rm -f $R/etc/resolv.conf; mv $R/etc/resolv.conf.keep $R/etc/resolv.conf; rm -f $R/etc/resolv.conf.v

echo "== v6 lockdown: no ssh, no Tailscale, nothing inbound but the hall's"
for u in sshd.service sshd.socket sshd-keygen.service; do
  s=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1)
  case "$s" in masked|*"No such file"*|*"not found"*|*"does not exist"*) ok "$u: ${s:0:40}" ;; *) bad "$u is $s (must be absent or masked)" ;; esac
done
w=$(find $R/etc/systemd/system $R/usr/lib/systemd/system -path '*.wants/*' -name 'sshd*' 2>/dev/null)
[ -z "$w" ] && ok "no sshd unit in any .wants directory" || bad "sshd wanted by: $w"
if [ -e $R/usr/sbin/sshd ]; then
  [ "$(chroot $R systemctl is-enabled sshd.service 2>&1 | tail -1)" = masked ] && ok "sshd binary present but its unit masked" || bad "sshd installed and not masked"
else ok "no sshd binary"; fi
k=$(find $R/root $R/home $R/etc/ssh -name 'authorized_keys*' 2>/dev/null)
[ -z "$k" ] && ok "no authorized_keys anywhere" || bad "authorized_keys found: $k"
ls $R/etc/ssh/ssh_host_* 2>/dev/null && bad "host keys baked in" || ok "no ssh host keys baked in"
fw=$(bash -c "source <(sed -n '/^CHAIN=/p;/^rules_v4()/,/^}/p;/^rules_v6()/,/^}/p' $R/usr/local/sbin/alnasl-firewall); rules_v4; rules_v6")
echo "$fw" | grep -q -E -- '--dport 22( |$)' && bad "firewall lets port 22 in" || ok "firewall: port 22 closed"
echo "$fw" | grep -q -i -E 'tailscale|41641' && bad "firewall still has the Tailscale rules" || ok "firewall: no Tailscale rules"
echo "$fw" | grep -q -- '--dport 4040 -j ACCEPT' && ok "firewall: Alnasl (4040) let in" || bad "firewall lacks the Alnasl rule"
echo "$fw" | grep -q -- '--dport 4050 -j ACCEPT' && ok "firewall: Arkab's status page (4050) let in (a slave's)" || bad "firewall lacks the Arkab rule"
ts=$(ls $R/usr/local/bin/tailscale* $R/usr/bin/tailscale* $R/usr/sbin/tailscale* $R/usr/local/sbin/alnasl-tailscale-up \
        $R/etc/systemd/system/tailscale* $R/etc/systemd/system/alnasl-tailscale* $R/usr/lib/systemd/system/tailscale* $B/tailscale* 2>/dev/null)
[ -z "$ts" ] && ok "no Tailscale binary, unit, script or key file" || bad "Tailscale pieces: $ts"
grep -q -E 'sshd|tailscale' $R/usr/local/lib/alnasl-setup/server.py && bad "server.py can still reach sshd/tailscale" || ok "server.py: /api/services cannot start sshd or Tailscale"
grep -q -i -E 'tailscale|"ssh"|s_ssh' $R/usr/local/share/alnasl-setup/www/app.js && bad "app.js still offers ssh/Tailscale" || ok "app.js: no ssh/Tailscale switches"

echo "== units"
for u in alnasl-firewall alnasl-firstboot alnasl-wifi alnasl-kiosk-load alnasl-kiosk alnasl-setup docker containerd alnasl alnasl-update.path wpa_supplicant@wlan0 systemd-networkd systemd-resolved getty@tty2 getty@tty3 \
         alnasl-splash alnasl-splash-reboot alnasl-splash-poweroff alnasl-os-update.timer alnasl-reset-boot \
         alnasl-data alnasl-slot-check alnasl-upgrade-boot alnasl-mode alnasl-system-update-check.timer; do
  s=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); [ "$s" = enabled ] && ok "$u enabled" || bad "$u: $s"
done
for u in getty@tty1 autovt@tty1; do
  s=$(chroot $R systemctl is-enabled $u.service 2>&1 | tail -1); [ "$s" = masked ] && ok "$u masked (tty1 is the boot screen's)" || bad "$u: $s (masked expected)"
done
echo "  iptables.service: $(chroot $R systemctl is-enabled iptables.service 2>&1 | tail -1)"
echo "  wait-online:      $(chroot $R systemctl is-enabled systemd-networkd-wait-online.service 2>&1 | tail -1)"
echo "  -- does anything that starts at boot PULL IN network-online.target? (drop-ins evaluated) --"
python3 - "$R" <<'PY'
import os, re, sys
R = sys.argv[1]
dirs = [R + '/etc/systemd/system', R + '/usr/lib/systemd/system']
def find(n):
    for d in dirs:
        p = os.path.join(d, n)
        if os.path.lexists(p):
            return p
def unit(n):
    p = find(n)
    if not p or os.path.realpath(p).endswith('/dev/null') or os.path.islink(p) and os.readlink(p) == '/dev/null':
        return None
    files = [p]
    for d in dirs:
        dd = os.path.join(d, n + '.d')
        if os.path.isdir(dd):
            files += [os.path.join(dd, f) for f in sorted(os.listdir(dd)) if f.endswith('.conf')]
    res = {'After': [], 'Wants': [], 'Requires': [], 'BindsTo': [], 'Requisite': []}
    for f in files:
        try:
            for line in open(f):
                m = re.match(r'(After|Wants|Requires|BindsTo|Requisite)=(.*)', line.strip())
                if m:
                    k, v = m.groups()
                    res[k] = [] if v == '' else res[k] + v.split()
        except IsADirectoryError:
            pass
    return res
def wants_dir(n):
    out = []
    for d in dirs:
        for suffix in ('.wants', '.requires'):
            dd = os.path.join(d, n + suffix)
            if os.path.isdir(dd):
                out += os.listdir(dd)
    return out
seen, todo, hits = set(), ['default.target'], []
while todo:
    n = todo.pop()
    if n in seen:
        continue
    seen.add(n)
    u = unit(n)
    if u is None:
        continue
    pulled = u['Wants'] + u['Requires'] + u['BindsTo'] + u['Requisite'] + wants_dir(n)
    if 'network-online.target' in pulled:
        hits.append(n)
    todo += [x for x in pulled if x != 'network-online.target']
masked = [n for n in ('systemd-networkd-wait-online.service',) if unit(n) is None]
print('       units reachable from default.target: %d' % len(seen))
print('       pulling network-online.target: %s' % (hits or 'none'))
print('       wait-online masked: %s' % bool(masked))
sys.exit(1 if hits else 0)
PY
[ $? = 0 ] && ok "nothing at boot pulls in network-online.target" || bad "something pulls in network-online.target"
echo "  -- merged docker.service: --"; cat $R/usr/lib/systemd/system/docker.service $R/etc/systemd/system/docker.service.d/*.conf | grep -E '^(\[|After|Wants|Requires|ExecStart|Before)' | sed 's/^/       /'
ls $R/etc/systemd/system/network-online.target.wants 2>/dev/null | sed 's/^/       wants: /'
[ -L $R/etc/resolv.conf ] && ok "resolv.conf -> $(readlink $R/etc/resolv.conf)" || bad "resolv.conf"
grep -c . $R/etc/systemd/network/*.network | sed 's/^/       /'

echo "== directory modes (the overlay must not make / or /etc private)"
bad_dirs=$(for d in / etc usr usr/local usr/local/lib usr/local/share usr/local/sbin etc/systemd etc/systemd/system etc/systemd/network etc/alnasl var var/lib; do m=$(stat -c %a $R/$d); [ "$m" = 755 ] || echo "/$d=$m"; done)
for d in $(cd $W/overlay && find . -type d ! -path './boot-efi*' | sed 's#^\./##'); do m=$(stat -c %a "$R/$d" 2>/dev/null); case "$m" in 755|555|775) ;; *) bad_dirs="$bad_dirs /$d=$m";; esac; done
[ -z "$bad_dirs" ] && ok "overlay directories are world-readable (755)" || bad "directory modes: $bad_dirs"
echo "== v3: console access, Wi-Fi tooling, kiosk script"
# getty@tty2/3 are enabled explicitly (the enabled check above), and nothing may disable VT switching.
# Comments stripped once; here-strings, not pipes: with pipefail a writer killed by SIGPIPE (grep -q stops at its first match) turns a hit into a FAIL.
ksrc=$(grep -v '^[[:space:]]*#' $W/kiosk/kiosk.sh)
if grep -q -E 'DontVTSwitch|novtswitch|DontZap' <<<"$ksrc"; then bad "kiosk.sh (source) still disables VT switching"; else ok "kiosk.sh (source) has no DontVTSwitch / -novtswitch"; fi
grep -q -E 'cage -s ' <<<"$ksrc" && ok "cage runs with -s (VT switching allowed)" || bad "cage without -s"
# the kiosk script INSIDE the image that is baked into the card: the docker image on this VM, and the tarball on the card must be the same one
dk=$(docker run --rm --platform linux/arm64 --entrypoint cat alnasl-kiosk:latest /kiosk.sh 2>/dev/null)
dknc=$(grep -v '^[[:space:]]*#' <<<"$dk")
if [ -n "$dk" ]; then
  grep -q -E 'DontVTSwitch|novtswitch' <<<"$dknc" && bad "kiosk image's kiosk.sh disables VT switching" || ok "kiosk image's kiosk.sh: no DontVTSwitch / -novtswitch"
  grep -q 'reload.log' <<<"$dk" && ok "kiosk image has the v3 watchdog (reload.log)" || bad "kiosk image is not the v3 kiosk"
  echo "$dk" | sh -n && ok "sh -n kiosk.sh (from the image)" || bad "kiosk.sh syntax"
else bad "could not read /kiosk.sh from the docker image"; fi
want=$(docker image inspect alnasl-kiosk:latest --format '{{.Id}}' | sed 's/^sha256://')
have=$(tar -xzOf $R/var/lib/alnasl-image/alnasl-kiosk.tar.gz manifest.json 2>/dev/null | grep -o '[0-9a-f]\{64\}' | head -n 1)
[ -n "$have" ] && [ "$have" = "$want" ] && ok "the image tarball on the card is this kiosk image ($have)" || bad "kiosk tarball on the card ($have) differs from the docker image ($want)"
grep -q -- '-s -i' $R/etc/systemd/system/wpa_supplicant@.service.d/alnasl-conf.conf && ok "wpa_supplicant@ drop-in logs to the journal (-s)" || bad "wpa_supplicant drop-in"
chroot $R /usr/sbin/iw --version 2>&1 | sed 's/^/       /'; [ -x $R/usr/sbin/iw ] && ok "iw present" || bad "iw missing"
[ -x $R/usr/local/sbin/alnasl-screen ] && bash -n $R/usr/local/sbin/alnasl-screen && ok "alnasl-screen present, bash -n" || bad "alnasl-screen"
for pk in linux linux-drivers-gpu dtb-rpi4 linux-firmware; do echo "       $(rpm --root=$R -q $pk)"; done
echo "== settings server / wizard / kiosk script"
for f in usr/local/lib/alnasl-setup/server.py usr/local/lib/alnasl-setup/diag.py usr/local/share/alnasl-setup/www/index.html usr/local/share/alnasl-setup/www/app.js usr/local/share/alnasl-setup/www/app.css \
         usr/local/sbin/alnasl-setup etc/alnasl/keyboard.conf etc/alnasl/kiosk.conf etc/alnasl/image-version etc/wpa_supplicant/wpa_supplicant-wlan0.conf \
         etc/systemd/system/alnasl-setup.service; do
  [ -e $R/$f ] || [ -L $R/$f ] && ok "present: /$f" || bad "missing: /$f"
done
chroot $R python3 -c "import sys; compile(open('/usr/local/lib/alnasl-setup/server.py').read(), 'server.py', 'exec'); print('compiles with image python', sys.version.split()[0])" 2>&1 | sed 's/^/       /'
for s in alnasl-setup alnasl-kiosk alnasl-kiosk-load alnasl-firstboot alnasl-wifi-setup alnasl-os-update alnasl-reset alnasl-data alnasl-mode; do bash -n $R/usr/local/sbin/$s && ok "bash -n $s" || bad "bash -n $s"; done
echo "       vconsole.conf: $(cat $R/etc/vconsole.conf 2>/dev/null)"
for k in be-latin1 fr-latin9 nl us-acentos de-latin1-nodeadkeys us uk es it pt-latin1; do
  f=$(find $R/usr/share/keymaps $R/usr/lib/kbd $R/lib/kbd -name "$k.map*" 2>/dev/null | head -n 1); [ -n "$f" ] && ok "keymap $k" || bad "keymap $k missing"
done
rpm --root=$R -q kbd | sed 's/^/       /'
cmount $R
cat > $R/tmp/setup-test.sh <<'IN'
python3 /usr/local/lib/alnasl-setup/server.py > /tmp/setup.log 2>&1 &
echo $! > /tmp/setup.pid
for i in $(seq 1 30); do curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:4041/healthz && break; sleep 1; done
H='Host: 127.0.0.1:4041'
c() { curl -s -o /tmp/body -w '%{http_code}' "$@"; }
echo "GET /            -> $(c -H "$H" http://127.0.0.1:4041/) (302 expected: not set up yet)"
echo "GET /setup       -> $(c -H "$H" http://127.0.0.1:4041/setup) $(grep -c app.js /tmp/body) script tag"
echo "GET /app.js      -> $(c -H "$H" http://127.0.0.1:4041/app.js)"
echo "GET /api/state   -> $(c -H "$H" http://127.0.0.1:4041/api/state) $(head -c 90 /tmp/body)"
echo "GET /api/net     -> $(c -H "$H" http://127.0.0.1:4041/api/net)"
echo "GET /api/sysinfo -> $(c -H "$H" http://127.0.0.1:4041/api/sysinfo) $(head -c 120 /tmp/body)"
echo "GET /diag        -> $(c -H "$H" http://127.0.0.1:4041/diag) $(grep -c app.js /tmp/body) script tag"
echo "GET /api/diag    -> $(c -H "$H" http://127.0.0.1:4041/api/diag) checks=$(python3 -c 'import json;d=json.load(open("/tmp/body"));print(len(d["checks"]), "verdict", d["verdict"], "sections", [s["id"] for s in d["sections"]])')"
echo "GET /api/diag/journals -> $(c -H "$H" http://127.0.0.1:4041/api/diag/journals) units=$(python3 -c 'import json;print(len(json.load(open("/tmp/body"))["journals"]))')"
echo "GET /api/diag/scan -> $(c -H "$H" http://127.0.0.1:4041/api/diag/scan) $(python3 -c 'import json;d=json.load(open("/tmp/body"));print("reason", d.get("reason"), "networks", len(d["networks"]), "available", d["available"])') (no wlan0 in a chroot: a reason, not an empty list)"
echo "GET /api/kiosk-busy -> $(c -H "$H" http://127.0.0.1:4041/api/kiosk-busy) $(head -c 80 /tmp/body)"
echo "ping settings    -> $(c -H "$H" 'http://127.0.0.1:4041/api/ping?p=%2Fsettings%2Fnetwork%3Ftab%3Dwifi&first=1')"
echo "GET / (resume)   -> $(curl -s -o /dev/null -D - -H "$H" http://127.0.0.1:4041/ | grep -i -E '^(HTTP|Location)' | tr -d '\r' | tr '\n' ' ') (302 to /settings/network?tab=wifi expected)"
echo "kiosk-busy       -> $(curl -s -H "$H" http://127.0.0.1:4041/api/kiosk-busy) (busy true expected); heartbeat file: $(cat /run/alnasl-kiosk/ping | tr '\t' ' ')"
echo "ping evil page   -> $(c -H "$H" 'http://127.0.0.1:4041/api/ping?p=%2Fx%0D%0AInjected%3A%201') then file: $(cat /run/alnasl-kiosk/ping | tr '\t' ' ') (empty page expected)"
echo "ping leave       -> $(c -H "$H" 'http://127.0.0.1:4041/api/ping?p=') then GET / -> $(curl -s -o /dev/null -D - -H "$H" http://127.0.0.1:4041/ | grep -i '^Location' | tr -d '\r') (/setup expected)"
echo "healthz while a scan runs -> $( (curl -s -H "$H" http://127.0.0.1:4041/api/diag/scan >/dev/null &) ; sleep 0.5; curl -s -o /dev/null -w '%{http_code} in %{time_total}s' -H "$H" http://127.0.0.1:4041/healthz)"
echo "POST diag/save without header -> $(c -X POST -H "$H" -d '{}' http://127.0.0.1:4041/api/diag/save) (403 expected)"
echo "foreign Host     -> $(c -H 'Host: evil.example:4041' http://127.0.0.1:4041/api/state) (403 expected)"
echo "foreign Host diag -> $(c -H 'Host: evil.example:4041' http://127.0.0.1:4041/api/diag) (403 expected)"
echo "POST no header   -> $(c -X POST -H "$H" -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:4041/api/lang) (403 expected)"
echo "POST bad ip      -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"iface":"eth0","mode":"static","address":"nope"}' http://127.0.0.1:4041/api/net/set) (400 expected)"
echo "POST bad name    -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"hostname":"a b;rm"}' http://127.0.0.1:4041/api/hostname) (400 expected)"
echo "POST lang nl     -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"lang":"nl"}' http://127.0.0.1:4041/api/lang) then lang=$(curl -s -H "$H" http://127.0.0.1:4041/api/state | python3 -c 'import sys,json;print(json.load(sys.stdin)["lang"])')"
echo "GET /api/resolution -> $(c -H "$H" http://127.0.0.1:4041/api/resolution) $(head -c 160 /tmp/body) (no screen in a chroot: modes [] expected)"
echo "POST resolution not offered -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"mode":"1280x720"}' http://127.0.0.1:4041/api/resolution) (400 expected)"
echo "POST resolution evil -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"mode":"1x1;reboot"}' http://127.0.0.1:4041/api/resolution) (400 expected)"
echo "POST resolution confirm -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:4041/api/resolution/confirm) (200 expected)"
echo "POST resolution no header -> $(c -X POST -H "$H" -d '{}' http://127.0.0.1:4041/api/resolution) (403 expected)"
echo "app.js serves the resolution UI: $(curl -s -H "$H" http://127.0.0.1:4041/app.js | grep -c 'api/resolution') api/resolution references"
echo "GET /api/mode    -> $(c -H "$H" http://127.0.0.1:4041/api/mode) $(head -c 90 /tmp/body) (master, not set expected)"
echo "state has mode   -> $(curl -s -H "$H" http://127.0.0.1:4041/api/state | python3 -c 'import sys,json;print(json.load(sys.stdin)["mode"])')"
echo "POST mode no confirm -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"mode":"slave"}' http://127.0.0.1:4041/api/mode) (400 expected)"
echo "POST mode evil   -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"mode":"root","confirm":"SWITCH"}' http://127.0.0.1:4041/api/mode) (400 expected)"
echo "POST mode no header -> $(c -X POST -H "$H" -d '{"mode":"slave","confirm":"SWITCH"}' http://127.0.0.1:4041/api/mode) (403 expected)"
echo "mode file after the refused ones -> '$(cat /var/lib/alnasl-setup/mode 2>/dev/null)' (empty expected)"
echo "GET /boot        -> $(c -H "$H" http://127.0.0.1:4041/boot) $(grep -c 'api/bootscreen' /tmp/body) bootscreen call"
echo "GET /screen      -> $(c -H "$H" http://127.0.0.1:4041/screen)"
echo "GET splash png   -> $(c -H "$H" http://127.0.0.1:4041/splash/alnasl-splash.png) $(head -c 4 /tmp/body | tail -c 3)"
echo "GET screen png   -> $(c -H "$H" http://127.0.0.1:4041/splash/screens/nl/reset-2.png)"
echo "GET splash ../   -> $(c -H "$H" 'http://127.0.0.1:4041/splash/../../../../etc/shadow.png') (404 expected)"
echo "GET /api/bootscreen -> $(c -H "$H" http://127.0.0.1:4041/api/bootscreen) $(head -c 120 /tmp/body)"
echo "POST reset unconfirmed -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"confirm":"yes"}' http://127.0.0.1:4041/api/reset) (400 expected)"
echo "POST reset no header   -> $(c -X POST -H "$H" -d '{"confirm":"RESET"}' http://127.0.0.1:4041/api/reset) (403 expected)"
echo "POST services ssh -> $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"ssh":true,"tailscale":true}' http://127.0.0.1:4041/api/services) $(head -c 160 /tmp/body) (no ssh/tailscale keys expected)"
echo "listening on:    $(ss -ltn 2>/dev/null | awk '$4 ~ /:4041$/ {print $4}' | tr '\n' ' ')"
kill $(cat /tmp/setup.pid); sleep 1
echo "log (no secrets expected):"; sed 's/^/  | /' /tmp/setup.log | head -20
IN
chroot $R /bin/bash /tmp/setup-test.sh 2>&1 | sed 's/^/       /'
echo "  -- redaction unit test (fake wpa conf with a psk, a clear passphrase and a Tailscale key; image python) --"
install -m 0644 $W/test-diag.py $R/tmp/test-diag.py
chroot $R python3 -I /tmp/test-diag.py 2>&1 | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "redaction: no secret survives, SSIDs do" || bad "redaction unit test failed"
cumount $R
rm -rf $R/var/lib/alnasl-setup $R/tmp/setup-test.sh $R/tmp/setup.* $R/tmp/body $R/tmp/test-diag.py $R/run/alnasl-kiosk
find $R/usr/local -name __pycache__ -prune -exec rm -rf {} +

echo "== v4: PrivateTmp, policies, OSK extension, resolution, touch"
if grep -E '^[[:space:]]*PrivateTmp=(yes|true|1)' $R/etc/systemd/system/alnasl-setup.service $R/etc/systemd/system/alnasl-setup.service.d/*.conf $R/usr/lib/systemd/system/alnasl-setup.service 2>/dev/null; then bad "alnasl-setup.service has PrivateTmp=yes (wpa_cli replies would be swallowed)"; else ok "alnasl-setup.service has no PrivateTmp=yes"; fi
grep -q '^PrivateTmp=no' $R/etc/systemd/system/alnasl-setup.service && ok "alnasl-setup.service sets PrivateTmp=no explicitly" || bad "PrivateTmp=no missing"
[ "$(cat $R/etc/alnasl/image-version)" = v6 ] && ok "image-version v6" || bad "image-version: $(cat $R/etc/alnasl/image-version)"
grep -q '^KIOSK_RES="auto"' $R/usr/share/alnasl/defaults/etc/alnasl/kiosk.conf && ok "kiosk.conf defaults to KIOSK_RES=auto" || bad "kiosk.conf default resolution"
grep -q 'KIOSK_RES' $R/usr/local/sbin/alnasl-kiosk && ok "alnasl-kiosk passes KIOSK_RES to the container" || bad "alnasl-kiosk lacks KIOSK_RES"
KC=alnasl-kiosk:latest
P=$(docker run --rm --platform linux/arm64 --entrypoint cat $KC /etc/chromium/policies/managed/alnasl-kiosk.json 2>/dev/null)
if [ -n "$P" ]; then
  for k in PasswordManagerEnabled AutofillAddressEnabled AutofillCreditCardEnabled TranslateEnabled BrowserSignin DefaultNotificationsSetting; do echo "$P" | grep -q "\"$k\"" && ok "policy $k present" || bad "policy $k missing"; done
  echo "$P" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["PasswordManagerEnabled"] is False and d["AutofillAddressEnabled"] is False and d["AutofillCreditCardEnabled"] is False and d["TranslateEnabled"] is False and d["BrowserSignin"]==0; print("values ok")' && ok "policy values: password manager, address+card autofill, translate off; sign-in disabled" || bad "policy values"
else bad "no /etc/chromium/policies/managed/alnasl-kiosk.json in the kiosk image"; fi
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'grep -a -o -m1 "/etc/chromium/policies" /usr/lib/chromium/chromium; chromium --version 2>/dev/null' 2>&1 | sed 's/^/       /'
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'grep -q -a "/etc/chromium/policies" /usr/lib/chromium/chromium' && ok "this Chromium build has the Debian policy base /etc/chromium/policies (managed/ below it is appended at run time)" || bad "Chromium build does not know the managed policy path"
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'ls /opt/kiosk-ext; test -x /usr/local/bin/kiosk-res && sh -n /usr/local/bin/kiosk-res && echo kiosk-res-ok; which wlr-randr xrandr cage Xorg; wlr-randr --version 2>&1 | head -1' 2>&1 | sed 's/^/       /'
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'test -x /usr/local/bin/kiosk-res && which wlr-randr xrandr >/dev/null' && ok "kiosk image has kiosk-res, wlr-randr and xrandr" || bad "kiosk-res / wlr-randr / xrandr missing in the kiosk image"
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'grep -a -c output_management $(which cage)' 2>&1 | sed 's/^/       cage output-management strings: /'
E=$W/ext-check; rm -rf $E; mkdir -p $E; docker run --rm --platform linux/arm64 --entrypoint tar $KC -C /opt -cf - kiosk-ext 2>/dev/null | tar -xf - -C $E
python3 - $E/kiosk-ext <<'PY' && ok "extension manifest: valid, files exist, OSK content script registered, service worker + host permission for :4041" || bad "extension manifest/files"
import json, os, sys
d = sys.argv[1]
m = json.load(open(d + "/manifest.json"))
assert m["manifest_version"] == 3
js = [j for c in m["content_scripts"] for j in c.get("js", [])]
css = [j for c in m["content_scripts"] for j in c.get("css", [])]
for f in js + css + [m["background"]["service_worker"]]:
    assert os.path.isfile(d + "/" + f), f
assert "osk.js" in js and "menu-button.js" in js and "touch.css" in css and "external-bar.js" in js
assert "http://localhost:4041/*" in m["host_permissions"]
mb = [c for c in m["content_scripts"] if "menu-button.js" in c.get("js", [])][0]
assert mb["matches"] == ["http://localhost:4040/*"]
PY
for f in osk.js touch.js bg.js menu-button.js external-bar.js; do
  if command -v node >/dev/null; then node --check $E/kiosk-ext/$f && ok "node --check $f" || bad "syntax $f"; fi
done
grep -q 'execCommand("insertText"' $E/kiosk-ext/osk.js && grep -q 'requestSubmit' $E/kiosk-ext/osk.js && grep -q 'keydown' $E/kiosk-ext/osk.js && grep -q 'osk-config' $E/kiosk-ext/bg.js && ok "OSK content script types via insertText (real input events), submits forms, reads layout via the service worker" || bad "OSK script content"
grep -q 'touch-action' $E/kiosk-ext/touch.css && ok "touch.css present" || bad "touch.css"
rm -rf $E
echo "  -- OSK in a real Chromium? (headless, arm64 under qemu-user; best effort, not a failure when it cannot run) --"
echo "  -- resolution logic unit test (modes from a fake DRM connector, live apply stubbed, confirm/undo/timeout) --"
install -m 0644 $W/test-res.py $R/tmp/test-res.py
chroot $R python3 -I /tmp/test-res.py 2>&1 | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "resolution: apply/confirm/undo/auto-revert/validation" || bad "resolution unit test failed"
rm -f $R/tmp/test-res.py
grep -c "api/resolution" $R/usr/local/share/alnasl-setup/www/app.js | sed 's/^/       app.js api\/resolution refs: /'
for key in res_apply res_keep_q res_auto; do n=$(grep -c "$key:" $R/usr/local/share/alnasl-setup/www/app.js); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"; done

echo "== v5: sound modules + vc4, config.txt, display path, external-page bar, scrollbars, menu design"
SNDPKG=linux-drivers-sound-$KVER
[ "$(rpm --root=$R -q $SNDPKG.aarch64 2>&1)" = "$SNDPKG.aarch64" ] && ok "$SNDPKG.aarch64 installed (exactly the kernel's version)" || bad "sound package: $(rpm --root=$R -q linux-drivers-sound 2>&1)"
[ "$(rpm --root=$R -q linux)" = "linux-$KVER.aarch64" ] && ok "kernel package still linux-$KVER" || bad "kernel package moved"
cat > $R/tmp/sigcheck.sh <<'IN'
rm -rf /tmp/kdb2; mkdir /tmp/kdb2; rpm --dbpath /tmp/kdb2 --initdb
for k in /etc/pki/rpm-gpg/VMWARE-RPM-GPG-KEY*; do rpm --dbpath /tmp/kdb2 --import "$k"; done
sig=$(rpm -q --qf '%{SIGPGP:pgpsig}' linux-drivers-sound-6.1.10-11.ph5)
echo "signature: $sig"
kid=$(echo "$sig" | sed -n 's/.*Key ID \([0-9a-f]*\).*/\1/p')
rpm --dbpath /tmp/kdb2 -q gpg-pubkey --qf 'VMware key (short id): %{VERSION}\n'
short=${kid: -8}
rpm --dbpath /tmp/kdb2 -q gpg-pubkey --qf '%{VERSION}\n' | grep -qx "$short" && echo "SIG-OK $kid" || echo "SIG-BAD [$kid]"
rm -rf /tmp/kdb2
IN
sigout=$(chroot $R /bin/bash /tmp/sigcheck.sh 2>&1); echo "$sigout" | sed 's/^/       /'; rm -f $R/tmp/sigcheck.sh
echo "$sigout" | grep -q '^SIG-OK' && ok "the sound package is signed by a key that ships in /etc/pki/rpm-gpg (VMware)" || bad "sound package signature does not match a VMware key"
grep '^excludepkgs' $R/etc/tdnf/tdnf.conf | grep -q 'linux-\*' && ok "tdnf exclude list covers linux-* (so the sound package is pinned with the kernel)" || bad "exclude list lacks linux-*"
chroot $R modprobe -n -v -S $KVER vc4 2>&1 | sed 's/^/       /' > $W/vc4-v.txt; cat $W/vc4-v.txt
grep -q 'snd-soc-core\|snd_soc_core' $W/vc4-v.txt && grep -q 'vc4.ko' $W/vc4-v.txt && ok "modprobe -n -v vc4 resolves, and pulls in snd-soc-core" || bad "vc4 modprobe dry-run lacks the sound chain"
unres=$(chroot $R depmod -n -e -F /boot/System.map-$KVER $KVER 2>&1 | grep -E 'WARNING.*(vc4|snd[-_]soc)' || true)
[ -z "$unres" ] && ok "depmod -e: no unresolved symbol in vc4 or the ALSA SoC chain (v4 reported devm_snd_soc_register_component here)" || bad "unresolved symbols: $unres"
awk '/^\[/{sec=$0} sec=="[all]" && /^disable_overscan=1/{f=1} END{exit !f}' $B/config.txt && ok "config.txt: disable_overscan=1 in [all]" || bad "config.txt lacks disable_overscan=1 in [all]"
awk '/^\[/{sec=$0} sec=="[pi4]" && /^core_freq_min=500/{f=1} END{exit !f}' $B/config.txt && ok "config.txt: core_freq_min=500 in [pi4] (justification: README v5)" || bad "config.txt lacks core_freq_min=500 in [pi4]"
sed 's/^/       config.txt: /' $B/config.txt
grep -q 'case "$KIOSK_PATH" in cage) mode=cage ;; \*) mode=x ;; esac' $R/usr/local/sbin/alnasl-kiosk && ! grep -q 'mode=auto' $R/usr/local/sbin/alnasl-kiosk && ok "supervisor: path is X unless kiosk.conf says KIOSK_PATH=cage; never 'auto'" || bad "supervisor display path"
grep -q 'KIOSK_PATH' $R/usr/share/alnasl/defaults/etc/alnasl/kiosk.conf && bad "kiosk.conf must not set KIOSK_PATH by default" || ok "kiosk.conf does not select cage"
if [ -n "$dk" ]; then
  grep -q 'MODE=${KIOSK_MODE:-x}' <<<"$dk" && ok "kiosk image: default KIOSK_MODE is x" || bad "kiosk image default mode is not x"
  grep -q 'kill_cage_group' <<<"$dk" && grep -q 'CAGE_BUDGET' <<<"$dk" && grep -q 'setsid cage' <<<"$dk" && ok "kiosk image: cage runs behind the start-up watchdog (setsid, budget, group kill)" || bad "cage watchdog missing"
  grep -q 'X_BUDGET' <<<"$dk" && grep -q 'Driver "modesetting"' <<<"$dk" && grep -q 'falling back to fbdev' <<<"$dk" && ok "kiosk image: modesetting first, X start-up budget, fbdev fallback" || bad "X modesetting/fbdev logic missing"
fi
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'ls /usr/lib/xorg/modules/drivers/ | tr "\n" " "' 2>&1 | sed 's/^/       X drivers: /'
docker run --rm --platform linux/arm64 --entrypoint sh $KC -c 'test -e /usr/lib/xorg/modules/drivers/modesetting_drv.so && test -e /usr/lib/xorg/modules/drivers/fbdev_drv.so' && ok "kiosk image has both the modesetting and the fbdev X drivers" || bad "X driver missing"
grep -q 'consoleblank=0' $R/boot/systemd.cfg && ok "kernel command line has consoleblank=0 (/boot/systemd.cfg)" || bad "consoleblank=0 missing"
if [ -n "$dk" ]; then grep -q 'xset s off s noblank -dpms' <<<"$dk" && grep -q 'Option "DPMS" "false"' <<<"$dk" && ok "kiosk image: no blanking (xorg ServerFlags + xset)" || bad "kiosk image can blank the screen"; fi
echo "  -- display-path logic (shipped kiosk.sh + stub cage/xinit, in the arm64 kiosk container) --"
install -m 0755 $W/test-kiosk-logic.sh $W/test-kiosk-logic.run
docker run --rm --platform linux/arm64 -v $W/test-kiosk-logic.run:/test.sh:ro --entrypoint sh $KC /test.sh 2>&1 | sed 's/^/       /' | tee $W/kiosk-logic.out
if grep -q 'FAIL' $W/kiosk-logic.out || ! grep -q 'no KMS card' $W/kiosk-logic.out; then bad "kiosk display-path logic test"; else ok "kiosk display-path logic: X default, X start-up budget, hung cage killed and replaced by X, working cage left alone"; fi
rm -f $W/test-kiosk-logic.run
E=$W/ext-check5; rm -rf $E; mkdir -p $E; docker run --rm --platform linux/arm64 --entrypoint tar $KC -C /opt -cf - kiosk-ext 2>/dev/null | tar -xf - -C $E
python3 - $E/kiosk-ext <<'PY' && ok "extension: external-bar.js matches every http/https page except Alnasl and the box pages; OSK and touch also cover them" || bad "extension external-page matching"
import json, sys
d = sys.argv[1]
m = json.load(open(d + "/manifest.json"))
bar = [c for c in m["content_scripts"] if "external-bar.js" in c.get("js", [])][0]
assert "http://*/*" in bar["matches"] and "https://*/*" in bar["matches"]
assert "http://localhost:4040/*" in bar["exclude_matches"] and "http://localhost:4041/*" in bar["exclude_matches"]
assert not bar.get("all_frames")
osk = [c for c in m["content_scripts"] if "osk.js" in c.get("js", [])][0]
assert "http://*/*" in osk["matches"] and "https://*/*" in osk["matches"] and "http://localhost:4040/*" in osk["matches"]
assert "http://localhost:4041/*" in osk["exclude_matches"]
touch = [c for c in m["content_scripts"] if "touch.js" in c.get("js", [])][0]
assert "https://*/*" in touch["matches"]
assert "webNavigation" in m["permissions"]
PY
b=$E/kiosk-ext/external-bar.js
grep -q 'Back to Alnasl' $b && grep -q 'Terug naar Alnasl' $b && grep -q 'http://localhost:4040/' $b && grep -q 'history.back' $b && grep -q 'http://localhost:4041/menu' $b && ok "external-bar.js: EN+NL 'Back to Alnasl', history.back first, then localhost:4040, menu button" || bad "external-bar.js content"
grep -q 'onErrorOccurred' $E/kiosk-ext/bg.js && ok "bg.js: an unreachable external page returns to Alnasl" || bad "bg.js error redirect"
grep -q 'webkit-scrollbar' $E/kiosk-ext/touch.css && grep -q 'webkit-scrollbar' $R/usr/local/share/alnasl-setup/www/app.css && ok "thin, see-through scrollbars in Alnasl/external pages (touch.css) and the setup pages (app.css)" || bad "scrollbar CSS"
rm -rf $E
python3 - $R/usr/local/share/alnasl-setup/www <<'PY' && ok "menu design: tiles are plain text, brand is plain 'Alnasl', no emoji/pictograph/svg/img in the setup pages" || bad "menu design"
import re, sys
d = sys.argv[1]
js = open(d + "/app.js", encoding="utf-8").read()
css = open(d + "/app.css", encoding="utf-8").read()
html = open(d + "/index.html", encoding="utf-8").read()
for n, line in enumerate(js.splitlines(), 1):
    if "tile(" in line:
        assert all(ord(c) < 128 for c in line), "non-ASCII on a tile line %d" % n
assert 'h("div", { class: "brand" }, "Alnasl")' in js
assert not re.search(r"\.brand\s+(span|i|b|img|svg)|\.brand::(before|after)", css)
RANGES = ((0x1F000, 0x1FAFF), (0x2190, 0x21FF), (0x2300, 0x23FF), (0x2600, 0x27BF), (0x2B00, 0x2BFF), (0xFE0F, 0xFE0F))
allowed = (0x2190, 0x232B)   # the arrow in the label of a back button, the backspace key of the on-screen keyboard
for name, text in (("app.js", js), ("app.css", css), ("index.html", html)):
    for ch in text:
        o = ord(ch)
        assert o in allowed or not any(a <= o <= b for a, b in RANGES), "%s has glyph U+%04X" % (name, o)
for name, text in (("app.js", js), ("index.html", html)):
    assert "<svg" not in text and "<img" not in text and 'h("svg"' not in text and 'h("img"' not in text, name + " has svg/img"
PY

echo "== firewall script: syntax + ruleset dry run on the build VM's iptables"
bash -n $R/usr/local/sbin/alnasl-firewall && ok "bash -n"
for fn in rules_v4 rules_v6; do
  out=$(bash -c "source <(sed -n '/^CHAIN=/p;/^rules_v4()/,/^}/p;/^rules_v6()/,/^}/p' $R/usr/local/sbin/alnasl-firewall); $fn" | grep -c -E '^-A ALNASL-IN')
  echo "       $fn: $out rules"
done

echo "== Alnasl release inside the image (qemu-user)"
cmount $R
port=4047
cat > $R/tmp/alnasl-test.sh <<'IN'
set -u
export HOME=/var/lib/alnasl ALNASL_DATA=/var/lib/alnasl PORT=4047 LANG=C.UTF-8 RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp/alnasl-rel ALNASL_LISTEN=lan
mkdir -p /tmp/alnasl-rel; chown alnasl:alnasl /tmp/alnasl-rel
echo "serial lib: $(/opt/alnasl/current/bin/alnasl eval 'IO.puts(Arkab.Transport.Uart.available?())' 2>&1 | tail -n 1)"
( /opt/alnasl/current/bin/alnasl start > /tmp/alnasl-test.log 2>&1 & echo $! > /tmp/alnasl-test.pid )
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4047/ 2>/dev/null)
  [ "$code" = 200 ] && break
  sleep 2
done
echo "HTTP on :4047 after $((i*2))s -> $code"
curl -s -o /dev/null -w 'via LAN-style address %{http_code}\n' --max-time 3 http://$(hostname -I 2>/dev/null | awk '{print $1}'):4047/ 2>/dev/null
IN
chmod 755 $R/tmp/alnasl-test.sh
# as the service user, with the dialout group, as the unit does
chroot --userspec=alnasl:alnasl $R /bin/bash /tmp/alnasl-test.sh 2>&1 | sed 's/^/       /'
sleep 2
pkill -u "$(chroot $R id -u alnasl)" -f 'beam.smp' 2>/dev/null; sleep 3
pkill -9 -u "$(chroot $R id -u alnasl)" 2>/dev/null
tail -5 $R/tmp/alnasl-test.log 2>/dev/null | sed 's/^/       log: /'
ldd $R/opt/alnasl/current/erts-*/bin/beam.smp 2>/dev/null | head -0
chroot $R /bin/bash -c 'ldd /opt/alnasl/current/erts-*/bin/beam.smp | sed "s/^/       /"; ldd /opt/alnasl/current/lib/exqlite-*/priv/*.so 2>/dev/null | grep -i "not found"; ldd /opt/alnasl/current/lib/crypto-*/priv/lib/crypto.so | grep -E "crypto|not found" | sed "s/^/       /"' 2>&1
cumount $R
rm -rf $R/tmp/alnasl-test.* $R/tmp/alnasl-rel
find $R/var/lib/alnasl -mindepth 1 -delete
chroot $R chown alnasl:alnasl /var/lib/alnasl
install -d -m 0750 $R/var/lib/alnasl/update; chroot $R chown alnasl:alnasl /var/lib/alnasl/update
install -d -o root -g root $R/var/lib/alnasl-update 2>/dev/null
ls -la $R/var/lib/alnasl | sed 's/^/       /'

echo "== v6: boot screen, OS updates, reset"
for f in usr/share/alnasl/splash/alnasl-splash.png usr/share/alnasl/splash/messages.json boot/grub2/alnasl-splash.png \
         usr/local/sbin/alnasl-splash usr/local/sbin/alnasl-os-update usr/local/sbin/alnasl-reset \
         etc/systemd/system/alnasl-splash.service etc/systemd/system/alnasl-splash-reboot.service etc/systemd/system/alnasl-splash-poweroff.service \
         etc/systemd/system/alnasl-os-update.timer etc/systemd/system/alnasl-os-update.service \
         etc/systemd/system/alnasl-reset.service etc/systemd/system/alnasl-reset-boot.service etc/systemd/system/alnasl-update.service.d/alnasl-screen.conf \
         usr/local/share/alnasl-setup/www/screen.html usr/share/alnasl/defaults/etc/alnasl/keyboard.conf usr/share/alnasl/defaults/etc/alnasl/kiosk.conf \
         usr/share/alnasl/defaults/etc/wpa_supplicant/wpa_supplicant-wlan0.conf; do
  [ -e $R/$f ] && ok "present: /$f" || bad "missing: /$f"
done
for f in alnasl-splash alnasl-os-update alnasl-reset; do [ -x $R/usr/local/sbin/$f ] && ok "$f executable" || bad "$f not executable"; done
same $R/usr/share/alnasl/splash/alnasl-splash.png $W/overlay/usr/share/alnasl/splash/alnasl-splash.png && ok "splash png on the card is the overlay's, byte for byte" || bad "splash png differs from the overlay (damaged on the way?)"
n=$(find $R/usr/share/alnasl/splash/screens -name '*.png' | wc -l); [ "$n" -ge 20 ] && ok "$n state pictures for the browser" || bad "only $n state pictures"
chroot $R python3 -c "import py_compile; py_compile.compile('/usr/local/sbin/alnasl-splash', cfile='/tmp/s.pyc', doraise=True)" && ok "alnasl-splash compiles with image python" || bad "alnasl-splash does not compile"
rm -f $R/tmp/s.pyc
install -m 0644 $W/test-splash.py $R/tmp/test-splash.py
chroot $R python3 -I /tmp/test-splash.py 2>&1 | grep -v '^ok ' | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "painter: every state, both languages, 16/24/32 bpp, 720p..4K" || bad "painter unit test failed"
rm -f $R/tmp/test-splash.py
grep -q '^ExecStart=/usr/local/sbin/alnasl-splash --hold' $R/etc/systemd/system/alnasl-splash.service && grep -q '^DefaultDependencies=no' $R/etc/systemd/system/alnasl-splash.service && ok "alnasl-splash.service: early (no default dependencies), --hold" || bad "alnasl-splash.service"
grep -q 'alnasl-splash --once' $R/etc/systemd/system/alnasl-kiosk.service && grep -q 'alnasl-splash --once' $R/usr/local/sbin/alnasl-kiosk && ok "the picture comes back when the kiosk stops or restarts" || bad "kiosk does not repaint the boot screen"
grep -q 'KIOSK_URL=http://localhost:4041/boot' $R/usr/local/sbin/alnasl-kiosk && ok "kiosk starts on /boot" || bad "kiosk start page"
for k in quiet loglevel=0 vt.global_cursor_default=0 logo.nologo console=tty3 systemd.show_status=false; do
  grep -q "^systemd_cmdline=.*$k" $R/boot/systemd.cfg && ok "cmdline: $k" || bad "cmdline lacks $k"
done
grep -E '^photon_cmdline=.*console=tty[01]( |$)' $R/boot/photon.cfg && bad "photon_cmdline sends the console to tty0/tty1" || ok "photon_cmdline: no console on tty0/tty1"
awk '/^\[/{sec=$0} sec=="[all]" && /^disable_splash=1/{f=1} END{exit !f}' $B/config.txt && ok "config.txt: disable_splash=1 in [all]" || bad "config.txt lacks disable_splash=1"
gc=$(grep -l 'Alnasl v6 boot screen' $R/boot/grub2/grub.cfg $(find $B -name grub.cfg) 2>/dev/null | head -1)
[ -n "$gc" ] && grep -q 'set timeout=0' "$gc" && ok "grub: timeout 0, hidden ($gc)" || bad "grub.cfg not set up for the boot screen"
grep -q 'background_image' "${gc:-/dev/null}" && echo "       grub draws the picture (gfxterm + png available)" || echo "       grub: no gfxterm/png here; it shows nothing, briefly"
[ -f $B/uboot.env ] && echo "       u-boot: uboot.env written ($(stat -c %s $B/uboot.env) bytes): bootdelay 0, console on serial" || echo "       u-boot: no uboot.env (left with its defaults; see the assemble log)"
grep -q -- '-background none' <<<"$ksrc" && ok "kiosk.sh (source): X keeps the framebuffer (-background none)" || bad "kiosk.sh without -background none"
if [ -n "$dk" ]; then grep -q -- '-background none' <<<"$dknc" && ok "kiosk image's kiosk.sh: -background none" || bad "kiosk image is not the v6 kiosk (rebuild it)"; fi
if grep -q -- '-nocursor' <<<"$ksrc"; then bad "kiosk.sh (source) starts X with -nocursor: the mouse is invisible everywhere"; else ok "kiosk.sh (source): no -nocursor, the mouse shows"; fi
if [ -n "$dk" ]; then grep -q -- '-nocursor' <<<"$dknc" && bad "kiosk image hides the mouse (-nocursor; rebuild it)" || ok "kiosk image's kiosk.sh: no -nocursor"; fi
docker run --rm --platform linux/arm64 --entrypoint sh alnasl-kiosk:latest -c 'test -f /opt/kiosk-ext/boot-fade.js && test -f /opt/kiosk-ext/screen-watch.js' && ok "kiosk extension: boot-fade.js, screen-watch.js" || bad "kiosk extension lacks the v6 boot screen scripts"
t=$R/etc/systemd/system/alnasl-os-update.timer
grep -q '^OnCalendar=\*-\*-\* 03:00:00' $t && grep -q '^RandomizedDelaySec=110min' $t && grep -q '^Persistent=false' $t && ok "OS update timer: 03:00 + up to 110 min, no catch-up" || bad "OS update timer"
grep -q -- '--security' $R/usr/local/sbin/alnasl-os-update && grep -q 'excludepkgs' $R/usr/local/sbin/alnasl-os-update && ok "OS update: security first, refuses without the exclude list" || bad "alnasl-os-update content"
grep -q 'updates_text' $R/usr/local/lib/alnasl-setup/diag.py && grep -q 'alnasl-os-update' $R/usr/local/lib/alnasl-setup/diag.py && ok "diagnostics include the OS update result" || bad "diag.py lacks the OS update section"
grep -q '127.0.0.1:4040/local/status' $R/usr/local/sbin/alnasl-os-update && ! grep -q 'round_in_progress() { return 1; }' $R/usr/local/sbin/alnasl-os-update && ok "OS update asks Alnasl's /local/status before touching anything" || bad "alnasl-os-update still stubs the round check"
S=$R/usr/local/lib/alnasl-setup/server.py; J=$R/usr/local/share/alnasl-setup/www/app.js
grep -q '/api/help/send' $S && grep -q '/api/help/url' $S && grep -q 'support/upload' $S && grep -q 'def valid_support_url' $S && grep -q 'scheme != "https"' $S && ok "Get help: server.py sends the report to an https-only upload address" || bad "Get help missing from server.py"
grep -q '"/help"' $S && grep -q 'x-alnasl-box' $S && grep -q '_NoRedirect' $S && ok "Get help: /help page, box/version/mode headers, no redirects" || bad "Get help details missing from server.py"
grep -q 'helpPage' $J && grep -q 'helpSettings' $J && ok "Get help: menu page and Settings page in app.js" || bad "Get help missing from app.js"
for key in m_help help_d help_send help_read help_err_no_internet help_err_rate_limited help_err_support_off help_err_too_large help_url; do n=$(grep -c -E "(^|[^A-Za-z0-9_])$key:" $J); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"; done
grep -q 'helpcode' $R/usr/local/share/alnasl-setup/www/app.css && ok "Get help: big code style in app.css" || bad "app.css lacks .helpcode"
! grep -q -E 'ssh|inbound|listen\(' <(sed -n '/^# -* get help/,/^# -* console/p' $S) && ok "Get help: no listener or shell code in its section" || bad "Get help section mentions ssh/listen"
grep -q 'ExecStart=/usr/local/sbin/alnasl-reset --yes' $R/etc/systemd/system/alnasl-reset.service && ok "reset unit (menu)" || bad "alnasl-reset.service"
grep -q 'ConditionPathExists=/boot/efi/alnasl-reset.txt' $R/etc/systemd/system/alnasl-reset-boot.service && ok "reset unit (boot-partition file)" || bad "alnasl-reset-boot.service"
grep -q 'rm -f "$TRIGGER"' $R/usr/local/sbin/alnasl-reset && ! grep -q -E 'mkfs|/boot/efi/\*|rm -rf /boot' $R/usr/local/sbin/alnasl-reset && ok "reset removes only its trigger from the boot partition" || bad "alnasl-reset and the boot partition"
[ -f $B/alnasl-reset.txt.example ] && [ ! -f $B/alnasl-reset.txt ] && ok "boot partition: reset example, no live trigger" || bad "boot partition reset files"
grep -q '/api/reset' $R/usr/local/lib/alnasl-setup/server.py && grep -q 'reset-hold' $R/usr/local/share/alnasl-setup/www/app.js && ok "menu: Erase this box (hold to confirm)" || bad "reset missing from the menu"
for key in reset reset_d reset_hold; do n=$(grep -c "$key:" $R/usr/local/share/alnasl-setup/www/app.js); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"; done

echo "== v6 A/B: card layout, data partition, system updates, train rule"
DISK_ID=416c6e73
id=$(sfdisk --disk-id $IMG | tr 'A-F' 'a-f'); [ "$id" = "0x$DISK_ID" ] && ok "MBR disk id 0x$DISK_ID (every v6+ image: root=PARTUUID=$DISK_ID-02/-03)" || bad "disk id $id"
sfdisk -d $IMG | sed 's/^/       /'
psz() { sfdisk -d $IMG | grep -E "^${IMG}$1 :" | sed -n 's/.*size= *\([0-9]*\).*/\1/p'; }
pst() { sfdisk -d $IMG | grep -E "^${IMG}$1 :" | sed -n 's/.*start= *\([0-9]*\).*/\1/p'; }
[ "$(sfdisk -d $IMG | grep -c "^${IMG}[0-9] :")" = 4 ] && ok "four partitions: boot | system A | system B | data" || bad "partition count"
[ "$(pst 1)" = 2048 ] && ok "boot partition where Photon put it (sector 2048)" || bad "boot partition start $(pst 1)"
[ "$(psz 2)" = 6291456 ] && [ "$(psz 3)" = 6291456 ] && ok "system A and B: 3 GiB each" || bad "slot sizes: $(psz 2) / $(psz 3) sectors"
[ $(( $(pst 3) )) = $(( $(pst 2) + $(psz 2) )) ] && [ $(( $(pst 4) )) = $(( $(pst 3) + $(psz 3) )) ] && ok "slots and data are contiguous, data last (it grows at the first boot)" || bad "partition order"
end=$(( ($(pst 4) + $(psz 4)) * 512 )); [ $end -le 15000000000 ] && ok "image is $((end >> 20)) MiB: fits a 16 GB card" || bad "image is $end bytes: more than a 16 GB card holds"
[ "$(e2label ${L}p2 2>/dev/null)" = ALNASL_A ] && ok "slot A labelled ALNASL_A" || bad "slot A label: $(e2label ${L}p2 2>&1)"
[ -z "$(blkid -p -o value -s TYPE ${L}p3 2>/dev/null)" ] && ok "slot B empty (no file system until the first update)" || bad "slot B has $(blkid -p -o value -s TYPE ${L}p3)"
[ "$(e2label ${L}p4 2>/dev/null)" = ALNASL_DATA ] && e2fsck -fn ${L}p4 >/dev/null 2>&1 && ok "data partition: ext4 ALNASL_DATA, clean" || bad "data partition"
# The image's own e2fsprogs must accept it: alnasl-data grows and checks it with those at the first boot.
cmount $R; chroot $R e2fsck -fn ${L}p4 >/dev/null 2>&1; rc=$?; chroot $R resize2fs -P ${L}p4 >/dev/null 2>&1; rr=$?; cumount $R
[ $rc = 0 ] && [ $rr = 0 ] && ok "data partition: the image's own e2fsck and resize2fs accept it (no newer ext4 features)" || bad "the image's e2fsck ($rc) / resize2fs -P ($rr) refuse the data partition: made with a newer mke2fs?"
dumpe2fs -h ${L}p2 2>/dev/null | awk -F: '/^Block count/{c=$2} /^Block size/{b=$2} END{exit !(c*b <= 3221225472)}' && ok "slot A's file system fits a slot" || bad "slot A's file system is larger than the partition"
grep -q '^ALNASL_TRAIN=v6$' $R/etc/alnasl/image-release && grep -q -E '^ALNASL_VERSION=6\.[0-9]+' $R/etc/alnasl/image-release && ok "image-release: $(grep -h ALNASL_ $R/etc/alnasl/image-release | tr '\n' ' ')" || bad "image-release"
grep -E '^[^#]*[[:space:]]/[[:space:]]' $R/etc/fstab && bad "fstab still mounts / (the slot comes from the kernel command line)" || ok "fstab: no / line"
grep -q -i swap $R/etc/fstab && bad "fstab has swap" || ok "fstab: no swap"
grep -q "^PARTUUID=$DISK_ID-01[[:space:]]*/boot/efi" $R/etc/fstab && ok "fstab: /boot/efi by PARTUUID $DISK_ID-01" || bad "fstab /boot/efi line"
s=$(chroot $R systemctl is-enabled resizefs.service 2>&1 | tail -1); [ "$s" = masked ] && ok "resizefs masked (it would grow / over slot B)" || bad "resizefs.service: $s"
[ -d $R/data ] && ok "/data mount point" || bad "no /data"
for f in keyboard.conf kiosk.conf; do [ "$(readlink $R/etc/alnasl/$f)" = /data/etc/alnasl/$f ] && ok "/etc/alnasl/$f -> data partition" || bad "/etc/alnasl/$f is not the data symlink"; done
for d in var/lib/arkab var/lib/alnasl-setup var/lib/alnasl-os-update var/lib/docker var/log/journal etc/wpa_supplicant etc/systemd/network/10-wired.network.d; do
  grep -q "$d" $R/usr/local/sbin/alnasl-data && ok "alnasl-data binds /$d" || bad "alnasl-data does not keep /$d"
done
grep -q '.alnasl-wipe' $R/usr/local/sbin/alnasl-data && grep -q '.alnasl-wipe' $R/usr/local/sbin/alnasl-reset && ok "reset = flag on the data partition, formatted by alnasl-data at the next boot" || bad "reset/data wipe flag"
grep -q 'DefaultDependencies=no' $R/etc/systemd/system/alnasl-data.service && grep -q 'Before=.*local-fs.target' $R/etc/systemd/system/alnasl-data.service && ok "alnasl-data runs before local-fs.target" || bad "alnasl-data.service ordering"
for u in systemd-networkd docker containerd; do grep -q 'After=alnasl-data.service' $R/etc/systemd/system/$u.service.d/alnasl-data.conf 2>/dev/null && ok "$u waits for the data partition" || bad "$u.service.d/alnasl-data.conf"; done
G=$B/boot/grub2/grub.cfg
grep -q 'alnasl_tries' $G && grep -q "root=PARTUUID=$DISK_ID-" $G && ! grep -q '@DISKID@' $G && ok "boot partition grub.cfg is the A/B one (try counter, PARTUUID $DISK_ID)" || bad "boot partition grub.cfg is not grub-ab.cfg"
e=$B/alnasl/grubenv; [ "$(stat -c %s $e 2>/dev/null)" = 1024 ] && head -c 24 $e | grep -q 'GRUB Environment Block' && grep -q '^alnasl_slot=A$' $e && grep -q '^alnasl_try=none$' $e && ok "grubenv: 1024 bytes, slot A, no trial" || bad "grubenv"
[ -f $B/boot/grub2/alnasl-splash.png ] && ok "the picture is on the boot partition for grub" || bad "no splash png on the boot partition"
[ -f $B/alnasl-upgrade.txt.example ] && [ ! -f $B/alnasl-upgrade.txt ] && ok "boot partition: upgrade example, no live upgrade request" || bad "boot partition upgrade files"
grep -q 'bcm2835_wdt' $R/etc/modules-load.d/alnasl.conf && grep -q '^RuntimeWatchdogSec=' $R/etc/systemd/system.conf.d/alnasl-watchdog.conf && ok "hardware watchdog: a hung boot still costs a try" || bad "watchdog"
wdc=$R/etc/systemd/system.conf.d/alnasl-watchdog.conf; wd=$(awk -F= '/^RuntimeWatchdogSec=[0-9]+s?$/{sub(/s$/,"",$2); print $2}' $wdc); rb=$(awk -F= '/^RebootWatchdogSec=[0-9]+s?$/{sub(/s$/,"",$2); print $2}' $wdc)
[ -n "$wd" ] && [ "$wd" -ge 1 ] && [ "$wd" -le 15 ] && [ -n "$rb" ] && [ "$rb" -le 15 ] && ok "watchdog timeouts ${wd}s/${rb}s: within bcm2835_wdt's 15 s maximum (a longer one is refused and nothing is armed)" || bad "watchdog timeouts must be plain seconds <= 15 for bcm2835_wdt (runtime '$wd', reboot '$rb')"
U=$R/usr/local/sbin/alnasl-system-update
[ -x $U ] && chroot $R python3 -c "import py_compile; py_compile.compile('/usr/local/sbin/alnasl-system-update', cfile='/tmp/u.pyc', doraise=True)" && ok "alnasl-system-update: executable, compiles with image python" || bad "alnasl-system-update"
rm -f $R/tmp/u.pyc
grep -q 'def train_guard' $U && [ "$(grep -c 'train_guard(' $U)" -ge 2 ] && ok "train guard present and called before anything is written" || bad "train guard missing"
for u in alnasl-system-update.service alnasl-system-update-check.service alnasl-slot-check.service alnasl-upgrade-boot.service alnasl-data.service; do [ -f $R/etc/systemd/system/$u ] && ok "unit $u" || bad "missing unit $u"; done
grep -q -- '--nightly' $R/usr/local/sbin/alnasl-os-update && ok "the nightly run tries a system image of this train first" || bad "alnasl-os-update does not call --nightly"
grep -q 'ConditionPathExists=/boot/efi/alnasl-upgrade.txt' $R/etc/systemd/system/alnasl-upgrade-boot.service && ok "headless upgrade: alnasl-upgrade.txt on the boot partition" || bad "alnasl-upgrade-boot.service"
[ -f $R/usr/share/alnasl/kiosk-image-id ] && [ "$(cat $R/usr/share/alnasl/kiosk-image-id)" = "$(docker image inspect alnasl-kiosk:latest --format '{{.Id}}')" ] && ok "kiosk image id recorded (a new slot reloads its own kiosk)" || bad "kiosk-image-id"
grep -q '"/api/system/upgrade"' $S && grep -q '"UPGRADE"' $S && grep -q '"/api/system/install"' $S && ok "setup server: /api/system (GET), check, install (INSTALL), upgrade (UPGRADE)" || bad "setup server system API"
for key in upd upd_install upd_upgrade upd_upgrade_q upd_offer upd_r_rolled_back upd_trial; do n=$(grep -c "$key:" $J); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"; done
if grep -q 'ALNASL-PLACEHOLDER' $R/etc/alnasl/update-key.pub; then
  if [ "${ALNASL_RELEASE:-0}" = 1 ]; then bad "update-key.pub is the PLACEHOLDER in a release build"; else echo "  WARN update-key.pub is the PLACEHOLDER: boxes with this image install no system update (fine for a test build)"; fi
else
  openssl pkey -pubin -in $R/etc/alnasl/update-key.pub -noout 2>/dev/null && ok "update-key.pub is a public key" || bad "update-key.pub is neither the placeholder nor a public key"
fi
grep -r -l -E 'BEGIN (EC |RSA |ENCRYPTED )?PRIVATE KEY' $R/etc $R/usr/local $R/usr/share/alnasl $B 2>/dev/null | sed 's/^/       /' | grep . && bad "a PRIVATE key is in the image" || ok "no private key anywhere in /etc, /usr/local, /usr/share/alnasl or the boot partition"
install -m 0644 $W/test-update.py $R/tmp/test-update.py; install -m 0644 $W/grub-ab.cfg $R/tmp/grub-ab.cfg
chroot $R python3 -I /tmp/test-update.py /usr/local/sbin/alnasl-system-update /etc/alnasl/update-key.pub /tmp/grub-ab.cfg 2>&1 | grep -v '^ok ' | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "updater: train rule, choice, index check, grubenv, signatures (image python + openssl)" || bad "updater unit test failed"
rm -f $R/tmp/test-update.py $R/tmp/grub-ab.cfg
find $R/usr/local -name __pycache__ -prune -exec rm -rf {} +

echo "== modes: master (Alnasl + screen) or slave (Arkab only)"
M=$R/usr/local/sbin/alnasl-mode
[ -x $M ] && bash -n $M && ok "alnasl-mode: executable, bash -n" || bad "alnasl-mode"
MS=$R/etc/systemd/system/alnasl-mode.service
grep -q '^DefaultDependencies=no' $MS && grep -q '^After=alnasl-data.service' $MS && grep -q '^Before=sysinit.target' $MS && ! grep -q -E '^(After|Requires|Wants)=.*(basic|multi-user|reset-boot|network)' $MS && ok "alnasl-mode.service: before sysinit.target, after the data partition, no default dependencies (no ordering cycle with the path units)" || bad "alnasl-mode.service ordering (a cycle through paths.target / basic.target)"
for u in alnasl.service alnasl-update.path alnasl-kiosk.service alnasl-kiosk-load.service; do
  grep -q '^ConditionPathExists=/run/alnasl-mode/master$' $R/etc/systemd/system/$u.d/alnasl-mode.conf 2>/dev/null && ok "$u: master only" || bad "$u has no master-only condition"
done
for u in arkab.service arkab-update.path; do
  grep -q '^ConditionPathExists=/run/alnasl-mode/slave$' $R/etc/systemd/system/$u.d/alnasl-mode.conf 2>/dev/null && ok "$u: slave only" || bad "$u has no slave-only condition"
done
# Arkab is in the image, installed by its own install.sh, and shipped switched off (a new box is a master).
AV=$(cat $R/opt/arkab/current/VERSION 2>/dev/null)
[ -n "$AV" ] && [ -x $R/opt/arkab/current/bin/arkab ] && ok "Arkab $AV installed in /opt/arkab (current)" || bad "Arkab is not in the image (/opt/arkab/current/bin/arkab)"
ls $R/opt/arkab/current/lib/circuits_uart-*/priv/circuits_uart >/dev/null 2>&1 && ok "Arkab: the serial program is in the release" || bad "Arkab has no circuits_uart (cannot read a board)"
if chroot $R /bin/bash -c 'ldd /opt/arkab/current/erts-*/bin/beam.smp | grep -q "not found"'; then bad "Arkab's runtime misses a library on Photon"; else ok "Arkab's runtime: every library found on Photon"; fi
chroot $R getent passwd arkab >/dev/null && chroot $R id -nG arkab | grep -q -w dialout && ok "user arkab, in dialout (the serial ports)" || bad "user arkab / group dialout"
grep -q '^PORT=4050$' $R/etc/arkab/arkab.env && ! grep -q '^ARKAB_LISTEN=local' $R/etc/arkab/arkab.env && ok "arkab.env: port 4050, the hall's network may look" || bad "arkab.env"
for u in arkab.service arkab-update.path; do
  st=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); [ "$st" = disabled ] && ok "$u ships disabled (alnasl-mode enables it on a slave)" || bad "$u: $st (disabled expected)"
done
grep -q 'ARKAB_DATA=/var/lib/arkab' $R/etc/systemd/system/arkab.service && ok "arkab.service keeps its data in /var/lib/arkab (the data partition)" || bad "arkab.service ARKAB_DATA"
[ -f $B/alnasl-mode.txt.example ] && [ ! -f $B/alnasl-mode.txt ] && ok "boot partition: alnasl-mode.txt example, no live file" || bad "boot partition mode files"
grep -q '/api/mode' $S && grep -q '"SWITCH"' $S && ok "setup server: GET/POST /api/mode (SWITCH), mode in /api/state and /api/finish" || bad "setup server mode API"
for key in mode_title mode_master_d mode_slave_d mode_switch_slave mode_switch_master mode_q_slave mode_q_master mode_d_slave mode_d_master mode_yes done_slave_d; do n=$(grep -c "$key:" $J); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"; done
grep -q '"mode", "services"\|"welcome", "mode"' $J && ok "wizard: the Master / Slave step follows the language" || bad "wizard has no mode step"
# The script itself, run for real in the image's root: master by default, then the boot file says slave.
cmount $R
mkdir -p $R/boot/efi
cat > $R/tmp/mode-test.sh <<'IN'
set -u
M=/usr/local/sbin/alnasl-mode
rm -f /var/lib/alnasl-setup/mode /var/lib/alnasl-setup/mode-applied
$M >/dev/null 2>&1
echo "default: $(cat /run/alnasl-mode/mode) flags: $(ls /run/alnasl-mode | tr '
' ' ')"
printf 'SLAVE
ignored
' > /boot/efi/alnasl-mode.txt
$M >/dev/null 2>&1
echo "boot file slave: $(cat /run/alnasl-mode/mode) flags: $(ls /run/alnasl-mode | tr '
' ' ') file: $(cat /var/lib/alnasl-setup/mode) txt left: $(ls /boot/efi/alnasl-mode.txt 2>/dev/null | wc -l)"
printf 'banana
' > /boot/efi/alnasl-mode.txt
$M >/dev/null 2>&1
echo "boot file junk: $(cat /run/alnasl-mode/mode) txt left: $(ls /boot/efi/alnasl-mode.txt 2>/dev/null | wc -l)"
printf 'master
' > /boot/efi/alnasl-mode.txt
$M >/dev/null 2>&1
echo "boot file master: $(cat /run/alnasl-mode/mode) flags: $(ls /run/alnasl-mode | tr '
' ' ')"
rm -f /var/lib/alnasl-setup/mode /var/lib/alnasl-setup/mode-applied /boot/efi/alnasl-mode.txt
rm -rf /run/alnasl-mode
IN
out=$(chroot $R /bin/bash /tmp/mode-test.sh 2>&1); echo "$out" | sed 's/^/       /'
echo "$out" | grep -q '^default: master flags: master mode ' && ok "alnasl-mode: nothing set = master" || bad "alnasl-mode default"
echo "$out" | grep -q '^boot file slave: slave flags: mode slave  file: slave txt left: 0' && ok "alnasl-mode: alnasl-mode.txt (SLAVE, CRLF) -> slave, file consumed" || bad "alnasl-mode boot file slave"
echo "$out" | grep -q '^boot file junk: slave txt left: 0' && ok "alnasl-mode: a junk boot file is deleted and changes nothing" || bad "alnasl-mode junk boot file"
echo "$out" | grep -q '^boot file master: master flags: master mode ' && ok "alnasl-mode: and back to master" || bad "alnasl-mode back to master"
rm -f $R/tmp/mode-test.sh
cumount $R
[ ! -e $R/var/lib/alnasl-setup/mode ] && [ ! -e $R/var/lib/alnasl-setup/mode-applied ] && ok "no mode file left in the image (a new card asks the wizard)" || bad "a mode file is left in the image"
grep -q 'mode: back to master' $R/usr/local/sbin/alnasl-reset && ok "factory reset clears the mode (it is on the wiped data partition)" || bad "alnasl-reset does not say it clears the mode"

echo "== sizes"
df -h $R | tail -1
echo "== result: $([ $fail = 0 ] && echo ALL CHECKS PASSED || echo SOME CHECKS FAILED)"
sync
