"""bootlog: what the boot screen may show of the box's log (v7, docs/v7-plan.md section 2).

The boot screen stands in a public hall, so this is an allow-list, not a filter of bad things:
  - the kernel, at info level or more urgent;
  - systemd's own lines about the units below, and any of its warnings or failures;
  - the units below (the box's own, the network, docker, the four role apps, CUPS), info or more urgent.
Every line then goes through redact(): anything that looks like a secret becomes ***. What is left is made
ASCII (the screen's glyph atlas has nothing else) and cut to a screen's width.

Used by alnasl-splash (the framebuffer painter, until X starts) and by the setup server's /api/bootlog (the
browser's /boot page after that), so both show the same lines in the same order: the hand-over is seamless.
Python standard library only; no state of its own.
"""
import json
import os
import re
import select
import subprocess
import time

# ------------------------------------------------------------------ redaction --
# Generous on purpose: a word too many on the screen is a secret in a photo of the hall.
_KEYS = (r"(?:psk|wpa_passphrase|passphrase|passwd|password|pass|pwd|sae_password|wep_key\d?|private_key\w*|"
         r"secret\w*|client_secret|token\w*|access_token|refresh_token|api[_-]?key|apikey|key|keys|auth\w*|"
         r"cookie\w*|set-cookie|session\w*|sid|csrf\w*|bearer|signature|sig|otp|pin|code|join(?:_?link)?|"
         r"identity|anonymous_identity|credential\w*)")
_RULES = [
    # key=value, key: value, JSON "key": "value" (systemd's own "code=exited" says how a unit ended, and stays)
    (re.compile(r"(?i)(\"?\b" + _KEYS + r"\b\"?\s*[=:]\s*)(?!(?:exited|killed|dumped)\b)(\"[^\"]*\"|'[^']*'|[^\s,;]+)"),
     r"\1***"),
    # a query string on a bare path (a request log line: GET /join?t=...)
    (re.compile(r"(\s/[^\s?#]*)\?\S+"), r"\1?***"),
    (re.compile(r"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{6,}"), r"\1 ***"),
    (re.compile(r"(?i)(authorization\s*[:=]?\s*)\S.*$"), r"\1***"),
    (re.compile(r"(?i)(wpa_passphrase\s+(?:\"[^\"]*\"|\S+)\s+)\S+"), r"\1***"),
    # credentials and queries in URLs: scheme://user:pass@host/...?a=b
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@"), r"\1***@"),
    (re.compile(r"(?i)(\b[a-z][a-z0-9+.-]*://[^\s?#]*)[?#]\S*"), r"\1?***"),
    # e-mail addresses: the name goes
    (re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.[A-Za-z0-9.-]+)\b"), r"***@\1"),
    # long hex (keys, machine ids, hashes) and token-looking runs (mixed case and digits, 20+)
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "***"),
    (re.compile(r"(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*\d)(?=[A-Za-z0-9_+/=-]*[a-z])(?=[A-Za-z0-9_+/=-]*[A-Z])"
                r"[A-Za-z0-9_+/=-]{20,}"), "***"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+"), "***"),       # JWTs
    # support codes and the like: any number of exactly six digits, alone or as 123 456 / 123-456
    (re.compile(r"(?<![\d.:])\d{3}[ -]?\d{3}(?![\d.:])"), "***"),
]


def redact(text):
    for rx, rep in _RULES:
        text = rx.sub(rep, text)
    return text


def ascii_line(text, width=240):
    """Printable ASCII only (the glyph atlas has nothing else); tabs and controls become spaces."""
    out = []
    for ch in text:
        o = ord(ch)
        if 32 <= o < 127:
            out.append(ch)
        elif ch in "\t\r\n":
            out.append(" ")
        else:
            out.append(_FOLD.get(ch, "?"))
    s = re.sub(r" {2,}", " ", "".join(out)).strip()
    return s if len(s) <= width else s[:width - 3] + "..."


_FOLD = {}
for _a, _b in (("aàáâãäå", "a"), ("eèéêë", "e"), ("iìíîï", "i"), ("oòóôõö", "o"), ("uùúûü", "u"), ("cç", "c"),
               ("nñ", "n"), ("AÀÁÂÃÄÅ", "A"), ("EÈÉÊË", "E"), ("IÌÍÎÏ", "I"), ("OÒÓÔÕÖ", "O"), ("UÙÚÛÜ", "U"),
               ("CÇ", "C"), ("NÑ", "N")):
    for _c in _a[1:]:
        _FOLD[_c] = _b
_FOLD.update({"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-",
              "…": "...", "·": "-", "→": "->", " ": " "})

# ----------------------------------------------------------------- allow-list --
NET_UNITS = {"systemd-networkd.service", "systemd-resolved.service", "systemd-timesyncd.service",
             "wpa_supplicant@wlan0.service", "alnasl-wifi.service", "alnasl-firewall.service"}
APP_UNITS = {
    "alnasl": {"alnasl.service", "alnasl-update.service"},
    "arkab": {"arkab.service", "arkab-update.service"},
    "polis": {"polis.service", "polis-update.service", "cups.service"},
    "nunki": {"nunki.service", "nunki-update.service", "alnasl-sound.service"},
}
BOX_UNITS = {"docker.service", "containerd.service", "alnasl-setup.service", "alnasl-data.service",
             "alnasl-mode.service", "alnasl-firstboot.service", "alnasl-kiosk.service", "alnasl-kiosk-load.service",
             "alnasl-slot-check.service", "alnasl-upgrade-boot.service", "alnasl-os-update.service",
             "alnasl-system-update.service", "alnasl-system-update-check.service", "alnasl-reset-boot.service",
             "alnasl-hotspot.service"}  # v7.3: says when the hotspot goes on and off; never its password
ALL_APPS = set().union(*APP_UNITS.values())
ALLOWED = NET_UNITS | ALL_APPS | BOX_UNITS

# What the status line counts, per role: the box's own units, then the role's.
BASE_EXPECT = ["alnasl-data.service", "alnasl-mode.service", "alnasl-firewall.service", "systemd-networkd.service",
               "systemd-resolved.service", "alnasl-setup.service", "containerd.service", "docker.service",
               "alnasl-kiosk-load.service", "alnasl-kiosk.service"]
ROLE_EXPECT = {"alnasl": ["alnasl.service"], "arkab": ["arkab.service"],
               "polis": ["cups.service", "polis.service"], "nunki": ["alnasl-sound.service", "nunki.service"]}

# The colour of a line, by where it came from; the painter and the page map these words to the palette.
COLOURS = ("kernel", "systemd", "network", "app", "box", "error")


def classify(e, role):
    """A journal entry (dict of its JSON fields) -> (tag, colour, error?) or None when it is not shown."""
    try:
        prio = int(e.get("PRIORITY", "6"))
    except (TypeError, ValueError):
        prio = 6
    if prio > 6:
        return None                                        # debug: never
    err = prio <= 3
    if e.get("_TRANSPORT") == "kernel":
        return ("kernel", "error" if err else "kernel", err)
    unit = e.get("_SYSTEMD_UNIT") or ""
    if e.get("_PID") == "1":
        about = e.get("UNIT") or e.get("USER_UNIT") or ""
        msg = e.get("MESSAGE") or ""
        failed = prio <= 4 or "ailed" in msg or "rror" in msg
        if not failed and about not in ALLOWED and not about.endswith(".target"):
            return None
        return ("systemd", "error" if failed else "systemd", failed)
    if unit not in ALLOWED:
        return None
    if unit in NET_UNITS:
        tag, col = "network", "network"
    elif unit in ALL_APPS:
        tag = next(r for r, us in APP_UNITS.items() if unit in us)
        col = "app" if tag == role else "box"
    else:
        tag, col = unit.replace(".service", "").replace("alnasl-", "")[:10], "box"
    return (tag, "error" if err else col, err)


def entry_line(e, role):
    """(tag, colour, error?, text) or None."""
    c = classify(e, role)
    if c is None:
        return None
    msg = e.get("MESSAGE")
    if isinstance(msg, list):                               # journald gives bytes as a list of numbers
        try:
            msg = bytes(msg).decode("utf-8", "replace")
        except (TypeError, ValueError):
            return None
    if not isinstance(msg, str) or not msg.strip():
        return None
    text = ascii_line(redact(msg))
    if not text:
        return None
    return c[0], c[1], c[2], text


def format_line(tag, text):
    return "%-8s %s" % (tag[:8], text)


# --------------------------------------------------------------------- follow --
JOURNALCTL = ["journalctl", "-b", "-f", "--no-tail", "-o", "json", "--output-fields=" + ",".join(
    ["MESSAGE", "PRIORITY", "_TRANSPORT", "_SYSTEMD_UNIT", "_PID", "SYSLOG_IDENTIFIER", "UNIT", "USER_UNIT"])]


class Follower:
    """journalctl -b -f as a child process, read without blocking. poll() returns the new shown lines as
    (tag, colour, error?, text). It starts again by itself if journalctl ends (journald restarting)."""

    def __init__(self, role_fn, cmd=None):
        self.role_fn = role_fn
        self.cmd = cmd or JOURNALCTL
        self.p = None
        self.buf = b""
        self.next_try = 0.0
        self.caught_up = False      # journalctl had nothing more to give once: the past is all read

    def _start(self):
        if time.monotonic() < self.next_try:
            return
        self.next_try = time.monotonic() + 2.0
        try:
            self.p = subprocess.Popen(self.cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
            os.set_blocking(self.p.stdout.fileno(), False)
            self.buf = b""
        except OSError:
            self.p = None

    def poll(self, timeout=0.0, limit=4000):
        if self.p is None or self.p.poll() is not None:
            if self.p is not None:
                self.p = None
            self._start()
            if self.p is None:
                return []
        fd = self.p.stdout.fileno()
        out = []
        try:
            r, _, _ = select.select([fd], [], [], timeout)
        except (OSError, ValueError):
            return out
        if not r:
            if timeout > 0:
                self.caught_up = True
            return out
        while len(self.buf) < (1 << 20):
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                break
            except OSError:
                break
            if not chunk:
                break
            self.buf += chunk
        *lines, self.buf = self.buf.split(b"\n")
        role = self.role_fn()
        for raw in lines[-limit:]:
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            l = entry_line(e, role)
            if l:
                out.append(l)
        return out

    def close(self):
        if self.p is not None:
            try:
                self.p.kill()
            except OSError:
                pass
            self.p = None


# --------------------------------------------------------------------- status --
ROLE_FILE = "/run/alnasl-mode/role"
_PROPS = "Id,ActiveState,SubState,Result,Type,UnitFileState,InactiveEnterTimestampMonotonic"


def role():
    try:
        with open(ROLE_FILE) as f:
            r = f.read().strip()
    except OSError:
        r = ""
    return r if r in ROLE_EXPECT else "alnasl"


def unit_states(units):
    try:
        out = subprocess.run(["systemctl", "show", "-p", _PROPS, *units], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    res, cur = {}, {}
    for line in out.splitlines() + [""]:
        if not line.strip():
            if cur.get("Id"):
                res[cur["Id"]] = cur
            cur = {}
            continue
        k, _, v = line.partition("=")
        cur[k] = v
    return res


def count(states, units):
    """(up, expected, failed) over the units that are meant to run (enabled, or running anyway)."""
    up = exp = failed = 0
    for u in units:
        s = states.get(u)
        if not s:
            continue
        act = s.get("ActiveState")
        if s.get("UnitFileState") not in ("enabled", "static", "enabled-runtime", "alias") and act not in ("active", "activating", "failed"):
            continue
        exp += 1
        if act == "active" or (s.get("Type") == "oneshot" and act == "inactive" and s.get("Result") == "success"
                               and s.get("InactiveEnterTimestampMonotonic", "0") not in ("", "0")):
            up += 1
        elif act == "failed":
            failed += 1
    return up, exp, failed


def status_text(r, lang, up, exp, failed):
    if lang == "nl":
        s = "%s staat klaar" % r if exp and up == exp else "%s starten - %d van %d actief" % (r, up, exp)
        return s + (", %d mislukt" % failed if failed else "")
    s = "%s is up" % r if exp and up == exp else "starting %s - %d of %d up" % (r, up, exp)
    return s + (", %d failed" % failed if failed else "")


def status(lang):
    r = role()
    units = BASE_EXPECT + ROLE_EXPECT[r]
    up, exp, failed = count(unit_states(units), units)
    return {"role": r, "up": up, "expected": exp, "failed": failed, "text": status_text(r, lang, up, exp, failed)}
