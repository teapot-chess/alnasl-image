#!/bin/bash
# The box's access PIN (overlay/usr/local/sbin/alnasl-pin), run for real on temporary files. Called by
# verify.sh with the built image's copy; runs on its own on any Linux box too:
#   bash scripts/test-pin.sh overlay/usr/local/sbin/alnasl-pin
# Prints "ok"/"FAIL" lines like verify.sh and exits 1 on any FAIL.
PS=${1:?the alnasl-pin script}
fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
# Byte-for-byte compare without cmp: the build VM, where verify.sh runs this, has no diffutils.
same() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fresh() { rm -rf "$T/b" "$T/s" "$T/d"; mkdir -p "$T/b" "$T/s" "$T/d"; }
run() { ALNASL_PIN_FILE=$T/b/alnasl-pin.txt ALNASL_PIN_OLD_FILE=$T/b/alnasl-arkab-pin.txt ALNASL_PIN_STATE=$T/s \
          ALNASL_PIN_DATA=$T/d ALNASL_PIN_ROLE=${ROLE:-arkab} ALNASL_PIN_OWNER= ALNASL_PIN_RESTART= bash "$PS" "$@" > "$T/out.txt" 2>&1; }
req() { tr '\n' '|' < "$T/d/pin-request" 2>/dev/null; }
card() { grep -a '^PIN=' "$T/b/alnasl-pin.txt" | head -n 1 | tr -d '\r'; }
setcard() { sed -i "s/^PIN=[^\r]*/PIN=$1/" "$T/b/alnasl-pin.txt"; }
# What the app does when it starts: applies the request and writes access-pin.
app() { if [ -f "$T/d/pin-request" ]; then sed -n 2p "$T/d/pin-request" > "$T/d/access-pin"; rm -f "$T/d/pin-request"; fi; }

# 1. A new box: six random digits, handed over 0600, on the card with CRLF, in the box's copy; never echoed.
fresh; run
p=$(sed -n 2p "$T/d/pin-request" 2>/dev/null)
[[ "$p" =~ ^[0-9]{6}$ ]] && [ "$(stat -c %a "$T/d/pin-request")" = 600 ] && [ "$(card)" = "PIN=$p" ] \
  && [ "$(sed -n 2p "$T/s/pin")" = "$p" ] && [ "$(stat -c %a "$T/s/pin")" = 600 ] && ! grep -q "$p" "$T/out.txt" \
  && ok "a new box makes a 6-digit PIN, hands it over (0600), writes it on the card and keeps a 0600 copy; not echoed" || bad "first boot"
grep -q $'\r' "$T/b/alnasl-pin.txt" && grep -q 'ACCESS PIN OF THIS BOX' "$T/b/alnasl-pin.txt" && grep -q 'PINCODE VAN DEZE KAST' "$T/b/alnasl-pin.txt" \
  && grep -q 'Last result: a PIN was made' "$T/b/alnasl-pin.txt" && ok "the card's file: CRLF, English and Dutch header, the result line" || bad "card file shape"
[ "$(for i in 1 2 3 4 5; do fresh; run; sed -n 2p "$T/d/pin-request"; done | sort -u | wc -l)" -ge 4 ] && ok "random PINs differ from box to box" || bad "random PINs repeat"

# 2. The next boot, nothing changed: the card is not rewritten, nothing handed over.
fresh; run; app; p=$(sed -n 2p "$T/s/pin"); cp "$T/b/alnasl-pin.txt" "$T/card0"; run
[ ! -e "$T/d/pin-request" ] && same "$T/card0" "$T/b/alnasl-pin.txt" && ok "an ordinary boot hands nothing over and leaves the card alone" || bad "ordinary boot"

# 3. A PIN typed on the card: handed over, kept on the card (not blanked), the result says so.
setcard 'my hall 2026'; run
[ "$(req)" = 'set|my hall 2026|' ] && [ "$(card)" = 'PIN=my hall 2026' ] && grep -a -q 'Last result: PIN set' "$T/b/alnasl-pin.txt" \
  && [ "$(sed -n 2p "$T/s/pin")" = 'my hall 2026' ] && ok "PIN=my hall 2026 is handed over and stays on the card" || bad "a PIN typed on the card"
app

# 4. Too short, edge spaces, PIN=remove: refused, the old PIN stays, on the card too.
for bad_pin in 12345 ' 123456' remove verwijderen; do
  setcard "$bad_pin"; run
  { [ ! -e "$T/d/pin-request" ] && [ "$(card)" = 'PIN=my hall 2026' ] && grep -a -q 'Last result: refused' "$T/b/alnasl-pin.txt"; } || { bad "PIN=$bad_pin was not refused"; continue; }
done
setcard 12345; run; grep -a -q 'refused, too short' "$T/b/alnasl-pin.txt" && ok "PIN=12345, ' 123456', remove and verwijderen are refused; the PIN stays what it was" || bad "refusals"

# 5. PIN=new and PIN=nieuw: a fresh random one.
setcard new; run; p=$(sed -n 2p "$T/d/pin-request" 2>/dev/null)
[[ "$p" =~ ^[0-9]{6}$ ]] && [ "$(card)" = "PIN=$p" ] && grep -a -q 'new random PIN' "$T/b/alnasl-pin.txt" && ok "PIN=new makes a fresh random PIN" || bad "PIN=new"
app; setcard NIEUW; run; [[ "$(sed -n 2p "$T/d/pin-request" 2>/dev/null)" =~ ^[0-9]{6}$ ]] && ok "PIN=NIEUW too" || bad "PIN=nieuw"; app

# 6. Changed in the app's settings: --sync copies it to the box and the card.
printf 'changed-in-app\n' > "$T/d/access-pin"; run --sync
[ "$(card)" = 'PIN=changed-in-app' ] && [ "$(sed -n 2p "$T/s/pin")" = 'changed-in-app' ] && grep -a -q "changed in Arkab's own settings" "$T/b/alnasl-pin.txt" \
  && ! grep -q changed-in-app "$T/out.txt" && ok "--sync: a PIN changed in the app follows to the box's copy and the card" || bad "--sync"
cp "$T/b/alnasl-pin.txt" "$T/card1"; run --sync; same "$T/card1" "$T/b/alnasl-pin.txt" && ok "--sync with nothing new writes nothing" || bad "--sync rewrote an unchanged card"

# 7. The power went before --sync: at the next boot the app's own PIN wins (same role).
printf 'app-was-faster\n' > "$T/d/access-pin"; run
[ ! -e "$T/d/pin-request" ] && [ "$(card)" = 'PIN=app-was-faster' ] && ok "a PIN the app changed before a power cut is kept at the next boot" || bad "power cut"

# 8. Another role whose app has an old PIN of its own: the box's PIN goes to it.
mkdir -p "$T/d2"; printf 'stale-old-pin\n' > "$T/d2/access-pin"
ROLE=polis ALNASL_PIN_DATA=$T/d2 ALNASL_PIN_FILE=$T/b/alnasl-pin.txt ALNASL_PIN_OLD_FILE=$T/b/old ALNASL_PIN_STATE=$T/s ALNASL_PIN_ROLE=polis ALNASL_PIN_OWNER= bash "$PS" > "$T/out.txt" 2>&1
[ "$(tr '\n' '|' < "$T/d2/pin-request")" = 'set|app-was-faster|' ] && [ "$(sed -n 1p "$T/s/pin")" = polis ] && ok "a new role gets the PIN the box already shows" || bad "role switch"

# 9. The old Arkab file: a PIN still waiting in it comes along; the old file goes. PIN=remove in it does not.
fresh; printf '# old\r\nPIN=fromoldcard\r\n' > "$T/b/alnasl-arkab-pin.txt"; run
[ ! -e "$T/b/alnasl-arkab-pin.txt" ] && [ "$(req)" = 'set|fromoldcard|' ] && [ "$(card)" = 'PIN=fromoldcard' ] && ok "alnasl-arkab-pin.txt is migrated, its waiting PIN with it" || bad "migration"
fresh; printf 'PIN=remove\r\n' > "$T/b/alnasl-arkab-pin.txt"; run
[ ! -e "$T/b/alnasl-arkab-pin.txt" ] && [[ "$(sed -n 2p "$T/d/pin-request")" =~ ^[0-9]{6}$ ]] && ok "an old PIN=remove is not honoured: the box makes a PIN" || bad "migration of remove"

# 10. A factory reset (data gone) keeps the card's PIN.
fresh; run; app; p=$(sed -n 2p "$T/s/pin"); rm -rf "$T/s" "$T/d"; mkdir -p "$T/s" "$T/d"; run
[ "$(req)" = "set|$p|" ] && ok "after a factory reset the card's PIN comes back" || bad "factory reset"

# 11. --apply: the setup panel's request (set, new, too short); the wanted file is gone afterwards.
fresh; run; app
printf 'set\npanel-pin-1\n' > "$T/s/pin-wanted"; run --apply; r=$?
[ $r = 0 ] && [ "$(req)" = 'set|panel-pin-1|' ] && [ "$(card)" = 'PIN=panel-pin-1' ] && [ ! -e "$T/s/pin-wanted" ] && ! grep -q panel-pin-1 "$T/out.txt" \
  && ok "--apply set: handed over, on the card, the request file gone, not echoed" || bad "--apply set"
app; printf 'new\n' > "$T/s/pin-wanted"; run --apply; [[ "$(sed -n 2p "$T/d/pin-request")" =~ ^[0-9]{6}$ ]] && ok "--apply new" || bad "--apply new"
app; printf 'set\nabc\n' > "$T/s/pin-wanted"; run --apply; r=$?
[ $r = 3 ] && [ ! -e "$T/d/pin-request" ] && grep -q 'too short' "$T/out.txt" && ok "--apply refuses a short PIN (exit 3)" || bad "--apply short"
printf 'remove\n' > "$T/s/pin-wanted"; run --apply; [ $? = 2 ] && [ ! -e "$T/d/pin-request" ] && ok "--apply has no remove" || bad "--apply remove"

# 11b. Characters: UTF-8 counts characters, not bytes; a file saved in an old code page is refused.
fresh; run; app; setcard 'ëéïöü'; run; grep -a -q 'too short' "$T/b/alnasl-pin.txt" || bad "five accented letters were counted as bytes"; app; setcard 'ëéïöü1'; run; [ "$(req)" = 'set|ëéïöü1|' ] && ok "six accented letters are six characters" || bad "UTF-8 PIN"
app; sed -i 's/^PIN=[^\r]*/PIN=caf\xe9123/' "$T/b/alnasl-pin.txt"; run
[ ! -e "$T/d/pin-request" ] && grep -a -q 'not plain text' "$T/b/alnasl-pin.txt" && ok "a PIN in a non-UTF-8 file is refused and says why" || bad "non-UTF-8 PIN"

# 12. The script never prints or logs a PIN variable.
! grep -n -E '(echo|say)[^#]*\$(pin|p|a|t|edit|want)\b|logger|set -x|\| *tee' "$PS" >/dev/null && ok "alnasl-pin never echoes, logs or tees a PIN" || bad "alnasl-pin may show the PIN"
exit $fail
