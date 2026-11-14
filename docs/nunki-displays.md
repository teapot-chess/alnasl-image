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

`/var/lib/alnasl-setup/displays.conf` on the data partition (it survives updates). Four lines, read word by word
by `alnasl-kiosk`, never sourced:

```
LAYOUT=auto|single|manage|mirror|two
SWAP=0|1
ROTATE1=normal|right|inverted|left
ROTATE2=normal|right|inverted|left
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
3. **Turned**: a rotation per output (xrandr, cheap; a resolution per output is not offered, `auto` takes each
   monitor's preferred mode).
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
