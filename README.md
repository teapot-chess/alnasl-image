# photon-image

Builds the Alnasl Raspberry Pi image on Photon OS (roles alnasl, arkab, polis, nunki; see docs/v7-plan.md,
docs/v6-plan.md). Local repo, no remote yet. Builds run on the VM (`/root/w-photon-img5`), triggered by hand.

## What goes into an image

`versions.json` names the exact release tag of every bundled app (Alnasl, Arkab, Polis, Nunki). `build.ps1`
builds only from those tags (`git archive <tag>` in the sibling checkouts), never from a checkout's HEAD, so
the same commit of this repo always means the same image sources. It stops before shipping anything if:

- a tag is missing in its sibling checkout (`git fetch --tags` there), or
- the Arkab tag differs from the one Alnasl's `mix.exs` and `mix.lock` pin at the bundled Alnasl tag.

The `*-src.tar` files in `alnasl/`, `arkab/`, `polis/`, `nunki/` are build outputs: untracked, ignored,
rewritten on every build.

## Release procedure

1. Release the apps first (tag them). Arkab before Alnasl: Alnasl pins an Arkab tag.
2. Edit `versions.json`: Alnasl's new tag, the Arkab tag its `mix.exs`/`mix.lock` pin, Polis and Nunki tags.
   Commit it (one commit per image, message names the versions).
3. `powershell -File check.ps1` (local, no VM): tags exist, Arkab pin matches, script/JSON syntax, no tracked
   build outputs or keys.
4. `powershell -File build.ps1 -Version 7.x -Release ...` (needs the VM). Its verify stage runs
   `scripts/verify.sh` and the `test-*` scripts, which need the finished image and cannot run locally.
5. Sign with `scripts/sign-release.sh` on the machine with the private key (never in this tree), then publish
   by hand. Copy the image and its `.sha256` to the NAS as before.

`check.ps1 -SkipSiblings` is the part that works without the sibling checkouts, for CI once there is a remote.
CI cannot run `build.ps1` or `verify.sh`.

## Tests

`scripts/test-*.py`, `scripts/test-kiosk-logic.sh`, `scripts/verify.sh`: run on the VM by the verify stage.
The overlay's setup server (`overlay/usr/local/lib/alnasl-setup/*.py`), `alnasl-splash` and `alnasl-system-update` are
still Python on the image, along with their tests: the `no-python` branch ported the small shell-sized users (the
kiosk-load progress bar, the os-update status probe) and left these because they are applications, not scripts; they
need to be rewritten in Elixir inside Alnasl first. Until then `python3` stays in the image.
