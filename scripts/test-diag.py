"""Unit test for the diagnostics redaction, run by verify.sh inside the image (image python).

Builds a fake wpa_supplicant configuration with a hashed psk, a clear
passphrase (also as a commented-out line) and an open network, plus a fake
Tailscale auth key, feeds them to every path that ends up in the diagnostics
(summary, section texts, journals, saved file) and fails if any secret
survives or if an SSID is lost.
"""
import importlib.util
import os
import re
import sys
import tempfile

sys.path.insert(0, "/usr/local/lib/alnasl-setup")
import diag  # noqa: E402

spec = importlib.util.spec_from_file_location("server", "/usr/local/lib/alnasl-setup/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

PSK = "5f4dcc3b5aa765d61d8327deb882cf995f4dcc3b5aa765d61d8327deb882cf99"
CLEAR = "SuperSecretPassw0rd!"
TSKEY = "tskey-auth-kABCDE12CNTRL-abcdefghijklmnop1234567890"
LOGIN = "https://login.tailscale.com/a/1a2b3c4d5e6f"
SECRETS = [PSK, CLEAR, TSKEY, "1a2b3c4d5e6f"]

tmp = tempfile.mkdtemp()
conf = os.path.join(tmp, "wpa.conf")
with open(conf, "w") as f:
    f.write('ctrl_interface=/run/wpa_supplicant\nupdate_config=0\ncountry=BE\n'
            'network={\n\tssid=486f6d654e6574\n\tpsk=%s\n\tpriority=1\n}\n'
            'network={\n\tssid="Cafe Guest"\n\t#psk="%s"\n\tpsk="%s"\n\tscan_ssid=1\n}\n'
            'network={\n\tssid="OpenNet"\n\tkey_mgmt=NONE\n}\n' % (PSK, CLEAR, CLEAR))
server.WPA_CONF = conf

fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def leaked(text):
    return [s for s in SECRETS if s in text]


# 1. the Wi-Fi summary (what the diagnostics may say about the configuration)
summ = server.wpa_summary()
stext = summ["country"] + "\n" + "\n".join(summ["lines"])
check(not leaked(stext) and "psk" not in stext.lower(), "wpa_summary has no key material")
check("HomeNet" in stext and "Cafe Guest" in stext and "OpenNet" in stext, "wpa_summary lists the SSIDs")
check("country" in summ and summ["country"] == "BE", "wpa_summary has the country")

# 2. redact() on every shape a secret can have
samples = [
    "psk=%s" % PSK, '\tpsk="%s"' % CLEAR, '\t#psk="%s"' % CLEAR, "passphrase: %s" % CLEAR, "PASSPHRASE=%s" % CLEAR,
    "tailscale up --authkey=%s --hostname=x" % TSKEY, "tailscale up --auth-key %s" % TSKEY, "TS_AUTHKEY=%s" % TSKEY,
    "Visit %s to log in" % LOGIN, "key tskey-client-kXYZ-0123456789abcdef used", "wpa_passphrase HomeNet %s" % CLEAR,
    "pmk %s derived" % PSK, "sae_password=%s" % CLEAR, "wep_key0=%s" % CLEAR,
]
for s in samples:
    r = diag.redact(s)
    check(not leaked(r), "redact(%r) -> %r" % (s[:34], r[:60]))
check("486f6d654e6574" in diag.redact("ssid=486f6d654e6574"), "a hex SSID is kept")
check("Cafe Guest" in diag.redact('ssid="Cafe Guest"'), "a quoted SSID is kept")

# 3. the whole report, with every command and every file read answering with secrets
secret_blob = ("line one\npsk=%s\n\tpsk=\"%s\"\nkey %s\nlogin %s\nwpa_passphrase HomeNet %s\nTS_AUTHKEY=%s\nssid=486f6d654e6574\n"
               % (PSK, CLEAR, PSK, LOGIN, CLEAR, TSKEY))
diag.runo = lambda cmd, timeout=15: (0, secret_blob)
diag.read = lambda path, default="": secret_blob
info = diag.collect(summ, "last scan\n" + secret_blob, {"ping": "x"})
jl = diag.journals()
rep = diag.report_text(info, jl, {"hostname": "alnasl-test", "note": secret_blob})
check(not leaked(rep), "the full report has no secret (%d bytes)" % len(rep))
check("HomeNet" in rep and "486f6d654e6574" in rep, "the report keeps SSIDs")
check(all(not leaked(s["text"]) for s in info["sections"]) and all(not leaked(j["text"]) for j in jl), "sections and journals are clean on their own")
check({s["id"] for s in info["sections"]} == {"wifi", "network", "role", "services", "kiosk", "updates"}, "the six sections exist (v7.1: the role)")
check(all(c["id"] in ("driver", "hardware", "firmware", "interface", "link", "supplicant") for c in info["checks"]), "the check ids are known")

# 4. the file on the 'boot partition' (a temp directory here)
name = diag.save_report(rep, boot=tmp)
check(re.fullmatch(r"alnasl-diagnostics-\d{8}-\d{6}\.txt", name) is not None, "file name %s" % name)
data = open(os.path.join(tmp, name), "rb").read().decode()
check(not leaked(data), "the saved file has no secret")
check("\r\n" in data, "the saved file has Windows line endings")

print("RESULT:", "FAILED: %s" % fails if fails else "all redaction checks passed")
sys.exit(1 if fails else 0)
