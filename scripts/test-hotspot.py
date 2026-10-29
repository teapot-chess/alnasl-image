#!/usr/bin/env python3
"""Tests of the setup hotspot's logic (docs/captive-portal.md): when it is on, its password file and QR
code, hostapd's configuration, what the captive portal passes on, and the checks on what a phone sends.

    python3 scripts/test-hotspot.py [lib dir]     (default: the overlay's usr/local/lib/alnasl-setup)

None of it needs a radio, which is as well: qemu has none, and the Wi-Fi itself is on the hardware
checklist in docs/captive-portal.md. Runs on the PC and in verify.sh (on the image's own Python).
"""
import contextlib
import hashlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "overlay", "usr", "local", "lib", "alnasl-setup")
TEMPLATE = os.path.join(HERE, "..", "overlay", "boot-efi", "alnasl-hotspot.txt")
if not os.path.exists(TEMPLATE):  # inside the image: the copy assemble.sh keeps
    TEMPLATE = "/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt"
sys.dont_write_bytecode = True
sys.path.insert(0, LIB)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


hs = load("hotspot")
portal = load("portal")
arkab_live = load("arkab_live")
fails = 0


def check(cond, what):
    global fails
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails += 1


# ------------------------------------------------------------------ decide() ---
def d(now=10000.0, uptime=1000.0, has_wlan=True, enabled=True, eth=False, client=False, ap_on=False, saved=False,
      stations=0, no_net_since=None, had_network=False, off_since=None, hold_until=0.0, last_probe=None):
    boot = now - uptime
    return hs.decide(now, uptime, has_wlan, enabled, eth, client, ap_on, saved, stations,
                     boot if no_net_since is None else no_net_since, had_network, off_since, hold_until,
                     now if last_probe is None else last_probe)


check(d(uptime=30)[0] is False and d(uptime=30)[2] == "boot_grace", "(a) no network, 30 s after boot: not yet")
check(d(uptime=61) == (True, False, "no_network"), "(a) no network, 61 s after boot: on")
check(d(uptime=5000)[0] is True, "(a) still no network an hour later: still on")
check(d(uptime=61, eth=True) == (True, False, "ethernet_window"), "(b) Ethernet, 61 s after boot: on")
check(d(uptime=599, eth=True, ap_on=True)[0] is True, "(b) Ethernet, 599 s: still on")
check(d(uptime=601, eth=True, ap_on=True) == (False, False, "ethernet"), "(b) Ethernet, 601 s, nobody on it: off")
check(d(uptime=601, eth=True, ap_on=True, stations=1) == (True, False, "linger"), "(b) Ethernet, 601 s, a phone on it: lingers")
check(d(uptime=601, eth=True, ap_on=True, stations=1, off_since=10000.0 - 599)[0] is True, "linger: 599 s in, still on")
check(d(uptime=601, eth=True, ap_on=True, stations=1, off_since=10000.0 - 601)[0] is False, "linger: 601 s in, off even with a phone")
check(d(uptime=601, eth=True, ap_on=False, stations=1)[0] is False, "linger never turns an AP on")
check(d(client=True) == (False, False, "wifi_client"), "(c) Wi-Fi client: off")
check(d(client=True, ap_on=True, stations=3)[0] is False, "(c) Wi-Fi client: off, phones or not (it cannot be both)")
check(d(uptime=30, hold_until=10000.0 + 5) == (True, False, "hold"), "a failed join holds it on, even in the boot grace")
check(d(eth=True, uptime=5000, hold_until=10000.0 + 5)[0] is True, "a failed join holds it on beside Ethernet too")
check(d(eth=True, uptime=5000, hold_until=10000.0 - 1)[0] is False, "and lets go when the hold is over")
check(d(client=True, hold_until=10000.0 + 5)[0] is False, "a join that worked after all beats the hold")
check(d(enabled=False) == (False, False, "disabled"), "HOTSPOT=off: off")
check(d(has_wlan=False) == (False, False, "no_wlan"), "no wlan0 (or no password): off")
check(d(had_network=True, no_net_since=10000.0 - 100) == (False, False, "waiting"), "lost the network 100 s ago: not yet (the router may be rebooting)")
check(d(had_network=True, no_net_since=10000.0 - 301)[0] is True, "lost the network 301 s ago: on")
check(d(ap_on=True, saved=True, last_probe=10000.0 - 301) == (True, True, "probe"), "saved networks, nobody on: steps aside after 5 min")
check(d(ap_on=True, saved=True, last_probe=10000.0 - 200)[1] is False, "but not after 200 s")
check(d(ap_on=True, saved=True, had_network=True, no_net_since=9000.0, last_probe=10000.0 - 121)[1] is True, "after a lost network: every 2 min")
check(d(ap_on=True, saved=True, stations=1, last_probe=0.0)[1] is False, "never steps aside under a phone")
check(d(ap_on=True, saved=False, last_probe=0.0)[1] is False, "nothing saved: nothing to step aside for")
check(d(ap_on=True, saved=True, eth=True, uptime=200, last_probe=0.0)[1] is False, "not beside Ethernet either")


# Ten minutes of a box on Ethernet, with a phone that arrives late, through the daemon's own bookkeeping.
def simulate(eth, phone_from, until, step=3):
    ap, off_since, timeline = False, None, []
    for t in range(0, until, step):
        st = 1 if (ap and phone_from is not None and t >= phone_from) else 0
        want, probe, reason = hs.decide(1e6 + t, t, True, True, eth, False, ap, False, st, 1e6, False, off_since, 0.0, 1e6)
        off_since = (off_since or 1e6 + t) if reason == "linger" else None
        if want != ap:
            timeline.append((t, want, reason))
            ap = want
    return timeline


tl = simulate(True, None, 1500)
check([w for _, w, _ in tl] == [True, False] and 60 <= tl[0][0] <= 63 and 600 <= tl[1][0] <= 603, "Ethernet run: on at ~60 s, off at ~600 s: %s" % tl)
tl = simulate(True, 300, 1500)
check([w for _, w, _ in tl] == [True, False] and 1200 <= tl[1][0] <= 1206, "Ethernet run with a phone: off at ~600 s + 10 min linger: %s" % tl)
tl = simulate(False, None, 3000)
check(len(tl) == 1 and tl[0][1] is True, "no network run: on at ~60 s and stays on: %s" % tl)

# ------------------------------------------------------- the password file ---
for _ in range(200):
    p = hs.gen_password()
    if not (len(p) == 10 and hs.valid_password(p) and not set(p) & set("0Oo1lI")):
        break
check(len(p) == 10 and not set(p) & set("0Oo1lI"), "generated passwords: 10 characters, no 0/O/1/l")
check(hs.valid_password("x" * 8) and hs.valid_password("x" * 63), "8 and 63 characters are valid")
check(not hs.valid_password("x" * 7) and not hs.valid_password("x" * 64), "7 and 64 are not")
check(not hs.valid_password("abcdefgé") and not hs.valid_password("abc\tdefgh"), "non-ASCII and tabs are not")
check(hs.ssid_for("dc:a6:32:12:ab:cd") == "Alnasl-setup-ABCD", "SSID from the MAC: Alnasl-setup-ABCD")
check(hs.parse_file("PASSWORD=x\r\nHOTSPOT=uit\r\n")["hotspot"] == "off", "HOTSPOT=uit is off")
check(hs.parse_file("PASSWORD=x\nHOTSPOT=auto\n")["hotspot"] == "auto", "HOTSPOT=auto is auto")

tmp = tempfile.mkdtemp()
try:
    bf, qf, sf = (os.path.join(tmp, n) for n in ("alnasl-hotspot.txt", "alnasl-hotspot-qr.png", "state/qr.stamp"))
    tpl = open(TEMPLATE, encoding="utf-8").read()
    check("PASSWORD=" in tpl and "WACHTWOORD" not in tpl and "wachtwoord" in tpl and "QR" in tpl and "serienummer" in tpl and "serial number" in tpl,
          "the template has its English and Dutch header, the QR and the serial-number note")
    check([l for l in tpl.splitlines() if l.startswith("PASSWORD=")] == ["PASSWORD="], "the template ships with an empty PASSWORD=")
    shutil.copy(TEMPLATE, bf)

    def prep(**kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            pw, st = hs.prepare("Alnasl-setup-ABCD", boot_file=bf, qr_file=qf, template=TEMPLATE, stamp_file=sf, **kw)
        return pw, st, out.getvalue()

    pw, st, out = prep()
    text = open(bf, "rb").read().decode()
    check(hs.valid_password(pw) and ("PASSWORD=%s\r\n" % pw) in text, "an empty PASSWORD= gets a generated one, written back")
    check("SSID=Alnasl-setup-ABCD\r\n" in text, "the file names the SSID")
    check("\n" not in text.replace("\r\n", ""), "the file is CRLF throughout")
    check(text.startswith("# ALNASL SETUP HOTSPOT"), "the header is kept")
    check("# Box: a password was generated" in text, "and it says what it did")
    check(pw not in out, "the generated password is not in the log")
    check(os.path.exists(qf), "the QR code is written")
    qr1, mt = open(qf, "rb").read(), os.path.getmtime(qf)
    check(qr1[:8] == b"\x89PNG\r\n\x1a\n", "the QR code is a plain PNG")
    payload = "WIFI:T:WPA;S:Alnasl-setup-ABCD;P:%s;;" % pw
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "test-qr.py"), os.path.join(LIB, "alnasl_qr.py"), qf, payload],
                       capture_output=True, text=True)
    check(r.returncode == 0 and "decodes to the expected payload" in r.stdout, "the QR decodes to %s" % payload.replace(pw, "<password>"))

    pw2, _, out = prep()
    check(pw2 == pw and open(bf, "rb").read().decode() == text, "a second boot changes nothing")
    check(open(qf, "rb").read() == qr1 and os.path.getmtime(qf) == mt, "and does not rewrite the QR code")
    check(open(sf).read().strip() == hs.qr_stamp("Alnasl-setup-ABCD", pw) and pw not in open(sf).read(), "the stamp is a hash, not the password")

    with contextlib.redirect_stdout(io.StringIO()):
        hs.prepare("Alnasl-setup-EF01", boot_file=bf, qr_file=qf, template=TEMPLATE, stamp_file=sf)
    check(open(qf, "rb").read() != qr1 and "SSID=Alnasl-setup-EF01" in open(bf).read(), "another SSID (the card in another box): new QR, new SSID line")

    def set_pw(value):
        t = open(bf, "rb").read().decode()
        t = "\r\n".join(("PASSWORD=" + value) if l.startswith("PASSWORD=") else l for l in t.split("\r\n"))
        open(bf, "wb").write(t.encode())

    set_pw("Our hall; 2026, \"main\"")
    pw3, _, out = prep()
    check(pw3 == "Our hall; 2026, \"main\"", "an own password is kept as written")
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "test-qr.py"), os.path.join(LIB, "alnasl_qr.py"), qf,
                        'WIFI:T:WPA;S:Alnasl-setup-ABCD;P:Our hall\\; 2026\\, \\"main\\";;'], capture_output=True, text=True)
    check(r.returncode == 0, "its QR code escapes ; , and \" (WIFI: syntax)")
    check(pw3 not in out, "an own password is not in the log")
    set_pw("short")
    pw4, _, out = prep()
    t4 = open(bf).read()
    check(pw4 != "short" and hs.valid_password(pw4) and "was not 8 to 63" in t4, "a 5-character password is replaced, and the file says why")
    check("short" not in out and pw4 not in out, "neither the bad nor the new password is in the log")
    set_pw("trailing space ok ")
    pw5, _, _ = prep()
    check(pw5 == "trailing space ok", "a trailing space from an editor is dropped")
    prep(note="joined Wi-Fi \"Hall\"")
    pw6, _, _ = prep()
    check(pw6 == pw5 and [l for l in open(bf).read().splitlines() if l.startswith("# Box:")] == ['# Box: joined Wi-Fi "Hall"'] and "joined Wi-Fi" in open(bf).read(), "a note stays across boots, one line of it")
    os.remove(bf)
    pw7, _, _ = prep()
    check(os.path.exists(bf) and hs.valid_password(pw7) and "# ALNASL SETUP HOTSPOT" in open(bf).read(), "a deleted file is made again from the template")

    # ------------------------------------------------------------------ hostapd ---
    conf = hs.hostapd_conf("Alnasl-setup-ABCD", pw7, "BE")
    lines = dict(l.split("=", 1) for l in conf.splitlines())
    check(lines.get("wpa") == "2" and lines.get("wpa_key_mgmt") == "WPA-PSK" and lines.get("rsn_pairwise") == "CCMP", "hostapd: WPA2-PSK, CCMP")
    check(lines.get("wpa_psk") == hashlib.pbkdf2_hmac("sha1", pw7.encode(), b"Alnasl-setup-ABCD", 4096, 32).hex(), "hostapd: the derived key")
    check("wpa_passphrase" not in conf and pw7 not in conf, "hostapd: no passphrase in its file")
    check(lines.get("interface") == "wlan0" and lines.get("country_code") == "BE", "hostapd: wlan0, the country")
    sneaky = hs.hostapd_conf("Alnasl-setup-ABCD", pw7, "NL\nwpa=0")
    check("country_code=BE\n" in sneaky and "wpa=0" not in sneaky, "hostapd: a country with a line in it becomes BE and smuggles nothing in")
    for bad in ("", None, "short", "x" * 64):
        try:
            hs.hostapd_conf("Alnasl-setup-ABCD", bad, "BE")
            check(False, "hostapd refuses the password %r" % (bad,))
        except ValueError:
            check(True, "hostapd refuses the password %r (no open hotspot)" % (bad,))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# --------------------------------------------------------------- the portal ---
PROBES = [("captive.apple.com", "/hotspot-detect.html"), ("www.apple.com", "/library/test/success.html"),
          ("connectivitycheck.gstatic.com", "/generate_204"), ("clients3.google.com", "/generate_204"),
          ("connectivitycheck.android.com", "/generate_204"), ("www.google.com", "/gen_204"),
          ("www.msftconnecttest.com", "/connecttest.txt"), ("www.msftncsi.com", "/ncsi.txt"),
          ("www.msftconnecttest.com", "/redirect"), ("detectportal.firefox.com", "/canonical.html"),
          ("detectportal.firefox.com", "/success.txt"), ("nmcheck.gnome.org", "/check_network_status.txt"),
          ("example.com", "/"), ("10.42.0.2", "/"), ("", "/"), (None, "/")]
for host, path in PROBES:
    r = portal.route("GET", host, path)
    check(r == ("redirect", "http://10.42.0.1/"), "probe %s%s: a redirect to the page (never a 204, never 'Success')" % (host, path))
check(portal.route("POST", "captive.apple.com", "/api/portal/join")[0] == "redirect", "a POST to another host is not passed on")
check(portal.route("GET", "10.42.0.1", "/")[0] == "static" and portal.route("GET", "10.42.0.1:80", "/")[0] == "static", "the page itself")
check(portal.route("GET", "10.42.0.1", "/api/captive") == ("captive",), "RFC 8908 API")
check(portal.route("GET", "10.42.0.1", "/api/portal") == ("pass", "/api/portal"), "GET /api/portal is passed on")
check(portal.route("POST", "10.42.0.1", "/api/portal/join") == ("pass", "/api/portal/join"), "POST /api/portal/join is passed on")
for m, p in [("GET", "/api/diag"), ("GET", "/api/hotspot"), ("GET", "/api/mode"), ("POST", "/api/mode"), ("POST", "/api/factory-reset"),
             ("POST", "/api/power"), ("POST", "/api/system"), ("POST", "/api/wifi/connect"), ("POST", "/api/wifi/forget"),
             ("GET", "/api/portal/../diag"), ("POST", "/"), ("PUT", "/api/portal/join"), ("GET", "/api/portal/join")]:
    check(portal.route(m, "10.42.0.1", p) == ("forbidden",), "%s %s: forbidden on the hotspot" % (m, p))
allowed = set(portal.PASS_GET) | set(portal.PASS_POST)
check(all(p.startswith("/api/portal") for p in allowed), "everything passed on is /api/portal*: %s" % sorted(allowed))
check(not [p for p in allowed if any(w in p for w in ("reset", "power", "mode", "system", "update", "diag", "hotspot", "forget"))],
      "nothing destructive is passed on (and not /api/hotspot, which shows the password)")
check(portal.ADDR == "10.42.0.1" and portal.SETUP == ("127.0.0.1", 4041), "the portal listens on 10.42.0.1 and talks to 127.0.0.1:4041")

# -------------------------------------------------- what a phone may send ---
for good in ("https://arkab.example.org/join/AbC_12-x", "http://10.0.0.5:4006/join/k3y"):
    check(arkab_live.valid_link(good) == good, "join link accepted: %s" % good)
check(arkab_live.valid_link(" https://x.org/join/abc\n") == "https://x.org/join/abc", "a pasted link loses the whitespace around it")
for bad in ("javascript:alert(1)", "https://x.org/join/abc?x=1", "https://x.org/join/a\nbc", "ftp://x.org/join/abc",
            "https://x.org/other/abc", "https://user@x.org/join/abc", "https://x.org/join/" + "a" * 65, ""):
    check(not arkab_live.valid_link(bad), "join link refused: %r" % bad)

try:
    server = load("server")
except Exception as e:  # noqa: BLE001  (a PC without the box's modules)
    server = None
    check(os.name == "nt", "server.py imports (%s)" % e)
if server:
    for good in ("4821", "a" * 64, "my pin, with spaces"):
        check(server.arkab_pin_check(good) == good, "PIN accepted: %r" % good[:20])
    for bad, why in (("123", "pin_length"), ("a" * 65, "pin_length"), (" 1234", "pin_edges"), ("1234 ", "pin_edges"),
                     ('"1234', "pin_edges"), ("1234'", "pin_edges"), ("12\n34", "pin_control"), ("12\x7f34", "pin_control"),
                     ("remove", "pin_word"), ("Verwijderen", "pin_word"), (None, "pin_length"), (1234, "pin_length")):
        try:
            server.arkab_pin_check(bad)
            check(False, "PIN refused: %r" % (bad,))
        except ValueError as e:
            check(str(e) == why, "PIN refused: %r (%s)" % (bad, e))
    for args, ok in ((("Hall", "12345678", "BE"), True), (("Hall", "", "nl"), True), (("", "12345678", "BE"), False),
                     (("x" * 33, "12345678", "BE"), False), (("Hall", "1234567", "BE"), False), (("Hall", "12345678", "B1"), False)):
        try:
            server.validate_wifi(*args)
            check(ok, "Wi-Fi %r accepted" % (args[0][:10],))
        except ValueError:
            check(not ok, "Wi-Fi %r refused" % (args[0][:10],))

print("RESULT:", "FAILED (%d)" % fails if fails else "all hotspot checks passed")
sys.exit(1 if fails else 0)
