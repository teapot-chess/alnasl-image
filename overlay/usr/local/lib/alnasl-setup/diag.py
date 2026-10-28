"""Diagnostics for the Alnasl hall box (python3 standard library only).

Imported by server.py. Collects what is needed to answer "does the Wi-Fi work
at all, and if not, where does it stop" plus the network, the services, the
kiosk and the last journal lines, and can write all of it to one text file on
the FAT boot partition so it can be read on any PC.

Secrets never leave this module: every piece of text goes through redact()
before it is returned or written, and the Wi-Fi configuration is never dumped
raw (only a summary: SSIDs, country, secured yes/no).
"""
import glob
import os
import re
import subprocess
import time

BOOT_EFI = "/boot/efi"
WPA_DIR = "/run/wpa_supplicant"
KIOSK_RUN = "/run/alnasl-kiosk"
OS_UPDATE_DIR = "/var/lib/alnasl-os-update"   # written by /usr/local/sbin/alnasl-os-update

# (unit, extra journalctl selector)
JOURNAL_UNITS = [
    ("alnasl-setup.service", []),
    ("alnasl-kiosk.service", []),
    ("alnasl.service", []),
    # v7: the role, every role's app, and the steps between docker and the screen
    ("alnasl-mode.service", []),
    ("arkab.service", []),
    ("polis.service", []),
    ("nunki.service", []),
    ("cups.service", []),
    ("alnasl-sound.service", []),
    ("containerd.service", []),
    ("alnasl-kiosk-load.service", []),
    ("alnasl-slot-check.service", []),
    ("wpa_supplicant@wlan0.service", ["-t", "wpa_supplicant"]),
    ("systemd-networkd.service", []),
    ("systemd-resolved.service", []),
    ("alnasl-wifi.service", []),
    ("docker.service", []),
    ("alnasl-os-update.service", []),
    ("alnasl-splash.service", []),
    ("alnasl-reset.service", []),
]
SERVICE_UNITS = ["alnasl.service", "alnasl-kiosk.service", "alnasl-setup.service", "wpa_supplicant@wlan0.service",
                 "systemd-networkd.service", "systemd-resolved.service", "docker.service", "alnasl-firewall.service",
                 "alnasl-os-update.timer", "alnasl-os-update.service", "alnasl-splash.service",
                 "getty@tty1.service", "getty@tty2.service", "getty@tty3.service", "systemd-logind.service",
                 # v7: every role's units, not only Alnasl's: a box that is the wrong thing, or no thing, shows here
                 "alnasl-mode.service", "alnasl-update.path", "arkab.service", "arkab-update.path",
                 "polis.service", "polis-update.path", "cups.service", "nunki.service", "nunki-update.path",
                 "alnasl-sound.service", "containerd.service", "alnasl-kiosk-load.service", "alnasl-slot-check.service"]
ROLE_FILE = "/var/lib/alnasl-setup/mode"   # the role as chosen (data partition; v6 wrote master/slave)
ROLE_RUN = "/run/alnasl-mode"               # what alnasl-mode made of it this boot
ROLE_APPLIED = "/etc/alnasl/role-applied"   # the role whose units this slot last switched on
ROLES = ("alnasl", "arkab", "polis", "nunki")

# --------------------------------------------------------------------- redact --

_SECRET_KEYS = r"(?:psk|passphrase|wpa_passphrase|password|sae_password|wep_key\d?|private_key_passwd|identity|anonymous_identity|pairwise_psk|authkey|auth-key|auth_key|ts_authkey|tskey)"
_REDACTIONS = [
    # wpa_supplicant style "key=value" lines, quoted or not, also commented-out ones (#psk="clear")
    (re.compile(r"(?im)^(\s*#?\s*" + _SECRET_KEYS + r"\s*=).*$"), r"\1<redacted>"),
    # the same inside a longer line: psk=..., passphrase: ..., --authkey=..., TS_AUTHKEY=...
    (re.compile(r"(?i)(\b" + _SECRET_KEYS + r"\b\s*[=:]\s*)(\"[^\"\n]*\"|\S+)"), r"\1<redacted>"),
    (re.compile(r"(?i)(--auth-?key[= ]+)\S+"), r"\1<redacted>"),
    (re.compile(r"(?i)\btskey-[A-Za-z0-9_-]+"), "tskey-<redacted>"),
    (re.compile(r"(?i)(login\.tailscale\.com/a/)\S+"), r"\1<redacted>"),
    # wpa_passphrase <ssid> <passphrase>
    (re.compile(r"(\bwpa_passphrase\s+(?:\"[^\"]*\"|\S+)\s+)(\"[^\"]*\"|\S+)"), r"\1<redacted>"),
    # a 256-bit key in hex (a PSK / PMK as wpa_supplicant stores it)
    (re.compile(r"\b[0-9a-fA-F]{64}\b"), "<redacted-key>"),
]


def redact(text):
    for rx, rep in _REDACTIONS:
        text = rx.sub(rep, text)
    return text


# -------------------------------------------------------------------- helpers --

def read(path, default=""):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return default


def runo(cmd, timeout=15):
    """stdout+stderr as text; never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return 127, "(not installed: %s)\n" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "(timed out after %d s)\n" % timeout
    except Exception as e:  # noqa: BLE001 - a diagnostics page must not fall over
        return 127, "(%s)\n" % e


def block(cmd, timeout=15, maxlines=60, tail=True):
    rc, out = runo(cmd, timeout)
    lines = out.rstrip("\n").splitlines()
    if len(lines) > maxlines:
        cut = len(lines) - maxlines
        lines = (["... (%d earlier lines cut)" % cut] + lines[-maxlines:]) if tail else (lines[:maxlines] + ["... (%d more lines cut)" % cut])
    return "$ %s%s\n%s" % (" ".join(cmd), "   [exit %d]" % rc if rc else "", "\n".join(lines))


def kernel_log():
    rc, out = runo(["dmesg"], 15)
    if rc != 0 or not out.strip():
        rc, out = runo(["journalctl", "-k", "-b", "--no-pager", "-o", "short-monotonic"], 20)
    return out


def grep_lines(text, pattern, limit=40):
    rx = re.compile(pattern, re.I)
    hits = [l for l in text.splitlines() if rx.search(l)]
    return hits[-limit:]


def wpa_cli(*args):
    return runo(["wpa_cli", "-p", WPA_DIR, "-i", "wlan0", *args], 8)


def have(cmd):
    for d in ("/usr/sbin", "/usr/bin", "/sbin", "/bin", "/usr/local/sbin", "/usr/local/bin"):
        if os.access(os.path.join(d, cmd), os.X_OK):
            return True
    return False


# --------------------------------------------------------------------- checks --

def wifi_checks(klog):
    """The 'does the Wi-Fi work at all' questions, each True/False/None + a detail."""
    checks = []

    def add(cid, ok, detail):
        checks.append({"id": cid, "ok": ok, "detail": detail})

    mods = [l.split()[0] for l in read("/proc/modules").splitlines() if l.strip()]
    loaded = [m for m in mods if re.match(r"(brcmfmac|brcmutil|cfg80211)", m)]
    add("driver", "brcmfmac" in mods or os.path.isdir("/sys/module/brcmfmac"),
        "loaded: " + (", ".join(loaded) or "none of brcmfmac/brcmutil/cfg80211"))

    sdio = []
    for d in sorted(glob.glob("/sys/bus/sdio/devices/*")):
        drv = os.path.basename(os.path.realpath(d + "/driver")) if os.path.exists(d + "/driver") else "no driver bound"
        sdio.append("%s vendor=%s device=%s driver=%s" % (os.path.basename(d), read(d + "/vendor").strip(),
                                                          read(d + "/device").strip(), drv))
    chip = any("0x02d0" in s for s in sdio)
    add("hardware", True if chip else (True if os.path.exists("/sys/class/net/wlan0/device") else False),
        "; ".join(sdio) or "no SDIO device found (the Wi-Fi chip sits on the SDIO bus of the Pi 4)")

    fw = grep_lines(klog, r"brcmf_c_preinit_dcmds: Firmware|brcmfmac.*(firmware|fw).*(fail|error|-2)|Direct firmware load for brcm.*failed", 6)
    good = [l for l in fw if "Firmware:" in l]
    bad = [l for l in fw if "Firmware:" not in l]
    if good:
        add("firmware", True, good[-1].split("] ", 1)[-1])
    elif bad:
        add("firmware", False, bad[-1].split("] ", 1)[-1])
    else:
        add("firmware", None, "no firmware line in the kernel log (the log may have scrolled; the interface below is the real proof)")

    wl = os.path.exists("/sys/class/net/wlan0")
    add("interface", wl, "wlan0 exists" + (" (a Wi-Fi interface only appears after the firmware was loaded)" if wl else ""))
    if wl:
        st = read("/sys/class/net/wlan0/operstate").strip()
        flags = int(read("/sys/class/net/wlan0/flags", "0x0").strip() or "0x0", 16)
        add("link", bool(flags & 1), "operstate=%s, flags=0x%x (%s)" % (st, flags, "UP" if flags & 1 else "administratively DOWN"))
        rc, out = wpa_cli("ping")
        add("supplicant", out.strip().startswith("PONG"), out.strip().splitlines()[0] if out.strip() else "no answer")
    else:
        add("link", None, "no interface")
        add("supplicant", None, "no interface")
    return checks


def verdict(checks):
    by = {c["id"]: c["ok"] for c in checks}
    if by.get("driver") is False:
        return "no_driver"
    if by.get("hardware") is False:
        return "no_hardware"
    if by.get("firmware") is False:
        return "firmware"
    if by.get("interface") is False:
        return "no_interface"
    if by.get("link") is False:
        return "link_down"
    if by.get("supplicant") is False:
        return "supplicant"
    return "ok"


# ------------------------------------------------------------------- sections --

def wifi_text(klog, wpa_summary, last_scan):
    out = []
    mods = [l for l in read("/proc/modules").splitlines() if re.match(r"(brcm|cfg80211|mac80211|rfkill|libarc4)", l)]
    out.append("modules (name size users deps):\n  " + ("\n  ".join(" ".join(l.split()[:4]) for l in mods) or "none"))
    out.append("kernel messages about the chip, firmware and regulatory domain:\n  " +
               ("\n  ".join(grep_lines(klog, r"brcm|cfg80211|regulatory|sdio|mmc1|wlan0|firmware", 40)) or "none found"))
    fwdir = "/lib/firmware/brcm"
    files = ["brcmfmac43455-sdio.bin", "brcmfmac43455-sdio.clm_blob", "brcmfmac43455-sdio.txt", "brcmfmac43455-sdio.raspberrypi,4-model-b.txt"]
    out.append("firmware files:\n  " + "\n  ".join("%s: %s" % (f, ("present, %d bytes" % os.path.getsize(os.path.join(fwdir, f))) if os.path.exists(os.path.join(fwdir, f)) else "MISSING") for f in files)
               + "\n  regulatory.db: " + ("present" if os.path.exists("/lib/firmware/regulatory.db") else "MISSING"))
    if os.path.exists("/dev/rfkill") or os.path.exists("/sys/class/rfkill"):
        out.append(block(["rfkill", "list"]))
    else:
        out.append("rfkill: this kernel was built without rfkill support (no /dev/rfkill), so nothing can block the radio.")
    out.append(block(["ip", "-d", "link", "show", "wlan0"]))
    out.append(block(["ip", "addr", "show", "wlan0"]))
    out.append("regulatory domain:\n  cfg80211 module parameter: %s\n  configured country (wpa_supplicant conf): %s" % (
        read("/sys/module/cfg80211/parameters/ieee80211_regdom").strip() or "(unset)", wpa_summary.get("country", "?")))
    if have("iw"):
        out.append(block(["iw", "reg", "get"]))
        out.append(block(["iw", "dev"]))
        out.append(block(["iw", "dev", "wlan0", "link"]))
    else:
        out.append("iw: not installed")
    out.append("wpa_supplicant:\n  unit: %s\n  processes: %s" % (
        runo(["systemctl", "is-active", "wpa_supplicant@wlan0.service"])[1].strip(),
        runo(["pgrep", "-a", "wpa_supplicant"])[1].strip() or "none running"))
    for a in (["ping"], ["status"], ["list_networks"]):
        rc, o = wpa_cli(*a)
        out.append("$ wpa_cli %s\n%s" % (a[0], o.rstrip()))
    out.append("saved networks (SSIDs only, no keys):\n  " + ("\n  ".join(wpa_summary.get("lines", [])) or "none"))
    out.append("last Wi-Fi scan test:\n" + (last_scan or "  (not run since the box started; use the Test Wi-Fi scan button)"))
    return "\n\n".join(out)


def network_text():
    out = [block(["ip", "-br", "link"]), block(["ip", "-br", "addr"]), block(["ip", "route"]), block(["ip", "-6", "route"], maxlines=20),
           "resolv.conf:\n  " + "\n  ".join(read("/etc/resolv.conf").splitlines()[:12]),
           block(["resolvectl", "status"], maxlines=40, tail=False),
           block(["networkctl", "--no-pager", "list"]),
           block(["networkctl", "--no-pager", "status", "wlan0"], maxlines=25, tail=False),
           block(["networkctl", "--no-pager", "status", "eth0"], maxlines=25, tail=False)]
    return "\n\n".join(out)


def updates_text():
    """The nightly OS update: its last result, the packages it changed, the runs before it, the next one."""
    out = ["last OS update run:\n  " + ("\n  ".join(read(OS_UPDATE_DIR + "/last-result").splitlines()[:20]) or
                                     "(none yet; it runs at night, between 03:00 and 05:00)")]
    changed = read(OS_UPDATE_DIR + "/last-changes").splitlines()
    out.append("packages changed by that run (%d):\n  " % len(changed) + ("\n  ".join(changed[:60]) or "none"))
    out.append("earlier runs (newest last):\n  " + ("\n  ".join(read(OS_UPDATE_DIR + "/history").splitlines()[-10:]) or "none"))
    out.append(block(["systemctl", "list-timers", "--all", "--no-pager", "alnasl-os-update.timer"], maxlines=5, tail=False))
    # v6 A/B: the whole-system image updates (alnasl-system-update) and the data partition.
    slot = re.search(r"(?:^|\s)alnasl\.slot=([AB])(?:\s|$)", read("/proc/cmdline"))
    rel = " ".join(l for l in read("/etc/alnasl/image-release").splitlines() if l.startswith("ALNASL_"))
    out.append("system image: %s, running from slot %s" % (rel or "(no image-release)", slot.group(1) if slot else "?"))
    out.append("boot environment (grub): " + (" ".join(l for l in read("/boot/efi/alnasl/grubenv").splitlines()
                                                     if l.startswith("alnasl_")) or "(none: not the A/B layout)"))
    out.append("last system image update:\n  " + ("\n  ".join(read(OS_UPDATE_DIR + "/system-last-result").splitlines()[:12]) or
                                                 "(none yet)"))
    out.append("earlier system image updates (newest last):\n  " +
               ("\n  ".join(read(OS_UPDATE_DIR + "/system-history").splitlines()[-10:]) or "none"))
    out.append("data partition: " + (read("/run/alnasl-data/state").strip() or "(no state: alnasl-data did not run)"))
    out.append(block(["df", "-h", "/", "/data", "/boot/efi"], maxlines=5, tail=False))
    return "\n\n".join(out)


def services_text():
    lines = []
    for u in SERVICE_UNITS:
        rc, o = runo(["systemctl", "show", "-p", "ActiveState", "-p", "SubState", "-p", "UnitFileState", "-p", "Result",
                      "-p", "NRestarts", "-p", "ConditionResult", "-p", "LoadState", u])
        d = dict(l.split("=", 1) for l in o.splitlines() if "=" in l)
        if d.get("LoadState") == "not-found":
            lines.append("%-34s not installed" % u)
            continue
        # v7: a unit of another role is skipped by its condition, which is not the same as failed.
        cond = {"yes": "conditions met", "no": "SKIPPED (a condition was not met)"}.get(
            d.get("ConditionResult", ""), "not started this boot")
        lines.append("%-34s %s (%s), %s, result=%s, restarts=%s, %s" % (
            u, d.get("ActiveState", "?"), d.get("SubState", "?"), d.get("UnitFileState") or "static/not found",
            d.get("Result", "?"), d.get("NRestarts", "?"), cond))
    return "\n".join(lines)


def role_text():
    """v7: what this box is: the stored choice, what alnasl-mode made of it this boot, what the slot applied.
    A box whose app never starts is most often a box that is not what its owner thinks it is."""
    out = [
        "role as chosen:     %s  (%s)" % (read(ROLE_FILE).strip() or "(no file: alnasl, the default)", ROLE_FILE),
        "role this boot:     %s  (%s/role)" % (read(ROLE_RUN + "/role").strip() or "(none: alnasl-mode did not run)", ROLE_RUN),
        "v6 word this boot:  %s  (%s/mode)" % (read(ROLE_RUN + "/mode").strip() or "-", ROLE_RUN),
        "role flags present: %s" % (" ".join(r for r in ROLES if os.path.exists(os.path.join(ROLE_RUN, r)))
                                     or "NONE: every role's app is held back by its condition"),
        "units applied for:  %s  (%s)" % (read(ROLE_APPLIED).strip() or "(none yet)", ROLE_APPLIED),
        "alnasl-mode.txt:    %s" % ("waiting on the boot partition" if os.path.exists(BOOT_EFI + "/alnasl-mode.txt") else "none"),
        "alnasl-mode, this boot:\n  " + ("\n  ".join(runo(
            ["journalctl", "-b", "-u", "alnasl-mode.service", "--no-pager", "-o", "cat", "-n", "30"], 15)[1].splitlines()) or "(nothing)"),
        "role requests to the setup server (last 10):\n  " + ("\n  ".join(grep_lines(runo(
            ["journalctl", "-u", "alnasl-setup.service", "--no-pager", "-o", "short-iso", "-n", "20000"], 20)[1],
            r"POST /api/mode|role switch:", 10)) or "none"),
    ]
    return "\n".join(out)


def kiosk_text(extra):
    out = []
    out.append("kiosk state file: " + (read(KIOSK_RUN + "/state").strip() or "(none)"))
    for d in sorted(glob.glob("/sys/class/drm/card*-*")):
        out.append("%s: %s, first mode %s" % (os.path.basename(d), read(d + "/status").strip(), (read(d + "/modes").splitlines() or ["-"])[0]))
    out.append("fb0: virtual_size=%s modes=%s" % (read("/sys/class/graphics/fb0/virtual_size").strip() or "none",
                                                  (read("/sys/class/graphics/fb0/modes").strip() or "none")))
    out.append("active virtual terminal: %s (the kiosk holds tty1; consoles are on tty2 and tty3)" % (read("/sys/class/tty/tty0/active").strip() or "?"))
    out.append("browser heartbeat: " + (extra.get("ping") or "(none)"))
    out.append("kiosk config: " + " ".join(read("/etc/alnasl/kiosk.conf").split()) + " | keyboard: " + " ".join(read("/etc/alnasl/keyboard.conf").split()))
    out.append("browser restart log (why the kiosk restarted the browser):\n  " +
               ("\n  ".join(read(KIOSK_RUN + "/reload.log").splitlines()[-15:]) or "no restart recorded since boot"))
    out.append(block(["docker", "ps", "-a", "--format", "{{.Names}}  {{.Status}}  {{.Image}}"], maxlines=10))
    out.append("kiosk path/resolution lines from the journal:\n  " + "\n  ".join(
        grep_lines(runo(["journalctl", "-u", "alnasl-kiosk.service", "-b", "--no-pager", "-o", "cat", "-n", "400"], 20)[1],
                   r"kiosk: (path|X screen|fb0|connector|starting|container ended|browser)|path=", 12)))
    out.append("power / memory events in the kernel log:\n  " + ("\n  ".join(grep_lines(
        kernel_log(), r"under-?voltage|throttl|out of memory|oom-kill|killed process|brcmf.*(timeout|error|fail)", 15)) or "none"))
    out.append(block(["journalctl", "--list-boots", "--no-pager"], maxlines=8))
    return "\n\n".join(out)


def journals():
    res = []
    for unit, extra in JOURNAL_UNITS:
        cmd = ["journalctl", "--no-pager", "-n", "60", "-o", "short-iso", "-u", unit] if not extra else \
              ["journalctl", "--no-pager", "-n", "60", "-o", "short-iso"] + extra
        rc, out = runo(cmd, 20)
        res.append({"unit": unit + (" + syslog tag wpa_supplicant" if extra else ""), "text": redact(out.rstrip("\n"))})
    rc, out = runo(["dmesg"], 15)
    res.append({"unit": "kernel (Wi-Fi, cfg80211, mmc)", "text": redact("\n".join(grep_lines(out, r"brcm|cfg80211|mmc|sdio|wlan0|regulatory", 60)))})
    return res


def collect(wpa_summary, last_scan="", extra=None):
    extra = extra or {}
    klog = kernel_log()
    checks = wifi_checks(klog)
    sections = [
        {"id": "wifi", "title": "Wi-Fi hardware and driver", "text": wifi_text(klog, wpa_summary, last_scan)},
        {"id": "network", "title": "Network", "text": network_text()},
        {"id": "role", "title": "Role (what this box is)", "text": role_text()},
        {"id": "services", "title": "Services", "text": services_text()},
        {"id": "kiosk", "title": "Screen and kiosk", "text": kiosk_text(extra)},
        {"id": "updates", "title": "OS and system updates", "text": updates_text()},
    ]
    for s in sections:
        s["text"] = redact(s["text"])
    return {"generated": time.strftime("%Y-%m-%d %H:%M:%S %z"), "checks": checks, "verdict": verdict(checks), "sections": sections}


def report_text(info, jl, system):
    """One plain-text file with everything."""
    out = ["ALNASL HALL BOX DIAGNOSTICS", "generated: " + info["generated"], ""]
    for k, v in system.items():
        out.append("%-12s %s" % (k + ":", v))
    out += ["", "== WI-FI VERDICT: %s ==" % info["verdict"]]
    for c in info["checks"]:
        out.append("  [%s] %-10s %s" % ({True: "ok", False: "FAIL", None: "?"}[c["ok"]], c["id"], c["detail"]))
    for s in info["sections"]:
        out += ["", "=" * 70, s["title"].upper(), "=" * 70, s["text"]]
    out += ["", "=" * 70, "JOURNALS (last 60 lines each)", "=" * 70]
    for j in jl:
        out += ["", "--- " + j["unit"] + " ---", j["text"]]
    return redact("\n".join(out) + "\n")


def save_report(text, boot=BOOT_EFI):
    """Writes alnasl-diagnostics-YYYYMMDD-HHMMSS.txt to the FAT partition and syncs."""
    if boot == BOOT_EFI and not os.path.ismount(boot):
        runo(["mount", boot], 15)
        if not os.path.ismount(boot):
            raise OSError("The boot partition (%s) is not mounted and could not be mounted." % boot)
    name = "alnasl-diagnostics-%s.txt" % time.strftime("%Y%m%d-%H%M%S")
    path = os.path.join(boot, name)
    with open(path, "w", newline="\r\n") as f:  # CRLF: opens properly in Windows Notepad
        f.write(redact(text))
        f.flush()
        os.fsync(f.fileno())
    os.sync()
    return name
