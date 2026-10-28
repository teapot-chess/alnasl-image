"""v6 boot screen painter (and v7's boot log): unit test, run inside the image (chroot, image python) by verify.sh.

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

# v7: the boot log. The glyph atlases are there, the log changes the picture of the states that show it and
# nothing else, and the log region alone is whole rows of the frame, the same bytes the full frame has there.
check(m.bootlog is not None, "the painter found bootlog.py")
for size in (1080, 720):
    check(os.path.isfile("%s/text/mono/%d.pgm" % (m.SHARE, size)), "glyph atlas %d" % size)
    check(os.path.isfile("%s/screens/mono/%d.png" % (m.SHARE, size)), "browser glyph atlas %d" % size)
lines = [("kernel", "kernel", False, "usb 1-1: new high-speed USB device"), ("network", "network", False, "eth0: Gained carrier"),
         ("systemd", "error", True, "nunki.service: Failed with result 'exit-code'."), ("nunki", "app", False, "listening on 127.0.0.1:4062")]
logv = ("starting nunki - 7 of 12 up", lines)
for w, h, bpp, pad in ((1920, 1080, 32, 0), (800, 480, 16, 0), (1280, 720, 32, 128), (720, 720, 32, 0), (1024, 600, 24, 0)):
    fb = FakeFb(w, h, bpp, pad)
    for key in m.LOG_STATES:
        if key not in states:
            continue
        bare, _ = m.compose(fb, key, "en")
        t = time.time()
        withlog, _ = m.compose(fb, key, "en", logv=logv)
        dt = time.time() - t
        check(len(withlog) == len(bare) and withlog != bare, "%s at %dx%d %dbpp: the log is drawn (%.0f ms)" % (key, w, h, bpp, dt * 1000))
        reg = m.log_region(fb, key, *logv)
        check(reg is not None and len(reg[1]) % fb.stride == 0 and withlog[reg[0] * fb.stride:reg[0] * fb.stride + len(reg[1])] == reg[1],
              "%s at %dx%d: the log region is whole rows, as in the full frame" % (key, w, h))
    for key in ("update-restart", "reset-2", "shutdown"):
        if key in states:
            a, _ = m.compose(fb, key, "en")
            b2, _ = m.compose(fb, key, "en", logv=None)
            check(a == b2, "%s at %dx%d: v6's picture, no log" % (key, w, h))
sys.exit(1 if fails else 0)
