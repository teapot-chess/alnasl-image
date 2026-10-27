# alnasl-image

System-image releases for the Alnasl hall box (Raspberry Pi 4, Photon OS), from v6 on.

Boxes read `index.json` from the `index` release, check its signature against the
public key their own image carries, and install a newer system image of **their own
train** (v6.x) into the other A/B slot by themselves. Another train (v7) is only ever
installed when someone asks for it: the box's menu, Arkab, or `alnasl-upgrade.txt` on
the boot partition.

Every file here is signed (`.sig`, ECDSA P-256 over SHA-256). An unsigned or wrongly
signed file is refused, which is the point.

Full SD images for a fresh card are not published here.
