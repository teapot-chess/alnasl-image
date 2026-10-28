# v7.0: a 6.2 box with a screen updated and went black (2026-10-28)

The report: a real Pi 4, role master (alnasl), kiosk on HDMI, 6.2. It updated itself to v7.0 the day
v7.0 came out, and the screen went black. (It later came up on 7.0 by itself; see the next section but one.) There is no SSH on the box and there never will be,
so all of this comes from the code and from qemu.

## What was reproduced and what was not

The 6.2 to 7.0 update was replayed in qemu (raspi4b) on the build VM:

- a 6.2 card booted twice;
- the 6.2 updater's steps applied to slot B: 7.0's zst written, sha checked, label, carry-over,
  `next-boot=update-finish`, grubenv `alnasl_try=B`, and `trial.json`;
- slot B then booted with the data partition of a configured master (`done`, `mode=master`, and v6's
  `mode-applied`).

In that boot:

- alnasl-mode said "this boot runs as alnasl" and "applying alnasl".
- The firewall came up for the alnasl role (4040 and so on).
- Alnasl 0.12.0 started on 6.2's 0.10.2 database. It ran the new migrations (support_uploads,
  ui_mode) and listened on 4040.
- The setup server listened on 4041.
- There was no ordering cycle: `systemd-analyze verify` is clean, and the boot log has none.
- 7.0 needs a new kiosk image (6.2's ID is `fb75382…`, 7.0's is `4d17d34…`), so
  alnasl-kiosk-load started loading the tarball.
  - That load failed in qemu with a gzip error.
  - The same tarball tests clean (`gzip -t`) in the 7.0 release file, so the corruption is qemu's SD
    emulation, which was seen before.

What qemu could not show is the screen itself. raspi4b has no framebuffer and no vc4, so the
splash → X → Chromium hand-over never runs there. **The exact cause on the maintainer's Pi 4 is
therefore not proven.** Without the box's journal, it cannot be.

## Later evidence from the box, and the cause it points to

The box did **not** roll back. After about three reboots it came up on 7.0 and has run fine since. 7.0
is therefore not broken; its first boots were too slow. Read against the code, the evidence goes like
this.

- **Why the box rebooted.** The trial health check (`alnasl-system-update --boot-check`) allows
  `HEALTH_MINUTES` = 15. In that time it needs three things: the setup server, Alnasl, and Chromium
  having requested /boot.
- **Why Chromium is so late on that boot.** 7.0 ships a new kiosk image, so the first boot runs
  `docker load` on a 338 MB gzip (about 1 GB unpacked) from the SD card. alnasl-kiosk.service is
  ordered after alnasl-kiosk-load. The load may take 30 minutes (`TimeoutStartSec=1800`), and there is
  no X and no Chromium until it is done.
  - On this card the load did not finish in 15 minutes, so the check rebooted in the middle of it.
  - The qemu journal shows one more way the load restarts from 0 % without a reboot (the
    progress-painter timeout below).
- **Why each try got further (most likely; not measured on the box).** docker keeps every layer it has
  fully unpacked. A load interrupted by a
  reboot skips those layers next time ("already exists"). So boot 2 had less to do than boot 1, and
  boot 3 finished inside the window and passed.
- **Why it stayed on 7.0.** grub counts the trial down 3 → 2 → 1 → 0 (`scripts/grub-ab.cfg`).
  - The boot check goes back to the old slot only when a trial boot fails while no tries are left
    (`alnasl_tries=0`, or `trial.json` counted 3 boots).
  - Here the third trial boot was healthy, so it was marked good.
  - "About three reboots" = the 6.2 updater's reboot into B plus two health-check reboots.
  - This is the intended behaviour, and grub's counter did not misbehave. The margin was one boot: one
    more slow boot and it would have gone back to 6.2.
  - If the third boot had also failed, the next boot would have been 6.2, never 7.0.
- **Why the screen was black.** This part is still unproven. During the load the screen should show the
  boot picture with a progress bar, and qemu has no display to check that with. The diagnostics from
  the box's history (Menu > Diagnostics > Save, "OS and system updates" section) will name what each
  trial boot was missing ("boot N: missing the screen").

## The fixes for this

- **The health check waits for a kiosk load that is still running.** At 15 minutes, while
  alnasl-kiosk-load is active or between two of its retries, the check keeps waiting, up to
  `HEALTH_MAX_MINUTES` = 60 in all. A reboot in the middle of the load only throws away work.
- **The load itself cannot be cut by its own progress bar** (below).

## Other defects found on this path

qemu showed one real chain that ends with no browser for good, on 6.2 and v7 alike:

```
containerd.service: start operation timed out
alnasl-kiosk-load.service: Job ... failed with result 'dependency'
```

1. containerd has the stock 90 s to start.
2. If it runs out, docker fails.
3. alnasl-kiosk-load had `Requires=docker.service`, so it failed as a *dependency*.
4. `Restart=on-failure` never retries that kind of failure.
5. alnasl-kiosk then waits for an image that nothing will ever load: "kiosk: image alnasl-kiosk:latest
   not loaded yet; waiting".
6. X never starts, so Chromium never asks for /boot.

The first boot after an update is the boot where containerd is most likely to be late. On that boot:

- Alnasl starts for the first time in a new slot, and its migrations run.
- The journal is busy.
- 7.0's new kiosk image (338 MB of gzip) is read from the SD card.

v7 made that boot heavier than 6.x boots: a kiosk image change, CUPS, ALSA and the boot-log follower.
This chain fits "updated, then no picture". It is the leading candidate, not a proven cause.

One more thing matters for the advice below. The A/B health check calls the slot good as soon as all
three of these hold:

- the setup server answers;
- Alnasl answers;
- Chromium has requested /boot, /screen or / once.

So a screen that goes black **after** Chromium's first page counts as healthy, and the box does not
roll back by itself.

A second weak point appeared in the same boot's journal. alnasl-kiosk-load's reader calls
`alnasl-splash --progress N` with a 20 s timeout. When the painter was slow to start, the reader raised
`subprocess.TimeoutExpired`, which cut the pipe into `docker load`:

```
TimeoutExpired: Command '['/usr/local/sbin/alnasl-splash', '--progress', '6']' timed out after 19.9 seconds
gzip: stdin: unexpected end of file
alnasl-kiosk-load: docker load failed
```

The load then starts again from 0 % every 30 s. On a slow or busy card it may never finish. That boot's
other failed attempt was real gzip corruption, which is qemu's SD emulation.

## Ruled out (with what)

- **The role mapping.** "master" becomes alnasl. alnasl-mode's chroot tests in verify.sh pass, and in
  the qemu journal alnasl-mode applied alnasl and Alnasl ran.
- **The ordering cycle through the firewall's `After=alnasl-mode`.** `systemd-analyze verify` is
  clean and the boot log has no cycle.
- **CUPS and sound.** Their units are held back by their role flags. On an alnasl box they do not run.
- **The splash glyph atlas.** A compose sweep over states, sizes and depths gave 0 exceptions. A broken
  log never costs the picture.
- **The kiosk extension and kiosk.sh changes.** They only switch ports (4040, 4050, 4061 or 4062). The
  Chromium layer and packages are identical to 6.2.
- **The containerd timeout as a v7 regression.** 6.2 times out in qemu too (ttyS0-v62boot1.log). It
  is a latent bug, not a new one.
- **The release tarball.** It is intact (`gzip -t`, sha256 `416e8e23…`).

## The fix (7.1)

- **`alnasl-kiosk-load.service`:** `Wants=docker.service`, not `Requires`. The script waits up to
  15 min for `docker info` and kicks `docker.service` while it waits.
- **The progress call in alnasl-kiosk-load** can no longer raise. A slow painter skips a step of the bar;
  it never fails the load.
- **`alnasl-kiosk`:** after 60 s with no image and no alnasl-kiosk-load running, it starts the load
  again.
- **`containerd.service.d/alnasl.conf`:** `TimeoutStartSec=300`, `Restart=on-failure`.
- **A failed trial boot now explains itself on the FAT partition.** Before its reboot, alnasl-slot-check
  writes the full diagnostics to `alnasl-trial-<version>-boot<N>.txt`. A box with a black screen that
  rolls back leaves up to three of these, readable on any PC.
- **Diagnostics** (the menu's Save and the support upload) now include:
  - a Role section: the chosen role, the role this boot, the flags, what the slot applied, a pending
    `alnasl-mode.txt`, alnasl-mode's journal and role switches;
  - every role's units (Arkab, Polis, Nunki, CUPS, sound, containerd, kiosk-load, slot-check and so
    on) with their state and whether their condition held or they were skipped.
  - The setup server also logs each role switch.
- **verify.sh** checks all of the above. The check on kiosk-load's `Requires=docker` would have caught
  the defect.
