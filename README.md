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

## Building the image

Builds the Alnasl Raspberry Pi image on Photon OS (roles alnasl, arkab, polis, nunki; see docs/v7-plan.md,
docs/v6-plan.md). Builds run on the VM (`/root/w-photon-img5`), triggered by hand.

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

## Nunki on two monitors, remote access (7.5)

A nunki box puts the broadcast (`/hall?screen=hdmi1|hdmi2`) on its HDMI monitors: one monitor, management +
broadcast, mirror or two tournaments, chosen in Settings > Screens with an Identify button; a panel on the pins
becomes the remote control (Live / Pause / Black, tournament, sound). One X server spans both HDMI outputs, a
second one drives the panel: `docs/nunki-displays.md`. Every role can join its owner's Tailscale network from
the menu (a QR code, no key in the image, off until Start; the role's port on tailscale0 only, Tailscale SSH):
`docs/remote-access.md`. Neither has met a real Pi as of 7.5; both docs list what has not.

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

## Small screens on the pins (v7.3)

`alnasl-screen.txt` on the boot partition names a small SPI panel (or a 3.5-inch HDMI screen with its stylus on
the pins); the shipped `SCREEN=hdmi` touches nothing. `alnasl-small-screen.service` applies the device-tree
overlays at boot through configfs and tells the kiosk which DRM card to drive. Presets, the white-panel trap
and what has never met real hardware: `docs/spi-screens.md`.

## Warm reboots that never come back (7.4.2)

About one `systemctl reboot` in five on a Pi 4B Rev 1.5 never came back: the kernel repeated
`mmc0: Timeout waiting for hardware cmd interrupt` and the initrd waited for `416c6e73-02` with no limit. The SD
timeouts look like a symptom. The same boots show the VideoCore firmware mailbox timing out
(`rpi_firmware_property_list` from `raspberrypi_hwmon`, `hwmon0: Failed to get throttled (-110)`), and the Pi 4's
SD clock and regulators go through that firmware. Keeping the card at 3.3 V (`sdhci.debug_quirks2=4`) did not
help and is not in the image. Newer Pi firmware alone did not help either. The cause is open; 7.4.2 only
stops the box from hanging on it.

- `rd.timeout=90 rd.shell=0 rd.emergency=reboot`: when the root partition does not appear, dracut gives up
  after 90 s and restarts, instead of waiting forever or opening an emergency shell for a keyboard nobody has.
  All three names are dracut 059's (checked in the image's initrd by `verify.sh`); `rd.shell=0` is needed
  because the shell is on by default and `rd.emergency` only applies once it is off.
- They are on the linux line of the boot partition's `grub.cfg` (`scripts/grub-ab.cfg`) and in the slot's
  `/boot/systemd.cfg` (`assemble.sh`). A system update writes a slot and never the boot partition, so a card
  flashed before 7.4.2 gets them through the slot only. `alnasl-cmdline-check` (ExecStartPre of
  `alnasl-slot-check.service`) logs an error when the running kernel lacks them and appends what is missing to
  `/boot/systemd.cfg` for the next boot. A rollback to a slot older than 7.4.2 boots without them.
- `start4.elf` and `fixup4.dat` come from raspberrypi/firmware `1.20260915`, pinned by SHA-256 in `assemble.sh`.
  They are on the boot partition, so an update does not bring them either; reflash for those.

## Tests

- `cd setup-app && mix test`: ExUnit, runs locally (tests tagged `:unix` are skipped on Windows; the arm64 build
  runs all of them).
- `scripts/test-scripts.sh`, `scripts/test-compact-css.sh`, `scripts/test-kiosk-logic.sh`: shell, run locally
  with bash.
- `scripts/verify.sh`: needs the finished image, runs on the VM in the verify stage.
- What none of these can show (hotspot on real Wi-Fi, the iPhone captive sheet, the framebuffer, A/B update and
  rollback, diagnostics upload) is in `docs/no-python-checklist.md`.

## Licence

Source published for reference under the Microsoft Reference Source License (Ms-RSL), copyright 2026 Jorian Burssens. The builds we publish (downloads, app stores, the Alnasl Pi image) may be used free of charge to run chess events; that permission covers our builds, not builds you make yourself. See [LICENSE](LICENSE).
