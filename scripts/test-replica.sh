#!/bin/bash
# The replica's settings from the boot partition (overlay/usr/local/sbin/alnasl-replica), run for real on
# temporary files. Called by verify.sh with the built image's copy; runs on its own too (Git Bash on the PC):
#   bash scripts/test-replica.sh overlay/usr/local/sbin/alnasl-replica
# Prints "ok"/"FAIL" lines like verify.sh and exits 1 on any FAIL.
RS=${1:?the alnasl-replica script}
fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
run() { ALNASL_REPLICA_TXT=$T/b/alnasl-replica.txt ALNASL_REPLICA_ENV=$T/s/replica.env bash "$RS" > "$T/out.txt" 2>&1; }
card() { mkdir -p "$T/b"; printf '%s\r\n' "$@" > "$T/b/alnasl-replica.txt"; }
envf() { grep -v '^#' "$T/s/replica.env" 2>/dev/null | tr '\n' '|'; }
SECRET='wJalr/XUtnFEMI+K7MDENG=bPxRfiCY'

# 1. No file: nothing happens, nothing is made.
rm -rf "$T/b" "$T/s"; run
[ $? = 0 ] && [ ! -e "$T/s/replica.env" ] && ok "no file on the card: nothing to do" || bad "no file"

# 2. A good file (CRLF, comments, blank lines): taken, 0600, consumed from the card; the key never echoed.
card '# the hall replica' 'ALNASL_TAKEOVER_REPLICA=s3://alnasl/club' '' 'ALNASL_TAKEOVER_REPLICA_ENDPOINT=http://10.0.0.5:9000' \
  'LITESTREAM_ACCESS_KEY_ID=club' "LITESTREAM_SECRET_ACCESS_KEY=$SECRET"
run
[ "$(envf)" = "ALNASL_TAKEOVER_REPLICA=s3://alnasl/club|ALNASL_TAKEOVER_REPLICA_ENDPOINT=http://10.0.0.5:9000|LITESTREAM_ACCESS_KEY_ID=club|LITESTREAM_SECRET_ACCESS_KEY=$SECRET|" ] \
  && ok "a good file: the settings, CR stripped, comments dropped" || bad "good file: '$(envf)'"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ok "(mode 600 not checked on Windows)" ;;
  *) [ "$(stat -c %a "$T/s/replica.env")" = 600 ] && ok "the environment file is 0600" || bad "mode $(stat -c %a "$T/s/replica.env")" ;; esac
[ ! -e "$T/b/alnasl-replica.txt" ] && ok "the card's file is deleted (it holds a key)" || bad "the card's file is still there"
! grep -q -F "$SECRET" "$T/out.txt" && ok "the key is not in the output" || bad "the key was echoed"

# 3. Junk: refused whole, the previous settings stay, the card's copy is gone anyway.
before=$(envf)
for junk in 'ALNASL_TAKEOVER_REPLICA=s3://a/b|PATH=/tmp' 'ALNASL_TAKEOVER_REPLICA=s3://a/b c' 'ALNASL_TAKEOVER_REPLICA=http://a/b' \
            'ALNASL_TAKEOVER_REPLICA=s3://a/$(reboot)' 'LITESTREAM_ACCESS_KEY_ID=x' 'just words' "ALNASL_TAKEOVER_REPLICA=s3://a/\"b\""; do
  IFS='|' read -r -a ls <<< "$junk"; card "${ls[@]}"; run
  [ "$(envf)" = "$before" ] && [ ! -e "$T/b/alnasl-replica.txt" ] && ok "refused, nothing changed: $junk" || bad "junk taken: $junk -> '$(envf)'"
done

# 4. The example as shipped, filled in for a directory replica: the empty keys are simply not set.
card 'ALNASL_TAKEOVER_REPLICA=file:///mnt/replicas/club' 'LITESTREAM_ACCESS_KEY_ID=' 'LITESTREAM_SECRET_ACCESS_KEY='; run
[ "$(envf)" = "ALNASL_TAKEOVER_REPLICA=file:///mnt/replicas/club|" ] && ok "empty keys are left out" || bad "empty keys: '$(envf)'"

# 5. "off" removes them.
card 'OFF'; run
[ ! -e "$T/s/replica.env" ] && ok "off removes the settings" || bad "off"

exit $fail
