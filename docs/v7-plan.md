# Alnasl Pi image v7: four roles, the boot log, small screens

Decided 2026-10-28. v7 is a new release train; v6 boxes see it offered and never take it on their own
(`train_guard`). v7.0 needs 6.2 first (`--min-from 6.2`). Everything in docs/v6-plan.md still holds unless
it is said otherwise here.

## 1. Roles

One box, one job. "Master slave is simple" stays simple: there are just four words now.

| role | runs | page on the box's screen | inbound port |
|---|---|---|---|
| `alnasl` (was master, the default) | Alnasl + the hall screen | `http://localhost:4040/` | 4040 |
| `arkab` (was slave) | Arkab, the board bridge | `http://localhost:4050/` | 4050 |
| `polis` | Polis, the print station, + CUPS | `http://localhost:4061/` | none (it dials out) |
| `nunki` | Nunki, the announcer, + espeak-ng and ALSA | `http://localhost:4062/` | none (it dials out) |

- `/var/lib/alnasl-setup/mode` holds the role word. `master` and `slave` are read as `alnasl` and `arkab`,
  in the file and in `mode-applied`, so a v6 box that upgrades keeps what it was and does not re-enable what
  somebody switched off. Missing or nonsense means `alnasl`.
- `alnasl-mode` writes `/run/alnasl-mode/{mode,role,<role>}`. `mode` keeps the v6 word for the alnasl and
  arkab roles (`master`/`slave`) and is the role word otherwise; `role` is always the role word.
- Units per role, each gated by a `ConditionPathExists=/run/alnasl-mode/<role>` drop-in (not masks: the
  apps' updaters rewrite their unit files):
  - alnasl: `alnasl.service alnasl-update.path`
  - arkab: `arkab.service arkab-update.path`
  - polis: `polis.service polis-update.path cups.service (Photon's cups package has no socket or path unit)`
  - nunki: `nunki.service nunki-update.path alnasl-sound.service`
- The kiosk is every role's screen now (no condition on it). The setup server's `/` sends it to the role's
  page when that is up, otherwise to the menu (Settings, Get help) which says what is wrong.
- All four apps are installed in every image by their own `install.sh`, then disabled; only the role's run.
- `alnasl-mode.txt` on the boot partition: `alnasl`, `arkab`, `polis`, `nunki`, `master` or `slave`.
- The wizard's mode step becomes "What is this box?" with four choices, one EN and one NL line each. Only
  alnasl asks the Services step. Settings: "Change what this box is", a choice, a confirmation, a restart.
- API (Arkab's status page uses it): `GET /api/mode` returns `{mode, role, roles, set, running}` with `mode`
  still `master`/`slave` for those two roles; `POST /api/mode {mode, confirm: "SWITCH"}` takes any of the six
  words.
- Firewall: only the role's port (above), plus DHCP, mDNS and ICMP as before.
- Updates: `alnasl-system-update` checks the running role's app after a trial boot (port above, `/` answering)
  and carries over a newer installed copy of any of the four apps into the new slot.

### Polis on the box
Photon's `cups` (no cups-filters, no Ghostscript in Photon's repository). `/etc/cups/local.convs` lets a PDF
through untouched, so a printer that understands PDF (most network office printers, IPP Everywhere) prints.
Settings > Printers (polis role only): add a network printer by address (`ipp://ADDR/ipp/print`,
`lpadmin -m everywhere`), make one the default, print a test page, remove one. USB printers are queues with
the `raw` model. No printer discovery (no Avahi in Photon).

### Nunki on the box
espeak-ng is not in Photon: `scripts/build-espeak.sh` takes Debian bookworm's arm64 `espeak-ng` with its
libraries and data (glibc 2.36, the same as Photon 5) into `/opt/espeak-ng`, behind a wrapper
`/usr/local/bin/espeak-ng`. ALSA from Photon (`alsa-lib`, `alsa-utils`). `alnasl-sound` (at start of the
nunki role and when Settings changes) writes `/etc/asound.conf`: the default device is a softvol "Alnasl"
control on HDMI or on the 3.5 mm jack. Settings > Sound (nunki role only): output, volume, test.
7.5: the HDMI monitors show the broadcast, not the admin page; two monitors, the screen wizard and the panel's
hall-screen controls are in `docs/nunki-displays.md`. Nunki's sound is off in a fresh image (`NUNKI_AUDIO=off`).
Remote access for every role (opt-in Tailscale): `docs/remote-access.md`.

## 2. Boot screen: the log

From power-on until the role's page is up the screen shows the Alnasl mark, a status line ("starting
nunki, 7 of 12 up") and below it the box's log scrolling: newest line at the bottom, older lines fading.
Coloured by source: kernel, systemd, the role's app, network. Errors and failed units in the accent colour,
never hidden. Same palette as v6, monospace, the frame composed whole (no flicker, no black frame).

- `AlnaslSetup.Bootlog` (setup-app, in /opt/alnasl-setup) follows `journalctl -b -f -o json`. Shown are only: the
  kernel, systemd's own lines about allowed units, and an allow-list of units, at priority info or more
  urgent. Every line goes through `redact()` first: Wi-Fi passphrases and PSKs, passwords, tokens, keys,
  cookies, `Authorization`, `user:pass@` in URLs, long hex and base64 strings, query strings and support
  codes are replaced with `***`. Non-ASCII becomes `?`. Tests: `setup-app/test/bootlog_test.exs`.
- The painter (`alnasl-splash --log`, run by `alnasl-splash.service`) draws from a monospace glyph atlas that
  `scripts/render-splash.exs` pre-renders (DejaVu Sans Mono, printable ASCII, at the 1080 and 720 sizes).
- After X starts, `/boot` draws the same view from the same atlas on a canvas, fed by
  `GET /api/bootlog?after=N` on the loopback-only setup server, so the hand-over shows the same lines in the
  same places.
- The update and reset screens keep their v6 look.

## 3. Small screens

app.css and app.js work at 800x480, 1024x600 and 720x720: one column, nothing cut off, every tap target at
least 44 px, focus visible.

v7.3 goes smaller: 480x320 and 320x240 panels on the GPIO pins (waveshare35a/piscreen, waveshare32b, hx8357d)
and the 3.5-inch HDMI stylus screen, switched on in `alnasl-screen.txt`, with an on-screen stylus calibration.
Off by default; how it works and what was never tried on a real panel: `docs/spi-screens.md`.

## 4. Version

`image-version` v7, `photon-alnasl-v7.img`, `ALNASL_TRAIN=v7`, 7.0. The release index keeps 6.1 and 6.2.

## 5. The spare, and Litestream (v7.5, branch spare-role)

A spare box takes over a hall when the box running it dies (Alnasl's docs/takeover.md). Alnasl does the
work; the image only has to say "this one is a spare" and give it what the replica needs.

- **The word.** `spare` in `/var/lib/alnasl-setup/mode` (or `alnasl-mode.txt`, or `POST /api/mode`). It is
  the alnasl role: same units, same port, same firewall, `/run/alnasl-mode/role` says `alnasl`, `mode` says
  `master`. What differs: the flag `/run/alnasl-mode/spare`, and `/run/alnasl-mode/takeover.env` saying
  `ALNASL_TAKEOVER_ROLE=spare` (`active` on every other box). `alnasl.service.d/alnasl-takeover.conf` hands
  it to Alnasl. Alnasl reads it once, when the box is paired with a hall in the cloud: after that its own
  record decides, so a spare that took over stays in charge across reboots and system updates, whatever
  the mode file says. Switching between alnasl and spare restarts the box (Alnasl hears it at its start).
  `GET /api/mode` adds `spare` and `running_spare`. The wizard and Settings do not offer it yet: a spare is
  set up with the boot-partition file or the API.
- **Litestream.** 0.5.17, linux-arm64, pinned by version and SHA-256 in assemble.sh (3d), installed as
  `/usr/local/bin/litestream` in the slot. Alnasl runs it itself (`Alnasl.Takeover.Replicator`) while the
  box is the active box of a hall and a replica is configured, and stops it when the box steps down; at a
  takeover it runs `litestream restore` once. It only calls out: no port, no firewall change.
- **The replica's settings.** `alnasl-replica.txt` on the boot partition (example shipped), lines
  `KEY=VALUE`: `ALNASL_TAKEOVER_REPLICA` (s3/gs/abs/sftp/file URL), `_ENDPOINT`, `_REGION`, `_SYNC`,
  `LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY`. `alnasl-replica` (run by alnasl-mode at boot)
  checks it, writes `/var/lib/alnasl-setup/replica.env` (data partition, root, 0600) and deletes the card's
  file, which holds a key. systemd reads the env file for alnasl.service; the alnasl user cannot. `off` on
  the first line removes it. A factory reset wipes it with the data partition. Tests: scripts/test-replica.sh
  (Git Bash or the VM), verify.sh's v7.5 block and the alnasl-mode run in the image.
- **The fallback store.** The user's own server (MinIO under Tanzu, at home or in the hall) or any S3
  bucket. Every box of a hall gets the same file; each writes under its own uid, the spare reads the one
  that ran the hall.
- **Not tried on hardware.** Two Pis, a store, a pulled plug: nobody has yet. Nor has Litestream 0.5.17 run
  on Photon 5 (verify.sh only asks it its version).

## Open, outside this image
- Polis: no raster drivers, so a printer that does not take PDF does not print. Every role has an access PIN
  since universal-pin (alnasl-pin). Nunki: needs a real Pi to hear HDMI and the jack. Neither repo is changed by v7.
