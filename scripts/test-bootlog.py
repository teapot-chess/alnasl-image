#!/usr/bin/env python3
"""Tests of what the v7 boot screen may show (overlay/usr/local/lib/alnasl-setup/bootlog.py).

    python3 scripts/test-bootlog.py [path/to/bootlog.py]

The screen stands in a public hall: a secret that reaches it is in somebody's photo. So every kind of
secret the box knows of is tried here, and so are the lines that must stay readable (a failed unit is
never hidden). Runs on the PC and in verify.sh (on the image's own Python).
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "overlay", "usr", "local", "lib", "alnasl-setup", "bootlog.py")
spec = importlib.util.spec_from_file_location("bootlog", path)
b = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(b)

fails = 0


def check(cond, what):
    global fails
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        fails += 1


def shown(msg):
    return b.ascii_line(b.redact(msg))


# --- secrets never reach the screen -------------------------------------------------------------------
SECRETS = [
    ('psk="hunter2hunter2" key_mgmt=WPA-PSK', "hunter2hunter2"),
    ("wlan0: passphrase=CorrectHorse ssid=Hall", "CorrectHorse"),
    ("wpa_passphrase Hall S3cretWifi!", "S3cretWifi"),
    ("sae_password=zxcvbnm123", "zxcvbnm123"),
    ("psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef"),
    ("password: letmein99", "letmein99"),
    ('{"token": "tok_live_abc"}', "tok_live_abc"),
    ("api_key=k-1234-5678", "k-1234-5678"),
    ("Authorization: Bearer abc.def.ghi", "abc.def.ghi"),
    ("sent with bearer qwertyuiop12", "qwertyuiop12"),
    ("Set-Cookie: _alnasl_key=SFMyNTY.g3QAAAAB; path=/", "SFMyNTY"),
    ("cookie=abcdef; secret_key_base=xyz789", "xyz789"),
    ("fetch https://admin:pa55word@updates.example.org/index.json", "pa55word"),
    ("GET https://pairings.cloud/join?token=Zx81kQ", "Zx81kQ"),
    ("GET /api/join?t=Zx81kQ HTTP/1.1", "Zx81kQ"),
    ("join link https://pairings.cloud/j/AbcDEF12345xyzQRs", "AbcDEF12345xyzQRs"),
    ("signed in, session=9f8e7d6c5b4a", "9f8e7d6c5b4a"),
    ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", "eyJhbGciOiJIUzI1NiJ9"),
    ("support: help code 482913, valid until 18:00", "482913"),
    ("your code is 482 913", "482 913"),
    ("code=482-913", "482-913"),
    ("machine-id 5c1f0b2e9a7d4c3b8e6f1a2b3c4d5e6f", "5c1f0b2e9a7d4c3b"),
    ("pin: 4821", "4821"),
    ("otp=917355", "917355"),
    ("mailing jorian@example.org", "jorian@"),
    ("x-api-key: AKIA1234ABCD5678EFGH", "AKIA1234ABCD5678EFGH"),
    ("credentials=user:pw", "user:pw"),
    ("private_key=/etc/x.pem passwd=aa", "passwd=aa"),
]
for msg, secret in SECRETS:
    out = shown(msg)
    check(secret not in out, "hidden: %-40s -> %s" % (msg[:40], out))

# --- what must stay readable -----------------------------------------------------------------------------
KEEP = [
    ("Main process exited, code=exited, status=1/FAILURE", "code=exited, status=1/FAILURE"),
    ("Failed to start nunki.service - Nunki.", "Failed to start nunki.service"),
    ("Started polis.service - Polis.", "Started polis.service"),
    ("wlan0: link becomes ready", "wlan0: link becomes ready"),
    ("eth0: Link is Up - 1Gbps/Full", "Link is Up - 1Gbps/Full"),
    ("Reached target Network.", "Reached target Network."),
    ("vc4-drm gpu: [drm] fb0: vc4drmfb frame buffer device", "fb0: vc4drmfb"),
    ("Running on http://localhost:4062 (port 4062)", "localhost:4062"),
    ("Listening on port 4040", "4040"),
    ("brcmfmac: Firmware: BCM4345/6 wl0: Jan  4 2021", "BCM4345/6"),
    ("Memory: 3870160K/4050944K available", "3870160K"),
]
for msg, part in KEEP:
    out = shown(msg)
    check(part in out, "kept:   %-40s -> %s" % (msg[:40], out))

# --- ASCII only, one line, not too long ---------------------------------------------------------------------
out = shown("Résumé – café “ok” 中文\ttab\nnewline")
check(all(32 <= ord(c) < 127 for c in out), "ascii only: %r" % out)
check("Resume - cafe" in out and '"ok"' in out and "??" in out, "folded, not dropped: %r" % out)
check(len(shown("x" * 1000)) <= 240 and shown("x" * 1000).endswith("..."), "cut to the screen")

# --- the allow-list ----------------------------------------------------------------------------------------
E = lambda **kw: dict({"PRIORITY": "6", "MESSAGE": "hello"}, **kw)
check(b.entry_line(E(_TRANSPORT="kernel"), "alnasl")[:2] == ("kernel", "kernel"), "kernel info is shown")
check(b.entry_line(E(_TRANSPORT="kernel", PRIORITY="7"), "alnasl") is None, "kernel debug is not")
check(b.entry_line(E(_TRANSPORT="kernel", PRIORITY="3"), "alnasl")[1:3] == ("error", True), "kernel error is an error")
check(b.entry_line(E(_SYSTEMD_UNIT="nunki.service"), "nunki")[:2] == ("nunki", "app"), "the role's app: app colour")
check(b.entry_line(E(_SYSTEMD_UNIT="alnasl.service"), "nunki")[:2] == ("alnasl", "box"), "another role's app: box colour")
check(b.entry_line(E(_SYSTEMD_UNIT="systemd-networkd.service"), "polis")[:2] == ("network", "network"), "network")
check(b.entry_line(E(_SYSTEMD_UNIT="sshd.service"), "alnasl") is None, "a unit not on the list is not shown")
check(b.entry_line(E(_SYSTEMD_UNIT="session-3.scope"), "alnasl") is None, "a login session is not shown")
check(b.entry_line(E(_SYSTEMD_UNIT="systemd-logind.service"), "alnasl") is None, "logind is not shown")
check(b.entry_line(E(_PID="1", UNIT="nunki.service", MESSAGE="Started nunki.service."), "nunki")[:2] == ("systemd", "systemd"),
      "systemd about an allowed unit")
check(b.entry_line(E(_PID="1", UNIT="getty@tty2.service", MESSAGE="Started getty."), "nunki") is None,
      "systemd about another unit: not shown")
f = b.entry_line(E(_PID="1", UNIT="weird.service", PRIORITY="4", MESSAGE="Failed to start weird.service."), "nunki")
check(f is not None and f[1] == "error" and f[2], "a failed unit is never hidden, and is an error")
f = b.entry_line(E(_PID="1", UNIT="x.service", PRIORITY="3", MESSAGE="x.service: Failed with result 'exit-code'. psk=abc"), "nunki")
check(f is not None and "abc" not in f[3], "a failure line is redacted too")
check(b.entry_line(E(_SYSTEMD_UNIT="nunki.service", MESSAGE=[104, 105]), "nunki")[3] == "hi", "a binary MESSAGE is decoded")
check(b.entry_line(E(_SYSTEMD_UNIT="nunki.service", MESSAGE="   "), "nunki") is None, "an empty line is not shown")

# --- the status line ------------------------------------------------------------------------------------------
st = {"a.service": {"ActiveState": "active", "UnitFileState": "enabled"},
      "b.service": {"ActiveState": "activating", "UnitFileState": "enabled"},
      "c.service": {"ActiveState": "inactive", "UnitFileState": "disabled"},
      "d.service": {"ActiveState": "inactive", "Type": "oneshot", "Result": "success", "UnitFileState": "enabled",
                    "InactiveEnterTimestampMonotonic": "123"},
      "e.service": {"ActiveState": "failed", "UnitFileState": "enabled"}}
check(b.count(st, list(st)) == (2, 4, 1), "count: up, expected (switched-off units do not count), failed: %r" % (b.count(st, list(st)),))
check(b.status_text("nunki", "en", 7, 12, 0) == "starting nunki - 7 of 12 up", "status line EN")
check(b.status_text("nunki", "nl", 7, 12, 1) == "nunki starten - 7 van 12 actief, 1 mislukt", "status line NL")
check(b.status_text("polis", "en", 12, 12, 0) == "polis is up", "status line when all is up")

print("\n%s" % ("ALL BOOTLOG TESTS PASSED" if not fails else "%d BOOTLOG TEST(S) FAILED" % fails))
sys.exit(1 if fails else 0)
