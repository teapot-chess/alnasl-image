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

## The box's own programs (setup-app)

There is no Python on the image. The setup server (127.0.0.1:4041), the hotspot and its captive portal
(10.42.0.1:80), the boot screen painter (`alnasl-splash`) and the system updater (`alnasl-system-update`) are one
small Elixir release in `setup-app/` (no dependencies, its own ERTS), installed at `/opt/alnasl-setup`.
`ALNASL_SETUP_MODE=server|hotspot|portal` picks the long-running program in the units; the two `/usr/local/sbin`
commands are shell wrappers around `bin/alnasl_setup eval 'AlnaslSetup.CLI.main()' -- ...`. The two ioctls the
painter needs are done by a tiny C helper, `alnasl-fbtool`, built into the release.

`build.ps1` ships `git archive HEAD:setup-app` (this repository's committed source, not the working tree) and
`scripts/build-setup.sh` builds it in an arm64 container on the VM, running the full test suite there first.
`assemble.sh` unpacks it into the image and removes every python3 package; the build stops if anything else
depends on one. Build-VM helpers that need more than shell (`uboot-env.exs`, `release-index.exs`,
`render-splash.exs`) are Elixir scripts run in the same hexpm Elixir image.

## Tests

- `cd setup-app && mix test`: ExUnit, runs locally (tests tagged `:unix` are skipped on Windows; the arm64 build
  runs all of them).
- `scripts/test-scripts.sh`, `scripts/test-compact-css.sh`, `scripts/test-kiosk-logic.sh`: shell, run locally
  with bash.
- `scripts/verify.sh`: needs the finished image, runs on the VM in the verify stage.
- What none of these can show (hotspot on real Wi-Fi, the iPhone captive sheet, the framebuffer, A/B update and
  rollback, diagnostics upload) is in `docs/no-python-checklist.md`.
