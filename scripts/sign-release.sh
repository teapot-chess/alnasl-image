#!/bin/bash
# sign-release.sh: detached signatures for a system-image release (v6 A/B updates).
#
#   sign-release.sh PRIVATE-KEY FILE...      writes FILE.sig next to each FILE, then checks it
#
# PRIVATE-KEY is a path given on the command line, every time. It is never copied, never read from an
# environment variable, never looked up in this repo. Keep it OFF this repo, every image, the NAS
# (public) and the build VM: on a machine of your own, ideally an encrypted USB stick.
#
# Making the key pair, once (EC P-256; openssl only):
#   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out alnasl-update.key   # PRIVATE
#   chmod 600 alnasl-update.key
#   openssl pkey -in alnasl-update.key -pubout -out update-key.pub    # PUBLIC: goes in the image
# Put update-key.pub at overlay/etc/alnasl/update-key.pub (replacing the placeholder) BEFORE building
# the first image that should take updates: boxes trust only the key their image carries. Losing the
# private key means no more updates for the boxes out there (they need one reflash with a new key).
#
# What a box checks: openssl dgst -sha256 -verify /etc/alnasl/update-key.pub -signature FILE.sig FILE
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,18p' "$0"; exit 2; }
KEY=$1; shift
[ -f "$KEY" ] || { echo "no private key at $KEY"; exit 1; }
case $(realpath "$KEY") in
  "$(realpath "$(dirname "$0")/..")"/*) echo "REFUSED: the private key is inside this repo ($KEY). Move it out first."; exit 1 ;;
esac
openssl pkey -in "$KEY" -noout 2>/dev/null || { echo "$KEY is not a private key openssl can read"; exit 1; }
pub=$(mktemp); trap 'rm -f "$pub"' EXIT
openssl pkey -in "$KEY" -pubout -out "$pub"
here=$(dirname "$0")/../overlay/etc/alnasl/update-key.pub
if [ -f "$here" ] && ! cmp -s <(openssl pkey -pubin -in "$here" -pubout 2>/dev/null) "$pub"; then
  echo "WARNING: this key does not match overlay/etc/alnasl/update-key.pub; boxes built from this tree will refuse these signatures"
fi
for f in "$@"; do
  [ -f "$f" ] || { echo "no file $f"; exit 1; }
  openssl dgst -sha256 -sign "$KEY" -out "$f.sig" "$f"
  openssl dgst -sha256 -verify "$pub" -signature "$f.sig" "$f" >/dev/null || { echo "the signature of $f does not verify"; exit 1; }
  echo "signed: $f.sig"
done
