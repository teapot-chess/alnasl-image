# Small screens on the pins (v7.3, compact screen v7.4)

A hall box does not need a 24-inch monitor to show its menu. A 3.5-inch panel on the Pi's GPIO header
does, if somebody tells the box it is there: SPI panels do not announce themselves, so the box cannot
detect one. `alnasl-screen.txt` on the boot partition is where that somebody writes it down.

## The file

`/boot/efi/alnasl-screen.txt`, CRLF for Notepad, English and Dutch header. It ships as:

```
SCREEN=hdmi
TOUCH=auto
ROTATE=0
MODE=640x480
CALIBRATION=
SWAPXY=
```

`SCREEN=hdmi` is the default and does nothing: no overlay, no module, the pins stay free. The file is read at
every boot and stays as it is. Deleted, it comes back from `/usr/share/alnasl/defaults/boot-efi/`. Damaged or
unreadable, the box starts as if it said `SCREEN=hdmi` and logs why.

| `SCREEN=` | Panel | Picture | Touch | Wiring the overlay assumes |
|---|---|---|---|---|
| `hdmi` | none | HDMI | none | nothing |
| `waveshare35a` (alias `piscreen`, `waveshare35`) | ILI9486, 3.5-inch, `waveshare,rpi-lcd-35` | 480x320 | XPT2046 on CE1 | DC GPIO24, reset GPIO25, pen GPIO17, backlight GPIO22 held high |
| `waveshare32b` | ILI9341, 2.8/3.2-inch, `adafruit,yx240qv29` | 320x240 | XPT2046 on CE1 | DC GPIO22, reset GPIO27, pen GPIO17 |
| `hx8357d` | HX8357D, Adafruit 3.5-inch PiTFT type, `adafruit,yx350hv15` | 480x320 | none (its STMPE610 is out of scope) | DC GPIO25, no reset |
| `mpi3508` | a 3.5-inch HDMI screen | HDMI, `MODE=` | XPT2046 on CE1 | pen GPIO17; same as `SCREEN=hdmi` + `TOUCH=xpt2046` |

`TOUCH=xpt2046` only means something with `SCREEN=hdmi` (an SPI preset brings its own touch, or has none).
`ROTATE=` is 0/90/180/270 clockwise; the panel and the stylus turn together. `MODE=` is for the HDMI stylus
screen only. `CALIBRATION=x0 x1 y0 y1` and `SWAPXY=1` override the built-in raw ranges for `ROTATE=0`.

## What a boot does

`alnasl-small-screen.service` (a oneshot, before `alnasl-kiosk.service`) runs
`AlnaslSetup.SmallScreen.boot/0` in `setup-app/lib/alnasl_setup/small_screen.ex`. It always exits 0: a
screen is not a reason for a box not to start.

1. Parse the file. `SCREEN=hdmi`: remove the udev rule and the kiosk's env file, write state `off`, done.
2. Write `/run/alnasl-small-screen/kiosk.env` saying HDMI (so a panel that never appears costs nothing), and
   the libinput matrix as a udev rule in `/run/udev/rules.d/90-alnasl-touch.rules` before the stylus exists.
3. Apply the overlays at runtime through configfs (`/sys/kernel/config/device-tree/overlays/<name>`):
   - `alnasl-spidev0-off`, `alnasl-spidev1-off`: the downstream Pi 4 tree has `spidev@0/1` on the chip selects
     the panel and the touch want; each is applied only when the node is there.
   - `alnasl-spi0-pins`: only when the SPI node has no `pinctrl-0` (the mainline Pi 3 tree).
   - the panel's own, `alnasl-<preset>-r<rotation>`: one compiled file per rotation, because the driver reads
     `rotation` at probe time and an overlay is not a template.
4. `modprobe` the modules, wait (at most 10 s each) for the panel's DRM card and the stylus's event device.
5. Unblank the panel's fb and write `KIOSK_CARD=cardN KIOSK_FB=/dev/fbN` for the kiosk. State
   `ready`, `no_panel`, `no_touch`, `overlay_failed` or `no_overlay_support`, in
   `/run/alnasl-small-screen/state.json`. `alnasl-small-screen --status` prints it.

The panel's rotation is `(base + ROTATE) mod 360`. `base` is 0 for the landscape-native waveshare35a and 90
for the portrait-native waveshare32b and hx8357d, so `ROTATE=0` is landscape on all three.

## The trap: a white panel

A `drm/tiny` driver sends its init sequence only when its pipe is enabled. Loaded, probed and left alone, the
panel shows white (the backlight on a blank controller) and looks broken. Two things enable the pipe: an
unblank of its fbdev emulation (`echo 0 > /sys/class/graphics/fbN/blank`, which boot does) and X driving
the card. The boot splash stays on HDMI's fb0, so the panel is black until X starts.

X must be told the card: `kiosk.sh` writes `Option "kmsdev" "/dev/dri/cardN"` for modesetting and
`Option "AutoAddGPU" "false"` in ServerFlags, or X picks up vc4 as a second GPU and spreads the desktop over
HDMI. The fbdev fallback uses the panel's fb, not fb0. A saved HDMI resolution is ignored (the panel has one
mode) and Settings > Resolution stands aside. With an SPI panel the kiosk uses it even when HDMI is plugged in.
If the panel does not appear, `KIOSK_CARD` stays empty and the kiosk is on HDMI as before.

## The stylus

The matrix libinput gets is `rotation(ROTATE) ∘ C`. C comes from, first to last:

1. the on-screen calibration (menu > Settings > Touch screen, five crosses; "Try it", then Keep or Undo), kept in
   `/var/lib/alnasl-setup/touch-calibration.json` with the preset it was made for. A least-squares affine fit
   of the five taps, refused when the residual is over 5 % of the screen. Stored per preset, so changing
   `SCREEN=` does not carry another panel's numbers along.
2. `CALIBRATION=` / `SWAPXY=` in the file.
3. the preset's built-in raw ranges (waveshare35a: x 390..3750, y 3700..400, measured on a real panel).

**Smoothing (v7.5).** A resistive panel jitters, and nothing above the driver can fix that well. The ads7846 driver
does it: every stylus overlay (waveshare35a, waveshare32b, the HDMI-screen `alnasl-xpt2046`) carries
`ti,debounce-max=10` (average up to ten samples), `ti,debounce-tol=30` (a reading counts when it repeats within 30
units), `ti,debounce-rep=1`, `ti,settle-delay-usec=150` (let the plates settle) and `ti,keep-vref-on`. libinput has
no smoothing for touchscreens, so the web page does none either. Too sluggish or still jumpy: those five lines in
`module/*.dts*` are the knobs (tolerance down = steadier and slower to accept a reading).

**Calibrating without a restart (v7.5).** Settings > Touch screen > Calibrate shows five crosses (corners at 15 %/85 %
and the middle, 48 px). The box fits them, then `AlnaslSetup.SmallScreen.try_calibration/1` does two things at once:
rewrites `/run/udev/rules.d/90-alnasl-touch.rules` (the next start of X) and tells the running X server through
`docker exec alnasl-kiosk xinput set-prop "ADS7846 Touchscreen" "libinput Calibration Matrix" <6 numbers> 0 0 1`.
Nothing is saved yet: the page turns into a test pad with a dot where the stylus lands, and two 44 px buttons.
**Keep** writes `/var/lib/alnasl-setup/touch-calibration.json` (reboots and updates keep it). **Undo**, or 20 seconds
without Keep (the timer lives in `AlnaslSetup.Server.TouchCal`, so a calibration too wrong to reach Keep undoes
itself), puts the saved one back, again live. Only when xinput cannot be reached (the cage path, a kiosk that is
not running) does the screen restart, as before. API: `POST /api/touch/calibrate` (try), `/keep`, `/undo`, `/reset`.


## The compact screen (v7.4)

A 3.5-inch panel can show the menu, in the sense that a postage stamp can show a map. So with a small screen
the box shows the compact screen (`/compact`, `AlnaslSetup.Compact`, `compactPage` in app.js) instead of the
menu and the role's own page. It needs nobody to touch it:

- **Who gets it.** `UI=` in `alnasl-screen.txt`: `auto` (shipped) means compact for any `SCREEN=` preset on
  the pins and the normal pages for HDMI; `compact` forces it (the 3.5-inch HDMI stylus screen); `normal`
  never. A boot without a working panel (`no_panel`) falls back to the normal pages.
- **Not set up:** always a big QR code plus one line. The setup hotspot's Wi-Fi while it is up (a phone that
  joins gets the setup page by itself), with the SSID and password in text beside it.
- **Set up:** after every start the QR code for two minutes (with a countdown), then the status: the role and
  whether its app runs, the Ethernet and Wi-Fi addresses, the access PIN (the box's own screen is where it is shown), the hotspot if it is on, host name and version.
  Without the hotspot (a set-up box on Wi-Fi, or on Ethernet past its first ten minutes) the QR code is the
  role's own page on the hall network, `http://<address>:<port>/`; the setup itself listens on localhost only.
- **With a working stylus** one Menu button (60 px) opens six tiles at most: Use (the role), PIN (every role:
  the PIN now, a new one through the on-screen keyboard, or a new random one), Wi-Fi (the network page and its on-screen keyboard; the phone through the QR code does
  the same), Show the QR code, Touch screen (calibration), Restart or shut down (asks first). Everything else
  stays on the phone. Without a stylus there is no button and nothing is missed.
- Tournament and board counts are not on it: nothing cheap to ask for them.

The page polls `/api/compact` every four seconds; the two minutes count from this boot's first poll.
`compact_test.exs` covers the selection and the timer; `verify.sh` runs the same in the image.

## Measured, and not

- waveshare35a: the overlay, the white-panel trap and the raw touch ranges were measured on a real panel
  (corners TL 356,3693, TR 3749,3597, BR 3753,582, BL 423,409).
- waveshare32b and hx8357d: built from the panels' data sheets and the mainline drivers. NOT tried on
  hardware. The waveshare32b touch ranges are a guess; the on-screen calibration fits any affine map, so a
  wrong guess costs four taps. The rotation direction for 90/270 is the driver's, unverified here.
- The 320x240 layout is CSS only (`test-compact-css.sh`); nobody has looked at it on a 2.8-inch panel.
- qemu has no SPI bus: `verify.sh` checks the modules (vermagic), the overlays, the unit, the boot file and
  the plan the shipped file gives (nothing), not a panel lighting up.

## Building

`scripts/build-modules.sh` builds, against the exact image kernel (6.1.10-11.ph5): `ads7846`, `drm_mipi_dbi`,
`ili9486`, `ili9341`, `mi0283qt`, `hx8357d`, `st7735r`, `ili9163`, `ili9225` (the sources from kernel.org
v6.1.10; `panel-mipi-dbi` is left out). `module/*.dts` and `module/*.dts.in` become `.dtbo` with `dtc -@` in a
Photon chroot, the `.dts.in` once per rotation. `assemble.sh` puts them in `/usr/lib/alnasl/overlays`.
Only `mi0283qt`, `st7735r`, `ili9163` and `ili9225` have no preset yet: they are there so a new preset needs
an overlay, not a kernel build.

## In het kort (NL)

Een klein scherm op de pinnen van de Pi meldt zich niet aan; je zet het zelf in `alnasl-screen.txt` op de
SD-kaart. `SCREEN=hdmi` (standaard) laat de pinnen met rust. `SCREEN=waveshare35a` (of `piscreen`) is het
3,5-inch scherm van 480x320 met stylus, `SCREEN=waveshare32b` het 2,8/3,2-inch scherm van 320x240 met stylus,
`SCREEN=hx8357d` het Adafruit-type van 3,5 inch, alleen beeld. Een 3,5-inch HDMI-scherm met stylus op de pinnen:
laat `SCREEN=hdmi` staan en zet `TOUCH=xpt2046`. `ROTATE=` draait beeld en stylus samen. Kom je met de stylus
naast wat je bedoelt, kalibreer dan in het menu: Instellingen > Aanraakscherm, vijf kruisjes (eerst uitproberen, dan bewaren of ongedaan maken). Een wijziging in
het bestand geldt vanaf de volgende start.

Met een klein scherm toont de kast het compacte scherm in plaats van het menu (`UI=auto`; `UI=compact` zet het
ook aan voor het 3,5-inch HDMI-scherm, `UI=normal` nooit). Is de kast nog niet ingesteld, dan zie je altijd een
grote QR-code: scan hem met je telefoon, je komt op de hotspot en de instelpagina. Is ze wel ingesteld, dan zie
je na elke start twee minuten de QR-code en daarna de status: rol, of de app draait, de adressen, versie. Werkt
de stylus, dan opent de knop Menu een paar grote tegels: gebruik, pincode (Arkab), wifi, QR-code, aanraakscherm,
herstarten of afsluiten. De rest doe je met je telefoon.
