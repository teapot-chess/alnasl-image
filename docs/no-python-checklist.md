# No Python: what to verify on the VM build and on a Pi

The `no-python` branch replaced every Python program on the image and on the build VM:

| was | is now |
|---|---|
| `alnasl-setup/server.py`, `diag.py` | `AlnaslSetup.Server` (+ `Server.*`, `Wifi`, `Diag`), mode `server`, 127.0.0.1:4041 |
| `hotspot.py` | `AlnaslSetup.Hotspot`, mode `hotspot` |
| `portal.py` | `AlnaslSetup.Portal`, mode `portal`, 10.42.0.1:80 |
| `alnasl_qr.py`, `arkab_live.py` | `AlnaslSetup.QR`, `AlnaslSetup.ArkabLive` |
| `bootlog.py`, `/usr/local/sbin/alnasl-splash` | `AlnaslSetup.Bootlog`, `AlnaslSetup.Splash` + `alnasl-fbtool` (C, two ioctls); the sbin file is a shell wrapper |
| `/usr/local/sbin/alnasl-system-update` | `AlnaslSetup.SystemUpdate`; the sbin file is a shell wrapper |
| `alnasl-kiosk-load`, `alnasl-os-update` | POSIX shell |
| `scripts/test-*.py` | `setup-app/test/*_test.exs`, `scripts/test-scripts.sh`, `scripts/test-compact-css.sh` |
| `render-splash.py`, `bootscreen.py`, python3 in `assemble.sh` / `make-release.sh` | `render-splash.exs`, `bootscreen.sh`, `uboot-env.exs`, `release-index.exs` |

All of it passes locally (ExUnit and shell). None of it has run on arm64, in the image or on hardware. Tick
every box below before this branch goes to `main`.

## 1. VM build

- [ ] `build.ps1` runs the `setup` stage: the arm64 Docker build of `setup-app` passes `MIX_ENV=test mix test`
      **including the `:unix` tests** (symlinks, `flock`, real `openssl` sign/verify, zstd FIFO unpack), and
      the release check (`bin/alnasl_setup`, `bin/alnasl-fbtool`, `ldd` on beam.smp and fbtool, eval smoke).
- [ ] glibc of the build image (bookworm, 2.36) still matches Photon 5; `ldd` of `beam.smp` shows only libs
      present in the image (libtinfo/ncurses, libz, libcrypto 3).
- [ ] `assemble.sh` section 7b: note what it removed. If it stops with "PYTHON IS STILL NEEDED", write down the
      dependants and decide (none expected: Photon's tdnf is C; check `cloud-init`, `photon-os-installer`,
      `audit`, `libxml2-python`, `rpm-python` style packages). The kernel check after 7b must pass.
- [ ] `verify.sh`: zero FAIL. In particular the server smoke (`ROLEAPI ... false`, `BOOTLOG 200 [...]`,
      `BOOTLOG2 200 false []`), the JSON and unit-graph checks, the in-image smokes (redact, splash compose,
      train guard, openssl round trip, `--status`, hostapd_conf, QR, help URL) and the "no Python" section.
      The `src` route checks read `$W/setup/src`: run verify before anything cleans that directory.
- [ ] `render-splash.exs` (vix in Docker) with `--compare` against the committed PNGs/PGMs: identical, or the
      differences looked at and accepted. `messages.json` byte-identical.
- [ ] `release-index.exs` and `uboot-env.exs`: on one release build, diff the new `index.json`, the entry JSON
      and `uboot.env` against the ones the last Python build made (same inputs). Must be byte-identical.
- [ ] Image size: note what the release adds and what the python removal takes off.

## 2. Hotspot (Pi, no network configured)

- [ ] The `Alnasl-XXXX` network appears about 60 s after boot; `/run/alnasl-hotspot/status.json` and the
      screen show SSID, password and the QR code.
- [ ] Scan the QR code with an iPhone and an Android phone: both join (QR byte-exact encoding, level M).
- [ ] `alnasl-portal.service` runs under DynamicUser with a read-only root (`RELEASE_TMP=/tmp`): no write
      errors in `journalctl -u alnasl-portal`.
- [ ] Stopping the hotspot (`systemctl stop alnasl-hotspot`) runs `ExecStopPost ... hotspot --stop`: hostapd
      and dnsmasq gone, wlan0 back to managed.

## 3. Captive sheet

- [ ] iPhone: the captive sheet opens by itself, shows the portal page, and "Open setup" (or the DHCP option
      114 link) reaches the setup page. Back in the sheet works (`window.top` history).
- [ ] Android: the "Sign in to network" notification opens the same page.
- [ ] A laptop (Windows/macOS): the captive detection page redirects to the portal.

## 4. Setup flow (127.0.0.1:4041 through the kiosk, and over the hotspot)

- [ ] The wizard from first boot to done: language, keyboard, Wi-Fi scan, connect with a password, forget a
      network, network confirm and the automatic revert when not confirmed, screen resolution change and
      revert, role switch (alnasl/arkab/polis/nunki) including the reboot.
- [ ] Wi-Fi keys land 0600 in the right file (through the `/etc/alnasl` -> `/data` symlinks), never 0644.
- [ ] The kiosk pages that call the API (status, printers, help, boot log view) all render.

## 5. Splash

- [ ] Boot shows the boot screen from the first second (fbtool FBIOGET_VSCREENINFO + KDSETMODE graphics),
      the steps advance, and it repaints when vc4 takes over the framebuffer.
- [ ] X / the kiosk takes over cleanly (KDSETMODE text on handover; no garbage, no stuck console).
- [ ] Each `alnasl-splash` call now costs about 1 s (BEAM start for `eval`): boot time compared with the
      Python image, and no step shown late enough to matter.
- [ ] Shutdown and reboot screens (the shutdown units) appear.

## 6. A/B update and rollback

- [ ] `alnasl-system-update --check` reaches GitHub over TLS (OTP CA store, verify_peer) and reads the index.
- [ ] A full update: the zstd FIFO unpack into the other slot; measure time and peak memory on a 2 GB Pi 4.
- [ ] grubenv counts (written with pwrite) are read correctly by GRUB's `save_env`/`load_env`: the new slot
      boots, the health check passes, the counter resets.
- [ ] Rollback: make the health check fail (stop alnasl.service in the new slot); after the tries run out the
      box is back on the old slot and `--status` says so.
- [ ] A signature that does not verify (tampered image or index) is refused, exactly as before.
- [ ] Train guard: an index entry from another train or below `min_from` is refused; a stepping stone is
      chosen when needed.
- [ ] The nightly OS update (`alnasl-os-update`, tdnf) does not pull python3 back in as a dependency. Check
      `rpm -qa | grep -i python` after one nightly run.

## 7. Diagnostics

- [ ] "Get help" uploads the diagnostics over real HTTPS and shows the code.
- [ ] "Save to the SD card" writes the report to /boot/efi with CRLF line ends; it opens fine on Windows.
- [ ] The report contents match a Python-era report section by section (redaction of keys and passwords).

## 8. Running cost

- [ ] Up to three BEAMs at once (server, hotspot, portal): note RSS of each and the boot-to-ready time;
      `+S 2:2` and no busy-waiting should keep CPU idle at rest (`top` for a minute).

## 9. Small screens on the pins (v7.3, docs/spi-screens.md)

- [ ] `SCREEN=hdmi` (as shipped): `ls /sys/kernel/config/device-tree/overlays/` is empty, `spidev0.0`/`spidev0.1`
      are as before, the kiosk log has no "small SPI screen" line.
- [ ] `SCREEN=waveshare35a`: the panel shows the menu at 480x320 (not white), HDMI shows only the boot picture,
      the stylus lands where it is aimed. `ROTATE=180` turns picture and stylus together.
- [ ] Settings > Touch screen: the four-cross calibration saves, the kiosk restarts with it, it survives a
      reboot; "Back to the defaults" undoes it.
- [ ] `SCREEN=waveshare32b` (never tried): picture at 320x240 in landscape, the menu fits, the keyboard leaves
      room for the field; calibrate if the guessed touch ranges are off.
- [ ] `SCREEN=hx8357d` (never tried): picture at 480x320, no stylus.
- [ ] A preset with no panel on the pins: state `no_panel`, the kiosk stays on HDMI, the boot is not slower than
      the two 10-second waits.
