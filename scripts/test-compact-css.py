"""Static checks for the 3.5 inch layout (app.css compact-screen block, app.js status strip). Runs on any host:
python scripts/test-compact-css.py   (no image needed)."""
import os
import re
import sys

WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "overlay", "usr", "local", "share", "alnasl-setup", "www")
css = open(os.path.join(WWW, "app.css"), encoding="utf-8").read()
js = open(os.path.join(WWW, "app.js"), encoding="utf-8").read()
fails = 0


def expect(cond, what):
    global fails
    print(("ok   " if cond else "FAIL ") + what)
    fails += 0 if cond else 1


m = re.search(r"/\* ==== compact-screen:.*?/\* ==== end compact-screen ==== \*/", css, re.S)
expect(bool(m), "compact block is delimited")
blk = m.group(0) if m else ""
expect(blk.count("{") == blk.count("}"), "compact block braces balance")
expect("@media (max-width: 520px), (max-height: 360px)" in blk, "compact layout sits behind the 520/360 media query")
expect(re.search(r"^\.statusbar \{ display: none; \}", blk, re.M) is not None, "status strip hidden on big screens")
# Everything between the markers other than the one hidden rule lives inside an @media block.
outside = re.sub(r"@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}", "", blk[blk.index("*/") + 2 : blk.rindex("/*")], flags=re.S)
rules = [x for x in re.findall(r"[^{}]+\{[^{}]*\}", outside)]
expect(len(rules) == 1, "no compact rule leaks outside a media query (%d outside)" % len(rules))
for sel in (".tab", ".btn", ".top .btn.sm", ".item"):
    mm = re.search(re.escape(sel) + r" \{[^}]*min-height: (\d+)px", blk)
    expect(bool(mm) and int(mm.group(1)) >= 40, "%s keeps a tap target of 40 px or more" % sel)
expect("hover" not in blk, "no hover-only control in the compact block")
expect(js.count('st_up:') == 2 and js.count('st_down:') == 2, "status strip words exist in EN and NL")
sys.exit(1 if fails else 0)
