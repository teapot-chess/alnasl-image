# Alnasl Pi image v6: modes, lockdown, auto-updates, Get help, boot screen, A/B updates

Decided 2026-10-26. v5 is skipped (nobody runs it); v6 starts from the v5 source.
Dropped: Headscale, Tailscale, any VPN, any remote shell. A box nobody can log
in to cannot be logged in to by the wrong person either.

## 1. Modes

"Master slave is simple: Arkab is slave, Alnasl master, so that's just that. No more logic." (the user,
2026-10-27). That is the whole design.

| | Master (Alnasl) | Slave (Arkab) |
|---|---|---|
| runs | Alnasl and the hall screen (kiosk) | Arkab only: reads the DGT boards, passes them to a master |
| default | yes | no |
| screen | usually | not needed |

- `/var/lib/alnasl-setup/mode` holds `master` or `slave` (on the data partition via the bind mount, so it
  survives system updates). Missing means master. `alnasl-mode.service` (oneshot, no default dependencies, after
  the data partition and before `sysinit.target`, so before the path units that carry a condition on it) runs `/usr/local/sbin/alnasl-mode`: it writes
  `/run/alnasl-mode/{mode,master,slave}`, enables and starts the right side, disables the other.
- The units of the other side cannot start: each carries a drop-in
  `ConditionPathExists=/run/alnasl-mode/master` (alnasl.service, alnasl-update.path, alnasl-kiosk.service,
  alnasl-kiosk-load.service) or `/slave` (arkab.service, arkab-update.path). Not masked: a mask replaces the
  unit file, and Alnasl's and Arkab's own updaters write those files.
- Data stays in `/var/lib/alnasl` and `/var/lib/arkab`; switching never deletes either.
- Arkab is built from the Arkab repo's HEAD (`scripts/build-arkab.sh`, an arm64 container like Alnasl's),
  installed by its own `install.sh` in `assemble.sh`, and shipped disabled. Port 4050 is open in the firewall.
- The setup wizard's first step after the language asks which, one line under each choice: "Master runs the
  hall: Alnasl and the hall screen." / "Slave only reads DGT boards and passes them to a master." The choice is
  kept in the page and written only by the last request (`/api/finish`), so a box that loses power halfway is
  not a slave without a screen. Choosing the other mode than the running one restarts the box at the end. A slave
  skips the Services step.
- Switching later: Settings > "Switch to slave" / "Switch to master" with a confirmation, then a restart;
  Arkab's status page, "Switch to master" on a slave (`GET/POST 127.0.0.1:4041/api/mode`, body
  `{"mode": "master", "confirm": "SWITCH"}`); or, headless, `alnasl-mode.txt` on the boot partition
  (`master` or `slave` on the first line, read at boot and deleted, like `alnasl-reset.txt`).
- A factory reset empties the data partition, so the mode is gone: master, wizard again.
- A slave is joined to its master on Arkab's own status page (paste the join link), as on any PC.

Dropped by the user on 2026-10-27, and not built: finding masters on the hall network (mDNS) and the 4-digit
confirmation code, `arkab-join.txt`, LED blink patterns, and hosted Alnasl as a slave's master through
anything but the existing join link.

## 2. Lockdown

- No SSH. sshd is not installed (or, if a dependency drags it in, disabled
  and masked). `alnasl-sshd.conf` and the baked root `authorized_keys` of
  v1-v5 are gone.
- Firewall: nothing inbound except what the hall needs (Alnasl's port on the
  hall network, mDNS). Port 22 closed; the `tailscale0` rule gone.
- Tailscale removed: `tailscaled`, `alnasl-tailscale-up`,
  `tailscale-authkey.txt.example`.
- The setup server's `/api/services` can no longer start sshd.
- `scripts/verify.sh` fails the build if any of the above comes back.

## 3. Auto-updates

- Apps (Alnasl / Arkab / kiosk container): the existing updater, unchanged.
- OS: `alnasl-os-update.timer`, nightly at a random time between 03:00 and
  05:00, runs `tdnf -y --security update` (falls back to a full `update`
  if Photon has no security metadata for a package set). The excludes stay:
  kernel, device trees, GPU drivers, firmware, u-boot and grub only move
  together, by a new image or a tested bundle.
- Never during a round: the script asks Alnasl `GET http://127.0.0.1:4040/local/status`
  (loopback only; 403 for anything else or anything with a forwarding header).
  `{"round_in_progress": true}` means a local game of the tournament's current
  round is live and was written to within six hours; the run is skipped
  ("skipped (round in progress)" in the result file) and tried again the next
  night. Alnasl not running (slave mode, stopped), no answer in 4 s or an
  unclear answer count as no round, and the result file says which.
- Reboot only if a running library or service needs it
  (`needs-restarting`-style check), and only in the same quiet window.
- Result in the diagnostics file: last run, packages changed, failures.

## 4. Get help (diagnostics upload, nothing else)

- One button, "Get help": the menu of the box (page `/help`, tile "Get help")
  and, on a slave, the Arkab status page on the box itself (local only; it
  presses the same button through `POST 127.0.0.1:4041/api/help/send`).
- The setup server builds the existing diagnostics file (passphrases and keys
  already removed) and POSTs it as raw `text/plain; charset=utf-8` over HTTPS,
  with `x-alnasl-box` (Pi serial, last 6), `x-alnasl-version` (Alnasl/image)
  and `x-alnasl-mode` (master/slave). Redirects are not followed, 25 s timeout.
  Outbound only: no listener, no port, no shell.
- The server answers with a 6-digit code; the screen shows a big
  "Help code 123 456", "Read this code to the people helping you. Valid until
  <date>." and keeps the last code in the page until it expires. Errors have
  their own sentence: no internet, too many requests (try again in an hour),
  support switched off on that server (404), report too large, rejected,
  unexpected answer. A slave's screenless case is not solved yet: the code is
  shown on the Arkab page of that box, not on the master's menu.
- The upload address is a setting (Settings > Get help, `support_url` in
  `/var/lib/alnasl-setup/state.json`, https:// only, empty = default hosted
  Alnasl `https://alnasl.zerotwo.cloud/support/upload`).
- Receiving side: built into Alnasl (open source), so a self-hosted Alnasl runs
  its own support. The box's upload URL is a setting (default hosted Alnasl).
  `/support`, only the configured support admins (hosted: jorian@zerotwo.cloud)
  (Keycloak, checked on every request) plus Cloudflare Access on the path.
  Enter a code, read or download the file. Uploads expire after 30 days.
  Rate-limited per IP; size-capped.

## 5. Boot screen: no black, no text, from power to kiosk

One image (the Alnasl mark on the brand background) carried through every
stage, so the screen never goes black and never shows a line of text.

| stage | how it shows the image |
|---|---|
| Pi firmware | `disable_splash=1` (no rainbow); the firmware's own framebuffer stays on the brand background colour via `framebuffer_*` defaults |
| u-boot / grub | `bootdelay=0`, silent console (`silent=1`, `stdout=nulldev` once booted); grub `timeout=0`, `timeout_style=hidden`, `GRUB_TERMINAL=gfxterm` with the splash as `background_image` |
| kernel | cmdline `quiet loglevel=0 vt.global_cursor_default=0 logo.nologo console=tty3 systemd.show_status=false rd.udev.log_level=0`; no messages reach tty1 |
| vc4 mode switch | the one place a blank can happen. Keep the firmware and KMS on the same mode (`hdmi_group/hdmi_mode` matched to the EDID mode the kernel picks, `video=` on the cmdline) so the switch is a repaint, not a re-sync |
| early userspace | `alnasl-splash.service` (very early, before `sysinit`): draws the image straight to `/dev/fb0` / DRM dumb buffer with a tiny static tool, keeps it until X owns the screen |
| X / kiosk | X starts with `-background none` (keeps the framebuffer contents), the kiosk window starts with the same image as its page background and a fade into the app once it has painted |

- Plymouth is not in Photon's repos for aarch64 and would be one more
  thing to patch; a 50-line framebuffer painter is enough.
- The cursor, getty on tty1 and every systemd status line are off.
- Shutdown/reboot shows the same image (the painter runs again on
  `shutdown.target`).
- Test: a capture card or phone video of a cold boot, frame-checked for
  black or text; done when there is neither.

## 6. Build order
1. Lockdown (section 2) + verify.sh checks.
2. Boot screen (section 5), iterated in qemu, then confirmed on the Pi.
3. OS auto-updates (section 3).
4. Get help: box side (this repo + Arkab), receiving side (Alnasl).
5. Modes (section 1).
6. A/B system updates (section 7).
7. Build v6, test in qemu, then on the Pi.

## 7. Updates without reflashing (A/B system slots)

v6 is the last image anyone flashes by hand. After it, whole-system images come over the network,
are written next to the running system, and are tried out with an automatic way back.

### Card layout (16 GB card or larger)

| # | What | Size | Label |
|---|---|---|---|
| 1 | boot (FAT): Pi firmware, u-boot, grub, `alnasl/grubenv`, the user files | 30 MiB (Photon's, unchanged) | |
| 2 | system A | 3 GiB | `ALNASL_A` |
| 3 | system B | 3 GiB | `ALNASL_B` (empty until the first update) |
| 4 | data | 512 MiB in the image, grown to the end of the card at the first boot | `ALNASL_DATA` |

Every v6+ image carries the MBR disk identifier `0x416c6e73` ("Alns"), so the slots are always
`PARTUUID=416c6e73-02` and `-03`. Photon's `resizefs.service` (grows / to 90 % and adds swap) is masked.

**Data partition** (`alnasl-data.service`, before `local-fs.target`): mounted on `/data` and bind-mounted
over `/var/lib/{alnasl,arkab,alnasl-setup,alnasl-update,alnasl-os-update,docker,containerd}`,
`/var/log/journal`, `/etc/wpa_supplicant` and the two `systemd/network/*.network.d` drop-in folders.
`/etc/alnasl/keyboard.conf` and `kiosk.conf` are symlinks into it, and the setup server writes through
them. The kiosk image therefore lives in docker's store on the data partition. Each slot keeps its
own tarball and image ID, and reloads the tarball when the store holds another image.

**Why / stays read-write.** A read-only root was considered and dropped, for three reasons:
- Alnasl's own app updater writes `/opt/alnasl` and its units.
- The nightly `tdnf` security run writes `/usr`.
- PID 1 reads `/etc/machine-id`, `/etc/hostname` and `/etc/vconsole.conf` before any mount.

Instead the root is *replaceable*: nothing on it is the only copy of anything. The updater carries
those three files into the new slot. When the running slot has a newer Alnasl than the image, it
carries that Alnasl release too, because going back would meet a database it already migrated.

**Factory reset** means the data partition, emptied. `alnasl-reset` puts back the slot's host name and
keymap, leaves `/data/.alnasl-wipe` and restarts. `alnasl-data` formats the partition early in the
next boot. The screens are the same as before.

### Trains (the rule: never auto-update between trains)

A train is a major image line (`v6`). Versions inside it are `6.0`, `6.1`, `6.2` ...
(`/etc/alnasl/image-release`).

- **Inside the box's train**, the newest image installs by itself in the nightly window (03:00-05:00).
  `alnasl-os-update` runs it before the package update, and never while Alnasl's `/local/status` says
  a round is in progress. An image downloaded and written outside the window waits ("staged") for the
  next window.
- **The next train is only offered.** The menu says "v7 is available", and only "Upgrade to v7" plus
  its confirmation starts it. Arkab can do the same (API below). A box without a screen can do it with
  `alnasl-upgrade.txt` on the boot partition, holding the train (`v7`); it is read and deleted at boot.
- **`train_guard()`** refuses any image of another train unless exactly that train was asked for. It
  never accepts an older train.
- **`min_from`** in the index makes a box take a stepping-stone version first.

### Update flow (`/usr/local/sbin/alnasl-system-update`)

1. **Fetch** `index.json` + `index.json.sig` and check the signature against
   `/etc/alnasl/update-key.pub`. The index URL is `INDEX_URL` in `/etc/alnasl/update.conf`, or the
   menu's "Where updates come from". The default is
   `https://github.com/teapot-chess/alnasl-image/releases/download/index/index.json`, a rolling
   release named `index`.
2. **Choose** the newest image of this train, or of the asked-for train.
3. **Download** the `.img.zst` to the data partition. Downloads resume, and are https only, also
   across redirects. Check its size, sha256 and its own signature.
4. **Write** it straight onto the other slot, hashing while writing. Then read the slot back from the
   card (caches dropped), compare with `raw_sha256`, and label it.
5. **Carry over**: mount the new slot, check it says it is the version the index said, and copy the
   files described above.
6. **Flip**: set the grub env to `alnasl_try=<slot> alnasl_tries=3`, then restart with the
   "Restarting into vX" screen.

The screens are in boot-screen style, in EN and NL, and also on the kiosk's /screen page:
- "Downloading an update", with a percentage and a bar
- "Installing the update / Keep the power on", with a bar
- "Restarting into v6.2"
- "The update did not work / Back on the version it had before"

### Rollback

`grub.cfg` on the boot partition (`scripts/grub-ab.cfg`) loads `/alnasl/grubenv`. No slot's own
grub.cfg is read any more.
- **Counting.** With a slot on trial, grub counts `alnasl_tries` 3 -> 2 -> 1 -> 0 and runs `save_env`
  *before* booting it. At 0 it sets `alnasl_failed` and boots `alnasl_slot`, the good one.
- **A boot that never reaches user space still costs a try.** `panic=10` restarts after a panic, and
  the BCM2835 hardware watchdog (`RuntimeWatchdogSec=15s`, the most bcm2835_wdt accepts) restarts after a hang.

`alnasl-slot-check.service` (`--boot-check`) runs on every boot.
- **On the trial slot** it waits up to 15 min for health:
  - the setup server answers;
  - master: Alnasl answers on 4040 when it is enabled, and the kiosk has painted when a screen is
    connected;
  - slave: Arkab answers on 4050.
- **Healthy**: `alnasl_slot` becomes this slot and the trial is over.
- **Not healthy**: it restarts for the next try. After the last try it points grub back itself.
- **Back on the old slot with `alnasl_failed` set**: it records "the update to vX did not start
  properly 3 times; back on vY" in `system-last-result` (shown in the diagnostics and the menu), and
  shows the rolled-back screen.
- **If grub's `save_env` ever fails to write** (FAT, block list), the user-space boot counter in
  `trial.json` still ends the trial after 3 boots.

### Trust: the update key

The image ships a **placeholder** `/etc/alnasl/update-key.pub`, marked `ALNASL-PLACEHOLDER`. With it,
updates are checked but nothing installs, and the menu says "System updates are off on this box".

Make the key pair once, on a machine of your own (not the build VM):

    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out alnasl-update.key
    chmod 600 alnasl-update.key
    openssl pkey -in alnasl-update.key -pubout -out update-key.pub

`update-key.pub` replaces `overlay/etc/alnasl/update-key.pub` before you build the image that ships to
people.
- **The private key never goes into this folder, an image, the NAS (public) or the VM.**
  `scripts/sign-release.sh` takes its path on the command line, and refuses one inside this folder.
- **If the private key is lost**, every box needs one reflash with a new public key.

### Cutting a release (the scripts publish nothing)

1. **Build.** Run `& .\build.ps1 -Version 6.1 -Release [-MinFrom 6.0] [-Notes "..."]`. It assembles
   with `ALNASL_VERSION=6.1`, verifies, and `scripts/make-release.sh` writes `out/release/`:
   - `alnasl-system-v6.1.img.zst`: slot A, compressed
   - its `.json` entry
   - `index.json`: the last one in `out/release/`, merged with this entry

   It refuses an image that carries the placeholder key.
2. **Sign**, on the machine with the key:
   `scripts/sign-release.sh /path/alnasl-update.key out/release/index.json out/release/alnasl-system-v6.1.img.zst`.
3. **Upload by hand** to `teapot-chess/alnasl-image` (that repo is not created yet):
   - the image and its `.sig` to release `v6.1`;
   - `index.json` and `index.json.sig` to the rolling release `index`.

An index entry is `{train, version, file, url, sig_url, size, sha256, raw_size, raw_sha256, min_from,
released, notes}`, inside `{"format": 1, "images": [...]}`.

### API for Arkab (setup server, 127.0.0.1:4041 only)

- **`GET /api/system`** returns `{train, version, slot, ab, updates_on, off_reason, phase, progress,
  busy, trial, available, offer, offer_blocked, last_result, checked_at, index_url}`. `offer` is
  `{train, version, size, released, notes}` of the next train, or null.
- **`POST /api/system/check`** (body `{}`) asks the index now.
- **`POST /api/system/upgrade`**, with header `X-Alnasl-Setup: 1` and body
  `{"train": "v7", "confirm": "UPGRADE", "by": "arkab"}`.
  - It accepts only a later train.
  - It answers 400 with `busy`, `updates_off`, `not_ab` or `bad_train`.
  - Then poll `GET /api/system`. `phase` is downloading, verifying, installing or restarting, and
    `progress` runs 0-100. `request_error` is `round_in_progress` if a round was live.
- **`POST /api/system/install`** with `{"confirm": "INSTALL"}` installs the newest image of the box's
  own train, now.

Arkab needs three things on its status page:
- a card that shows `offer` ("v7 is available");
- an "Upgrade to v7" button, with a confirmation step, that posts the upgrade request above;
- a progress line from `phase` and `progress`.

### Tested, and not yet

**Tested on the PC:**
- `setup-app/test/system_update_test.exs` (was scripts/test-update.py): the train rule, the choice of image including stepping stones, index
  validation, writing grubenv in place, and signatures with a throw-away key
- the screens rendered by `alnasl-splash`
- `sign-release.sh`
- the syntax of every script

**Needs the VM:**
- assemble and verify on the new layout
- `qemu-smoke.sh`, which boots slot A with an 8G disk so `alnasl-data` can grow the data partition

**Needs the Pi:**
- grub's `save_env` on this FAT, through u-boot's EFI
- a real A -> B update, and a rollback (break slot B on purpose)
- the watchdog
- the kiosk reloading its image on a new slot
