#!/usr/bin/python3
"""Alnasl hall box: settings + first-run wizard backend.

Runs as root, listens on 127.0.0.1:4041 ONLY (never on the LAN), python3
standard library only. Serves the single-page UI from
/usr/local/share/alnasl-setup/www and a small JSON API. Everything it changes
on the box goes through the functions below; nothing from a request is ever
given to a shell (argument lists only, input validated first).

Secrets: Wi-Fi passphrases arrive in POST bodies, are written to their
root-only file (0600) and are never logged; the access log
holds only method, path and status.
"""
import collections
import datetime
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diag  # noqa: E402  (diagnostics + redaction; same folder)
import bootlog  # noqa: E402  (v7: what the boot screen may show of the log; same folder)

HOST, PORT = "127.0.0.1", 4041
WWW = "/usr/local/share/alnasl-setup/www"
STATE_DIR = "/var/lib/alnasl-setup"
DONE = STATE_DIR + "/done"
STATE_JSON = STATE_DIR + "/state.json"
WPA_CONF = "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
KBD_CONF = "/etc/alnasl/keyboard.conf"
KIOSK_CONF = "/etc/alnasl/kiosk.conf"
KIOSK_STATE = "/run/alnasl-kiosk/state"
NETD = "/etc/systemd/network"
NETD_DROPIN = {"eth0": NETD + "/10-wired.network.d/50-alnasl.conf",
               "wlan0": NETD + "/20-wireless.network.d/50-alnasl.conf"}
ALNASL_PORT = 4040

# v6 boot screen: what the box is doing ("reset-2", "update-os", ...), written by alnasl-splash and
# the scripts that call it; the pictures of each state, the same ones the framebuffer painter shows.
SCREEN_STATE = "/run/alnasl-screen/state"
SCREEN_VALUE = "/run/alnasl-screen/value"        # "37%", "v6.2": the update states' value line
SCREEN_PROGRESS = "/run/alnasl-screen/progress"  # 0-100: their bar
SPLASH = "/usr/share/alnasl/splash"

KIOSK_RUN = "/run/alnasl-kiosk"
PING_FILE = KIOSK_RUN + "/ping"          # "<unix time>\t<page>"; read by the kiosk watchdog too
BUSY_SECONDS = 35                        # a menu page pings every 8 s; this is "open" for the watchdog
RESUME_SECONDS = 180                     # a page seen this recently is where a restarted browser returns to
MENU_PAGES = ("/menu", "/settings", "/info", "/diag", "/help", "/setup")

LOCK = threading.RLock()
LAST_PAGE = {"t": 0.0, "page": ""}
LAST_SCAN = [""]                         # raw text of the last Wi-Fi scan test, for the diagnostics
PENDING = {}  # interface -> (timer, previous dropin text or None)

# (id, label, X layout, X variant, console keymap candidates in order of preference)
LAYOUTS = [
    ("be", "Belgian (AZERTY)", "be", "", ["be-latin1"]),
    ("fr", "French (AZERTY)", "fr", "", ["fr-latin9", "fr-latin1", "fr"]),
    ("nl", "Dutch", "nl", "", ["nl", "nl2"]),
    ("us-intl", "US international", "us", "intl", ["us-acentos", "us"]),
    ("de", "German (QWERTZ)", "de", "", ["de-latin1-nodeadkeys", "de-latin1", "de"]),
    ("us", "US (QWERTY)", "us", "", ["us"]),
    ("gb", "British", "gb", "", ["uk"]),
    ("es", "Spanish", "es", "", ["es"]),
    ("it", "Italian", "it", "", ["it"]),
    ("pt", "Portuguese", "pt", "", ["pt-latin1", "pt"]),
]


def log(*a):
    print("alnasl-setup:", *a, flush=True)


def run(cmd, timeout=20, inp=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=inp)
        return p.returncode, p.stdout
    except Exception as e:  # missing binary, timeout
        return 127, str(e)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def write_atomic(path, text, mode=0o644):
    # v6 A/B: some settings files are symlinks into the data partition (/etc/alnasl/keyboard.conf ->
    # /data/etc/alnasl/keyboard.conf). Replace the file they point at, never the link itself.
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def later(delay, fn, *args):
    """Run fn after a delay, on its own thread (so the HTTP reply goes out first)."""
    t = threading.Timer(delay, fn, args)
    t.daemon = True
    t.start()


def sysctl(*args):
    return run(["systemctl", *args], timeout=60)


# --------------------------------------------------------------------- state --

def get_state():
    try:
        return json.loads(read(STATE_JSON, "{}"))
    except ValueError:
        return {}


def set_state(**kw):
    s = get_state()
    s.update(kw)
    write_atomic(STATE_JSON, json.dumps(s))


def setup_done():
    return os.path.exists(DONE)


def unit_state(u):
    en = run(["systemctl", "is-enabled", u])[1].strip()
    ac = run(["systemctl", "is-active", u])[1].strip()
    return {"enabled": en == "enabled", "active": ac == "active"}


def alnasl_up():
    try:
        with socket.create_connection(("127.0.0.1", ALNASL_PORT), timeout=1):
            return True
    except OSError:
        return False


# ------------------------------------------------------- page heartbeat ------
# The menu pages ping every few seconds with the page they show. The kiosk
# watchdog reads PING_FILE (a file, so it survives a restart of this server)
# and never restarts the browser while a page is open; and when the browser
# does restart, "/" sends it back to the page it was on.

def page_ping(page, first=False):
    now = time.time()
    if not re.fullmatch(r"/[A-Za-z0-9/_\-]{0,60}(\?[A-Za-z0-9=&_\-]{0,80})?", page or ""):
        page = ""  # empty = "not on a menu page" (e.g. the browser went to Alnasl)
    if first:
        log("page loaded: %s (previous page %s, %d s ago)" % (
            page or "-", LAST_PAGE["page"] or "-", now - LAST_PAGE["t"] if LAST_PAGE["t"] else -1))
    LAST_PAGE["t"], LAST_PAGE["page"] = now, page
    try:
        os.makedirs(KIOSK_RUN, exist_ok=True)
        write_atomic(PING_FILE, "%d\t%s\n" % (now, page))
    except OSError:
        pass


def read_ping():
    """(age in seconds, page) of the last ping; survives a restart of this server."""
    t, page = LAST_PAGE["t"], LAST_PAGE["page"]
    if not t:
        try:
            ts, _, page = read(PING_FILE).strip().partition("\t")
            t = float(ts)
        except ValueError:
            return None, ""
    return time.time() - t, page


def resume_page():
    """Where a freshly started browser should go instead of the default."""
    age, page = read_ping()
    if age is None or age > RESUME_SECONDS or not page.startswith("/"):
        return None
    base = page.split("?")[0].rstrip("/")
    if base not in MENU_PAGES and not base.startswith("/settings/"):
        return None
    if base == "/setup" and setup_done():
        return None
    return page


# ------------------------------------------------------------------ keyboard --

def keymap_exists(name):
    rc, out = run(["find", "/usr/share/keymaps", "/usr/lib/kbd/keymaps", "/lib/kbd/keymaps",
                   "-name", name + ".map*"], timeout=15)
    return bool(out.strip())


def get_keyboard():
    d = {}
    for line in read(KBD_CONF).splitlines():
        m = re.match(r'(\w+)="?([^"]*)"?$', line.strip())
        if m:
            d[m.group(1)] = m.group(2)
    return d


def set_keyboard(layout_id):
    for lid, _label, xl, xv, cmaps in LAYOUTS:
        if lid == layout_id:
            break
    else:
        raise ValueError("unknown keyboard layout")
    cmap = next((c for c in cmaps if keymap_exists(c)), "")
    write_atomic(KBD_CONF, 'KBD_ID="%s"\nKBD_LAYOUT="%s"\nKBD_VARIANT="%s"\nKBD_CONSOLE="%s"\n'
                 % (lid, xl, xv, cmap))
    if cmap:
        write_atomic("/etc/vconsole.conf", "KEYMAP=%s\n" % cmap)
        run(["loadkeys", cmap])
    return {"console_keymap": cmap}


# ---------------------------------------------------------------------- wifi --

def hexify(s):
    return s.encode().hex()


def parse_wpa():
    """Returns (country, [networks]); networks: dict(ssid=hex, psk=hex|None, hidden, prio)."""
    text = read(WPA_CONF)
    country = (re.search(r"^country=(\w\w)", text, re.M) or [None, "BE"])[1]
    nets = []
    for blk in re.findall(r"network=\{(.*?)\}", text, re.S):
        d = {}
        for line in blk.splitlines():
            if "=" in line:
                k, v = line.strip().split("=", 1)
                d[k] = v
        if "ssid" not in d:
            continue
        ssid = d["ssid"]
        if ssid.startswith('"'):
            ssid = hexify(ssid.strip('"'))
        psk = d.get("psk")
        if psk and psk.startswith('"'):
            psk = hashlib.pbkdf2_hmac("sha1", psk.strip('"').encode(), bytes.fromhex(ssid), 4096, 32).hex()
        nets.append({"ssid": ssid.lower(), "psk": psk, "hidden": d.get("scan_ssid") == "1",
                     "prio": int(d.get("priority", "0") or 0)})
    return country, nets


def write_wpa(country, nets):
    out = ["ctrl_interface=/run/wpa_supplicant", "ctrl_interface_group=0", "update_config=0",
           "country=" + country]
    for n in nets:
        out.append("network={")
        out.append("\tssid=" + n["ssid"])
        out.append("\tpsk=" + n["psk"] if n["psk"] else "\tkey_mgmt=NONE")
        if n["hidden"]:
            out.append("\tscan_ssid=1")
        out.append("\tpriority=%d" % n["prio"])
        out.append("}")
    write_atomic(WPA_CONF, "\n".join(out) + "\n", 0o600)


def wpa(*args):
    return run(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", "wlan0", *args], timeout=10)


def wpa_unescape(s):
    return re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), s) \
        .encode("latin-1", "replace").decode("utf-8", "replace")


def wpa_o(*args):
    """Like wpa(), but stdout and stderr together (wpa_cli says 'Failed to connect' on stderr)."""
    return diag.wpa_cli(*args)


def wpa_alive():
    """True when a wpa_supplicant really answers on wlan0.

    Photon's wpa_supplicant@.service is Type=oneshot + RemainAfterExit: systemd
    reports it 'active' even after the daemon it started with -B has died, so
    'systemctl is-active' proves nothing."""
    return wpa_o("ping")[1].strip().startswith("PONG")


def ensure_wifi():
    """Make sure wlan0 exists, is up, and a supplicant answers.

    Returns {"ok": bool, "reason": None|code, "steps": [str], "journal": str}.
    Reason codes: no_interface, supplicant_failed."""
    steps = []
    info = {"ok": False, "reason": None, "steps": steps, "journal": ""}
    if not os.path.exists("/sys/class/net/wlan0"):
        steps.append("wlan0 is missing; trying modprobe brcmfmac")
        steps.append(diag.runo(["modprobe", "brcmfmac"], 20)[1].strip() or "modprobe brcmfmac: done")
        for _ in range(10):
            if os.path.exists("/sys/class/net/wlan0"):
                break
            time.sleep(1)
    if not os.path.exists("/sys/class/net/wlan0"):
        info["reason"] = "no_interface"
        info["journal"] = "\n".join(diag.grep_lines(diag.kernel_log(), r"brcm|cfg80211|sdio|mmc1|firmware", 25))
        return info
    if os.path.exists("/dev/rfkill"):
        run(["rfkill", "unblock", "wifi"])
    if not os.path.exists(WPA_CONF):
        write_wpa("BE", [])
    rc, out = diag.runo(["ip", "link", "set", "dev", "wlan0", "up"], 10)
    steps.append("ip link set wlan0 up: " + (out.strip() or "ok"))
    if not wpa_alive():
        steps.append("no supplicant answers on wlan0; restarting wpa_supplicant@wlan0")
        sysctl("stop", "wpa_supplicant@wlan0.service")
        run(["pkill", "-x", "wpa_supplicant"])
        time.sleep(0.5)
        try:
            os.remove("/run/wpa_supplicant/wlan0")  # a stale socket makes the new daemon refuse to start
        except OSError:
            pass
        diag.runo(["ip", "link", "set", "dev", "wlan0", "up"], 10)
        rc, out = sysctl("restart", "wpa_supplicant@wlan0.service")
        if out.strip():
            steps.append(out.strip())
        for _ in range(12):
            if wpa_alive():
                break
            time.sleep(0.7)
        if not wpa_alive():
            # Last attempt: the daemon directly, so its own error message is captured.
            rc, out = diag.runo(["wpa_supplicant", "-B", "-s", "-i", "wlan0", "-c", WPA_CONF], 20)
            steps.append("direct start: exit %d %s" % (rc, out.strip()))
            for _ in range(8):
                if wpa_alive():
                    break
                time.sleep(0.7)
    if wpa_alive():
        info["ok"] = True
        return info
    info["reason"] = "supplicant_failed"
    info["journal"] = diag.runo(["journalctl", "--no-pager", "-n", "30", "-o", "short-iso", "-u", "wpa_supplicant@wlan0.service",
                                 "-t", "wpa_supplicant"], 15)[1]
    return info


def ensure_wifi_running():  # kept for wifi_connect
    return ensure_wifi()["ok"]


def parse_scan_results(out):
    best = {}
    for line in out.splitlines()[1:]:
        p = line.split("\t")
        if len(p) < 5 or not p[4]:
            continue
        ssid = wpa_unescape(p[4])
        try:
            sig, freq = int(p[2]), int(p[1])
        except ValueError:
            continue
        secured = any(x in p[3] for x in ("WPA", "WEP", "RSN", "SAE"))
        if ssid not in best or sig > best[ssid]["signal"]:
            best[ssid] = {"ssid": ssid, "signal": sig, "secured": secured, "band": "5" if freq > 4000 else "2.4"}
    return list(best.values())


def parse_iw_scan(out):
    best = {}
    for blk in re.split(r"(?m)^BSS ", out)[1:]:
        m = re.search(r"^\s*SSID: (.*)$", blk, re.M)
        if not m or not m.group(1).strip() or "\\x00" in m.group(1):
            continue
        ssid = wpa_unescape(m.group(1).strip())
        sig = re.search(r"signal: (-?\d+)", blk)
        freq = re.search(r"freq: (\d+)", blk)
        sig = int(sig.group(1)) if sig else -90
        secured = bool(re.search(r"^\s*(RSN|WPA):", blk, re.M)) or "Privacy" in blk
        if ssid not in best or sig > best[ssid]["signal"]:
            best[ssid] = {"ssid": ssid, "signal": sig, "secured": secured,
                          "band": "5" if freq and int(freq.group(1)) > 4000 else "2.4"}
    return list(best.values())


def wifi_scan():
    """Scan for networks. Never returns a bare empty list: when nothing was found
    the answer carries a reason code and the raw outputs, which the UI shows."""
    if hotspot_active():  # hostapd has the radio: restarting the supplicant now would take it away
        return hotspot_scan()
    t0 = time.time()
    raw = []
    info = ensure_wifi()
    raw += info["steps"]
    if info["reason"]:
        text = "\n".join(raw + [info["journal"]])
        LAST_SCAN[0] = diag.redact("Wi-Fi scan test at %s: %s\n%s" % (time.strftime("%H:%M:%S"), info["reason"], text))
        return {"available": info["reason"] != "no_interface", "networks": [], "reason": info["reason"],
                "detail": diag.redact(text), "elapsed": round(time.time() - t0, 1)}
    nets, source = [], "wpa"
    started = 0.0
    refused = 0
    polls = 0
    last_n = -1
    deadline = t0 + 20
    while time.time() < deadline:
        if not started:
            rc, out = wpa_o("scan")
            raw.append("wpa_cli scan -> " + out.strip())
            if "FAIL-BUSY" in out:
                time.sleep(1.5)   # another scan is running (ours, or the supplicant's own): wait for its results
                started = time.time() - 2
            elif out.strip().endswith("OK") or out.strip() == "OK":
                started = time.time()
            else:
                refused += 1
                if refused >= 4:
                    break
                time.sleep(1.5)
                continue
        time.sleep(1.5)
        polls += 1
        rc, out = wpa_o("scan_results")
        cur = parse_scan_results(out)
        if cur:
            nets = cur
            # results of a finished scan; accept once they stopped growing (or after a good wait)
            if (len(cur) == last_n and time.time() - started >= 3.5) or time.time() - started >= 12:
                break
        elif time.time() - started > 9 and polls < 12:
            started = 0.0     # the scan never delivered: ask again once
        last_n = len(cur)
    raw.append("wpa_cli scan_results -> %d networks after %.1f s (%d polls)" % (len(nets), time.time() - t0, polls))
    if not nets and diag.have("iw"):
        rc, out = diag.runo(["iw", "dev", "wlan0", "scan"], 25)
        raw.append("iw dev wlan0 scan -> exit %d, %d bytes" % (rc, len(out)))
        iwn = parse_iw_scan(out)
        if iwn:
            nets, source = iwn, "iw"
        else:
            raw.append("\n".join(out.strip().splitlines()[:12]))
    raw.append(wpa_o("status")[1].strip())
    if diag.have("iw"):
        raw.append(diag.runo(["iw", "reg", "get"], 8)[1].strip())
    nets.sort(key=lambda n: -n["signal"])
    saved = {bytes.fromhex(n["ssid"]).decode("utf-8", "replace") for n in parse_wpa()[1]}
    for n in nets:
        n["saved"] = n["ssid"] in saved
    LAST_SCAN[0] = diag.redact("Wi-Fi scan test at %s: %d networks via %s in %.1f s\n%s" % (
        time.strftime("%H:%M:%S"), len(nets), source, time.time() - t0, "\n".join(raw)))
    res = {"available": True, "networks": nets, "source": source, "elapsed": round(time.time() - t0, 1)}
    if not nets:
        res["reason"] = "scan_rejected" if refused >= 4 else "no_results"
        res["detail"] = diag.redact("\n".join(raw))
    return res


def wpa_summary():
    """What the diagnostics may say about the Wi-Fi configuration: SSIDs, country, secured or not. Never keys."""
    country, nets = parse_wpa()
    return {"country": country,
            "lines": ["%s  [%s%s]" % (bytes.fromhex(n["ssid"]).decode("utf-8", "replace"),
                                      "secured" if n["psk"] else "open", ", hidden" if n["hidden"] else "") for n in nets]}


def wifi_saved():
    country, nets = parse_wpa()
    return {"country": country,
            "saved": [{"ssid": bytes.fromhex(n["ssid"]).decode("utf-8", "replace"),
                       "secured": bool(n["psk"]), "hidden": n["hidden"]} for n in nets]}


def wlan_ip():
    rc, out = run(["ip", "-j", "-4", "addr", "show", "wlan0"])
    try:
        return json.loads(out)[0]["addr_info"][0]["local"]
    except (ValueError, IndexError, KeyError):
        return None


def validate_wifi(ssid, passphrase, country):
    if not ssid or len(ssid.encode()) > 32:
        raise ValueError("The network name must be 1 to 32 bytes.")
    if passphrase and not 8 <= len(passphrase) <= 63:
        raise ValueError("The passphrase must be 8 to 63 characters.")
    if not re.fullmatch(r"[A-Za-z]{2}", country or "BE"):
        raise ValueError("The country must be two letters.")
    return (country or "BE").upper()


def wifi_connect(ssid, passphrase, hidden, country):
    country = validate_wifi(ssid, passphrase, country)
    if hotspot_active():
        # The radio is the setup hotspot's. The hotspot daemon lets go of it and tries this network
        # (with this very function, once wlan0 is a client again); the answer comes on the next page load.
        hotspot_join_request(ssid, passphrase, hidden, country)
        return {"ok": False, "reason": "hotspot_handover", "pending": True}
    if not ensure_wifi_running():
        return {"ok": False, "reason": "supplicant_failed"}
    old_text = read(WPA_CONF)
    old_country, nets = parse_wpa()
    sh = hexify(ssid)
    prio = max([n["prio"] for n in nets] + [0]) + 1
    psk = hashlib.pbkdf2_hmac("sha1", passphrase.encode(), ssid.encode(), 4096, 32).hex() if passphrase else None
    nets = [n for n in nets if n["ssid"] != sh]
    nets.append({"ssid": sh, "psk": psk, "hidden": bool(hidden), "prio": prio})
    write_wpa(country, nets)
    run(["iw", "reg", "set", country])  # iw may be absent; wpa_supplicant sets it too
    wpa("reconfigure")
    saw = set()
    deadline = time.time() + 40
    ok = False
    while time.time() < deadline:
        time.sleep(1.5)
        st = dict(l.split("=", 1) for l in wpa("status")[1].splitlines() if "=" in l)
        state = st.get("wpa_state", "")
        saw.add(state)
        if state == "COMPLETED" and wpa_unescape(st.get("ssid", "")) == ssid:
            if wlan_ip() or time.time() > deadline - 20:
                ok = True  # associated; an address may still be on its way
                break
    if ok:
        return {"ok": True, "ip": wlan_ip()}
    # Put the old configuration back: a failed attempt must not cost the working one.
    if old_text:
        write_atomic(WPA_CONF, old_text, 0o600)
    wpa("reconfigure")
    if "4WAY_HANDSHAKE" in saw or "GROUP_HANDSHAKE" in saw:
        reason = "wrong_passphrase"
    elif "ASSOCIATING" in saw or "ASSOCIATED" in saw or "AUTHENTICATING" in saw:
        reason = "rejected"
    else:
        reason = "not_found"
    return {"ok": False, "reason": reason}


def wifi_forget(ssid):
    country, nets = parse_wpa()
    sh = hexify(ssid)
    write_wpa(country, [n for n in nets if n["ssid"] != sh])
    wpa("reconfigure")
    return {"ok": True}


def wifi_country(country):
    if not re.fullmatch(r"[A-Za-z]{2}", country or ""):
        raise ValueError("The country must be two letters.")
    _c, nets = parse_wpa()
    write_wpa(country.upper(), nets)
    wpa("reconfigure")
    return {"ok": True}


# ------------------------------------------------------------------- network --

def ipv4_info(iface):
    rc, out = run(["ip", "-j", "-4", "addr", "show", iface])
    try:
        return [a["local"] + "/" + str(a["prefixlen"]) for a in json.loads(out)[0]["addr_info"]]
    except (ValueError, IndexError, KeyError):
        return []


def read_dropin(iface):
    text = read(NETD_DROPIN[iface])
    if not text:
        return {"mode": "dhcp"}
    d = {"mode": "static", "dns": []}
    for line in text.splitlines():
        if line.startswith("Address="):
            d["address"] = line[8:]
        elif line.startswith("Gateway="):
            d["gateway"] = line[8:]
        elif line.startswith("DNS="):
            d["dns"] += line[4:].split()
    return d


def default_gateway(iface):
    rc, out = run(["ip", "-j", "route", "show", "default", "dev", iface])
    try:
        return json.loads(out)[0]["gateway"]
    except (ValueError, IndexError, KeyError):
        return None


def net_status():
    res = {}
    for iface in ("eth0", "wlan0"):
        present = os.path.exists("/sys/class/net/" + iface)
        carrier = read("/sys/class/net/%s/carrier" % iface).strip() == "1" if present else False
        res[iface] = {"present": present, "link": carrier, "addresses": ipv4_info(iface) if present else [],
                      "gateway": default_gateway(iface) if present else None,
                      "config": read_dropin(iface),
                      "mac": read("/sys/class/net/%s/address" % iface).strip()}
    st = dict(l.split("=", 1) for l in wpa("status")[1].splitlines() if "=" in l) if res["wlan0"]["present"] else {}
    if st.get("wpa_state") == "COMPLETED":
        sig = dict(l.split("=", 1) for l in wpa("signal_poll")[1].splitlines() if "=" in l)
        res["wlan0"]["ssid"] = wpa_unescape(st.get("ssid", ""))
        res["wlan0"]["rssi"] = sig.get("RSSI")
    rc, out = run(["resolvectl", "dns"])
    res["dns"] = sorted(set(re.findall(r"\b\d+\.\d+\.\d+\.\d+\b", out)))
    res["hostname"] = socket.gethostname()
    return res


def validate_static(cfg):
    addr = ipaddress.ip_interface(cfg.get("address", ""))
    if addr.version != 4 or addr.network.prefixlen in (0, 32):
        raise ValueError("Enter an IPv4 address with a prefix, such as 192.168.1.50/24.")
    gw = (cfg.get("gateway") or "").strip()
    if gw:
        g = ipaddress.ip_address(gw)
        if g.version != 4 or g not in addr.network:
            raise ValueError("The gateway must be an address inside the same network.")
    dns = [d for d in re.split(r"[,\s]+", cfg.get("dns") or "") if d]
    for d in dns:
        if ipaddress.ip_address(d).version != 4:
            raise ValueError("DNS servers must be IPv4 addresses.")
    return str(addr), gw, dns


def apply_net(iface, cfg):
    path = NETD_DROPIN[iface]
    prev = read(path, None) if os.path.exists(path) else None
    if cfg.get("mode") == "dhcp":
        text = None
    else:
        addr, gw, dns = validate_static(cfg)
        text = "[Network]\nDHCP=no\nAddress=%s\n" % addr
        if gw:
            text += "Gateway=%s\n" % gw
        for d in dns:
            text += "DNS=%s\n" % d
    if text is None:
        if os.path.exists(path):
            os.remove(path)
    else:
        write_atomic(path, text)
    run(["networkctl", "reload"])
    run(["networkctl", "reconfigure", iface])
    # Confirm-or-revert: if nobody confirms in 60 s, the old setting comes back.
    if iface in PENDING:
        PENDING[iface][0].cancel()
    t = threading.Timer(60, revert_net, (iface,))
    t.daemon = True
    t.start()
    PENDING[iface] = (t, prev)
    return {"ok": True, "confirm_seconds": 60}


def revert_net(iface):
    with LOCK:
        entry = PENDING.pop(iface, None)
        if not entry:
            return
        prev = entry[1]
        path = NETD_DROPIN[iface]
        if prev is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            write_atomic(path, prev)
        run(["networkctl", "reload"])
        run(["networkctl", "reconfigure", iface])
        log("network settings for %s were not confirmed; reverted" % iface)


def confirm_net(iface):
    entry = PENDING.pop(iface, None)
    if entry:
        entry[0].cancel()
    return {"ok": True}


def set_hostname(name):
    name = (name or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", name):
        raise ValueError("Use letters, digits and hyphens only (1 to 32 characters).")
    write_atomic("/etc/hostname", name + "\n")
    run(["hostname", name])
    return {"ok": True, "hostname": name}


# ------------------------------------------------------------------ services --

def services_status():
    # v6: no remote login of any kind. Nobody logs in to this box from elsewhere.
    return {"alnasl": unit_state("alnasl.service"), "kiosk": unit_state("alnasl-kiosk.service")}


def enable(unit, on, now=True):
    if on:
        sysctl("enable", *( [unit] if isinstance(unit, str) else unit))
        if now:
            sysctl("start", "--no-block", *([unit] if isinstance(unit, str) else unit))
    else:
        units = [unit] if isinstance(unit, str) else unit
        sysctl("disable", *units)
        if now:
            sysctl("stop", "--no-block", *units)


def set_services(req):
    if "alnasl" in req:
        enable(["alnasl.service", "alnasl-update.path"], bool(req["alnasl"]))
    # v6: no remote shell and no VPN switches here. The image has neither, and
    # this page will not be the thing that brings one back.
    if "kiosk" in req:
        on = bool(req["kiosk"])
        # Enable now; the stop (which removes the screen the user is looking at)
        # waits until the reply has been delivered.
        if on:
            enable("alnasl-kiosk.service", True)
        else:
            sysctl("disable", "alnasl-kiosk.service")
            later(2.0, sysctl, "stop", "--no-block", "alnasl-kiosk.service")
    return services_status()


# ------------------------------------------------------------ kiosk / system --

def get_kiosk_conf():
    d = {"KIOSK_SCALE": "100", "KIOSK_RES": "auto"}
    for line in read(KIOSK_CONF).splitlines():
        m = re.match(r'(\w+)="?([^"]*)"?$', line.strip())
        if m:
            d[m.group(1)] = m.group(2)
    return d


def set_scale(scale):
    scale = int(scale)
    if scale not in (75, 100, 125, 150, 200, 250):
        raise ValueError("Unsupported scale.")
    set_kiosk_conf(KIOSK_SCALE=str(scale))
    return {"ok": True}


def set_kiosk_conf(**kw):
    d = get_kiosk_conf()
    d.update(kw)
    write_atomic(KIOSK_CONF, "".join('%s="%s"\n' % (k, v) for k, v in sorted(d.items())))


# ---------------------------------------------------------------- resolution --
# The modes the connected screen really offers come from the kernel (DRM connector "modes" file; the
# first line is the screen's preferred mode). A pick is applied LIVE inside the kiosk container
# (kiosk-res: wlr-randr under cage, xrandr under X) and saved; kiosk.sh applies it again at every
# start. Like the network settings it must be confirmed: after RES_CONFIRM_SECONDS the previous
# setting comes back by itself, from this server, so a mode that gives a black screen undoes itself.
RES_CONFIRM_SECONDS = 20
RES_RESTART_EXTRA = 25      # extra seconds when the screen has to restart to switch (it takes a while to come back)
RES_RE = re.compile(r"[0-9]{3,5}x[0-9]{3,5}")
RES_PENDING = {"timer": None, "prev": None, "deadline": 0.0}


def drm_connector():
    """(connector name such as HDMI-A-1, [progressive modes WxH, preferred first]) of the first connected screen."""
    import glob
    for d in sorted(glob.glob("/sys/class/drm/card*-*")):
        if read(d + "/status").strip() != "connected":
            continue
        modes = []
        for line in read(d + "/modes").splitlines():
            line = line.strip()
            if RES_RE.fullmatch(line) and line not in modes:
                modes.append(line)
        return re.sub(r"^card[0-9]+-", "", os.path.basename(d)), modes
    return None, []


def res_status():
    conn, modes = drm_connector()
    cur = get_kiosk_conf().get("KIOSK_RES", "auto")
    pend = RES_PENDING["timer"] is not None
    return {"connector": conn, "modes": modes, "preferred": modes[0] if modes else None,
            "setting": cur if cur == "auto" or cur in modes else "auto",
            "pending": pend, "seconds_left": max(0, int(RES_PENDING["deadline"] - time.time())) if pend else 0,
            "confirm_seconds": RES_CONFIRM_SECONDS, "kiosk_running": unit_state("alnasl-kiosk.service")["active"]}


def kiosk_res_live(conn, mode):
    """Apply a mode inside the running kiosk container. (ok, message)"""
    if not unit_state("alnasl-kiosk.service")["active"]:
        return False, "the screen is not running"
    rc, out = run(["docker", "exec", "-e", "XDG_RUNTIME_DIR=/run/user/0", "-e", "WAYLAND_DISPLAY=wayland-0", "-e", "DISPLAY=:0",
                   "alnasl-kiosk", "/usr/local/bin/kiosk-res", "apply", conn or "-", mode], timeout=25)
    return rc == 0, out.strip()[-400:]


def res_revert():
    with LOCK:
        prev = RES_PENDING["prev"]
        RES_PENDING.update(timer=None, prev=None, deadline=0.0)
        if prev is None:
            return
        conn, _modes = drm_connector()
        set_kiosk_conf(KIOSK_RES=prev)
        ok, msg = kiosk_res_live(conn, prev)
        log("resolution was not confirmed; back to %s (%s)" % (prev, "ok" if ok else msg))
        if not ok:
            restart_kiosk()   # kiosk.sh applies the saved value at its start


def set_resolution(mode):
    conn, modes = drm_connector()
    if mode != "auto" and mode not in modes:
        raise ValueError("The screen does not offer that resolution.")
    prev = get_kiosk_conf().get("KIOSK_RES", "auto")
    if RES_PENDING["timer"] is not None:       # a second change before the first was confirmed: keep the ORIGINAL to go back to
        prev = RES_PENDING["prev"]
        RES_PENDING["timer"].cancel()
    ok, msg = kiosk_res_live(conn, mode)
    running = unit_state("alnasl-kiosk.service")["active"]
    # X on the fbdev driver has one mode only, so xrandr cannot switch it. The kiosk then has to restart:
    # kiosk.sh starts X with the KMS (modesetting) driver whenever a resolution is chosen.
    kstate = read(KIOSK_STATE)
    restart_needed = (not ok) and running and "path=x" in kstate and "driver=modesetting" not in kstate
    if not ok and running and not restart_needed:
        RES_PENDING.update(timer=None, prev=None, deadline=0.0)
        raise ValueError("The screen would not switch: " + (msg or "no answer"))
    set_kiosk_conf(KIOSK_RES=mode)
    if not running:
        return {"ok": True, "live": False, "pending": False, "confirm_seconds": 0}
    wait = RES_CONFIRM_SECONDS + 2 + (RES_RESTART_EXTRA if restart_needed else 0)
    t = threading.Timer(wait, res_revert)
    t.daemon = True
    t.start()
    RES_PENDING.update(timer=t, prev=prev, deadline=time.time() + wait)
    if restart_needed:
        restart_kiosk()
        log("resolution %s saved; the screen restarts to use it (%s); waiting for confirmation" % (mode, msg))
    else:
        log("resolution %s applied (%s); waiting for confirmation" % (mode, msg))
    return {"ok": True, "live": not restart_needed, "restart": restart_needed, "pending": True,
            "confirm_seconds": wait - 2}


def confirm_resolution():
    t = RES_PENDING["timer"]
    if t:
        t.cancel()
    RES_PENDING.update(timer=None, prev=None, deadline=0.0)
    return {"ok": True}


def cancel_resolution():
    """The user pressed Undo: same as the timer running out, right now."""
    t = RES_PENDING["timer"]
    if t:
        t.cancel()
    res_revert()
    return {"ok": True}


def restart_kiosk():
    if unit_state("alnasl-kiosk.service")["enabled"]:
        later(1.5, sysctl, "restart", "--no-block", "alnasl-kiosk.service")


def sysinfo():
    up = float(read("/proc/uptime", "0 0").split()[0])
    mem = dict(re.findall(r"(\w+):\s+(\d+) kB", read("/proc/meminfo")))
    du = shutil.disk_usage("/")
    temp = read("/sys/class/thermal/thermal_zone0/temp").strip()
    cur = os.path.realpath("/opt/alnasl/current") if os.path.exists("/opt/alnasl/current") else ""
    return {
        "hostname": socket.gethostname(),
        "model": read("/proc/device-tree/model").strip("\0\n"),
        "serial": read("/proc/device-tree/serial-number").strip("\0\n")[-6:],
        "kernel": os.uname().release,
        "os": (re.search(r'PRETTY_NAME="?([^"\n]+)', read("/etc/os-release")) or [0, "?"])[1],
        "image": read("/etc/alnasl/image-version", "?").strip(),
        "image_release": image_release(),
        "alnasl": (read("/opt/alnasl/current/VERSION") or os.path.basename(cur) or "?").strip(),
        "uptime": int(up),
        "mem_total": int(mem.get("MemTotal", 0)) * 1024, "mem_avail": int(mem.get("MemAvailable", 0)) * 1024,
        "disk_total": du.total, "disk_free": du.free,
        "temp_c": round(int(temp) / 1000, 1) if temp.isdigit() else None,
        "display": read(KIOSK_STATE).strip() or "unknown",
        "net": {i: ipv4_info(i) for i in ("eth0", "wlan0") if os.path.exists("/sys/class/net/" + i)},
    }


def image_release():
    """v6 A/B: this slot's train and version, and which slot runs (A or B)."""
    r = dict(re.findall(r'(?m)^(ALNASL_TRAIN|ALNASL_VERSION)="?([^"\n]*)"?\s*$', read("/etc/alnasl/image-release")))
    m = re.search(r"(?:^|\s)alnasl\.slot=([AB])(?:\s|$)", read("/proc/cmdline"))
    return {"train": r.get("ALNASL_TRAIN", ""), "version": r.get("ALNASL_VERSION", ""), "slot": m.group(1) if m else ""}


def ping_text():
    age, page = read_ping()
    return "never" if age is None else "%s, %d s ago" % (page or "(not on a menu page)", age)


def system_header():
    s = sysinfo()
    return {"hostname": s["hostname"], "model": s["model"], "serial": s["serial"], "kernel": s["kernel"], "os": s["os"],
            "image": s["image"], "alnasl": s["alnasl"], "uptime": "%d s" % s["uptime"], "screen": s["display"],
            # v7: what the box is, chosen and running (the ROLE section has the detail)
            "role": "%s (chosen: %s)" % (read(ROLE_RUN).strip() or "none this boot", read(MODE_FILE).strip() or "default")}


def diag_info():
    return diag.collect(wpa_summary(), LAST_SCAN[0], {"ping": ping_text()})


def diag_save():
    info = diag_info()
    text = diag.report_text(info, diag.journals(), system_header())
    name = diag.save_report(text)
    log("diagnostics saved to", name)
    return {"ok": True, "file": name, "where": "the boot partition of the SD card (the small drive that shows up on a PC)"}


# ---------------------------------------------------------------- get help ----
# "Get help": the diagnostics (already redacted by diag.py) are POSTed over HTTPS to the support
# address and the server answers with a six-digit code, which the person reads out. Outbound only:
# nothing listens for it and nothing comes back but that answer. Contract: Alnasl docs/support.md.
SUPPORT_DEFAULT_URL = "https://alnasl.zerotwo.cloud/support/upload"
SUPPORT_MAX_BYTES = 2000000              # the server refuses more than 2 MiB
SUPPORT_TIMEOUT = 25
MODE_FILE = STATE_DIR + "/mode"
ROLE_RUN = "/run/alnasl-mode/role"        # what alnasl-mode started this boot as (v7 word)
# v7: four roles (docs/v7-plan.md section 1). v6's two words still mean the first two, everywhere.
ROLES = ("alnasl", "arkab", "polis", "nunki")
ALIASES = {"master": "alnasl", "slave": "arkab"}
LEGACY = {"alnasl": "master", "arkab": "slave"}
MODES = ROLES + tuple(ALIASES)            # what a request may say
# The page each role shows on the box's screen; its port answering is "up".
ROLE_PORT = {"alnasl": 4040, "arkab": 4050, "polis": 4061, "nunki": 4062}


def canon_role(word):
    w = (word or "").strip().lower()
    w = ALIASES.get(w, w)
    return w if w in ROLES else None


def get_mode():
    """The box's role as chosen. Nothing set (or nonsense) means alnasl."""
    return canon_role(read(MODE_FILE)) or "alnasl"


def running_role():
    return canon_role(read(ROLE_RUN)) or get_mode()


def mode_status():
    """GET /api/mode. "mode" stays v6's word for the two v6 roles (Arkab's page compares it with
    master/slave); "role" is the v7 word."""
    role, run_ = get_mode(), running_role()
    return {"mode": LEGACY.get(role, role), "role": role, "roles": list(ROLES),
            "set": canon_role(read(MODE_FILE)) is not None,
            "running": LEGACY.get(run_, run_), "running_role": run_}


def set_mode(mode):
    role = canon_role(mode)
    if role is None:
        raise ValueError("bad_mode")
    write_atomic(MODE_FILE, role + "\n", 0o644)
    return role


def switch_mode(mode, confirm):
    """Settings > Change what this box is, and Arkab's page. The role is only a file that alnasl-mode reads
    at boot, so the switch is that file and a restart (the boot screen shows it). Nothing is deleted:
    every app keeps its data, switching back loses nothing."""
    if confirm != "SWITCH":
        raise ValueError("Not confirmed.")
    role = canon_role(mode)
    if role is None:
        raise ValueError("bad_mode")
    if role == running_role() and role == get_mode():
        return {"ok": True, "mode": LEGACY.get(role, role), "role": role, "same": True}
    log("role switch: %s -> %s (running %s); restarting" % (get_mode(), role, running_role()))  # diagnostics read this
    set_mode(role)
    power("reboot")
    return {"ok": True, "mode": LEGACY.get(role, role), "role": role, "same": False}


def role_up(role=None):
    try:
        with socket.create_connection(("127.0.0.1", ROLE_PORT[role or running_role()]), timeout=1):
            return True
    except OSError:
        return False


def role_wanted(role=None):
    """The role's own app is switched on (Settings > Services can switch Alnasl off)."""
    role = role or running_role()
    return unit_state("%s.service" % role)["enabled"]


# ------------------------------------------------------------------ printers --
# Settings > Printers, on a polis box (docs/v7-plan.md, "Polis on the box"). CUPS from Photon, without
# cups-filters or Ghostscript: a PDF goes to the printer as it is (/etc/cups/local.convs), so a printer that
# understands PDF prints (IPP Everywhere network printers, most office printers). Nothing is discovered: the
# address is typed in, or a USB printer is picked from what CUPS sees.
PRINTER_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PRINTER_ADDR_RE = re.compile(r"^[A-Za-z0-9.:\[\]-]{1,253}$")


def _lpstat(*args):
    rc, out = run(["lpstat", *args], timeout=10)
    return out if rc == 0 else ""


def printers_status():
    default = ""
    m = re.search(r"system default destination: (\S+)", _lpstat("-d"))
    if m:
        default = m.group(1)
    uris = dict(re.findall(r"^device for (\S+): (\S+)$", _lpstat("-v"), re.M))
    out = []
    for name, rest in re.findall(r"^printer (\S+) (.*)$", _lpstat("-p"), re.M):
        uri = uris.get(name, "")
        # what is shown of the address: scheme and host, never a user name or a query in it
        shown = re.sub(r"//[^@/]*@", "//", uri).split("?")[0]
        out.append({"name": name, "uri": shown, "default": name == default,
                    "state": "disabled" if "disabled" in rest else ("printing" if "now printing" in rest else "idle")})
    return {"printers": out, "cups": unit_state("cups.service")["active"]}


def printers_usb():
    rc, out = run(["lpinfo", "--include-schemes", "usb", "-v"], timeout=30)
    return {"usb": [u for u in re.findall(r"^direct (usb://\S+)$", out, re.M)][:16] if rc == 0 else []}


def _printer_name(b, fallback):
    n = str(b.get("name") or "").strip()
    if not n:
        n = re.sub(r"[^A-Za-z0-9_-]+", "-", fallback).strip("-")[:32] or "printer"
    if not PRINTER_NAME_RE.fullmatch(n):
        raise ValueError("bad_printer_name")
    return n


def printer_add(b):
    usb = str(b.get("usb") or "")
    if usb:
        if not usb.startswith("usb://") or usb not in printers_usb()["usb"]:
            raise ValueError("bad_printer_address")
        name = _printer_name(b, usb[6:].split("?")[0].replace("/", "-"))
        cmd = ["lpadmin", "-p", name, "-E", "-v", usb, "-m", "raw"]
    else:
        addr = str(b.get("address") or "").strip()
        if not PRINTER_ADDR_RE.fullmatch(addr):
            raise ValueError("bad_printer_address")
        name = _printer_name(b, addr)
        cmd = ["lpadmin", "-p", name, "-E", "-v", "ipp://%s/ipp/print" % addr, "-m", "everywhere"]
    rc, out = run(cmd, timeout=60)
    if rc != 0:
        log("lpadmin failed for", name)
        raise ValueError("printer_not_added")
    if not any(p["default"] for p in printers_status()["printers"]):
        run(["lpadmin", "-d", name], timeout=20)
    log("printer added:", name)
    return printers_status()


def _known_printer(b):
    name = str(b.get("name") or "")
    if not PRINTER_NAME_RE.fullmatch(name) or name not in [p["name"] for p in printers_status()["printers"]]:
        raise ValueError("bad_printer_name")
    return name


def printer_default(b):
    run(["lpadmin", "-d", _known_printer(b)], timeout=20)
    return printers_status()


def printer_remove(b):
    name = _known_printer(b)
    run(["lpadmin", "-x", name], timeout=20)
    log("printer removed:", name)
    return printers_status()


def test_pdf(title, line):
    """A one-page A4 PDF with two lines of Helvetica: what the printer gets is a PDF, as Polis sends."""
    def esc(t):
        return t.encode("ascii", "replace").decode().replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    content = ("BT /F1 28 Tf 72 740 Td (%s) Tj ET BT /F1 14 Tf 72 700 Td (%s) Tj ET" % (esc(title), esc(line))).encode()
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream"]
    pdf, offs = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(pdf))
        pdf += b"%d 0 obj\n" % i + o + b"\nendobj\n"
    xref = len(pdf)
    pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    pdf += b"".join(b"%010d 00000 n \n" % o for o in offs)
    pdf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return pdf


def printer_test(b):
    name = _known_printer(b)
    path = "/run/alnasl-setup-testpage.pdf"
    with open(path, "wb") as f:
        f.write(test_pdf("Alnasl - test page", "Printer %s, %s" % (name, time.strftime("%Y-%m-%d %H:%M"))))
    rc, _ = run(["lp", "-d", name, "-t", "Alnasl test page", "-o", "media=A4", path], timeout=30)
    if rc != 0:
        raise ValueError("printer_test_failed")
    return {"ok": True}


# --------------------------------------------------------------------- sound --
# Settings > Sound, on a nunki box: which output the announcer speaks through, and how loud. alnasl-sound
# writes /etc/asound.conf from sound.conf and sets the volume.
SOUND_CONF = STATE_DIR + "/sound.conf"
SOUND = "/usr/local/sbin/alnasl-sound"
SOUND_OUTPUTS = ("hdmi", "hdmi2", "jack")


def sound_status():
    kv = dict(re.findall(r"^([A-Z]+)=([a-z0-9]*)", read(SOUND_CONF), re.M))
    rc, out = run([SOUND, "--cards"], timeout=20)
    have = [w for w in out.split() if w in SOUND_OUTPUTS] if rc == 0 else []
    out_ = kv.get("OUTPUT") if kv.get("OUTPUT") in SOUND_OUTPUTS else "hdmi"
    vol = int(kv["VOLUME"]) if kv.get("VOLUME", "").isdigit() and int(kv["VOLUME"]) <= 100 else 80
    return {"outputs": have, "output": out_, "volume": vol}


def set_sound(b):
    cur = sound_status()
    out = b.get("output", cur["output"])
    if out not in SOUND_OUTPUTS:
        raise ValueError("bad_output")
    try:
        vol = int(b.get("volume", cur["volume"]))
    except (TypeError, ValueError):
        raise ValueError("bad_volume")
    if not 0 <= vol <= 100:
        raise ValueError("bad_volume")
    write_atomic(SOUND_CONF, "OUTPUT=%s\nVOLUME=%d\n" % (out, vol), 0o644)
    run([SOUND], timeout=30)
    return sound_status()


def sound_test():
    lang = get_state().get("lang", "en")
    line = "Dit is de omroeper. Een, twee, drie." if lang == "nl" else "This is the announcer. One, two, three."
    later(0.2, run, [SOUND, "--test", "nl" if lang == "nl" else "en", line], 30)
    return {"ok": True}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):  # a redirect could move the file to plain http or elsewhere
        return None


def valid_support_url(url):
    """The upload address: https only, a host, no credentials, no spaces. Raises ValueError."""
    url = (url or "").strip()
    if not url:
        return ""
    if len(url) > 300 or re.search(r"[\s\x00-\x1f\x7f]", url):
        raise ValueError("bad_url")
    u = urlsplit(url)
    if u.scheme != "https" or not u.hostname or u.username or u.password or u.fragment:
        raise ValueError("bad_url")
    try:
        u.port  # noqa: B018  (raises on a bad port)
    except ValueError:
        raise ValueError("bad_url")
    return url


def support_url():
    try:
        return valid_support_url(get_state().get("support_url")) or SUPPORT_DEFAULT_URL
    except ValueError:
        return SUPPORT_DEFAULT_URL


def help_last():
    """The last code, only while it is still valid."""
    h = get_state().get("help_last") or {}
    try:
        exp = datetime.datetime.fromisoformat(str(h.get("expires_at", "")).replace("Z", "+00:00"))
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=datetime.timezone.utc)
        if h.get("code") and exp > datetime.datetime.now(datetime.timezone.utc):
            return {"code": h["code"], "expires_at": h["expires_at"]}
    except ValueError:
        pass
    return None


def help_status():
    return {"url": support_url(), "default_url": SUPPORT_DEFAULT_URL, "last": help_last()}


def help_headers():
    s = sysinfo()
    mode = running_role()
    box = (s["serial"] or s["hostname"] or "unknown")
    return {"x-alnasl-box": box[:100], "x-alnasl-version": ("%s/%s" % (s["alnasl"], s["image"]))[:50],
            "x-alnasl-mode": mode[:50]}


def help_body():
    text = diag.report_text(diag_info(), diag.journals(), system_header())
    data = text.encode("utf-8", "replace")
    if len(data) > SUPPORT_MAX_BYTES:  # keep the top (verdict and sections); the journals come last
        data = data[:SUPPORT_MAX_BYTES].decode("utf-8", "ignore").encode("utf-8")
    return data


def help_send():
    """Build, send, answer {"ok": True, code, expires_at} or {"ok": False, "error": key}. Keys: no_internet,
    rate_limited, support_off, too_large, rejected, server_error."""
    url = support_url()
    data = help_body()
    hdr = {"Content-Type": "text/plain; charset=utf-8", "User-Agent": "alnasl-box-help"}
    hdr.update(help_headers())
    req = urllib.request.Request(url, data=data, method="POST", headers=hdr)
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=SUPPORT_TIMEOUT) as r:
            body, status = r.read(4096), r.status
    except urllib.error.HTTPError as e:
        status, body = e.code, b""
        try:
            body = e.read(4096)
        except Exception:
            pass
        log("help upload refused:", status)
        key = {404: "support_off", 413: "too_large", 429: "rate_limited", 400: "rejected", 415: "rejected"}.get(status)
        return {"ok": False, "error": key or "server_error", "status": status}
    except (urllib.error.URLError, OSError, ssl.SSLError, TimeoutError) as e:  # DNS, no route, timeout, TLS
        log("help upload failed:", type(e).__name__)
        return {"ok": False, "error": "no_internet"}
    try:
        j = json.loads(body.decode("utf-8"))
        code, exp = str(j["code"]), str(j["expires_at"])
        if status != 201 or not re.fullmatch(r"\d{6}", code):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        log("help upload: unexpected answer, status", status)
        return {"ok": False, "error": "server_error", "status": status}
    set_state(help_last={"code": code, "expires_at": exp, "sent_at": time.strftime("%Y-%m-%d %H:%M:%S %z")})
    log("help upload accepted")
    return {"ok": True, "code": code, "expires_at": exp}


# ----------------------------------------------------------------- console ----
# The kiosk holds tty1. Ctrl+Alt+F2/F3 should reach the consoles (getty@tty2,
# getty@tty3 are enabled); these two actions do the same without a keyboard
# shortcut, which is also the test of whether the VT switch itself works.

def console_show():
    later(0.8, run, ["chvt", "2"])
    return {"ok": True}


def _stop_screen():
    sysctl("stop", "alnasl-kiosk.service")
    time.sleep(1.5)
    note = ("\r\n\r\nThe Alnasl screen is stopped (until the next boot).\r\n"
            "To bring it back: run  alnasl-screen start  (or restart the box).\r\n\r\n")
    for tty in ("/dev/tty1", "/dev/tty2"):
        try:
            with open(tty, "w") as f:
                f.write(note)
        except OSError:
            pass
    run(["chvt", "1"])
    log("the screen (kiosk) was stopped from the menu; it starts again at the next boot")


def screen_stop():
    later(1.0, _stop_screen)
    return {"ok": True}


def screen_states():
    try:
        with open(SPLASH + "/messages.json", encoding="utf-8") as f:
            return json.load(f).get("states", {})
    except (OSError, ValueError):
        return {}


def set_screen(key):
    """The state the boot screen shows (the browser's /screen page and the framebuffer)."""
    if key in screen_states():
        write_atomic(SCREEN_STATE, key + "\n")


def screen_geom():
    """Where the value line and the bar of the update states go (1080-line units), and the glyphs."""
    try:
        with open(SPLASH + "/messages.json", encoding="utf-8") as f:
            m = json.load(f)
        g, gl = m.get("geometry", {}), (m.get("glyphs") or {}).get("1080") or {}
        return {"adv": gl.get("advance", {}), "names": gl.get("names", {}), "height": gl.get("height", 42),
                "sub_y": g.get("sub_y", 282), "dots_y": g.get("dots_y", 346),
                "bar_w": g.get("bar_w", 360), "bar_h": g.get("bar_h", 6), "bar_steps_y": g.get("bar_steps_y", 380),
                "with_steps": [k for k, v in (m.get("states") or {}).items() if v.get("steps") and v.get("bar")]}
    except (OSError, ValueError):
        return None


# v7: the boot log for the browser's /boot page (screen.html), after X has taken the screen from the
# framebuffer painter. Same source, same allow-list, same redaction, same order (bootlog.py), so the page
# carries on with the lines the painter last showed, in the same places. Loopback only, like all of this
# server. The reader is a thread with journalctl -b -f; it starts with the server when the box has just
# booted (so it has caught up by the time Chromium asks) and otherwise on the first request, and stops
# after two minutes without one.
BOOTLOG = {"lock": threading.Lock(), "lines": collections.deque(maxlen=400), "seq": 0, "thread": None,
           "asked": 0.0, "ready": False, "status": ("", 0.0)}
BOOTLOG_IDLE = 120


def _bootlog_reader():
    f = bootlog.Follower(bootlog.role)
    try:
        while time.monotonic() - BOOTLOG["asked"] < BOOTLOG_IDLE:
            new = f.poll(1.0)
            with BOOTLOG["lock"]:
                for line in new:
                    BOOTLOG["seq"] += 1
                    BOOTLOG["lines"].append((BOOTLOG["seq"],) + tuple(line))
                if f.caught_up:
                    BOOTLOG["ready"] = True
    finally:
        f.close()
        with BOOTLOG["lock"]:
            BOOTLOG["thread"] = None
            BOOTLOG["ready"] = False
            BOOTLOG["lines"].clear()


def bootlog_start():
    with BOOTLOG["lock"]:
        BOOTLOG["asked"] = time.monotonic()
        if BOOTLOG["thread"] is None:
            t = threading.Thread(target=_bootlog_reader, daemon=True, name="bootlog")
            BOOTLOG["thread"] = t
            t.start()


def bootlog_view():
    """What screen.html needs to lay the log out exactly as alnasl-splash does."""
    try:
        with open(SPLASH + "/messages.json", encoding="utf-8") as f:
            m = json.load(f)
        return {"mono": m["mono"], "logview": m["logview"],
                "steps": [k for k, v in (m.get("states") or {}).items() if v.get("steps")]}
    except (OSError, ValueError, KeyError):
        return None


def bootlog_get(q):
    bootlog_start()
    try:
        after = int((parse_qs(q or "").get("after") or ["0"])[0])
    except ValueError:
        after = 0
    text, t = BOOTLOG["status"]
    if time.monotonic() - t > 1.0:
        text = bootlog.status(get_state().get("lang", "en"))["text"]
        BOOTLOG["status"] = (text, time.monotonic())
    with BOOTLOG["lock"]:
        lines = [l for l in BOOTLOG["lines"] if l[0] > after][-60:]
        out = {"seq": BOOTLOG["seq"], "ready": BOOTLOG["ready"], "status": text,
               "lines": [{"n": n, "t": tag, "c": col, "e": err, "m": msg} for n, tag, col, err, msg in lines]}
    if after == 0:
        out["view"] = bootlog_view()
    return out


def bootscreen():
    st = read(SCREEN_STATE).strip()
    out = {"state": st if st in screen_states() else "", "lang": get_state().get("lang", "en"),
           # v7: "alnasl" here is the role's own app (the page the screen goes to), whatever the role.
           "alnasl_wanted": setup_done() and role_wanted(), "alnasl_up": role_up(), "role": running_role()}
    val = read(SCREEN_VALUE).strip()
    prog = read(SCREEN_PROGRESS).strip()
    if out["state"] and (val or prog):
        out["value"] = val if re.fullmatch(r"[0-9v.%]{1,12}", val) else ""
        out["progress"] = int(prog) if prog.isdigit() and int(prog) <= 100 else None
        out["geom"] = screen_geom()
    return out


# ----------------------------------------------------------- system updates ---
# v6 A/B: the whole system image (alnasl-system-update does the work, as root, outside this server).
# This server only reads its status and leaves it a request file; the unit picks that up. Never a train
# change without the word UPGRADE from the page that asked (the menu's confirmation, or Arkab's).
SYSUPD = "/usr/local/sbin/alnasl-system-update"
SYS_REQUEST = "/var/lib/alnasl-os-update/system/request"
PAINTED = KIOSK_RUN + "/painted"


def mark_painted():
    """The kiosk's browser has loaded a page from here: the health check of a new slot waits for this."""
    if not os.path.exists(PAINTED):
        try:
            os.makedirs(KIOSK_RUN, exist_ok=True)
            open(PAINTED, "w").close()
        except OSError:
            pass


def system_status():
    rc, out = run([SYSUPD, "--status"], timeout=20)
    try:
        s = json.loads(out)
        assert isinstance(s, dict)
    except (ValueError, AssertionError):
        return {"ab": False, "error": "unavailable"}
    return s


def _train_no(t):
    m = re.fullmatch(r"v([0-9]{1,3})", str(t or ""))
    if not m:
        raise ValueError("bad_train")
    return int(m.group(1))


def system_request(action, train=None, by="menu"):
    s = system_status()
    if not s.get("ab"):
        raise ValueError("not_ab")
    if not s.get("updates_on"):
        raise ValueError("updates_off")
    if s.get("busy") or s.get("trial"):
        raise ValueError("busy")
    r = {"action": action, "by": by if by in ("menu", "arkab") else "menu"}
    if action == "upgrade":
        if _train_no(train) <= _train_no(s.get("train")):
            raise ValueError("bad_train")
        r["train"] = train
    write_atomic(SYS_REQUEST, json.dumps(r) + "\n", 0o600)
    sysctl("start", "--no-block", "alnasl-system-update.service")
    return {"ok": True}


def system_check():
    sysctl("start", "--no-block", "alnasl-system-update-check.service")
    return {"ok": True}


def system_url(url):
    url = (url or "").strip()
    if url and (len(url) > 300 or not url.startswith("https://") or re.search(r"[\s\x00-\x1f\x7f]", url)
                or urlsplit(url).username or not urlsplit(url).hostname):
        raise ValueError("bad_url")
    set_state(update_url=url)
    return system_status()


def power(action):
    if action not in ("reboot", "poweroff"):
        raise ValueError("bad action")
    set_screen("reboot" if action == "reboot" else "shutdown")
    later(1.5, sysctl, action, "--no-block")
    return {"ok": True}


def factory_reset(confirm):
    """Erase the box back to new (alnasl-reset). The page has had the operator hold a button; the word
    is checked here too, so nothing but that page's own request can start it."""
    if confirm != "RESET":
        raise ValueError("Not confirmed.")
    set_screen("reset-1")
    later(1.0, sysctl, "start", "--no-block", "alnasl-reset.service")
    return {"ok": True}


# ------------------------------------------------------ setup hotspot/portal --
# docs/captive-portal.md. hotspot.py (alnasl-hotspot.service) owns wlan0 while the hotspot is on and
# writes what it is doing to /run/alnasl-hotspot/status.json; this server answers the page that phones
# see on the hotspot (portal.py, 10.42.0.1:80, which passes ONLY the /api/portal calls on to here) and the
# box's own screen (/api/hotspot, loopback, which is the one place the password is shown). Nothing here
# erases, updates or re-roles the box: the portal's calls are Wi-Fi, the Arkab PIN and Arkab's join link.
HOTSPOT_RUN = "/run/alnasl-hotspot"
HOTSPOT_ACTIVE = HOTSPOT_RUN + "/active"
HOTSPOT_STATUS = HOTSPOT_RUN + "/status.json"
HOTSPOT_JOIN = HOTSPOT_RUN + "/join.json"
HOTSPOT_SCAN = HOTSPOT_RUN + "/scan.json"
HOTSPOT_FILE = "/boot/efi/alnasl-hotspot.txt"
HOTSPOT_NET = ipaddress.ip_network("10.42.0.0/24")
ARKAB_DATA = "/var/lib/arkab"
ARKAB_PENDING = STATE_DIR + "/arkab-join.pending"
ARKAB_RESULT = STATE_DIR + "/arkab-join.result"
ARKAB_PENDING_MAX = 900                  # a join code is good for 15 minutes on the server's side


def hotspot_active():
    return os.path.exists(HOTSPOT_ACTIVE)


def hotspot_status():
    try:
        s = json.loads(read(HOTSPOT_STATUS, "{}"))
        return s if isinstance(s, dict) else {}
    except ValueError:
        return {}


def hotspot_screen():
    """GET /api/hotspot, for the box's own screen: the hotspot's name and password while it is on."""
    s = hotspot_status()
    out = {"active": hotspot_active(), "ssid": s.get("ssid"), "portal": "http://10.42.0.1/", "reason": s.get("reason")}
    if out["active"]:
        import hotspot
        pw = hotspot.parse_file(read(HOTSPOT_FILE)).get("password") or ""
        out["password"] = pw if hotspot.valid_password(pw) else None
    return out


def hotspot_join_request(ssid, passphrase, hidden, country):
    """Hands a network to the hotspot daemon. 0600 in a root-only /run directory; it reads and deletes
    it within a few seconds. Not logged, not kept."""
    os.makedirs(HOTSPOT_RUN, mode=0o700, exist_ok=True)
    tmp = HOTSPOT_JOIN + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"ssid": ssid, "passphrase": passphrase or "", "hidden": bool(hidden), "country": country}, f)
    os.replace(tmp, HOTSPOT_JOIN)
    log("a Wi-Fi network was handed to the hotspot daemon to try")


def hotspot_scan():
    """While the AP is up: a scan in AP mode if the chip allows it (brcmfmac often does not), otherwise
    the list the hotspot daemon saved just before it took the radio."""
    nets, source, age = [], "iw-ap", 0
    if diag.have("iw"):
        rc, out = diag.runo(["iw", "dev", "wlan0", "scan", "ap-force"], 15)
        if rc == 0:
            nets = [n for n in parse_iw_scan(out) if not n["ssid"].startswith("Alnasl-setup-")]
    if not nets:
        try:
            c = json.loads(read(HOTSPOT_SCAN, "{}"))
            nets, source, age = c.get("networks") or [], "cached", int(time.time() - float(c.get("t", 0)))
        except (ValueError, TypeError):
            nets = []
    nets = [n for n in nets if isinstance(n, dict) and isinstance(n.get("ssid"), str)]
    nets.sort(key=lambda n: -int(n.get("signal", -100)))
    saved = {bytes.fromhex(n["ssid"]).decode("utf-8", "replace") for n in parse_wpa()[1]}
    for n in nets:
        n["saved"] = n["ssid"] in saved
    res = {"available": True, "networks": nets, "source": source, "age": age, "hotspot": True}
    if not nets:
        res["reason"] = "no_results"
    return res


def box_addresses():
    """The box's IPv4 addresses on the hall's side (never the hotspot's own)."""
    out = []
    for iface in ("eth0", "wlan0"):
        for a in ipv4_info(iface):
            ip = a.split("/")[0]
            try:
                if ipaddress.ip_address(ip) not in HOTSPOT_NET:
                    out.append({"iface": iface, "ip": ip})
            except ValueError:
                pass
    return out


def where_next(role=None):
    """Where the box can be reached once it is on the hall's network: its name, and its page if it has one."""
    role = role or running_role()
    host = socket.gethostname()
    port = {"alnasl": ALNASL_PORT, "arkab": ROLE_PORT["arkab"]}.get(role)
    return {"host": host, "mdns": host + ".local", "port": port,
            "url": ("http://%s.local:%d/" % (host, port)) if port else None}


def read_json(path):
    try:
        v = json.loads(read(path, "null"))
        return v if isinstance(v, dict) else None
    except ValueError:
        return None


def write_json_private(path, obj):
    write_atomic(path, json.dumps(obj) + "\n", 0o600)


def portal_info():
    """GET /api/portal: everything the setup page on the hotspot shows. No secrets."""
    role = running_role()
    s = hotspot_status()
    out = {"role": role, "hostname": socket.gethostname(), "addresses": box_addresses(), "next": where_next(role),
           "hotspot": {"active": hotspot_active(), "ssid": s.get("ssid"), "reason": s.get("reason")},
           "last_join": s.get("last_join"), "country": parse_wpa()[0], "lang": get_state().get("lang", "en"),
           "saved": wifi_saved()["saved"]}
    if role == "arkab":
        pend = read_json(ARKAB_PENDING)
        out["arkab"] = {"up": role_up("arkab"), "pending": bool(pend), "last": read_json(ARKAB_RESULT)}
    return out


def portal_join(b):
    ssid, pw = str(b.get("ssid") or ""), str(b.get("passphrase") or "")
    country = validate_wifi(ssid, pw, str(b.get("country") or "BE"))
    if not hotspot_active():  # the portal page only exists while the hotspot is on; this is the odd race
        return wifi_connect(ssid, pw, b.get("hidden"), country)
    hotspot_join_request(ssid, pw, b.get("hidden"), country)
    return {"ok": True, "switching": True, "ssid": ssid, "hotspot": hotspot_status().get("ssid"), "next": where_next()}


def arkab_pin_check(pin):
    """The SD-card file's rules (alnasl-arkab-pin): 4 to 64 characters, no space or quote at either end, no
    control characters; and not the two words that mean "remove" there."""
    if not isinstance(pin, str) or not 4 <= len(pin) <= 64:
        raise ValueError("pin_length")
    if pin != pin.strip(" ") or pin[0] in "\"'" or pin[-1] in "\"'":
        raise ValueError("pin_edges")
    if any(ord(c) < 32 or ord(c) == 127 for c in pin):
        raise ValueError("pin_control")
    if pin.lower() in ("remove", "verwijderen"):
        raise ValueError("pin_word")
    return pin


def portal_arkab_pin(b):
    """Arkab's remote PIN, the way the SD card hands it over: a request file in Arkab's data directory
    (0600, owner arkab) that Arkab applies when it starts (Arkab.PinRequest), then a restart of Arkab."""
    if running_role() != "arkab":
        raise ValueError("not_arkab")
    pin = arkab_pin_check(b.get("pin"))
    import pwd
    try:
        pw = pwd.getpwnam("arkab")
    except KeyError:
        raise ValueError("arkab_missing")
    if not os.path.isdir(ARKAB_DATA):
        raise ValueError("arkab_missing")
    req = ARKAB_DATA + "/pin-request"
    tmp = req + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("set\n%s\n" % pin)
    os.chown(tmp, pw.pw_uid, pw.pw_gid)
    os.replace(tmp, req)
    log("an Arkab remote PIN was handed to Arkab from the setup page; Arkab restarts to apply it")
    later(1.0, sysctl, "restart", "--no-block", "arkab.service")
    return {"ok": True}


def _arkab_join_now(link):
    import arkab_live
    ok, reason = arkab_live.join(link)
    write_json_private(ARKAB_RESULT, {"ok": ok, "reason": reason, "at": time.time()})
    log("Arkab join from the setup page: %s" % reason)
    return ok, reason


def portal_arkab_join(b):
    """Arkab's join link. With a network now (Ethernet beside the hotspot), Arkab is asked at once over
    loopback; without one (the usual case: the box is on the hotspot because it has no network), the link
    waits here and the hotspot daemon hands it over as soon as the Wi-Fi works."""
    if running_role() != "arkab":
        raise ValueError("not_arkab")
    import arkab_live
    link = arkab_live.valid_link(str(b.get("link") or ""))
    if not link:
        raise ValueError("not_a_link")
    if box_addresses() and role_up("arkab"):
        ok, reason = _arkab_join_now(link)
        return {"ok": ok, "reason": reason, "pending": False}
    write_json_private(ARKAB_PENDING, {"link": link, "t": time.time()})
    try:
        os.remove(ARKAB_RESULT)
    except OSError:
        pass
    return {"ok": True, "pending": True}


def arkab_join_pending():
    """Called by the hotspot daemon once the box has a network: the waiting join link, if any."""
    pend = read_json(ARKAB_PENDING)
    if not pend:
        return None
    if time.time() - float(pend.get("t", 0)) > ARKAB_PENDING_MAX:
        os.remove(ARKAB_PENDING)
        write_json_private(ARKAB_RESULT, {"ok": False, "reason": "expired", "at": time.time()})
        return "expired"
    if running_role() != "arkab" or not box_addresses() or not role_up("arkab"):
        return None
    os.remove(ARKAB_PENDING)
    return _arkab_join_now(str(pend.get("link") or ""))[1]


# ---------------------------------------------------------------------- HTTP --

def api_get(path, q):
    if path == "/api/state":
        return {"done": setup_done(), "lang": get_state().get("lang", "en"),
                "layouts": [{"id": l[0], "label": l[1]} for l in LAYOUTS],
                "keyboard": get_keyboard(), "services": services_status(),
                "scale": get_kiosk_conf()["KIOSK_SCALE"], "alnasl_up": alnasl_up(), "mode": mode_status(),
                "role_up": role_up(), "role_port": ROLE_PORT[running_role()]}
    if path == "/api/resolution":
        return res_status()
    if path == "/api/net":
        return net_status()
    if path == "/api/wifi/scan":
        return wifi_scan()
    if path == "/api/wifi/saved":
        return wifi_saved()
    if path == "/api/sysinfo":
        return sysinfo()
    if path == "/api/ping":
        qs = parse_qs(q or "")
        page_ping((qs.get("p") or [""])[0], first=bool(qs.get("first")))
        return {"ok": True}
    if path == "/api/kiosk-busy":  # the kiosk watchdog reads PING_FILE itself; this is the same answer for people
        age, page = read_ping()
        return {"busy": age is not None and age < BUSY_SECONDS, "page": page, "age": None if age is None else int(age)}
    if path == "/api/diag":
        return diag_info()
    if path == "/api/diag/journals":
        return {"journals": diag.journals()}
    if path == "/api/diag/scan":  # the "Test Wi-Fi scan" button: raw outputs, nothing hidden
        r = wifi_scan()
        r["raw"] = LAST_SCAN[0]
        return r
    if path == "/api/help":
        return help_status()
    if path == "/api/bootscreen":
        mark_painted()
        return bootscreen()
    if path == "/api/bootlog":  # ?after=N: the log lines after N, the status line (v7)
        return bootlog_get(q)
    if path == "/api/system":
        return system_status()
    if path == "/api/mode":
        return mode_status()
    if path == "/api/printers":
        return printers_status()
    if path == "/api/printers/usb":
        return printers_usb()
    if path == "/api/sound":
        return sound_status()
    if path == "/api/hotspot":  # the box's own screen only: portal.py never passes this one on
        return hotspot_screen()
    if path == "/api/portal":
        return portal_info()
    if path == "/api/portal/scan":
        return wifi_scan()
    if path == "/healthz":
        return {"ok": True}
    return None


def api_post(path, b):
    if path == "/api/lang":
        if b.get("lang") in ("en", "nl"):
            set_state(lang=b["lang"])
        return {"ok": True}
    if path == "/api/keyboard":
        r = set_keyboard(b.get("layout", ""))
        if b.get("restart_kiosk"):
            restart_kiosk()
        return r
    if path == "/api/wifi/connect":
        return wifi_connect(b.get("ssid", ""), b.get("passphrase", ""), b.get("hidden"), b.get("country", "BE"))
    if path == "/api/wifi/forget":
        return wifi_forget(b.get("ssid", ""))
    if path == "/api/wifi/country":
        return wifi_country(b.get("country", ""))
    if path == "/api/net/set":
        if b.get("iface") not in NETD_DROPIN:
            raise ValueError("bad interface")
        return apply_net(b["iface"], b)
    if path == "/api/net/confirm":
        return confirm_net(b.get("iface", ""))
    if path == "/api/hostname":
        return set_hostname(b.get("hostname", ""))
    if path == "/api/services":
        return set_services(b)
    if path == "/api/scale":
        r = set_scale(b.get("scale", 100))
        restart_kiosk()
        return r
    if path == "/api/resolution":
        return set_resolution(str(b.get("mode", "auto")))
    if path == "/api/resolution/confirm":
        return confirm_resolution()
    if path == "/api/resolution/undo":
        return cancel_resolution()
    if path == "/api/finish":
        # The wizard's first question (what is this box) is only written here, at the end: a box that lost
        # power half way through the wizard must not come back as something it cannot finish the wizard on.
        want = b.get("mode")
        if want is not None:
            want = set_mode(str(want))
        write_atomic(DONE, "1\n")
        page_ping("")
        if want is not None and want != running_role():
            power("reboot")  # the other app takes the box over at the next boot
            return {"ok": True, "reboot": True}
        restart_kiosk()
        return {"ok": True}
    if path == "/api/diag/save":
        try:
            return diag_save()
        except OSError as e:
            raise ValueError("Could not write to the SD card: %s" % e)
    if path == "/api/help/send":  # blocks up to SUPPORT_TIMEOUT s; the answer is the code or the reason
        return help_send()
    if path == "/api/help/url":  # "" puts the default back
        set_state(support_url=valid_support_url(str(b.get("url", ""))))
        return help_status()
    if path == "/api/console/show":
        return console_show()
    if path == "/api/screen/stop":
        return screen_stop()
    if path == "/api/reopen":  # alnasl-setup
        if os.path.exists(DONE):
            os.remove(DONE)
        return {"ok": True}
    if path == "/api/power":
        return power(b.get("action", ""))
    if path == "/api/reset":
        return factory_reset(b.get("confirm", ""))
    # {"mode": "alnasl"|"arkab"|"polis"|"nunki" (or v6's "master"|"slave"), "confirm": "SWITCH"};
    # Settings and Arkab's page
    if path == "/api/mode":
        return switch_mode(str(b.get("mode", "")), b.get("confirm", ""))
    # Settings > Printers (polis) and Settings > Sound (nunki)
    if path in ("/api/printers/add", "/api/printers/default", "/api/printers/remove", "/api/printers/test"):
        if running_role() != "polis":
            raise ValueError("not_polis")
        return {"add": printer_add, "default": printer_default, "remove": printer_remove,
                "test": printer_test}[path.rsplit("/", 1)[1]](b)
    if path in ("/api/sound", "/api/sound/test"):
        if running_role() != "nunki":
            raise ValueError("not_nunki")
        return set_sound(b) if path == "/api/sound" else sound_test()
    # System updates (menu > Settings > System updates; Arkab's status page through the same API).
    if path == "/api/system/check":
        return system_check()
    if path == "/api/system/install":  # a newer image of this box's own train, now (round check included)
        if b.get("confirm") != "INSTALL":
            raise ValueError("Not confirmed.")
        return system_request("install", by=b.get("by", "menu"))
    if path == "/api/system/upgrade":  # the next train: only ever this way, never by itself
        if b.get("confirm") != "UPGRADE":
            raise ValueError("Not confirmed.")
        return system_request("upgrade", train=str(b.get("train", "")), by=b.get("by", "menu"))
    if path == "/api/system/url":  # "" puts the default back
        return system_url(str(b.get("url", "")))
    # The setup page on the hotspot (portal.py passes these three on, and nothing else that changes anything).
    if path == "/api/portal/join":
        return portal_join(b)
    if path == "/api/portal/arkab-pin":
        return portal_arkab_pin(b)
    if path == "/api/portal/arkab-join":
        return portal_arkab_join(b)
    return None


TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png"}
SPA = ("/", "/setup", "/menu", "/settings", "/info", "/diag", "/help")


class H(BaseHTTPRequestHandler):
    server_version = "alnasl-setup"
    protocol_version = "HTTP/1.1"
    timeout = 120  # an idle keep-alive connection must not hold a thread forever

    def log_message(self, fmt, *a):  # method, path and status only; never a body
        if self.path != "/healthz" and not self.path.startswith("/api/ping") and "/api/kiosk-busy" not in self.path:
            log(self.command, self.path.split("?")[0], a[1] if len(a) > 1 else "")

    def _send(self, code, body, ctype="application/json", extra=None, cache="no-store"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _host_ok(self):
        return (self.headers.get("Host") or "") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        u = urlsplit(self.path)
        path = u.path
        if path == "/healthz":  # first, and touching nothing that could be busy: the watchdog asks this every 10 s
            return self._send(200, b'{"ok": true}')
        try:
            if path == "/favicon.ico":
                return self._send(204, b"")
            if path in ("/boot", "/screen", "/"):
                mark_painted()  # the kiosk's browser is up and asking (the A/B health check waits for this)
            if path == "/":
                # A browser that was restarted while a menu page was open goes back to that page.
                back = resume_page()
                if back:
                    log("start page: returning to", back)
                    return self._send(302, b"", extra={"Location": back})
                # Where the kiosk starts: the wizard until setup is done, then the role's own page (Alnasl,
                # Arkab, Polis or Nunki); the menu, which says what is wrong, when that is not up.
                if not setup_done():
                    return self._send(302, b"", extra={"Location": "/setup"})
                if role_wanted() and role_up():
                    return self._send(302, b"", extra={"Location": "http://localhost:%d/" % ROLE_PORT[running_role()]})
                return self._send(302, b"", extra={"Location": "/menu"})
            if path in ("/boot", "/screen"):
                # The kiosk's first page, and where it waits while Alnasl is away: the boot screen.
                return self._send(200, open(WWW + "/screen.html", "rb").read(), TYPES[".html"])
            if path.startswith("/splash/") and path.endswith(".png"):
                f = os.path.normpath(SPLASH + "/" + path[len("/splash/"):])
                if f.startswith(SPLASH + "/") and os.path.isfile(f):
                    return self._send(200, open(f, "rb").read(), TYPES[".png"], cache="max-age=86400")
                return self._send(404, {"error": "not found"})
            if path.startswith("/api/") or path == "/healthz":
                r = api_get(path, u.query)
                return self._send(200 if r is not None else 404, r if r is not None else {"error": "not found"})
            if path in SPA or path.startswith("/settings/"):
                path = "/index.html"
            f = os.path.normpath(WWW + path)
            if f.startswith(WWW + "/") and os.path.isfile(f):
                ext = os.path.splitext(f)[1]
                return self._send(200, open(f, "rb").read(), TYPES.get(ext, "application/octet-stream"))
            return self._send(404, {"error": "not found"})
        except Exception as e:
            log("GET error", path, repr(e))
            return self._send(500, {"error": "internal error"})

    def do_POST(self):
        # Custom header + JSON body: a page on another origin cannot send this
        # without a CORS preflight, which this server never answers.
        if not self._host_ok() or self.headers.get("X-Alnasl-Setup") != "1":
            self.close_connection = True  # the unread body must not be parsed as the next request
            return self._send(403, {"error": "forbidden"}, extra={"Connection": "close"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 20000:
                return self._send(413, {"error": "too large"})
            b = json.loads(self.rfile.read(n) or b"{}")
            with LOCK:
                r = api_post(self.path.split("?")[0], b)
            return self._send(200 if r is not None else 404, r if r is not None else {"error": "not found"})
        except ValueError as e:  # includes bad JSON and validation errors
            return self._send(400, {"error": str(e)})
        except Exception as e:
            log("POST error", self.path.split("?")[0], type(e).__name__)
            return self._send(500, {"error": "internal error"})


def main():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    ThreadingHTTPServer.request_queue_size = 64
    srv = ThreadingHTTPServer((HOST, PORT), H)
    srv.daemon_threads = True
    log("listening on %s:%d" % (HOST, PORT))
    try:  # a box that has just started: have the log ready before the browser asks for it
        if float(read("/proc/uptime", "9999").split()[0]) < 600:
            bootlog_start()
    except (ValueError, IndexError):
        pass
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
