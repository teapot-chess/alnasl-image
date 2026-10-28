#!/usr/bin/env python3
"""v6 boot screen, the boot loaders' part. Run by assemble.sh on the build VM:

    python3 bootscreen.py ROOT BOOT

grub: no menu, no wait, no text, and the Alnasl picture as the background of its graphics
terminal (only when this grub can do that: gfxterm and png present, built in or as modules).

u-boot: bootdelay=0 and its console on the serial port only (nothing on HDMI), written to
uboot.env on the boot partition. The environment is u-boot's own default one (read out of
u-boot-rpi4.bin) or the uboot.env already there, with those keys changed; if neither can be read
with certainty, nothing is written and u-boot keeps its defaults. A uboot.env of the wrong size
is ignored by u-boot ("bad CRC, using default environment"), so the worst case of a wrong guess
is the v5 behaviour. ALNASL_NO_UBOOT_ENV=1 skips this part.
"""
import os
import re
import sys
import zlib

ENV_SIZE = 0x4000  # CONFIG_ENV_SIZE of the Raspberry Pi defconfigs
UBOOT_SET = {"bootdelay": "0", "stdout": "serial", "stderr": "serial", "silent": "1"}
ENTRY = re.compile(rb"^[A-Za-z0-9_#.:-]{1,64}=[\x09\x20-\x7e]*$")

GRUB_BLOCK = """
# Alnasl v6 boot screen: no menu, no text, the same picture as every other stage.
set timeout_style=hidden
set gfxmode=auto
set gfxpayload=keep
if loadfont unicode; then true; fi
if insmod gfxterm; then
  if insmod png; then
    terminal_output gfxterm
    background_image /boot/grub2/alnasl-splash.png
  fi
fi
"""


def say(*a):
    print("bootscreen:", *a, flush=True)


# ------------------------------------------------------------------ grub --

def grub_can_draw(root, boot):
    """gfxterm + png: as module files grub can load, or built into the EFI image."""
    mods = [os.path.join(root, "boot/grub2/arm64-efi"), os.path.join(root, "usr/lib/grub/arm64-efi")]
    for d in mods:
        if os.path.isfile(os.path.join(d, "gfxterm.mod")) and os.path.isfile(os.path.join(d, "png.mod")) \
                and os.path.isfile(os.path.join(d, "gfxterm_background.mod")):
            return "modules in " + d
    for dirpath, _, files in os.walk(boot):
        for f in files:
            if f.lower().endswith(".efi"):
                data = open(os.path.join(dirpath, f), "rb").read()
                if b"gfxterm" in data and b"background_image" in data and b"png" in data:
                    return "built into " + os.path.join(dirpath, f)[len(boot):]
    return None


def grub(root, boot):
    cfgs = [os.path.join(root, "boot/grub2/grub.cfg")]
    for dirpath, _, files in os.walk(boot):
        cfgs += [os.path.join(dirpath, f) for f in files if f == "grub.cfg"]
    cfgs = [c for c in cfgs if os.path.isfile(c)]
    if not cfgs:
        say("WARNING: no grub.cfg found; grub left as it is")
        return
    draw = grub_can_draw(root, boot)
    say("grub can draw the picture: %s" % (draw or "no (gfxterm/png not found); timeout only"))
    for c in cfgs:
        s = open(c, errors="replace").read()
        t = s
        if re.search(r"(?m)^\s*set\s+timeout=", t):
            t = re.sub(r"(?m)^(\s*)set\s+timeout=\S*", r"\1set timeout=0", t)
        elif "menuentry" in t:
            t = "set timeout=0\n" + t
        # grub's own lines on the screen ("Loading Linux ..."): only reported. Taking them out could
        # leave an empty if-block, which grub refuses; with u-boot on serial they go there anyway.
        for line in t.splitlines():
            if re.match(r"\s*echo\b", line):
                say("  NOTE %s still has: %s" % (os.path.basename(c), line.strip()))
        if "menuentry" in t and "Alnasl v6 boot screen" not in t:
            i = t.index("menuentry")
            i = t.rfind("\n", 0, i) + 1
            block = GRUB_BLOCK if draw else "\n# Alnasl v6 boot screen: no menu.\nset timeout_style=hidden\n"
            t = t[:i] + block + "\n" + t[i:]
        if t != s:
            open(c, "w").write(t)
            say("edited %s" % c[len(root):] if c.startswith(root) else c)
        for line in t.splitlines():
            if re.match(r"\s*(set\s+timeout|set\s+timeout_style|terminal_output|background_image|set\s+gfx)", line):
                say("  %s: %s" % (os.path.basename(c), line.strip()))


# ---------------------------------------------------------------- u-boot --

def parse_block(data, start):
    """NUL-separated key=value entries from start to the double NUL; None if anything is off."""
    end = data.find(b"\0\0", start)
    if end < 0:
        return None
    entries = data[start:end].split(b"\0")
    if not all(ENTRY.match(e) for e in entries):
        return None
    return entries


def default_env(binary):
    best = None
    for m in re.finditer(rb"bootcmd=", binary):
        i = m.start()
        if i and binary[i - 1] != 0:
            continue  # inside another string
        # walk back over whole entries while they look like entries
        start = i
        while True:
            j = binary.rfind(b"\0", 0, start - 1)
            cand = binary[j + 1:start - 1]
            if start - 1 <= 0 or not cand or not ENTRY.match(cand):
                break
            start = j + 1
        entries = parse_block(binary, start)
        if entries and (best is None or len(entries) > len(best)):
            best = entries
    if not best:
        return None
    keys = {e.split(b"=", 1)[0] for e in best}
    if len(best) < 10 or not {b"bootcmd", b"boot_targets"} <= keys:
        return None
    return best


def uboot(boot):
    if os.environ.get("ALNASL_NO_UBOOT_ENV") == "1":
        say("u-boot: skipped (ALNASL_NO_UBOOT_ENV=1)")
        return
    envp = os.path.join(boot, "uboot.env")
    entries, size, src = None, ENV_SIZE, None
    if os.path.isfile(envp):
        raw = open(envp, "rb").read()
        if len(raw) > 8 and int.from_bytes(raw[:4], "little") == zlib.crc32(raw[4:]):
            entries, size, src = parse_block(raw, 4), len(raw), "the uboot.env already there"
        else:
            say("u-boot: the uboot.env there has a bad CRC; it is replaced")
    if entries is None:
        ub = os.path.join(boot, "u-boot-rpi4.bin")
        if not os.path.isfile(ub):
            say("WARNING: u-boot: no u-boot-rpi4.bin; u-boot left with its defaults")
            return
        entries, src = default_env(open(ub, "rb").read()), "u-boot-rpi4.bin's default environment"
    if not entries:
        say("WARNING: u-boot: could not read its environment with certainty; u-boot left with its defaults")
        return
    env = {}
    for e in entries:
        k, v = e.decode().split("=", 1)
        env[k] = v
    was = {k: env.get(k) for k in UBOOT_SET}
    env.update(UBOOT_SET)
    body = b"".join(("%s=%s" % kv).encode() + b"\0" for kv in env.items()) + b"\0"
    if len(body) > size - 4:
        say("WARNING: u-boot: the environment does not fit in %d bytes; u-boot left with its defaults" % size)
        return
    body += b"\0" * (size - 4 - len(body))
    open(envp, "wb").write(zlib.crc32(body).to_bytes(4, "little") + body)
    say("u-boot: uboot.env written from %s (%d variables, %d bytes)" % (src, len(env), size))
    for k in UBOOT_SET:
        say("  %s: %s -> %s" % (k, was[k], env[k]))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root, boot = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/")
    grub(root, boot)
    uboot(boot)


if __name__ == "__main__":
    main()
