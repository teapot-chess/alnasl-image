#!/usr/bin/python3
"""Alnasl hall box: the setup hotspot (docs/captive-portal.md).

A box with no screen, no keyboard and no network still has to be told which Wi-Fi to use. So when it
has no network it opens its own Wi-Fi, "Alnasl-setup-XXXX" (WPA2, the password from alnasl-hotspot.txt
on the boot partition), and a phone that joins it gets the setup page shown by its own captive-portal
check. This daemon decides when that hotspot is on, and switches wlan0 between the two things it can
be: a Wi-Fi client (wpa_supplicant) or the access point (hostapd). Never both: the Pi's chip does not do
AP and client at once reliably, and we are not going to find out the hard way in a hall.

    hotspot.py            the daemon (alnasl-hotspot.service)
    hotspot.py --stop     put wlan0 back in client mode (the unit's ExecStopPost)
    hotspot.py --prepare  only the password file and the QR code (used by verify.sh)

When it is on (decide(), tested by scripts/test-hotspot.py):
  - the box has had no network (no Ethernet address, no Wi-Fi client connection) for 60 s after boot
    (5 min if it had one earlier this boot: a hall's router that reboots is not a reason to stop being
    a client): on, until the box gets a network;
  - the box is on Ethernet: on for the first 10 minutes after boot too (wlan0 has nothing else to do);
  - the box is a Wi-Fi client: off;
  - a join from the setup page failed: on again for at least 10 minutes, whatever else holds;
  - when the reason goes but a phone is still connected, it lingers up to 10 minutes;
  - with saved networks and no phone connected, it steps aside now and then (every 5 min, 2 after a
    network was lost) for 45 s so the supplicant can find a network that came back.
The password is never logged, never put on a command line, and hostapd is given the derived key only.
"""
import hashlib
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import time

LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)

BOOT_FILE = "/boot/efi/alnasl-hotspot.txt"
QR_FILE = "/boot/efi/alnasl-hotspot-qr.png"
TEMPLATE = "/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt"
STATE_DIR = "/var/lib/alnasl-setup"
QR_STAMP = STATE_DIR + "/hotspot-qr.stamp"   # a hash of (SSID, password): never the password itself
RUN = "/run/alnasl-hotspot"
ACTIVE = RUN + "/active"                     # exists while the AP is up; the firewall and server.py read it
STATUS = RUN + "/status.json"                # no secrets: what the setup server and the screen show
JOIN_REQ = RUN + "/join.json"                # written by server.py (0600), read and deleted at once here
SCAN_CACHE = RUN + "/scan.json"              # the last client-mode scan, for the page while the AP is up
HOSTAPD_CONF = RUN + "/hostapd.conf"
NET_FILE = "/run/systemd/network/05-alnasl-hotspot.network"
IFACE = "wlan0"
AP_ADDR = "10.42.0.1"
AP_NET = "10.42.0.0/24"
SSID_PREFIX = "Alnasl-setup-"
# No 0/O/o, 1/l/I: a password read off a sticker in a dim hall should not be a vision test.
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
PASSWORD_LEN = 10

BOOT_GRACE = 60          # s after boot before the first decision (a saved network gets this long)
ETH_WINDOW = 600         # s after boot the hotspot stays on beside Ethernet
REGRACE = 300            # s without network before the hotspot, when there was one earlier this boot
HOLD_AFTER_FAIL = 600    # s the hotspot stays on after a failed join from the page
LINGER = 600             # s a connected phone keeps it on after the reason went
PROBE_EVERY = 300        # s between steps aside (saved networks, no phone)
PROBE_EVERY_LOST = 120   # the same, after a network was lost
PROBE_FOR = 45           # s a step aside lasts
JOIN_EXTRA = 15          # s for an address after the association, on top of the 40 of wifi_connect
TICK = 3


def log(*a):
    print("alnasl-hotspot:", *a, flush=True)


# ------------------------------------------------------------ the decision ---
def decide(now, uptime, has_wlan, enabled, eth_up, client_up, ap_on, saved, stations,
           no_net_since, had_network, off_since, hold_until, last_probe):
    """(want_ap, probe, reason). Pure: every input is a number or a bool, every clock is `now`'s.

    no_net_since  when the box last stopped having a network (or the boot)
    off_since     when the reason for the AP went while it was on (None: not yet, so it is now)
    hold_until    a failed join keeps it on until then (0: no)
    last_probe    when the AP last came up or last stepped aside"""
    if not has_wlan:
        return False, False, "no_wlan"
    if not enabled:
        return False, False, "disabled"
    if client_up:
        return False, False, "wifi_client"
    if now < hold_until:
        return True, False, "hold"
    if uptime < BOOT_GRACE:
        return False, False, "boot_grace"
    if eth_up:
        policy, reason = uptime < ETH_WINDOW, "ethernet_window"
    else:
        grace = REGRACE if had_network else BOOT_GRACE
        policy, reason = now - no_net_since >= grace, "no_network"
    if not policy:
        if ap_on and stations > 0 and (off_since is None or now - off_since < LINGER):
            return True, False, "linger"
        return False, False, "ethernet" if eth_up else "waiting"
    if ap_on and not eth_up and saved and stations == 0:
        every = PROBE_EVERY_LOST if had_network else PROBE_EVERY
        if now - last_probe >= every:
            return True, True, "probe"
    return True, False, reason


# ------------------------------------------------------ the password file ---
def gen_password(n=PASSWORD_LEN):
    return "".join(secrets.choice(ALPHABET) for _ in range(n))


def valid_password(p):
    """WPA2's rule for a passphrase: 8 to 63 printable ASCII characters."""
    return isinstance(p, str) and 8 <= len(p) <= 63 and all(32 <= ord(c) <= 126 for c in p)


def parse_file(text):
    """{password, hotspot} from the file's lines. The first PASSWORD= and HOTSPOT= lines count."""
    out = {"password": None, "hotspot": "auto"}
    seen = set()
    for line in text.splitlines():
        line = line.rstrip("\r")
        for key in ("PASSWORD", "HOTSPOT"):
            if line.startswith(key + "=") and key not in seen:
                seen.add(key)
                v = line[len(key) + 1:]
                if key == "PASSWORD":
                    out["password"] = v
                else:
                    out["hotspot"] = "off" if v.strip().lower() in ("off", "uit", "no", "nee", "0") else "auto"
    return out


def render_file(text, password, ssid, note=None):
    """The file with its PASSWORD= and SSID= lines filled in and the box's status line at the end.
    Everything else (the header, the user's own lines) is kept as it was. CRLF, for the PC."""
    out, have_pw, have_ssid = [], False, False
    for line in text.splitlines():
        line = line.rstrip("\r")
        if line.startswith("PASSWORD=") and not have_pw:
            out.append("PASSWORD=" + password)
            have_pw = True
        elif line.startswith("SSID="):
            if not have_ssid:
                out.append("SSID=" + (ssid or ""))
                have_ssid = True
        elif line.startswith("# Box:") and note:
            continue  # the new status line replaces the old one
        else:
            out.append(line)
    while out and out[-1] == "":
        out.pop()
    if not have_pw:
        out.append("PASSWORD=" + password)
    if not have_ssid:
        out.append("SSID=" + (ssid or ""))
    if note:
        out.append("# Box: " + note)
    return "\r\n".join(out) + "\r\n"


def ssid_for(mac):
    hexs = re.sub(r"[^0-9A-Fa-f]", "", mac or "")
    return SSID_PREFIX + (hexs[-4:].upper() if len(hexs) >= 4 else "0000")


def psk_hex(ssid, password):
    return hashlib.pbkdf2_hmac("sha1", password.encode(), ssid.encode(), 4096, 32).hex()


def qr_stamp(ssid, password):
    return hashlib.sha256(("alnasl-hotspot-qr\0%s\0%s" % (ssid, password)).encode()).hexdigest()


def write_fat(path, data):
    """Whole file, then moved over the old one, then synced: a FAT partition and a pulled plug."""
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    getattr(os, "sync", lambda: None)()  # the tests run on a PC too, which has opinions about sync


def prepare(ssid, boot_file=BOOT_FILE, qr_file=QR_FILE, template=TEMPLATE, stamp_file=QR_STAMP, note=None):
    """Makes sure the file exists and holds a valid password (generated and written back when it is
    empty or not valid), that its SSID line is this box's, and that the QR code matches. Returns
    (password, settings). Raises OSError only when nothing can be written at all."""
    try:
        with open(boot_file, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        try:
            with open(template, encoding="utf-8") as f:
                text = f.read()
        except OSError:
            text = "# Alnasl setup hotspot / Alnasl-installatiehotspot\r\nPASSWORD=\r\nSSID=\r\n"
        log("%s was missing; made again from the image's copy" % boot_file)
    st = parse_file(text)
    pw = st["password"] or ""
    pw_stripped = pw.strip()
    if pw_stripped != pw and valid_password(pw_stripped):
        pw = pw_stripped  # a trailing space from a text editor is nobody's intention
    changed_note = note
    if not pw:
        pw = gen_password()
        changed_note = note or "a password was generated, because PASSWORD= was empty"
        log("generated a hotspot password (it is in %s, not here)" % boot_file)
    elif not valid_password(pw):
        pw = gen_password()
        changed_note = "the PASSWORD you wrote was not 8 to 63 plain characters; the box chose this one instead"
        log("the hotspot password in %s was not valid (8-63 printable ASCII); a new one was generated" % boot_file)
    new = render_file(text, pw, ssid, changed_note)
    if new.replace("\r\n", "\n") != text.replace("\r\n", "\n") or not os.path.exists(boot_file):
        write_fat(boot_file, new.encode("utf-8"))
    if ssid:
        stamp = qr_stamp(ssid, pw)
        old = ""
        try:
            with open(stamp_file) as f:
                old = f.read().strip()
        except OSError:
            pass
        if old != stamp or not os.path.exists(qr_file):
            import alnasl_qr
            write_fat(qr_file, alnasl_qr.wifi_png(ssid, pw))
            os.makedirs(os.path.dirname(stamp_file), exist_ok=True)
            with open(stamp_file, "w") as f:
                f.write(stamp + "\n")
            log("wrote the join QR code for %s to %s" % (ssid, qr_file))
    return pw, st


def hostapd_conf(ssid, password, country):
    """WPA2-PSK (CCMP), never open. The key is the derived PSK, so the passphrase is not in it."""
    if not valid_password(password):
        raise ValueError("no valid password: no hotspot (an open one is not an option)")
    if not re.fullmatch(r"[A-Z]{2}", country or ""):
        country = "BE"
    return "\n".join([
        "interface=" + IFACE, "driver=nl80211",
        "ctrl_interface=" + RUN + "/hostapd", "ctrl_interface_group=0",
        "ssid=" + ssid, "utf8_ssid=1", "country_code=" + country, "ieee80211d=1",
        "hw_mode=g", "channel=6", "ieee80211n=1", "wmm_enabled=1", "max_num_sta=8",
        "auth_algs=1", "ignore_broadcast_ssid=0",
        "wpa=2", "wpa_key_mgmt=WPA-PSK", "wpa_pairwise=CCMP", "rsn_pairwise=CCMP",
        "wpa_psk=" + psk_hex(ssid, password),
        "logger_stdout=-1", "logger_stdout_level=2", "logger_syslog=0",
    ]) + "\n"


NETWORK_FILE = """# Written by alnasl-hotspot while the setup hotspot is on; removed when it goes off.
[Match]
Name=%s

[Network]
Address=%s/24
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no
MulticastDNS=no
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
""" % (IFACE, AP_ADDR)


# ---------------------------------------------------------- the box itself ---
def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except Exception as e:  # noqa: BLE001  (missing binary, timeout)
        return 127, str(e)


def sysctl(*a):
    return run(["systemctl", *a], 90)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def ipv4(iface):
    rc, out = run(["ip", "-j", "-4", "addr", "show", "dev", iface], 10)
    try:
        return [a["local"] for a in json.loads(out)[0]["addr_info"] if a.get("scope") == "global"]
    except (ValueError, IndexError, KeyError):
        return []


def eth_up():
    for n in sorted(os.listdir("/sys/class/net")):
        if n.startswith("e") and read("/sys/class/net/%s/carrier" % n).strip() == "1" and ipv4(n):
            return True
    return False


def client_up():
    rc, out = run(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", IFACE, "status"], 10)
    if "wpa_state=COMPLETED" not in out:
        return False
    net = ipaddress.ip_network(AP_NET)
    return any(ipaddress.ip_address(a) not in net for a in ipv4(IFACE))


def stations():
    rc, out = run(["iw", "dev", IFACE, "station", "dump"], 10)
    return len(re.findall(r"(?m)^Station ", out)) if rc == 0 else 0


def write_status(**kw):
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    tmp = STATUS + ".new"
    with open(tmp, "w") as f:
        json.dump(kw, f)
    os.replace(tmp, STATUS)


class Hotspot:
    def __init__(self):
        import server  # the setup server's functions, in this process (wifi_scan, wifi_connect, parse_wpa)
        self.srv = server
        self.ap_on = False
        self.ssid = None
        self.password = None
        self.enabled = True
        self.boot = time.time() - float(read("/proc/uptime", "0").split()[0] or 0)
        self.no_net_since = self.boot
        self.had_network = False
        self.off_since = None
        self.hold_until = 0.0
        self.last_probe = 0.0
        self.fail_until = 0.0
        self.reason = "starting"
        self.last_join = None
        os.makedirs(RUN, mode=0o700, exist_ok=True)

    # -- wlan0, one way or the other ---------------------------------------------------------------
    def client_mode(self):
        """Everything the AP needed, gone; the supplicant back. Safe to call any time."""
        try:
            os.remove(ACTIVE)
        except OSError:
            pass
        run(["/usr/local/sbin/alnasl-firewall", "reload"], 60)
        for u in ("alnasl-portal.service", "alnasl-hotspot-dns.service", "alnasl-hotspot-ap.service"):
            sysctl("stop", u)
        if os.path.exists(NET_FILE):
            os.remove(NET_FILE)
            run(["networkctl", "reload"])
        run(["ip", "-4", "addr", "flush", "dev", IFACE], 10)
        run(["networkctl", "reconfigure", IFACE])
        if os.path.exists("/sys/class/net/" + IFACE):
            if not os.path.exists(self.srv.WPA_CONF):
                self.srv.write_wpa("BE", [])
            sysctl("restart", "wpa_supplicant@%s.service" % IFACE)
        self.ap_on = False

    def ap_mode(self):
        """The supplicant stopped, the address, hostapd, then DNS/DHCP and the page, then the firewall
        opens 53/67/80 on wlan0. False (and back to client mode) when any of it does not come up."""
        country = self.srv.parse_wpa()[0] or "BE"
        try:
            conf = hostapd_conf(self.ssid, self.password, country.upper())
        except ValueError as e:
            log(str(e))
            return False
        # A scan while the supplicant still has the radio: the page shows it while the AP has it.
        try:
            res = self.srv.wifi_scan()
            with open(SCAN_CACHE, "w") as f:
                json.dump({"t": time.time(), "networks": res.get("networks", [])}, f)
        except Exception as e:  # noqa: BLE001
            log("scan before the hotspot failed:", type(e).__name__)
        sysctl("stop", "wpa_supplicant@%s.service" % IFACE)
        run(["pkill", "-x", "wpa_supplicant"])
        try:
            os.remove("/run/wpa_supplicant/" + IFACE)
        except OSError:
            pass
        fd = os.open(HOSTAPD_CONF + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(conf)
        os.replace(HOSTAPD_CONF + ".new", HOSTAPD_CONF)
        os.makedirs(os.path.dirname(NET_FILE), exist_ok=True)
        with open(NET_FILE, "w") as f:
            f.write(NETWORK_FILE)
        run(["networkctl", "reload"])
        run(["ip", "link", "set", "dev", IFACE, "up"], 10)
        rc, out = sysctl("restart", "alnasl-hotspot-ap.service")
        ok = False
        for _ in range(20):
            time.sleep(1)
            if sysctl("is-active", "alnasl-hotspot-ap.service")[1].strip() != "active":
                continue
            run(["networkctl", "reconfigure", IFACE])
            if AP_ADDR in ipv4(IFACE):
                ok = True
                break
        if not ok:
            run(["ip", "addr", "replace", AP_ADDR + "/24", "dev", IFACE], 10)  # networkd being shy
            ok = AP_ADDR in ipv4(IFACE) and sysctl("is-active", "alnasl-hotspot-ap.service")[1].strip() == "active"
        if not ok:
            log("the access point did not come up (hostapd or the address); staying a Wi-Fi client")
            self.client_mode()
            return False
        # Nothing from the hotspot is forwarded anywhere: no NAT, and not even routing (docker turns
        # forwarding on for its own bridge; this interface is not that).
        run(["sysctl", "-q", "-w", "net.ipv4.conf.%s.forwarding=0" % IFACE], 10)
        for u in ("alnasl-hotspot-dns.service", "alnasl-portal.service"):
            if sysctl("restart", u)[0] != 0:
                log("%s did not start; the hotspot goes without it" % u)
        with open(ACTIVE, "w") as f:
            f.write("%s %s\n" % (IFACE, AP_ADDR))
        run(["/usr/local/sbin/alnasl-firewall", "reload"], 60)
        self.ap_on = True
        self.last_probe = time.time()
        log("hotspot %s is on (%s); the setup page is http://%s/" % (self.ssid, self.reason, AP_ADDR))
        return True

    # -- the page asked for a network ---------------------------------------------------------------
    def take_join(self):
        try:
            fd = os.open(JOIN_REQ, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        try:
            with os.fdopen(fd) as f:
                req = json.load(f)
        except (OSError, ValueError):
            req = None
        try:
            os.remove(JOIN_REQ)
        except OSError:
            pass
        return req if isinstance(req, dict) and req.get("ssid") else None

    def join(self, req):
        ssid = str(req.get("ssid"))
        log('a network was chosen on the setup page: "%s"; the hotspot steps aside to try it' % ssid)
        self.reason = "joining"
        self.status()
        if self.ap_on:
            self.client_mode()
        time.sleep(2)
        try:
            r = self.srv.wifi_connect(ssid, str(req.get("passphrase") or ""), bool(req.get("hidden")),
                                      str(req.get("country") or "BE"))
        except ValueError as e:
            r = {"ok": False, "reason": "bad_request", "detail": str(e)}
        req.clear()  # the passphrase goes out of this process's memory as far as Python lets it
        ip = r.get("ip") if r.get("ok") else None
        if r.get("ok") and not ip:
            for _ in range(JOIN_EXTRA):
                time.sleep(1)
                ip = self.srv.wlan_ip()
                if ip:
                    break
            if not ip:
                r = {"ok": False, "reason": "no_address"}
        now = time.time()
        host = self.srv.socket.gethostname()
        if r.get("ok"):
            self.last_join = {"ok": True, "ssid": ssid, "ip": ip, "host": host, "at": now}
            log('joined "%s" (%s); the hotspot stays off' % (ssid, ip))
            self.note('joined Wi-Fi "%s" on %s: address %s, name %s.local' % (ssid, time.strftime("%Y-%m-%d %H:%M"), ip, host))
            self.had_network = True
        else:
            self.last_join = {"ok": False, "ssid": ssid, "reason": r.get("reason", "failed"), "at": now}
            self.hold_until = now + HOLD_AFTER_FAIL
            log('joining "%s" did not work (%s); the hotspot comes back' % (ssid, self.last_join["reason"]))
        self.status()

    def note(self, text):
        try:
            prepare(self.ssid, note=text)
        except OSError as e:
            log("could not write to the boot partition:", e)

    def status(self):
        write_status(active=self.ap_on, ssid=self.ssid, reason=self.reason, address=AP_ADDR,
                     portal="http://%s/" % AP_ADDR, last_join=self.last_join, enabled=self.enabled,
                     updated=time.time())

    # -- the loop -----------------------------------------------------------------------------------
    def setup_identity(self):
        mac = read("/sys/class/net/%s/address" % IFACE).strip()
        self.ssid = ssid_for(mac) if mac else None
        try:
            self.password, st = prepare(self.ssid)
            self.enabled = st["hotspot"] != "off"
        except OSError as e:
            log("the boot partition cannot be read or written (%s); no hotspot" % e)
            self.password = None

    def loop(self):
        if os.path.exists(ACTIVE) or os.path.exists(NET_FILE):
            log("a hotspot of an earlier run was still up; put back to client mode first")
            self.client_mode()
        self.setup_identity()
        while True:
            now = time.time()
            uptime = now - self.boot
            req = self.take_join()
            if req:
                self.join(req)
                continue
            has_wlan = os.path.exists("/sys/class/net/" + IFACE) and self.password is not None
            if has_wlan and not self.ssid:
                self.setup_identity()
            e, c = eth_up(), (False if self.ap_on else client_up())
            if e or c:
                self.had_network = True
                self.no_net_since = now
                if os.path.exists(self.srv.ARKAB_PENDING):  # a join link from the page, waiting for a network
                    try:
                        res = self.srv.arkab_join_pending()
                        if res:
                            self.note("Arkab's join link from the setup page: %s" % res)
                    except Exception as ex:  # noqa: BLE001  (Arkab is a separate program; this loop is not its keeper)
                        log("handing the join link to Arkab failed:", type(ex).__name__)
            st = stations() if self.ap_on else 0
            saved = bool(self.srv.parse_wpa()[1])
            want, probe, reason = decide(now, uptime, has_wlan, self.enabled, e, c, self.ap_on, saved, st,
                                         self.no_net_since, self.had_network, self.off_since,
                                         self.hold_until, self.last_probe)
            self.off_since = (self.off_since or now) if reason == "linger" else None
            self.reason = reason
            if probe:
                log("stepping aside for %d s so a saved network can be found" % PROBE_FOR)
                self.client_mode()
                found = False
                for _ in range(PROBE_FOR // TICK):
                    time.sleep(TICK)
                    if client_up():
                        found = True
                        break
                self.last_probe = time.time()
                if found:
                    log("a saved network answered; the hotspot stays off")
                    self.had_network, self.no_net_since = True, time.time()
                else:
                    self.ap_mode()
            elif want and not self.ap_on and now >= self.fail_until:
                if not self.ap_mode():
                    self.fail_until = now + 120
            elif not want and self.ap_on:
                log("hotspot off (%s)" % reason)
                self.client_mode()
                self.off_since = None
            self.status()
            time.sleep(TICK)


def main(argv):
    if "--prepare" in argv:
        mac = read("/sys/class/net/%s/address" % IFACE).strip()
        prepare(ssid_for(mac) if mac else None)
        return 0
    h = Hotspot()
    if "--stop" in argv:
        h.client_mode()
        write_status(active=False, ssid=None, reason="stopped", address=AP_ADDR, portal=None,
                     last_join=None, enabled=False, updated=time.time())
        return 0
    h.loop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
