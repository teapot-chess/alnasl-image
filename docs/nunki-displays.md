# Nunki's screens (v7.5)

A Nunki box shows the hall what is happening: pairings, the clock, the announcer's next line. Before 7.5 it
had one screen and it showed Nunki's admin page, which is not what the hall wanted to look at. Now:

- the HDMI monitors show the **broadcast** (`http://localhost:4062/hall?screen=hdmi1|hdmi2`), full screen;
- a Pi 4 has two HDMI outputs, so a second monitor can show the **management** page, a mirror, or a second
  tournament;
- a touch panel on the pins (Waveshare 3.5(A), `docs/spi-screens.md`) is the **remote control**: Live, Pause,
  Black, which tournament, sound on or off, volume. It never shows the broadcast.

Other roles, and a nunki box without a second monitor or a panel, behave as before, except that a single
HDMI monitor on a nunki box now opens the broadcast instead of Nunki's admin page.

## Layouts

`/var/lib/alnasl-setup/displays.conf` on the data partition (it survives updates). Four lines (six since 7.7), read word by word
by `alnasl-kiosk`, never sourced:

```
LAYOUT=auto|single|manage|mirror|two
SWAP=0|1
ROTATE1=normal|right|inverted|left
ROTATE2=normal|right|inverted|left
MODE1=auto|WxH        (7.7, the Live boards wizard)
MODE2=auto|WxH
```

| Layout | HDMI 0 | HDMI 1 |
|---|---|---|
| `auto`, one monitor (no file) | broadcast 1 | - |
| `auto`, two monitors (no file) | management | broadcast 1 |
| `single` | broadcast 1 | dark |
| `manage` | management | broadcast 1 |
| `mirror` | broadcast 1 | broadcast 1 |
| `two` | broadcast 1 | broadcast 2 |

`SWAP=1` swaps the two outputs. "HDMI 0" and "HDMI 1" are what the Pi 4 prints on its case (HDMI 0 is next to
the power socket); the kernel calls them `HDMI-A-1` and `HDMI-A-2`, which is how every log line confuses you.

A two-monitor layout with only one monitor connected shows broadcast 1 on that monitor and says so in the wizard.
The rule lives in two places that must agree: `kiosk.sh` (`nunki_plan`, which decides) and
`AlnaslSetup.Server.Displays.plan/2` (which tells the wizard what will happen before anything restarts).
`scripts/test-kiosk-logic.sh` (section 8) and `setup-app/test/nunki_displays_test.exs` check the same table
from both ends.

## The wizard

Settings > Screens (HDMI menu), or Menu > Screens on the panel. One page, four numbered steps:

1. **What the monitors show**: the five layouts as small pictures (management in amber, broadcast 1 blue,
   broadcast 2 green, dark is dark).
2. **Which monitor is which**: *Identify screens* puts a big number and its job ("HDMI 1: Hall screen 1") on
   every monitor for eight seconds; *Swap* if the numbers are on the wrong monitors.
3. **Turned**: a rotation per output (xrandr, cheap). A resolution per output is the Live boards wizard's (7.7);
   this page keeps whatever it set.
4. **Tournaments**: per broadcast screen, Nunki's choice or a fixed tournament (through Nunki's API; skipped with
   a note when Nunki does not answer).

*Save* writes the tournaments to Nunki, the file to the data partition, and restarts the kiosk. About half a
minute of dark monitors.

## The panel's Nunki controls

`/nunki` in the setup app, through `/api/nunki` (`AlnaslSetup.Server.Nunki`), which proxies Nunki's local API
v1 on the loopback (Nunki refuses anything else):

```
GET  /api/local/v1/state            screen, audio, hall_tournament, tournaments, countdown, version,
                                    screens: {hdmi1: {mode, tournament}, hdmi2: {...}}
POST /api/local/v1/screen           {"screen": "hdmi1"|"hdmi2", "mode": "live"|"paused"|"black"}
POST /api/local/v1/audio            {"enabled": true|false}
POST /api/local/v1/hall_tournament  {"screen": "hdmi1"|"hdmi2", "id": id|null}
```

`screen` is optional and means hdmi1. A Nunki without `screens` (the first v1) gets one card. A Nunki that
answers 404 is "too old: update Nunki", one that does not answer is "Nunki does not answer", in those words,
on the panel. Big targets: the three mode buttons are 60 px high on a 480x320 panel. The volume slider is the
box's own (`alnasl-sound`, the same as Settings > Sound). Nunki's sound is off in a fresh image
(`NUNKI_AUDIO=off` in `/etc/nunki/nunki.env`: only the default; the button turns it on).

## Live boards on HDMI (7.7)

The panel's **Live boards** (stylus menu, Hall screens, or the HDMI menu's tile; `/liveboards`) puts OpenResults'
live boards on the monitors. A wizard of big tiles, nothing to type:

1. **Tournament**: *Whatever is playing* (Nunki's own pick, `id: null`) or one of Nunki's tournaments; one that is
   not published on OpenResults says so.
2. **Screen 1**, then **Screen 2** with two monitors: the first 1/2/4/6/8/12/16 boards (screen 2 goes on where
   screen 1 ends: 1-4 then 5-8), a *From - to* stepper (- and +, 1 to 999), *All* (screen 1), *Broadcast* (the
   ordinary hall screen), and for screen 2 *Same as screen 1* (mirror) or *Off*. *Identify screens* is on these steps.
3. **Resolution** per monitor that has its own picture: *Auto* (the monitor's preferred mode) or any mode the kernel
   lists for it (`/sys/class/drm/<card>-HDMI-A-n/modes`). The two may differ. A mirror takes screen 1's mode when
   monitor 2 lists it, else its own preferred one.
4. **Check**, then **Done**.

`POST /api/liveboards` (`AlnaslSetup.Server.LiveBoards`) sets, per hall screen, Nunki's tournament and its source
`boards` (Nunki 0.9.0: `POST /api/local/v1/screen_source {"source": "boards", "boards": "5-8"}`). Nunki frames
`<results>/live/current/projector?kiosk=1&boards=5-8`, where `<results>` is the tournament's OpenResults address that
OpenPairings sends over the hall link. That page always shows the latest round and moves on by itself, so the
screens follow round after round with nobody touching anything. Nunki keeps the source and the selection in its
own state: they survive a restart of Nunki or the box. Nothing published: Nunki's frame says the tournament is not
on OpenResults, in big letters, instead of an error page.

Then the box's half (`Displays.apply_live`): `displays.conf` gets the layout the answers mean (screen 2 boards or
broadcast: `two`; *Same as screen 1*: `mirror`; *Off* or one monitor: `single`) and two more lines:

```
MODE1=auto|WxH
MODE2=auto|WxH
```

**Nothing reboots, and the X server does not restart.** The setup app runs `docker exec alnasl-kiosk kiosk-res
layout <extend|mirror|single> X1 job1 mode1 rot1 X2 job2 mode2 rot2`: xrandr lays the outputs out again (`--mode`
or `--auto`, `--right-of` or `--same-as` or `--off`), writes each window's place to `/run/alnasl-kiosk/win-1` and
`win-2`, and ends only the Chromium windows whose line changed; each window's loop starts it again where it now
goes. The panel (`:1`) is not touched. With one monitor it is `kiosk-res apply`. Only a kiosk that cannot do it live
(fbdev, or one started by an older image) restarts its container, about half a minute, panel included.

**A new resolution must be kept.** The panel asks *Keep this resolution?* with a 15-second count; Undo, or nothing,
puts the previous modes back (the server's own timer, so a panel that froze or a monitor that went black reverts
anyway; 45 seconds when the kiosk had to restart). A change that touches no mode is final at once. A kiosk restart
comes back to `/liveboards`, which asks again while the timer runs.

Why OpenResults and not the box's own Alnasl, in a hall without internet: Alnasl's board pages sit behind its
operator login, and the broadcast delay (the anti-cheating minutes between a move and the public seeing it) is
OpenResults'. A hall screen that showed Alnasl's boards would show the moves before the delay. Without internet the
frame says the page cannot be reached and keeps trying; *Broadcast* (Nunki's own hall screen) works offline.

**Dutch.** The panel's Nunki pages (the compact screen and its menu, Hall screens, Screens, Live boards) speak Dutch
once the menu's *Language* tile says so (`/api/lang`, the box-wide setting). Every other page of the box stays
English.

## How it is built, and why this way

**One X server for both HDMI outputs, a second X server for the panel.**

- **X `:0`**: the `modesetting` driver on the vc4 card, both HDMI outputs arranged with xrandr (`--right-of` for
  two pictures, `--same-as` for the mirror). One Chromium per output, each with its own profile directory, placed
  with `--window-position`/`--window-size` from xrandr's own geometry, **no window manager** (matchbox would
  stretch one window across both monitors). Each window has its own restart loop. `/run/alnasl-kiosk/outputs`
  says which window is where; Identify and the wizard read it.
- **X `:1`**: the `fbdev` driver on the panel's framebuffer, `-sharevts -novtswitch` on `:0`'s VT, with only the
  panel's stylus (an explicit libinput device for the ADS7846; `AutoAddDevices` off). `:0` ignores that stylus
  with an InputClass. The panel's Chromium opens `/compact`, as on any box with a panel.

Why not one X server for everything (two Device sections, "Zaphod" screens, mixed modesetting and fbdev)? Each
piece already works alone: `:0` is today's single-screen config with a second output, `:1` is today's panel
config. Mixed drivers in one server are the configuration Xorg tests least. Input stays put by construction,
not by a matrix nobody can calibrate. And a panel X that dies takes the panel down, not the hall's screens.

**Every window starts at the setup app's boot screen** (`/boot?to=hall1|hall2|manage|compact&where=hdmi|panel`).
`screen.html` holds a broadcast window there until Nunki answers, then the server sends it to the right page.
This way a Nunki that starts slowly, crashes or is updated never shows Chromium's error page in the hall.
`where` is stored in the window's own `localStorage`, so the HDMI window never turns into the compact menu
(the panel is compact; the HDMI monitor beside it is not), and the panel's pings never move the HDMI window's
remembered page.

**Hot-plug.** A watcher looks at `/sys/class/drm/*-HDMI-A-*/status` every five seconds. Two looks that agree on a
different set of monitors: the screens stop and the kiosk container restarts with the new plan. A monitor that
goes to sleep and wakes up again inside five seconds is ignored. `KIOSK_NO_HOTPLUG=1` switches the watcher off.

**Fallbacks.** No `modesetting` (fbdev only): one broadcast window. No panel: the HDMI layout alone. No second
monitor: broadcast 1 on the first. A panel and no HDMI monitor: the panel as before. The kiosk watchdog
(`alnasl-kiosk`) restarts the container as before; it does not know or care how many windows it holds.

## Never met real hardware (as of 7.5)

The whole dual-screen path was written against fake sysfs, fake Xorg and a scratch dash harness. Untested on a Pi:

- two HDMI monitors on vc4 with xrandr `--right-of` and `--same-as`, especially with different resolutions;
- `:1` on fbdev with `-sharevts` while `:0` runs modesetting (the theory says yes; the Pi has not been asked);
- the ADS7846 stylus on `:1` only, and ignored on `:0`;
- hot-plug (the vc4 driver's connector status on unplug, and how long it takes);
- Identify matching windows by `screenX`/`screenY` in a window without a window manager;
- rotation per output with the window geometry read back after the rotation.

Added in 7.7, also never on a Pi:

- two monitors with different modes on a Pi 4 (`--mode` per output, `--right-of` with unequal heights);
- `kiosk-res layout` on real vc4: the geometry read back after a mode change, and a window that lands in it;
- the 15-second revert putting the previous modes back, and the 45-second one after a kiosk restart;
- a Chromium window ended and started again while the other keeps running (the profile lock of its own directory);
- the kiosk restart path (fbdev or an older kiosk) coming back to `/liveboards` with the question still open.
