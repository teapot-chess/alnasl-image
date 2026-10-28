"""v6 boot screen painter: unit test, run inside the image (chroot, image python) by verify.sh.

Composes every state, in both languages, on fake framebuffers of the usual shapes (16/24/32 bpp,
720p/1080p/4K, padded strides) and checks: the frame has the right size, the mark's accent square
sits where the probe says, a text state really differs from the plain screen, and every picture
the browser asks for (/splash/...) exists. No framebuffer, tty or X is touched.
"""
import importlib.machinery
import importlib.util
import os
import sys
import time

loader = importlib.machinery.SourceFileLoader("splash", "/usr/local/sbin/alnasl-splash")
spec = importlib.util.spec_from_loader("splash", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

fails = 0


def check(ok, what):
    global fails
    print("%s %s" % ("ok  " if ok else "FAIL", what))
    fails += not ok


class FakeFb(m.Fb):
    def __init__(self, w, h, bpp, pad=0):
        self.w, self.h, self.bpp, self.yoff, self.B = w, h, bpp, 0, bpp // 8
        self.chan = [(11, 5), (5, 6), (0, 5)] if self.B == 2 else [(16, 8), (8, 8), (0, 8)]
        self.stride = w * self.B + pad


states = m.MSG["states"]
check(len(states) >= 10 and "boot" in states, "messages.json: %d states" % len(states))
for key, st in states.items():
    for lang in ("en", "nl"):
        if st.get("text"):
            check(os.path.isfile("%s/screens/%s/%s.png" % (m.SHARE, lang, key)), "browser picture %s/%s" % (lang, key))
            for h in (1080, 720):
                check(os.path.isfile("%s/text/%s/%s.%d.title.pgm" % (m.SHARE, lang, key, h)), "title %s/%s %d" % (lang, key, h))
check(os.path.isfile(m.SHARE + "/alnasl-splash.png"), "plain picture")

worst = 0.0
for w, h, bpp, pad in ((1920, 1080, 32, 0), (1920, 1080, 16, 0), (1280, 720, 32, 128), (3840, 2160, 32, 0), (1024, 768, 24, 0)):
    fb = FakeFb(w, h, bpp, pad)
    plain, probe = m.compose(fb, "boot", "en")
    check(len(plain) == fb.stride * h, "%dx%d %dbpp: frame size" % (w, h, bpp))
    check(plain[probe:probe + fb.B] == fb.px(m.ACCENT), "%dx%d %dbpp: accent square at the probe" % (w, h, bpp))
    for key in states:
        for lang in ("en", "nl"):
            t = time.time()
            frame, _ = m.compose(fb, key, lang)
            worst = max(worst, time.time() - t)
            if states[key].get("text") and frame == plain:
                check(False, "%s/%s at %dx%d draws no text" % (lang, key, w, h))
print("slowest compose: %.0f ms (qemu-user here; the Pi itself is faster)" % (worst * 1000))
sys.exit(1 if fails else 0)
