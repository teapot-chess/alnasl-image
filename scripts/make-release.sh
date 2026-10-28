#!/bin/bash
# make-release.sh: the files of one system-image release (v6 A/B updates), from a built SD image.
# Publishes nothing and signs nothing (sign-release.sh does that, on a machine that holds the key).
#
#   make-release.sh IMAGE OUTDIR [--min-from VERSION] [--notes TEXT] [--index OLD-index.json]
#                                [--base-url URL]
#
#   IMAGE      photon-alnasl-v6.img (assemble.sh's output, not compressed)
#   OUTDIR     gets: alnasl-system-v<version>.img.zst   system slot A of IMAGE, compressed
#                    alnasl-system-v<version>.json      this release's entry
#                    index.json                         OLD-index.json (or an empty one) + this entry
#   --min-from the oldest version a box may update FROM to reach this one (a box on an older version
#              takes the versions in between first). Needed when a release depends on what an earlier
#              one did (a data migration ...). Default: none.
#   --base-url where the files will be downloadable; default the GitHub release of the train:
#              https://github.com/teapot-chess/alnasl-image/releases/download/v<version>/
#
# The train and version are read from the image itself (/etc/alnasl/image-release in slot A), so an
# entry can never claim another version than the slot it carries. No root needed: the partition is cut
# out of the image file with dd, and read with debugfs.
#
# Then, with the PRIVATE key (never in this repo, an image, the NAS or the build VM):
#   sign-release.sh /path/to/alnasl-update.key OUTDIR/index.json OUTDIR/alnasl-system-v<version>.img.zst
# and upload, by hand: the image + its .sig to the release v<version>, index.json + index.json.sig to the
# rolling release "index" (replacing the old ones). See docs/v6-plan.md, "Updates without reflashing".
set -euo pipefail
REPO_URL=https://github.com/teapot-chess/alnasl-image
DISK_ID=416c6e73
SLOT_MAX=$((3072 << 20))

[ $# -ge 2 ] || { sed -n '2,20p' "$0"; exit 2; }
IMG=$1; OUT=$2; shift 2
MIN_FROM=""; NOTES=""; OLD_INDEX=""; BASE=""
while [ $# -gt 0 ]; do
  case $1 in
    --min-from) MIN_FROM=$2; shift 2 ;;
    --notes) NOTES=$2; shift 2 ;;
    --index) OLD_INDEX=$2; shift 2 ;;
    --base-url) BASE=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
for t in sfdisk dd debugfs zstd sha256sum python3 stat; do command -v $t >/dev/null || { echo "needs $t"; exit 1; }; done
[ -f "$IMG" ] || { echo "no image at $IMG"; exit 1; }
mkdir -p "$OUT"

# The layout must be the v6 A/B one: disk id, and slot A where every v6 image has it.
id=$(sfdisk --disk-id "$IMG" | tr 'A-F' 'a-f')
[ "$id" = "0x$DISK_ID" ] || { echo "$IMG has disk id $id, not 0x$DISK_ID: not a v6 A/B image"; exit 1; }
read -r start size < <(sfdisk -d "$IMG" | grep -E "^${IMG}2 :" | sed -E 's/.*start= *([0-9]+), *size= *([0-9]+).*/\1 \2/')
[ -n "${size:-}" ] || { echo "no partition 2 in $IMG"; exit 1; }
raw_size=$((size * 512))
[ $raw_size -le $SLOT_MAX ] || { echo "slot A is $raw_size bytes, more than a slot ($SLOT_MAX)"; exit 1; }

work=$(mktemp -d "$OUT/.make-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
dd if="$IMG" of="$work/slot.img" bs=512 skip="$start" count="$size" conv=sparse status=none
rel=$(debugfs -R "cat /etc/alnasl/image-release" "$work/slot.img" 2>/dev/null)
TRAIN=$(echo "$rel" | sed -n 's/^ALNASL_TRAIN=//p'); VERSION=$(echo "$rel" | sed -n 's/^ALNASL_VERSION=//p')
[[ "$TRAIN" =~ ^v[0-9]+$ && "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "${VERSION%%.*}" = "${TRAIN#v}" ]] ||
  { echo "slot A's /etc/alnasl/image-release is missing or wrong: train '$TRAIN', version '$VERSION'"; exit 1; }
if debugfs -R "cat /etc/alnasl/update-key.pub" "$work/slot.img" 2>/dev/null | grep -q ALNASL-PLACEHOLDER; then
  echo "REFUSED: this image carries the PLACEHOLDER update key. A box running it could never take the next"
  echo "update; build with the real public key in overlay/etc/alnasl/update-key.pub first."
  exit 1
fi
[ -z "$MIN_FROM" ] || [[ "$MIN_FROM" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "--min-from $MIN_FROM is not a version"; exit 1; }
[ -n "$BASE" ] || BASE=$REPO_URL/releases/download/v$VERSION/
case $BASE in https://*/) ;; https://*) BASE=$BASE/ ;; *) echo "--base-url must be https://"; exit 1 ;; esac

FILE=alnasl-system-v$VERSION.img.zst
echo "slot A of $IMG: train $TRAIN, version $VERSION, $((raw_size >> 20)) MiB"
raw_sha=$(sha256sum "$work/slot.img" | cut -d' ' -f1)
zstd -q -19 -T8 -f "$work/slot.img" -o "$OUT/$FILE"
sha=$(sha256sum "$OUT/$FILE" | cut -d' ' -f1)
zsize=$(stat -c %s "$OUT/$FILE")
echo "$FILE: $((zsize >> 20)) MiB, sha256 $sha"

python3 - "$OUT" "$FILE" "$TRAIN" "$VERSION" "$BASE" "$zsize" "$sha" "$raw_size" "$raw_sha" "$MIN_FROM" "$NOTES" "$OLD_INDEX" <<'PY'
import datetime, json, os, sys
out, file, train, version, base, size, sha, raw_size, raw_sha, min_from, notes, old = sys.argv[1:]
entry = {"train": train, "version": version, "file": file, "url": base + file, "sig_url": base + file + ".sig",
         "size": int(size), "sha256": sha, "raw_size": int(raw_size), "raw_sha256": raw_sha,
         "min_from": min_from or None, "released": datetime.date.today().isoformat(), "notes": notes[:400]}
with open(os.path.join(out, "alnasl-system-v%s.json" % version), "w") as f:
    json.dump(entry, f, indent=1)
    f.write("\n")
idx = {"format": 1, "images": []}
if old:
    with open(old) as f:
        idx = json.load(f)
    assert idx.get("format") == 1, "the old index has another format"
idx["images"] = [i for i in idx["images"] if i.get("version") != version] + [entry]
key = lambda i: tuple(int(x) for x in i["version"].split("."))
idx["images"].sort(key=key)
with open(os.path.join(out, "index.json"), "w") as f:
    json.dump(idx, f, indent=1)
    f.write("\n")
print("index.json: %d image(s): %s" % (len(idx["images"]), ", ".join(i["version"] for i in idx["images"])))
PY
echo "next: sign-release.sh <private key> $OUT/index.json $OUT/$FILE   (on the machine that holds the key)"
