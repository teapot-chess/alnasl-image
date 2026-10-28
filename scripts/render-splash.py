#!/usr/bin/env python3
"""Renders the v6 boot screen and every screen that follows it, on the PC (needs Pillow).

    python scripts/render-splash.py path/to/alnasl-src.tar [fonts/DejaVuSansMono.ttf]

One look for every state the screen can be in: the Alnasl mark (brand/marks/alnasl.svg, nine
squares on a 24 x 24 grid, drawn here as rectangles so nothing is lost to an SVG renderer) on
Alnasl's dark theme background, and below it, when there is something to say, a title, a line
and a row of step squares. The mark never moves from one screen to the next.

Writes into overlay/usr/share/alnasl/splash/:
  alnasl-splash.png                 1920x1080, the mark only (grub, the browser's first page)
  messages.json                     the states, their steps and texts (alnasl-splash and server.py read it)
  screens/<lang>/<state>.png        1920x1080, the full screen of each state (the browser shows these)
  text/<lang>/<state>.<h>.<line>.pgm  the title and line as 8-bit coverage, for h = 1080 and 720
                                    (alnasl-splash composites these onto the framebuffer)
  text/glyphs/<h>/<name>.pgm        the few characters a changing value is made of ("37%", "v6.2"):
                                    0-9, dot, v, pct; their advances are in messages.json
  screens/glyphs/<name>.png         the same characters for the browser (1080 lines, ink, alpha)

v7, the boot log (docs/v7-plan.md section 2), from the second argument (default fonts/DejaVuSansMono.ttf):
  text/mono/<h>.pgm                 printable ASCII (32-126) in one row of fixed cells, coverage, for
                                    h = 1080 and 720 (the painter composes log lines from it)
  screens/mono/<h>.png              the same in white on alpha (the /boot page tints and draws it)
  messages.json "mono", "logview"   cell sizes, and where the status line and the log go, and their colours

A state can also show a value (a percentage or a version, composed from the glyphs) in the place
of its line, and a progress bar in the place of its step squares ("value"/"bar" in messages.json).

The font is Nunito (SIL OFL 1.1), taken from Alnasl's own source (the toon theme pack). Only
pictures rendered with it ship in the image, not the font itself.
"""
import io
import json
import os
import sys
import tarfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "overlay", "usr", "share", "alnasl", "splash")
FONT_IN_TAR = "priv/theme_packs/toon/fonts/nunito-latin.woff2"

# Alnasl's dark theme (assets/css/app.css): --bg, --ink, --accent. Dim and outline are ours.
BG = (0x16, 0x17, 0x1A)
INK = (0xE9, 0xE9, 0xE6)
ACCENT = (0xE2, 0xA0, 0x8C)
DIM = (0xA3, 0xA3, 0x9F)
OUTLINE = (0x55, 0x56, 0x5A)

# Geometry at 1080 lines; everything scales with the screen height (s = H / 1080).
# The mark: 24-unit grid, 1 unit = 15 px, squares 6 units, gaps 1; 7 of the 9 squares.
MARK = [(0, 0, "ink"), (1, 0, "ink"), (2, 0, "accent"), (1, 1, "ink"), (2, 1, "ink"), (0, 2, "ink"), (2, 2, "ink")]
SQ, STEP = 90, 105                # square, square + gap
TITLE_Y, TITLE_PX = 214, 46       # top of the title line box, below the centre
SUB_Y, SUB_PX = 282, 30
DOTS_Y, DOT, DOT_GAP = 346, 14, 10
BAR_W, BAR_H = 360, 6             # the progress bar (system updates), where the step squares go
BAR_STEPS_Y = DOTS_Y + DOT + 2 * DOT_GAP  # the bar of a state that also has step squares: under them
GLYPHS = {"0": "0", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
          ".": "dot", "v": "v", "%": "pct"}

# v7 boot log. Offsets below the centre at 1080 lines, like the rest; the mark ends at +150.
MONO_PX, MONO_LH = 17, 24          # at 1080 lines; 720 lines get round(x * 720 / 1080)
LOGVIEW = {
    "status_y": 178,               # the status line ("starting nunki - 7 of 12 up"), centred
    "log_y": 220,                  # the first log line's top; lines run down to `bottom` above the edge
    "log_y_steps": 410,            # ... on a screen that has a title, a line and step squares (first boot)
    "bottom": 18, "margin": 60, "max_chars": 150,
    # the newest line is drawn at full strength, older ones fade over BG: 255 = the colour itself
    "fade": [255, 225, 195, 170, 145, 120, 100, 85],
    # by source (bootlog.py COLOURS); errors are never faded
    "colours": {"kernel": [0x8A, 0x8B, 0x90], "systemd": list(INK), "network": [0x9D, 0xB8, 0xD6],
                "app": [0xA9, 0xC7, 0xB0], "box": list(DIM), "error": list(ACCENT), "status": list(INK)},
}


# state: steps (done-so-far, total) or None; EN and NL title and line.
STATES = {
    "boot": None,
    "firstboot-1": ((1, 3), ("Setting up this box", "Giving it a name"),
                    ("Deze box wordt klaargemaakt", "Een naam geven")),
    "firstboot-2": ((2, 3), ("Setting up this box", "Unpacking the screen software: a few minutes, only this once"),
                    ("Deze box wordt klaargemaakt", "De schermsoftware uitpakken: een paar minuten, alleen deze keer")),
    "firstboot-3": ((3, 3), ("Setting up this box", "Starting Alnasl"),
                    ("Deze box wordt klaargemaakt", "Alnasl starten")),
    "waiting": (None, ("Starting Alnasl", ""), ("Alnasl starten", "")),
    "update-os": (None, ("Updating", "Back in a minute"), ("Bijwerken", "Zo terug")),
    "update-reboot": (None, ("Updating", "Restarting, back in a minute"), ("Bijwerken", "Herstarten, zo terug")),
    "update-finish": (None, ("Updating", "Almost done"), ("Bijwerken", "Bijna klaar")),
    "update-app": (None, ("Updating Alnasl", "Back in a minute"), ("Alnasl bijwerken", "Zo terug")),
    "reboot": (None, ("Restarting", "Back in a minute"), ("Herstarten", "Zo terug")),
    "shutdown": (None, ("Shutting down", "Unplug once the green light has stopped blinking"),
                 ("Afsluiten", "Stekker eruit zodra het groene lampje niet meer knippert")),
    "reset-1": ((1, 4), ("Erasing this box", "Stopping Alnasl"), ("Deze box wissen", "Alnasl stoppen")),
    "reset-2": ((2, 4), ("Erasing this box", "Erasing the hall data"), ("Deze box wissen", "De zaalgegevens wissen")),
    "reset-3": ((3, 4), ("Erasing this box", "Erasing settings, Wi-Fi and logs"),
                ("Deze box wissen", "Instellingen, wifi en logs wissen")),
    "reset-4": ((4, 4), ("Erasing this box", "Restarting as new"), ("Deze box wissen", "Opnieuw starten als nieuw")),
    # System updates (A/B, v6): the line is replaced by a value where it says so, and a bar shows progress.
    "update-download": (None, ("Downloading an update", ""), ("Een update downloaden", "")),
    "update-install": (None, ("Installing the update", "Keep the power on"), ("De update installeren", "Laat de stroom aan")),
    "update-restart": (None, ("Restarting into", ""), ("Herstarten naar", "")),
    "update-rolledback": (None, ("The update did not work", "Back on the version it had before"),
                          ("De update werkte niet", "Terug op de vorige versie")),
}
# Which states show a value (in the line's place) and a progress bar (in the step squares' place, or just
# under them when the state has squares too: unpacking the kiosk at first boot).
VALUE = {"update-download": "pct", "update-restart": "version"}
BAR = {"update-download", "update-install", "firstboot-2"}


def font(data, px, weight):
    f = ImageFont.truetype(io.BytesIO(data), px)
    try:
        f.set_variation_by_axes([weight])
    except (OSError, AttributeError):
        pass
    return f


def coverage(text, f):
    """The line as an 8-bit coverage image: width = the text's advance, height = the line box."""
    if not text:
        return None
    asc, desc = f.getmetrics()
    w = int(round(f.getlength(text))) + 2
    im = Image.new("L", (w, asc + desc), 0)
    ImageDraw.Draw(im).text((1, 0), text, font=f, fill=255)
    return im


def write_pgm(path, im):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"P5\n%d %d\n255\n" % im.size)
        fh.write(im.tobytes())


def draw_base(W, H):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    s = H / 1080
    cx, cy = W // 2, H // 2
    for col, row, c in MARK:
        x0 = cx + round((col * STEP - 150) * s)
        y0 = cy + round((row * STEP - 150) * s)
        d.rectangle([x0, y0, x0 + round(SQ * s) - 1, y0 + round(SQ * s) - 1], fill=INK if c == "ink" else ACCENT)
    return im


def draw_dots(im, steps):
    if not steps:
        return
    done, total = steps
    W, H = im.size
    s = H / 1080
    d = ImageDraw.Draw(im)
    dot, gap = round(DOT * s), round(DOT_GAP * s)
    x = W // 2 - (total * dot + (total - 1) * gap) // 2
    y = H // 2 + round(DOTS_Y * s)
    lw = max(1, round(2 * s))
    for i in range(1, total + 1):
        box = [x, y, x + dot - 1, y + dot - 1]
        if i < done:
            d.rectangle(box, fill=INK)
        elif i == done:
            d.rectangle(box, fill=ACCENT)
        else:
            d.rectangle(box, outline=OUTLINE, width=lw)
        x += dot + gap


def draw_bar(im, frac, under_steps=False):
    W, H = im.size
    s = H / 1080
    d = ImageDraw.Draw(im)
    w, hh = round(BAR_W * s), max(2, round(BAR_H * s))
    x, y = W // 2 - w // 2, H // 2 + round((BAR_STEPS_Y if under_steps else DOTS_Y) * s)
    d.rectangle([x, y, x + w - 1, y + hh - 1], fill=OUTLINE)
    if frac > 0:
        d.rectangle([x, y, x + round(w * frac) - 1, y + hh - 1], fill=ACCENT)


def paste_line(im, cov, top, colour):
    if cov is None:
        return
    W, H = im.size
    x = W // 2 - cov.size[0] // 2
    y = H // 2 + top
    im.paste(Image.new("RGB", cov.size, colour), (x, y), cov)


def mono_atlas(path, meta):
    """One row of 95 fixed cells (ASCII 32-126) per height: coverage for the painter, white-on-alpha for
    the browser. Cell width is the font's advance rounded; the text sits in the middle of the line box."""
    meta["mono"] = {}
    for h in (1080, 720):
        px, lh = round(MONO_PX * h / 1080), round(MONO_LH * h / 1080)
        f = ImageFont.truetype(path, px)
        adv = int(round(f.getlength("M")))
        asc, desc = f.getmetrics()
        top = (lh - (asc + desc)) // 2
        im = Image.new("L", (95 * adv, lh), 0)
        d = ImageDraw.Draw(im)
        for i in range(95):
            ch = chr(32 + i)
            cell = Image.new("L", (adv, lh), 0)
            ImageDraw.Draw(cell).text((0, top), ch, font=f, fill=255)
            im.paste(cell, (i * adv, 0))
        write_pgm(os.path.join(OUT, "text", "mono", "%d.pgm" % h), im)
        g = Image.new("RGBA", im.size, (255, 255, 255, 0))
        g.putalpha(im)
        p = os.path.join(OUT, "screens", "mono", "%d.png" % h)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        g.save(p, optimize=True)
        meta["mono"][str(h)] = {"adv": adv, "lh": lh, "first": 32, "count": 95}
    meta["logview"] = LOGVIEW


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    with tarfile.open(sys.argv[1]) as t:
        fdata = t.extractfile(FONT_IN_TAR).read()
    mono = sys.argv[2] if len(sys.argv) == 3 else os.path.join(ROOT, "fonts", "DejaVuSansMono.ttf")
    os.makedirs(OUT, exist_ok=True)
    draw_base(1920, 1080).save(os.path.join(OUT, "alnasl-splash.png"), optimize=True)
    meta = {"geometry": {"title_y": TITLE_Y, "sub_y": SUB_Y, "dots_y": DOTS_Y, "dot": DOT, "dot_gap": DOT_GAP,
                         "bar_w": BAR_W, "bar_h": BAR_H, "bar_steps_y": BAR_STEPS_Y},
            "glyphs": {}, "states": {}}
    mono_atlas(mono, meta)
    # The glyphs of a value line: coverage for the painter, ink-on-alpha PNGs for the browser.
    for h in (1080, 720):
        f = font(fdata, round(SUB_PX * h / 1080), 500)
        adv = {}
        for ch, name in GLYPHS.items():
            cov = coverage(ch, f)
            write_pgm(os.path.join(OUT, "text", "glyphs", str(h), name + ".pgm"), cov)
            adv[ch] = int(round(f.getlength(ch)))
            if h == 1080:
                g = Image.new("RGBA", cov.size, INK + (0,))
                g.putalpha(cov)
                p = os.path.join(OUT, "screens", "glyphs", name + ".png")
                os.makedirs(os.path.dirname(p), exist_ok=True)
                g.save(p, optimize=True)
        meta["glyphs"][str(h)] = {"advance": adv, "names": GLYPHS, "height": cov.size[1]}
    for key, spec in STATES.items():
        if spec is None:
            meta["states"][key] = {"steps": None, "text": False}
            continue
        steps, en, nl = spec
        meta["states"][key] = {"steps": list(steps) if steps else None, "text": True,
                               "value": VALUE.get(key), "bar": key in BAR,
                               "en": {"title": en[0], "sub": en[1]}, "nl": {"title": nl[0], "sub": nl[1]}}
        for lang, (title, line) in (("en", en), ("nl", nl)):
            for h in (1080, 720):
                s = h / 1080
                ct = coverage(title, font(fdata, round(TITLE_PX * s), 700))
                cs = coverage(line, font(fdata, round(SUB_PX * s), 500))
                base = os.path.join(OUT, "text", lang, "%s.%d" % (key, h))
                write_pgm(base + ".title.pgm", ct)
                if cs is not None:
                    write_pgm(base + ".sub.pgm", cs)
                if h == 1080:
                    im = draw_base(1920, 1080)
                    paste_line(im, ct, TITLE_Y, INK)
                    paste_line(im, cs, SUB_Y, DIM)
                    draw_dots(im, steps)
                    if key in BAR:  # the browser draws the filled part over this empty track
                        draw_bar(im, 0, bool(steps))
                    p = os.path.join(OUT, "screens", lang, key + ".png")
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    im.save(p, optimize=True)
    with open(os.path.join(OUT, "messages.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print("written to", OUT)


if __name__ == "__main__":
    main()
