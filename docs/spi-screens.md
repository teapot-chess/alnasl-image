# Small screens on the pins (v7.3)

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

1. the on-screen calibration (menu > Settings > Touch screen, four crosses), kept in
   `/var/lib/alnasl-setup/touch-calibration.json` with the preset it was made for. A least-squares affine fit
   of the four taps, refused when the residual is over 5 % of the screen. Stored per preset, so changing
   `SCREEN=` does not carry another panel's numbers along.
2. `CALIBRATION=` / `SWAPXY=` in the file.
3. the preset's built-in raw ranges (waveshare35a: x 390..3750, y 3700..400, measured on a real panel).

The calibration page restarts the kiosk; the udev rule is rewritten and the device retriggered.

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
naast wat je bedoelt, kalibreer dan in het menu: Instellingen > Aanraakscherm, vier kruisjes. Een wijziging in
het bestand geldt vanaf de volgende start.
