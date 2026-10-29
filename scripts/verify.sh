#!/bin/bash
# Runs on the build VM: loop-mounts the finished (uncompressed) image read-write
# and checks it without hardware. Cleans up what the Alnasl test start leaves
# behind (its data dir), so the image ships with a fresh one.
set -uo pipefail
# All mounts live in a private mount namespace: nothing leaks into the VM's services.
if [ -z "${ALNASL_UNSHARED:-}" ]; then export ALNASL_UNSHARED=1; exec unshare -m --propagation private bash "$0" "$@"; fi
W=/root/w-photon-img5
. $W/lib-chroot.sh
IMG=$W/photon-alnasl-v7.img
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
# v7: the ports depend on the role (/run/alnasl-mode/role); each role's ruleset, as the script makes it.
fwrole() { # role -> both rulesets
  local d; d=$(mktemp -d); [ -n "$1" ] && echo "$1" > $d/role
  bash -c "source <(sed -n '/^CHAIN=/p;/^log()/p;/^ROLE=/,/^app_rule()/p;/^rules_v4()/,/^}/p;/^rules_v6()/,/^}/p' $R/usr/local/sbin/alnasl-firewall | sed 's#/run/alnasl-mode/role#$d/role#'); rules_v4; rules_v6"
  rm -rf $d
}
fw=$(for r in alnasl arkab polis nunki; do fwrole $r; done)
echo "$fw" | grep -q -E -- '--dport 22( |$)' && bad "firewall lets port 22 in" || ok "firewall: port 22 closed"
echo "$fw" | grep -q -i -E 'tailscale|41641' && bad "firewall still has the Tailscale rules" || ok "firewall: no Tailscale rules"
ports() { fwrole "$1" | grep -o -- '-p tcp --dport [0-9]* -j ACCEPT' | awk '{print $4}' | sort -u | tr '\n' ' '; }
[ "$(ports alnasl)" = "4040 " ] && ok "firewall, alnasl box: only 4040 (Alnasl) let in" || bad "firewall, alnasl box: tcp ports '$(ports alnasl)'"
[ "$(ports "")" = "4040 " ] && ok "firewall, no role file: as an alnasl box" || bad "firewall, no role file: tcp ports '$(ports "")'"
[ "$(ports arkab)" = "4050 " ] && ok "firewall, arkab box: only 4050 (Arkab's page) let in" || bad "firewall, arkab box: tcp ports '$(ports arkab)'"
[ -z "$(ports polis)" ] && [ -z "$(ports nunki)" ] && ok "firewall, polis and nunki boxes: no TCP port at all (they dial out)" || bad "firewall: polis '$(ports polis)' nunki '$(ports nunki)'"
for r in alnasl arkab polis nunki; do
  [ "$(fwrole $r | grep -c -- '^-A ALNASL-IN -j DROP$')" = 2 ] && [ "$(fwrole $r | grep -c '^$')" = 0 ] && ok "firewall, $r: both rulesets end in DROP, no blank lines" || bad "firewall, $r: no final DROP, or blank lines"
done
grep -q 'After=.*alnasl-mode.service' $R/etc/systemd/system/alnasl-firewall.service && ok "alnasl-firewall runs after alnasl-mode (it reads the role)" || bad "alnasl-firewall.service not ordered after alnasl-mode"
ts=$(ls $R/usr/local/bin/tailscale* $R/usr/bin/tailscale* $R/usr/sbin/tailscale* $R/usr/local/sbin/alnasl-tailscale-up \
        $R/etc/systemd/system/tailscale* $R/etc/systemd/system/alnasl-tailscale* $R/usr/lib/systemd/system/tailscale* $B/tailscale* 2>/dev/null)
[ -z "$ts" ] && ok "no Tailscale binary, unit, script or key file" || bad "Tailscale pieces: $ts"
grep -q -E 'sshd|tailscale' $R/usr/local/lib/alnasl-setup/server.py && bad "server.py can still reach sshd/tailscale" || ok "server.py: /api/services cannot start sshd or Tailscale"
grep -q -i -E 'tailscale|"ssh"|s_ssh' $R/usr/local/share/alnasl-setup/www/app.js && bad "app.js still offers ssh/Tailscale" || ok "app.js: no ssh/Tailscale switches"

echo "== units"
for u in alnasl-firewall alnasl-firstboot alnasl-wifi alnasl-kiosk-load alnasl-kiosk alnasl-setup docker containerd alnasl alnasl-update.path wpa_supplicant@wlan0 systemd-networkd systemd-resolved getty@tty2 getty@tty3 \
         alnasl-splash alnasl-splash-reboot alnasl-splash-poweroff alnasl-os-update.timer alnasl-reset-boot \
         alnasl-data alnasl-slot-check alnasl-upgrade-boot alnasl-mode alnasl-arkab-pin alnasl-system-update-check.timer; do
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
for f in usr/local/lib/alnasl-setup/server.py usr/local/lib/alnasl-setup/diag.py usr/local/lib/alnasl-setup/bootlog.py usr/local/share/alnasl-setup/www/index.html usr/local/share/alnasl-setup/www/app.js usr/local/share/alnasl-setup/www/app.css \
         usr/local/sbin/alnasl-setup etc/alnasl/keyboard.conf etc/alnasl/kiosk.conf etc/alnasl/image-version etc/wpa_supplicant/wpa_supplicant-wlan0.conf \
         etc/systemd/system/alnasl-setup.service; do
  [ -e $R/$f ] || [ -L $R/$f ] && ok "present: /$f" || bad "missing: /$f"
done
chroot $R python3 -c "import sys; compile(open('/usr/local/lib/alnasl-setup/server.py').read(), 'server.py', 'exec'); print('compiles with image python', sys.version.split()[0])" 2>&1 | sed 's/^/       /'
for s in alnasl-setup alnasl-kiosk alnasl-kiosk-load alnasl-firstboot alnasl-arkab-pin alnasl-wifi-setup alnasl-os-update alnasl-reset alnasl-data alnasl-mode alnasl-sound alnasl-firewall; do bash -n $R/usr/local/sbin/$s && ok "bash -n $s" || bad "bash -n $s"; done
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
echo "GET /api/mode    -> $(c -H "$H" http://127.0.0.1:4041/api/mode) $(head -c 160 /tmp/body) (master/alnasl, not set expected)"
echo "ROLEAPI $(python3 -c 'import json;d=json.load(open("/tmp/body"));print(d["mode"], d["role"], ",".join(d["roles"]), d["set"])')"
echo "BOOTLOG $(c -H "$H" 'http://127.0.0.1:4041/api/bootlog?after=0') $(python3 -c 'import json;d=json.load(open("/tmp/body"));v=d.get("view") or {};print(sorted(k for k in d if k!="view"), "view", sorted(v), type(d["lines"]).__name__)' 2>&1)"
echo "BOOTLOG2 $(c -H "$H" 'http://127.0.0.1:4041/api/bootlog?after=999999') $(python3 -c 'import json;d=json.load(open("/tmp/body"));print("view" in d, d["lines"])' 2>&1)"
echo "BOOTLOGHOST $(c -H 'Host: evil.example:4041' http://127.0.0.1:4041/api/bootlog)"
echo "PRINTERS $(c -H "$H" http://127.0.0.1:4041/api/printers)"
echo "PRINTADD $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"name":"hall","uri":"ipp://10.0.0.9/ipp/print"}' http://127.0.0.1:4041/api/printers/add) $(head -c 80 /tmp/body)"
echo "SOUND $(c -H "$H" http://127.0.0.1:4041/api/sound)"
echo "SOUNDSET $(c -X POST -H "$H" -H 'X-Alnasl-Setup: 1' -H 'Content-Type: application/json' -d '{"output":"jack","volume":50}' http://127.0.0.1:4041/api/sound) $(head -c 80 /tmp/body)"
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
sto=$(chroot $R /bin/bash /tmp/setup-test.sh 2>&1); echo "$sto" | sed 's/^/       /'
grep -q '^ROLEAPI master alnasl alnasl,arkab,polis,nunki False$' <<<"$sto" && ok "/api/mode: v6's word (master, for Arkab's sake) and the v7 role beside it, four roles" || bad "/api/mode role fields"
grep -q "^BOOTLOG 200 \['lines', 'ready', 'seq', 'status'\] view \['logview', 'mono', 'steps'\] list$" <<<"$sto" && ok "/api/bootlog: seq, ready, status, lines, and the layout on the first ask" || bad "/api/bootlog shape"
grep -q '^BOOTLOG2 200 False \[\]$' <<<"$sto" && ok "/api/bootlog?after=N: only newer lines, no layout" || bad "/api/bootlog?after"
grep -q '^BOOTLOGHOST 403$' <<<"$sto" && ok "/api/bootlog: a foreign Host is refused" || bad "/api/bootlog foreign Host"
grep -q '^PRINTERS 200' <<<"$sto" && grep -q '^PRINTADD 400.*not_polis' <<<"$sto" && ok "printers: listed anywhere, added only on a Polis box (400 here)" || bad "printers API: $(grep '^PRINT' <<<"$sto" | tr '\n' ' ')"
grep -q '^SOUND 200' <<<"$sto" && grep -q '^SOUNDSET 400.*not_nunki' <<<"$sto" && ok "sound: read anywhere, set only on a Nunki box (400 here)" || bad "sound API: $(grep '^SOUND' <<<"$sto" | tr '\n' ' ')"
echo "  -- redaction unit test (fake wpa conf with a psk, a clear passphrase and a Tailscale key; image python) --"
install -m 0644 $W/test-diag.py $R/tmp/test-diag.py
chroot $R python3 -I /tmp/test-diag.py 2>&1 | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "redaction: no secret survives, SSIDs do" || bad "redaction unit test failed"
echo "  -- v7 boot log: redaction, allow-list, colours, status line (image python) --"
install -m 0644 $W/test-bootlog.py $R/tmp/test-bootlog.py
chroot $R python3 -I /tmp/test-bootlog.py /usr/local/lib/alnasl-setup/bootlog.py 2>&1 | grep -v '^ok ' | sed 's/^/       /'
[ "${PIPESTATUS[0]}" = 0 ] && ok "boot log: no secret reaches the hall screen, failures always do (test-bootlog.py)" || bad "boot log unit test failed"
rm -f $R/tmp/test-bootlog.py
cumount $R
rm -rf $R/var/lib/alnasl-setup $R/tmp/setup-test.sh $R/tmp/setup.* $R/tmp/body $R/tmp/test-diag.py $R/run/alnasl-kiosk
find $R/usr/local -name __pycache__ -prune -exec rm -rf {} +

echo "== v4: PrivateTmp, policies, OSK extension, resolution, touch"
if grep -E '^[[:space:]]*PrivateTmp=(yes|true|1)' $R/etc/systemd/system/alnasl-setup.service $R/etc/systemd/system/alnasl-setup.service.d/*.conf $R/usr/lib/systemd/system/alnasl-setup.service 2>/dev/null; then bad "alnasl-setup.service has PrivateTmp=yes (wpa_cli replies would be swallowed)"; else ok "alnasl-setup.service has no PrivateTmp=yes"; fi
grep -q '^PrivateTmp=no' $R/etc/systemd/system/alnasl-setup.service && ok "alnasl-setup.service sets PrivateTmp=no explicitly" || bad "PrivateTmp=no missing"
[ "$(cat $R/etc/alnasl/image-version)" = v7 ] && ok "image-version v7" || bad "image-version: $(cat $R/etc/alnasl/image-version)"
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
assert mb["matches"] == ["http://localhost:%d/*" % p for p in (4040, 4050, 4061, 4062)], mb["matches"]
bar = [c for c in m["content_scripts"] if "external-bar.js" in c.get("js", [])][0]
for p in (4040, 4041, 4050, 4061, 4062):
    assert "http://localhost:%d/*" % p in bar["exclude_matches"] and "http://127.0.0.1:%d/*" % p in bar["exclude_matches"], p
assert m["version"].startswith("7.")
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
grep -q 'Back to Alnasl' $b && grep -q 'Terug naar Alnasl' $b && grep -q '"http://localhost:4041/"' $b && grep -q 'history.back' $b && grep -q 'http://localhost:4041/menu' $b && ok "external-bar.js: EN+NL 'Back to Alnasl', history.back first, then the menu server's / (the role's app), menu button" || bad "external-bar.js content"
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
for r in alnasl arkab polis nunki; do echo "       $r: $(fwrole $r | grep -c -E '^-A ALNASL-IN') rules (IPv4 + IPv6)"; done
if command -v iptables-restore >/dev/null; then
  for r in alnasl polis; do
    fwrole $r | awk '/^\*filter/{n++} n==1' | iptables-restore --noflush --test && ok "iptables-restore --test accepts the $r IPv4 ruleset" || bad "iptables-restore --test refuses the $r ruleset"
  done
fi

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
grep -q '^ALNASL_TRAIN=v7$' $R/etc/alnasl/image-release && grep -q -E '^ALNASL_VERSION=7\.[0-9]+' $R/etc/alnasl/image-release && ok "image-release: $(grep -h ALNASL_ $R/etc/alnasl/image-release | tr '\n' ' ')" || bad "image-release"
grep -E '^[^#]*[[:space:]]/[[:space:]]' $R/etc/fstab && bad "fstab still mounts / (the slot comes from the kernel command line)" || ok "fstab: no / line"
grep -q -i swap $R/etc/fstab && bad "fstab has swap" || ok "fstab: no swap"
grep -q "^PARTUUID=$DISK_ID-01[[:space:]]*/boot/efi" $R/etc/fstab && ok "fstab: /boot/efi by PARTUUID $DISK_ID-01" || bad "fstab /boot/efi line"
s=$(chroot $R systemctl is-enabled resizefs.service 2>&1 | tail -1); [ "$s" = masked ] && ok "resizefs masked (it would grow / over slot B)" || bad "resizefs.service: $s"
[ -d $R/data ] && ok "/data mount point" || bad "no /data"
for f in keyboard.conf kiosk.conf; do [ "$(readlink $R/etc/alnasl/$f)" = /data/etc/alnasl/$f ] && ok "/etc/alnasl/$f -> data partition" || bad "/etc/alnasl/$f is not the data symlink"; done
for d in var/lib/arkab var/lib/polis var/lib/polis-update var/lib/nunki var/lib/nunki-update etc/cups var/lib/alnasl-setup var/lib/alnasl-os-update var/lib/docker var/log/journal etc/wpa_supplicant etc/systemd/network/10-wired.network.d; do
  grep -q "$d" $R/usr/local/sbin/alnasl-data && ok "alnasl-data binds /$d" || bad "alnasl-data does not keep /$d"
done
for a in alnasl arkab polis nunki; do
  grep -q "^dir /var/lib/$a/update \"\$(owner $a)\" 0750" $R/usr/local/sbin/alnasl-data && ok "alnasl-data makes /var/lib/$a/update (the app's update button works)" || bad "alnasl-data does not make /var/lib/$a/update: $a would ask for a manual update"
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

echo "== v7 roles: alnasl, arkab, polis, nunki (docs/v7-plan.md section 1)"
M=$R/usr/local/sbin/alnasl-mode
[ -x $M ] && bash -n $M && ok "alnasl-mode: executable, bash -n" || bad "alnasl-mode"
MS=$R/etc/systemd/system/alnasl-mode.service
grep -q '^DefaultDependencies=no' $MS && grep -q '^After=alnasl-data.service' $MS && grep -q '^Before=sysinit.target' $MS && ! grep -q -E '^(After|Requires|Wants)=.*(basic|multi-user|reset-boot|network)' $MS && ok "alnasl-mode.service: before sysinit.target, after the data partition, no default dependencies (no ordering cycle with the path units)" || bad "alnasl-mode.service ordering (a cycle through paths.target / basic.target)"
cond() { sed -n 's/^ConditionPathExists=//p' $R/etc/systemd/system/$1.d/alnasl-mode.conf 2>/dev/null; }
for ru in alnasl:alnasl.service alnasl:alnasl-update.path arkab:arkab.service arkab:arkab-update.path \
          polis:polis.service polis:polis-update.path polis:cups.service \
          nunki:nunki.service nunki:nunki-update.path nunki:alnasl-sound.service; do
  r=${ru%%:*}; u=${ru#*:}
  [ "$(cond $u)" = "/run/alnasl-mode/$r" ] && ok "$u: $r boxes only" || bad "$u: condition '$(cond $u)' ($r expected)"
done
for u in alnasl-kiosk.service alnasl-kiosk-load.service; do
  [ -z "$(cond $u)" ] && ok "$u: every role (the screen shows the role's page)" || bad "$u still has a role condition: $(cond $u)"
done
# The apps: each installed by its own install.sh, shipped switched off (a new box is an alnasl box).
for a in arkab polis nunki; do
  V=$(cat $R/opt/$a/current/VERSION 2>/dev/null)
  [ -n "$V" ] && [ -x $R/opt/$a/current/bin/$a ] && ok "$a $V installed in /opt/$a (current)" || bad "$a is not in the image (/opt/$a/current/bin/$a)"
  if chroot $R /bin/bash -c "ldd /opt/$a/current/erts-*/bin/beam.smp | grep -q 'not found'"; then bad "$a's runtime misses a library on Photon"; else ok "$a's runtime: every library found on Photon"; fi
  chroot $R getent passwd $a >/dev/null && ok "user $a" || bad "no user $a"
  for u in $a.service $a-update.path; do
    st=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); [ "$st" = disabled ] && ok "$u ships disabled (alnasl-mode enables it on a $a box)" || bad "$u: $st (disabled expected)"
  done
done
ls $R/opt/arkab/current/lib/circuits_uart-*/priv/circuits_uart >/dev/null 2>&1 && ok "Arkab: the serial program is in the release" || bad "Arkab has no circuits_uart (cannot read a board)"
chroot $R id -nG arkab | grep -q -w dialout && ok "arkab in dialout (the serial ports)" || bad "arkab not in dialout"
grep -q '^PORT=4050$' $R/etc/arkab/arkab.env && ! grep -q '^ARKAB_LISTEN=local' $R/etc/arkab/arkab.env && ok "arkab.env: port 4050, the hall's network may look" || bad "arkab.env"
grep -q 'ARKAB_DATA=/var/lib/arkab' $R/etc/systemd/system/arkab.service && ok "arkab.service keeps its data in /var/lib/arkab (the data partition)" || bad "arkab.service ARKAB_DATA"
grep -q '^PORT=4061$' $R/etc/polis/polis.env && ! grep -q '^POLIS_LISTEN=lan' $R/etc/polis/polis.env && ok "polis.env: port 4061, this box only (no --lan)" || bad "polis.env"
grep -q '^PORT=4062$' $R/etc/nunki/nunki.env && ! grep -q '^NUNKI_LISTEN=lan' $R/etc/nunki/nunki.env && ok "nunki.env: port 4062, this box only (no --lan)" || bad "nunki.env"
chroot $R id -nG nunki | grep -q -w audio && ok "nunki in audio (the sound card)" || bad "nunki not in audio"
# Polis's printing: CUPS from Photon, switched off unless this is a Polis box; PDFs go to the printer as they are.
rpm --root=$R -q cups alsa-lib alsa-utils | sed 's/^/       /'
rpm --root=$R -q cups >/dev/null && [ -x $R/usr/bin/lp ] && [ -x $R/usr/sbin/lpadmin ] && ok "cups installed (lp, lpadmin)" || bad "cups / lp / lpadmin missing"
for u in cups.service; do
  st=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); case "$st" in disabled|static|indirect) ok "$u: $st (alnasl-mode enables it on a polis box)" ;; *) bad "$u: $st (off expected)" ;; esac
done
grep -q '^ExecStart=/usr/sbin/cupsd -f$' $R/etc/systemd/system/cups.service && ok "cups.service: our own unit (Photon ships only a SysV script)" || bad "no native cups.service"
grep -q '^application/pdf[[:space:]]*application/vnd.cups-pdf[[:space:]]*0[[:space:]]*-' $R/etc/cups/local.convs && ok "cups: PDF passes straight to the printer (local.convs)" || bad "cups local.convs"
[ -f $R/usr/share/alnasl/defaults/etc/cups/cupsd.conf ] && [ -f $R/usr/share/alnasl/defaults/etc/cups/local.convs ] && ok "cups: the image's configuration kept in defaults (alnasl-data puts it back)" || bad "cups defaults missing"
grep -q '/etc/cups' $R/usr/local/sbin/alnasl-data && grep -q 'printers.conf' $R/usr/local/sbin/alnasl-data && ok "alnasl-data: printers survive updates, the rest of /etc/cups is the image's" || bad "alnasl-data and /etc/cups"
# Nunki's voice and sound.
[ -x $R/usr/bin/aplay ] && [ -x $R/usr/bin/amixer ] && ok "alsa-utils: aplay, amixer" || bad "aplay/amixer missing"
[ -x $R/usr/local/sbin/alnasl-sound ] && bash -n $R/usr/local/sbin/alnasl-sound && ok "alnasl-sound: executable, bash -n" || bad "alnasl-sound"
st=$(chroot $R systemctl is-enabled alnasl-sound.service 2>&1 | tail -1); [ "$st" = disabled ] && ok "alnasl-sound.service ships disabled (a nunki box's)" || bad "alnasl-sound.service: $st"
[ -x $R/usr/local/bin/espeak-ng ] && [ -x $R/opt/espeak-ng/bin/espeak-ng ] && ok "espeak-ng in /opt/espeak-ng, run by /usr/local/bin/espeak-ng" || bad "espeak-ng missing"
chroot $R /bin/bash -c 'LD_LIBRARY_PATH=/opt/espeak-ng/lib ldd /opt/espeak-ng/bin/espeak-ng' | grep -E 'not found|pulse' && bad "espeak-ng: a library is missing, or it wants PulseAudio" || ok "espeak-ng: every library found, no PulseAudio"
cmount $R
v=$(chroot $R /usr/local/bin/espeak-ng --voices=nl 2>&1 | head -n 3); echo "$v" | sed 's/^/       /'
chroot $R /usr/local/bin/espeak-ng -v nl -w /tmp/espeak.wav "Ronde drie begint nu" 2>&1 | sed 's/^/       /'
[ -s $R/tmp/espeak.wav ] && head -c 4 $R/tmp/espeak.wav | grep -q RIFF && ok "espeak-ng speaks Dutch in the image ($(stat -c %s $R/tmp/espeak.wav) bytes of wav)" || bad "espeak-ng does not speak in the image"
rm -f $R/tmp/espeak.wav
cumount $R
grep -q 'alnasl_vol' $R/usr/local/sbin/alnasl-sound && grep -q 'vc4hdmi0' $R/usr/local/sbin/alnasl-sound && grep -q 'Headphones' $R/usr/local/sbin/alnasl-sound && ok "alnasl-sound: HDMI or the 3.5 mm jack, softvol volume" || bad "alnasl-sound content"
# The menu and the wizard.
[ -f $B/alnasl-mode.txt.example ] && [ ! -f $B/alnasl-mode.txt ] && grep -q 'polis' $B/alnasl-mode.txt.example && grep -q 'nunki' $B/alnasl-mode.txt.example && ok "boot partition: alnasl-mode.txt example (four roles), no live file" || bad "boot partition mode files"
# The Arkab PIN from the card: the file is pre-created with its header, the reader is ordered before Arkab, and it never shows the PIN.
P=$B/alnasl-arkab-pin.txt; PS=$R/usr/local/sbin/alnasl-arkab-pin
[ -f $P ] && grep -q '4 to 64 characters' $P && grep -q '4 tot 64 tekens' $P && grep -q 'port\|4050' $P && grep -q 'plain HTTP' $P && grep -q 'gewoon HTTP' $P && grep -q 'EMPTIES' $P && grep -q 'LEEG' $P && grep -q -i 'remove' $P && grep -q -i 'verwijderen' $P && ok "boot partition: alnasl-arkab-pin.txt is there with its English and Dutch header" || bad "boot partition alnasl-arkab-pin.txt or its header"
[ "$(grep -a -c '^PIN=[^[:cntrl:]]' $P)" = 0 ] && grep -a -q '^PIN=' $P && ok "boot partition: the shipped PIN line is empty" || bad "the shipped alnasl-arkab-pin.txt has a PIN in it"
grep -q $'' $P && ok "boot partition: alnasl-arkab-pin.txt keeps its Windows line endings" || bad "alnasl-arkab-pin.txt lost its CRLF line endings"
u=$R/etc/systemd/system/alnasl-arkab-pin.service
grep -q '^Before=arkab.service' $u && grep -q '^After=.*alnasl-mode.service' $u && grep -q '^After=.*alnasl-data.service' $u && grep -q '^ConditionPathExists=/run/alnasl-mode/arkab' $u && grep -q '^Wants=alnasl-arkab-pin.service' $R/etc/systemd/system/arkab.service.d/alnasl-pin.conf && grep -q '^After=alnasl-arkab-pin.service' $R/etc/systemd/system/arkab.service.d/alnasl-pin.conf && ok "PIN reader: only on an Arkab box, after the role and the data partition, before arkab.service" || bad "alnasl-arkab-pin.service ordering"
! grep -n -E 'echo[^#]*\$pin|printf[^#]*\$pin[^#]*(>&2|logger)|logger[^#]*\$pin|set -x|\$\{?pin\}?[^#]*\| *(tee|logger)' $PS >/dev/null && [ "$(grep -c 'printf .set.n%s.n. "$pin"' $PS)" = 1 ] && ok "PIN reader: the PIN goes only into the request file, never to a log or the screen" || bad "alnasl-arkab-pin may show the PIN"
# Run it for real (temporary files): a filled line becomes a 0600 request and a blank line with a status; a short one is refused; a non-Arkab box is left alone.
T=$(mktemp -d); touch $T/flag; mkdir $T/d
pinrun() { cp $P $T/f.txt; sed -i "s/^PIN=[^[:cntrl:]]*/PIN=$1/" $T/f.txt; rm -f $T/d/pin-request; ALNASL_ARKAB_PIN_FILE=$T/f.txt ALNASL_ARKAB_DATA=$T/d ALNASL_MODE_FLAG=${2:-$T/flag} ALNASL_ARKAB_OWNER= bash $PS > $T/out.txt; }
pinrun 4821; [ "$(tr '\n' '|' < $T/d/pin-request)" = 'set|4821|' ] && [ "$(stat -c %a $T/d/pin-request)" = 600 ] && grep -a -q '^PIN=.\?$' $T/f.txt && grep -a -q 'Last result: PIN set' $T/f.txt && ! grep -q 4821 $T/out.txt $T/f.txt && ok "PIN reader: 4821 becomes a 0600 request, the line is blank, the status says set, the PIN is not echoed" || bad "PIN reader, a good PIN"
pinrun 123; [ ! -e $T/d/pin-request ] && grep -a -q 'Last result: refused, too short' $T/f.txt && ok "PIN reader: a 3-character PIN is refused and says so" || bad "PIN reader, a short PIN"
pinrun remove; [ "$(tr '\n' '|' < $T/d/pin-request)" = 'remove|' ] && ok "PIN reader: PIN=remove becomes a remove request" || bad "PIN reader, remove"
pinrun 9999 $T/noflag; [ ! -e $T/d/pin-request ] && grep -a -q '^PIN=9999' $T/f.txt && ok "PIN reader: a box that is not Arkab leaves the file alone" || bad "PIN reader on a non-Arkab box"
pinrun ''; [ ! -e $T/d/pin-request ] && same $P $T/f.txt && ok "PIN reader: an empty PIN line changes nothing" || bad "PIN reader, empty line"
rm -rf $T
grep -q '/api/mode' $S && grep -q '"SWITCH"' $S && ok "setup server: GET/POST /api/mode (SWITCH), as Arkab's page calls it" || bad "setup server mode API"
grep -q '"/api/bootlog"' $S && grep -q '/api/printers' $S && grep -q '/api/sound' $S && ok "setup server: /api/bootlog, /api/printers, /api/sound" || bad "setup server v7 routes"
for key in role_title role_d role_alnasl_d role_arkab_d role_polis_d role_nunki_d role_now role_change role_yes role_q role_switch_d role_down done_arkab_d done_polis_d done_nunki_d printers_tile printers_d sound_tile sound_d out_jack sound_test; do
  n=$(grep -c -E "(^|[^A-Za-z0-9_])$key:" $J); [ "$n" = 2 ] && ok "app.js: $key in EN and NL" || bad "app.js: $key found $n times (2 expected)"
done
grep -q '"welcome", "mode"' $J && ok "wizard: the role step follows the language" || bad "wizard has no role step"
grep -q 'printersPage' $J && grep -q 'soundPage' $J && ok "Settings: Printers (polis) and Sound (nunki) pages" || bad "app.js lacks the printers/sound pages"
# Small screens: 800x480, 1024x600, 720x720.
C=$R/usr/local/share/alnasl-setup/www/app.css
grep -q '@media (max-width: 900px), (max-height: 640px)' $C && grep -q '@media (max-width: 560px)' $C && grep -q '@media (max-height: 520px)' $C && ok "app.css: small-screen rules (900x640 and below, one column under 560 px, short screens)" || bad "app.css small-screen media queries"
grep -q -- '--tap: 48px' $C && grep -q 'min-height: 44px' $C && grep -q 'grid-template-columns: 1fr' $C && ok "app.css: tap targets 44-48 px, one column on narrow screens" || bad "app.css small-screen sizes"
grep -q ':focus-visible' $C && ok "app.css: focus stays visible" || bad "app.css: no :focus-visible"
# The kiosk follows the role.
grep -q 'KIOSK_APP_PORT' $R/usr/local/sbin/alnasl-kiosk && grep -q '/run/alnasl-mode/role' $R/usr/local/sbin/alnasl-kiosk && ok "alnasl-kiosk: the watchdog watches the role's own app" || bad "alnasl-kiosk KIOSK_APP_PORT"
if [ -n "$dk" ]; then grep -q 'KIOSK_APP_PORT' <<<"$dk" && ok "kiosk image's kiosk.sh: KIOSK_APP_PORT" || bad "kiosk image is not the v7 kiosk (rebuild it)"; fi
# The boot log (painter, browser page, server).
grep -q 'import bootlog' $R/usr/local/sbin/alnasl-splash && grep -q 'api/bootlog' $R/usr/local/share/alnasl-setup/www/screen.html && ok "boot log: painter and /boot page both read it" || bad "boot log wiring"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert set(m["mono"]) >= {"1080","720"} and "colours" in m["logview"] and len(m["logview"]["fade"]) >= 4' $R/usr/share/alnasl/splash/messages.json && ok "messages.json: mono atlas (1080, 720) and the log layout" || bad "messages.json lacks mono/logview"

# The script itself, run for real in the image's root (its systemctl enable/disable work on the image's
# units; the run ends as a new box: alnasl, everything else off).
cmount $R
mkdir -p $R/boot/efi
cat > $R/tmp/mode-test.sh <<'IN'
set -u
M=/usr/local/sbin/alnasl-mode
E() { local o=""; for u in alnasl.service arkab.service polis.service cups.service nunki.service alnasl-sound.service alnasl-kiosk.service; do
        [ "$(systemctl is-enabled $u 2>/dev/null)" = enabled ] && o="$o ${u%.service}"; done; echo "on:$o"; }
F() { echo "mode=$(cat /run/alnasl-mode/mode) role=$(cat /run/alnasl-mode/role) flags=$(ls /run/alnasl-mode | tr '\n' ' ')"; }
txt() { printf '%s\r\nignored\r\n' "$1" > /boot/efi/alnasl-mode.txt; $M >/dev/null 2>&1; }
rm -f /var/lib/alnasl-setup/mode /var/lib/alnasl-setup/mode-applied /etc/alnasl/role-applied
$M >/dev/null 2>&1
echo "default: $(F) $(E) applied=$(cat /etc/alnasl/role-applied)"
txt SLAVE
echo "slave: $(F) file=$(cat /var/lib/alnasl-setup/mode) txt=$(ls /boot/efi/alnasl-mode.txt 2>/dev/null | wc -l) $(E)"
txt banana
echo "junk: $(F) txt=$(ls /boot/efi/alnasl-mode.txt 2>/dev/null | wc -l)"
txt polis
echo "polis: $(F) $(E)"
txt Nunki
echo "nunki: $(F) $(E)"
txt master
echo "master: $(F) $(E)"
# A v6 slave updated to v7: its data partition says slave (mode and v6's mode-applied); the new slot is the
# image as shipped (Alnasl on, Arkab off, nothing applied in the slot). It must come up as an Arkab box.
echo slave > /var/lib/alnasl-setup/mode; echo slave > /var/lib/alnasl-setup/mode-applied; rm -f /etc/alnasl/role-applied
$M >/dev/null 2>&1
echo "v6 slave updated: $(F) $(E) v6note=$(ls /var/lib/alnasl-setup/mode-applied 2>/dev/null | wc -l) applied=$(cat /etc/alnasl/role-applied)"
# A second boot of the same: nothing switched on again (Settings > Services stays as it was).
systemctl disable alnasl-kiosk.service >/dev/null 2>&1
$M >/dev/null 2>&1
echo "second boot: $(E)"
# Back to a new box.
rm -f /var/lib/alnasl-setup/mode /var/lib/alnasl-setup/mode-applied /etc/alnasl/role-applied /boot/efi/alnasl-mode.txt
$M >/dev/null 2>&1
echo "new again: $(F) $(E)"
rm -f /var/lib/alnasl-setup/mode /var/lib/alnasl-setup/mode-applied /etc/alnasl/role-applied
rm -rf /run/alnasl-mode
IN
out=$(chroot $R /bin/bash /tmp/mode-test.sh 2>&1); echo "$out" | sed 's/^/       /'
want() { grep -q -x -F -- "$1" <<<"$out" && ok "$2" || bad "$2: expected '$1'"; }
want "default: mode=master role=alnasl flags=alnasl mode role  on: alnasl alnasl-kiosk applied=alnasl" "alnasl-mode: nothing set = alnasl (v6's word 'master' beside it), Alnasl and the screen on"
want "slave: mode=slave role=arkab flags=arkab mode role  file=arkab txt=0 on: arkab alnasl-kiosk" "alnasl-mode: alnasl-mode.txt SLAVE (CRLF) = arkab, file consumed, Arkab on, Alnasl off"
want "junk: mode=slave role=arkab flags=arkab mode role  txt=0" "alnasl-mode: a junk boot file is deleted and changes nothing"
want "polis: mode=polis role=polis flags=mode polis role  on: polis cups alnasl-kiosk" "alnasl-mode: polis = Polis + CUPS on, Arkab off"
want "nunki: mode=nunki role=nunki flags=mode nunki role  on: nunki alnasl-sound alnasl-kiosk" "alnasl-mode: Nunki = Nunki + sound on, Polis and CUPS off"
want "master: mode=master role=alnasl flags=alnasl mode role  on: alnasl alnasl-kiosk" "alnasl-mode: master = alnasl again, the others off"
want "v6 slave updated: mode=slave role=arkab flags=arkab mode role  on: arkab alnasl-kiosk v6note=0 applied=arkab" "a v6 slave updated to v7 keeps its role: Arkab on in the new slot, Alnasl off"
want "second boot: on: arkab" "alnasl-mode: a box that is still what it was keeps what Settings switched off"
want "new again: mode=master role=alnasl flags=alnasl mode role  on: alnasl alnasl-kiosk" "alnasl-mode: and back to a new box"
rm -f $R/tmp/mode-test.sh
cumount $R
for u in alnasl.service alnasl-update.path alnasl-kiosk.service; do st=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); [ "$st" = enabled ] && ok "after the test: $u enabled, as shipped" || bad "after the test: $u $st"; done
for u in arkab.service polis.service nunki.service cups.service alnasl-sound.service; do st=$(chroot $R systemctl is-enabled $u 2>&1 | tail -1); [ "$st" = disabled ] && ok "after the test: $u disabled, as shipped" || bad "after the test: $u $st"; done
[ ! -e $R/var/lib/alnasl-setup/mode ] && [ ! -e $R/var/lib/alnasl-setup/mode-applied ] && [ ! -e $R/etc/alnasl/role-applied ] && ok "no role file left in the image (a new card asks the wizard)" || bad "a role file is left in the image"
grep -q 'role: back to alnasl' $R/usr/local/sbin/alnasl-reset && grep -q 'polis.service nunki.service' $R/usr/local/sbin/alnasl-reset && ok "factory reset: stops every role's app, clears the role (on the wiped data partition)" || bad "alnasl-reset and the roles"
U=$R/usr/local/sbin/alnasl-system-update
grep -q 'def box_role' $U && grep -q 'ROLE_APP' $U && grep -q 'def carry_app' $U && ok "system update: health and carry-over follow the role (Polis and Nunki included)" || bad "alnasl-system-update is not role-aware"

echo "== v7.1: the screen after an update, and what a box with no screen can still tell"
# The kiosk chain must never end in a job that nothing retries (docs/v7-blackscreen.md).
KL=$R/etc/systemd/system/alnasl-kiosk-load.service
grep -q '^Requires=docker.service' $KL && bad "alnasl-kiosk-load Requires=docker: a late docker drops it for good" || ok "alnasl-kiosk-load does not Require docker (a late docker cannot drop it)"
grep -q 'docker info' $R/usr/local/sbin/alnasl-kiosk-load && ok "alnasl-kiosk-load waits for docker itself" || bad "alnasl-kiosk-load does not wait for docker"
grep -B1 -A3 '"--progress", str(pct)' $R/usr/local/sbin/alnasl-kiosk-load | grep -q 'except Exception' && ok "alnasl-kiosk-load: a slow progress painter cannot cut the docker load" || bad "alnasl-kiosk-load: the progress call can still kill the load"
grep -q 'systemctl start --no-block alnasl-kiosk-load.service' $R/usr/local/sbin/alnasl-kiosk && ok "alnasl-kiosk asks for the image again when nothing is loading it" || bad "alnasl-kiosk never asks for the image again"
cdd=$(cat $R/etc/systemd/system/containerd.service.d/*.conf 2>/dev/null)
grep -q '^TimeoutStartSec=300$' <<<"$cdd" && grep -q '^Restart=on-failure$' <<<"$cdd" && ok "containerd: 5 min to start, and another try (drop-in)" || bad "containerd start timeout/restart drop-in missing"
grep -q 'tmp = "%s.new.%d" % (path, os.getpid())' $U && grep -q 'STATUS_LOCK' $U && ok "system update: one temporary file per process, status writes locked (the boot check cannot be raced by --check)" || bad "system update: a shared temporary file (boot check vs --check race)"
grep -q 'activating|reloading' $R/usr/local/sbin/alnasl-kiosk && ok "alnasl-kiosk leaves a running or retrying load alone" || bad "alnasl-kiosk restarts a load that is running"
grep -q 'def kiosk_loading' $U && grep -q 'HEALTH_MAX_MINUTES = 60' $U && ok "a trial boot is not restarted while the kiosk image is still loading (up to 60 min)" || bad "the health check can reboot in the middle of the kiosk load"
grep -q 'def trial_report' $U && grep -q 'trial_report(version' $U && ok "a trial boot that fails leaves its diagnostics on the boot partition" || bad "no diagnostics from a failed trial boot"
D=$R/usr/local/lib/alnasl-setup/diag.py
grep -q 'def role_text' $D && grep -q '"id": "role"' $D && ok "diagnostics: a Role section (chosen, this boot, flags)" || bad "diagnostics have no Role section"
for u in arkab.service polis.service nunki.service cups.service alnasl-sound.service alnasl-mode.service alnasl-kiosk-load.service containerd.service alnasl-slot-check.service; do
  grep -q "\"$u\"" $D || { bad "diagnostics do not list $u"; continue; }
done
grep -q 'ConditionResult' $D && ok "diagnostics: every role's units, with whether their condition held" || bad "diagnostics do not show ConditionResult"
# The diagnostics run end to end in the image's Python (the Role section on a box with no role yet).
dg=$(chroot $R /usr/bin/python3 -c 'import sys; sys.path.insert(0,"/usr/local/lib/alnasl-setup"); import diag; print("ROLE" if "chosen" in diag.role_text() else "NOROLE")' 2>&1 | tail -1)
[ "$dg" = ROLE ] && ok "diag.role_text() runs in the image" || bad "diag.role_text(): $dg"

echo "== v7.3: the setup hotspot and its captive portal (docs/captive-portal.md; qemu has no Wi-Fi, so no radio here)"
L=$R/usr/local/lib/alnasl-setup; SU=$R/etc/systemd/system; WWWD=$R/usr/local/share/alnasl-setup/www
for f in usr/local/lib/alnasl-setup/hotspot.py usr/local/lib/alnasl-setup/portal.py usr/local/lib/alnasl-setup/alnasl_qr.py usr/local/lib/alnasl-setup/arkab_live.py \
         usr/local/share/alnasl-setup/www/portal.html usr/local/share/alnasl-setup/www/portal.js etc/alnasl/hotspot-dnsmasq.conf \
         usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt usr/sbin/hostapd usr/sbin/hostapd_cli usr/sbin/dnsmasq; do
  [ -e $R/$f ] && ok "present: /$f" || bad "missing: /$f"
done
[ -x $L/hotspot.py ] && [ -x $L/portal.py ] && ok "hotspot.py and portal.py are executable" || bad "hotspot.py/portal.py modes"
for m in hotspot portal alnasl_qr arkab_live; do
  chroot $R python3 -c "compile(open('/usr/local/lib/alnasl-setup/$m.py').read(), '$m.py', 'exec')" && ok "$m.py compiles with the image's python" || bad "$m.py does not compile"
done
for b in /usr/sbin/hostapd /usr/sbin/hostapd_cli /usr/sbin/dnsmasq; do
  ! chroot $R ldd $b 2>&1 | grep -q 'not found' && ok "$b: every library is there" || bad "$b: a library is missing"
done
echo "       $(chroot $R /usr/sbin/hostapd -v 2>&1 | head -1); $(chroot $R /usr/sbin/dnsmasq --version 2>&1 | head -1)"
chroot $R /usr/sbin/dnsmasq --test --conf-file=/etc/alnasl/hotspot-dnsmasq.conf >/dev/null 2>&1 && ok "dnsmasq accepts hotspot-dnsmasq.conf" || bad "dnsmasq --test refuses hotspot-dnsmasq.conf"
DC=$R/etc/alnasl/hotspot-dnsmasq.conf
grep -q '^interface=wlan0$' $DC && grep -q '^bind-interfaces$' $DC && grep -q '^listen-address=10.42.0.1$' $DC && ! grep -q -E '^(interface|listen-address)=.*(eth|0\.0\.0\.0)' $DC \
  && grep -q '^address=/#/10.42.0.1$' $DC && grep -q '^dhcp-option=114,"http://10.42.0.1/api/captive"$' $DC && grep -q '^no-resolv$' $DC && ! grep -q '^server=' $DC \
  && ok "dnsmasq: wlan0 and 10.42.0.1 only, every name is the box, option 114, no upstream" || bad "hotspot-dnsmasq.conf"
# Units: the daemon is enabled and ordered; the three it drives have no [Install] (nothing else starts them); stock dnsmasq never runs.
s=$(chroot $R systemctl is-enabled alnasl-hotspot.service 2>&1 | tail -1); [ "$s" = enabled ] && ok "alnasl-hotspot enabled" || bad "alnasl-hotspot: $s"
for u in alnasl-hotspot-ap alnasl-hotspot-dns alnasl-portal; do
  [ -f $SU/$u.service ] && ! grep -q '^\[Install\]' $SU/$u.service && grep -q '^PartOf=alnasl-hotspot.service' $SU/$u.service && ok "$u: no [Install], part of alnasl-hotspot" || bad "$u unit"
done
s=$(chroot $R systemctl is-enabled dnsmasq.service 2>&1 | tail -1); [ "$s" = masked ] && ok "stock dnsmasq.service masked (it would answer on Ethernet)" || bad "dnsmasq.service: $s"
H=$SU/alnasl-hotspot.service
grep -q '^RequiresMountsFor=/boot/efi' $H && grep -q '^After=.*alnasl-firewall.service' $H && grep -q '^After=.*alnasl-data.service' $H && grep -q '^After=.*wpa_supplicant@wlan0.service' $H \
  && grep -q '^After=.*systemd-networkd.service' $H && grep -q '^ExecStopPost=.*hotspot.py --stop' $H && ok "alnasl-hotspot: after the boot partition, data, firewall, networkd and the supplicant; gives wlan0 back when it stops" || bad "alnasl-hotspot.service ordering"
grep -q '^After=alnasl-hotspot-ap.service' $SU/alnasl-hotspot-dns.service && grep -q '^Requires=alnasl-hotspot-ap.service' $SU/alnasl-hotspot-dns.service \
  && grep -q '^After=alnasl-hotspot-ap.service' $SU/alnasl-portal.service && ok "DNS/DHCP and the page come after (and need) the access point" || bad "hotspot unit order"
P=$SU/alnasl-portal.service
grep -q '^DynamicUser=yes' $P && grep -q '^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$' $P && grep -q '^NoNewPrivileges=yes' $P && grep -q '^ProtectSystem=strict' $P \
  && ok "the portal runs as a throwaway user with nothing but port 80" || bad "alnasl-portal.service hardening"
# The firewall: 53/67/80 only with the hotspot flag, only on wlan0, never on Ethernet; the hotspot's phones get nothing else.
fwhs() { # role flag(1/0) -> both rulesets
  local d; d=$(mktemp -d); echo "$1" > $d/role; [ "$2" = 1 ] && touch $d/active
  bash -c "source <(sed -n '/^CHAIN=/p;/^log()/p;/^ROLE=/,/^app_rule()/p;/^rules_v4()/,/^}/p;/^rules_v6()/,/^}/p' $R/usr/local/sbin/alnasl-firewall | sed 's#/run/alnasl-mode/role#$d/role#;s#/run/alnasl-hotspot/active#$d/active#'); rules_v4; rules_v6"
  rm -rf $d
}
for r in alnasl arkab polis nunki; do
  on=$(fwhs $r 1); off=$(fwhs $r 0)
  ! grep -q -E -- '--dport (53|67|80)( |$)' <<<"$off" && ok "firewall, $r, no hotspot: 53/67/80 closed" || bad "firewall, $r: 53/67/80 open without the hotspot"
  [ "$(grep -E -- '--dport (53|67|80)( |$)' <<<"$on" | grep -c -v -- '-i wlan0 ')" = 0 ] && [ "$(grep -c -E -- '--dport (53|67|80)( |$)' <<<"$on")" = 4 ] \
    && ok "firewall, $r, hotspot: DNS (udp+tcp), DHCP, page; every one -i wlan0" || bad "firewall, $r: a hotspot port without -i wlan0"
  ! grep -q -E -- '-i (eth|en|docker)' <<<"$on" && ok "firewall, $r, hotspot: nothing opened on Ethernet" || bad "firewall, $r: an Ethernet rule"
  v4=$(awk '/^\*filter/{n++} n==1' <<<"$on")
  a=$(grep -n -- '-i wlan0 -j DROP' <<<"$v4" | cut -d: -f1); b=$(grep -n -E -- '--dport (4040|4050) -j ACCEPT|-p icmp -j ACCEPT$|--dport 5353' <<<"$v4" | grep -v -- '-i wlan0' | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ "$a" -lt "${b:-999}" ] && [ "$(grep -c -- '-i wlan0 -j DROP' <<<"$on")" = 2 ] && ok "firewall, $r, hotspot: the phones get nothing else (wlan0 DROP before the role's rules, IPv6 too)" || bad "firewall, $r: hotspot DROP missing or late"
  [ "$(grep -c -- '^-A ALNASL-IN -j DROP$' <<<"$on")" = 2 ] && [ "$(grep -c '^$' <<<"$on")" = 0 ] || bad "firewall, $r, hotspot: no final DROP or blank lines"
done
if command -v iptables-restore >/dev/null; then
  for r in alnasl arkab; do
    fwhs $r 1 | awk '/^\*filter/{n++} n==1' | iptables-restore --noflush --test && ok "iptables-restore --test accepts the $r IPv4 ruleset with the hotspot" || bad "iptables-restore --test refuses the $r hotspot ruleset"
  done
fi
grep -q 'start | reload)' $R/usr/local/sbin/alnasl-firewall && grep -q 'alnasl-firewall", "reload"' $L/hotspot.py && ok "alnasl-hotspot reloads the firewall as it goes up and down" || bad "firewall reload"
# WPA2 only, never open; the password only as the derived key, and never in a log line.
grep -q '"wpa=2"' $L/hotspot.py && grep -q '"wpa_psk=" + psk_hex' $L/hotspot.py && ! grep -q -E 'wpa_passphrase|wpa=[013]"|key_mgmt=NONE|auth_algs=[23]' $L/hotspot.py \
  && ok "hostapd: WPA2-PSK with the derived key only; no open or WEP mode in the code" || bad "hostapd configuration in hotspot.py"
grep -q 'raise ValueError("no valid password' $L/hotspot.py && ok "no valid password, no hotspot (rather than an open one)" || bad "hostapd_conf does not refuse an empty password"
lk=$(grep -n -E '(^|[^a-z_])(log|print)\([^#]*(self\.password|passphrase|[^a-z_]pw[^a-z_0-9]|pw\)|password\))' $L/hotspot.py $L/portal.py $L/arkab_live.py; \
     sed -n '/setup hotspot\/portal --/,/^# ---.*HTTP --/p' $L/server.py | grep -n -E '(^|[^a-z_])(log|print)\([^#]*(passphrase|password|[^a-z_]pw[^a-z_0-9]|pin\))')
[ -z "$lk" ] && ok "no log line carries the hotspot password, a Wi-Fi passphrase or a PIN" || bad "a log line may show a secret: $lk"
grep -q 'def log_message' $L/portal.py && grep -q 'never a query or a body' $L/portal.py && ok "the portal logs method, path and status only" || bad "portal logging"
! grep -q -E '(src|href)="https?://' $WWWD/portal.html && [ -z "$(grep -E '(fetch|src|href)[:(= ]*["'"'"'`]https?://' $WWWD/portal.js | grep -v 'https\?://10\.42\.0\.1/')" ] && ok "the portal page loads nothing from outside (there is no outside)" || bad "portal page refers to an outside URL"
# The boot partition: the file is there, CRLF, with its English and Dutch header and an empty PASSWORD= (generated at first boot).
F=$B/alnasl-hotspot.txt
[ -f $F ] && grep -q 'ALNASL SETUP HOTSPOT' $F && grep -q 'ALNASL-INSTALLATIEHOTSPOT' $F && grep -q '8 to 63' $F && grep -q '8 tot' $F && grep -q 'WPA2' $F \
  && grep -q 'alnasl-hotspot-qr.png' $F && grep -q 'stick it on the case' $F && grep -q 'plak hem op de' $F && grep -q 'serial number' $F && grep -q 'serienummer' $F \
  && ok "boot partition: alnasl-hotspot.txt with its English and Dutch header (password rules, QR sticker, no serial number)" || bad "boot partition alnasl-hotspot.txt or its header"
[ "$(tr -d '\r' < $F | grep -c '^PASSWORD=.')" = 0 ] && [ "$(tr -d '\r' < $F | grep -c '^SSID=.')" = 0 ] && tr -d '\r' < $F | grep -q '^PASSWORD=$' \
  && ok "boot partition: PASSWORD= and SSID= ship empty (each box makes its own)" || bad "the shipped alnasl-hotspot.txt has a password or SSID in it"
[ "$(grep -a -c -v $'\r$' $F)" = 0 ] && ok "alnasl-hotspot.txt is CRLF (Notepad)" || bad "alnasl-hotspot.txt has LF-only lines"
[ ! -e $B/alnasl-hotspot-qr.png ] && ok "no QR code shipped (it is per box)" || bad "a QR code is on the image's boot partition"
[ "$(tr -d '\r' < $F | sha256sum)" = "$(tr -d '\r' < $R/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt | sha256sum)" ] && ok "the image keeps a copy to re-create it from" || bad "the template copy differs from the boot file"
grep -q 'alnasl-hotspot.txt' $B/README-ALNASL.txt && grep -q 'alnasl-hotspot-qr.png' $B/README-ALNASL.txt && grep -q -i 'stick it on the case' $B/README-ALNASL.txt && ok "README-ALNASL.txt: the hotspot file and the QR sticker" || bad "README-ALNASL.txt does not mention the hotspot"
# The logic and the QR code, on the image's own Python: decide(), the file, hostapd, the portal's routes, PIN and link checks; the QR decoded.
install -m 0644 $W/test-hotspot.py $R/tmp/test-hotspot.py; install -m 0644 $W/test-qr.py $R/tmp/test-qr.py
out=$(chroot $R python3 -I /tmp/test-hotspot.py /usr/local/lib/alnasl-setup 2>&1); echo "$out" | grep -v '^ok ' | sed 's/^/       /'
echo "$out" | grep -q 'RESULT: all hotspot checks passed' && ok "test-hotspot.py: $(echo "$out" | grep -c '^ok ') checks in the image" || bad "test-hotspot.py failed in the image"
out=$(chroot $R python3 -I /tmp/test-qr.py /usr/local/lib/alnasl-setup/alnasl_qr.py 2>&1); echo "$out" | tail -1 | sed 's/^/       /'
echo "$out" | grep -q 'test-qr: 0 failure' && ok "test-qr.py: the QR encoder's symbols decode (image python)" || bad "test-qr.py failed in the image"
rm -f $R/tmp/test-hotspot.py $R/tmp/test-qr.py
find $R/usr/local/lib/alnasl-setup -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

echo "== sizes"
df -h $R | tail -1
echo "== result: $([ $fail = 0 ] && echo ALL CHECKS PASSED || echo SOME CHECKS FAILED)"
sync
