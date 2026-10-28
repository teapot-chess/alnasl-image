#!/usr/bin/env python3
"""Tests of alnasl-system-update's decisions (v6 A/B), runnable anywhere with python3 + openssl:

    python3 scripts/test-update.py [UPDATER [SHIPPED-KEY [GRUB-AB-CFG]]]

(defaults: the overlay's files; verify.sh passes the image's own, inside the image with its python and openssl)

The train rule, the choice of image, the release index check, the grub environment block, and the
signature check with a throw-away key made in a temp directory (deleted afterwards; never a real key).
Nothing here touches a disk, a partition or the network.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "overlay", "usr", "local", "sbin", "alnasl-system-update")
PLACEHOLDER = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "overlay", "etc", "alnasl", "update-key.pub")
GRUB_AB = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, "grub-ab.cfg")

if "fcntl" not in sys.modules:
    try:
        import fcntl  # noqa: F401
    except ImportError:  # Windows: the module is only imported, never used by these tests
        sys.modules["fcntl"] = types.ModuleType("fcntl")

loader = importlib.machinery.SourceFileLoader("asu", SRC)
spec = importlib.util.spec_from_loader("asu", loader)
asu = importlib.util.module_from_spec(spec)
loader.exec_module(asu)
asu.log = lambda *a: None

FAILS = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        FAILS.append(what)


def raises(fn, exc=asu.Refused):
    try:
        fn()
    except exc:
        return True
    return False


def img(train, version, min_from=None, **kw):
    d = {"train": train, "version": version, "file": "alnasl-system-v%s.img.zst" % version,
         "url": "https://example.invalid/%s.zst" % version, "sig_url": "https://example.invalid/%s.zst.sig" % version,
         "size": 1000, "raw_size": 3000, "sha256": "a" * 64, "raw_sha256": "b" * 64, "min_from": min_from}
    d.update(kw)
    return d


# ---- the train rule -------------------------------------------------------------------------------
check(not raises(lambda: asu.train_guard(img("v6", "6.2"), "v6")), "same train: allowed without asking")
check(raises(lambda: asu.train_guard(img("v7", "7.0"), "v6")), "next train, not asked: REFUSED")
check(not raises(lambda: asu.train_guard(img("v7", "7.0"), "v6", "v7")), "next train, asked for exactly that train: allowed")
check(raises(lambda: asu.train_guard(img("v8", "8.0"), "v6", "v7")), "asked v7, image v8: REFUSED")
check(raises(lambda: asu.train_guard(img("v5", "5.9"), "v6", "v5")), "asked an OLDER train: REFUSED")
check(raises(lambda: asu.train_guard(img("v6", "7.0"), "v6")), "image whose version is of another train than it says: REFUSED")

# ---- choosing --------------------------------------------------------------------------------------
idx = [img("v6", "6.0"), img("v6", "6.1"), img("v6", "6.2"), img("v7", "7.0", "6.2"), img("v7", "7.1", "6.2")]
best, up, blocked = asu.choose(idx, "v6", "6.1")
check(best and best["version"] == "6.2", "on 6.1: the newest of its own train (6.2)")
check(up is None and blocked == "6.2", "on 6.1: v7 not offered yet, it needs 6.2 first")
best, up, blocked = asu.choose(idx, "v6", "6.2")
check(best is None, "on 6.2: nothing newer in v6")
check(up and up["train"] == "v7" and up["version"] == "7.1", "on 6.2: v7 (7.1) OFFERED, never chosen as best")
best, up, _ = asu.choose(idx + [img("v6", "6.10")], "v6", "6.2")
check(best and best["version"] == "6.10", "versions compare as numbers (6.10 > 6.2)")
best, up, _ = asu.choose([img("v6", "6.3", "6.2"), img("v6", "6.4", "6.3")], "v6", "6.1")
check(best is None, "on 6.1, every newer v6 needs 6.2 or 6.3 first: nothing to take")
best, _, _ = asu.choose([img("v6", "6.3"), img("v6", "6.4", "6.3")], "v6", "6.2")
check(best and best["version"] == "6.3", "a stepping stone is taken first (6.3 before 6.4 that needs it)")
best, up, _ = asu.choose(idx, "v7", "7.0")
check(best and best["version"] == "7.1" and up is None, "a box on v7 never goes back to v6")

# ---- the release index -----------------------------------------------------------------------------
good = img("v6", "6.3")
bad = [img("v6", "7.0"), img("v6", "6.4", url="http://example.invalid/x.zst"), img("v6", "6.5", sha256="xyz"),
       img("v6", "6.6", size=10 << 30), img("v6", "6.7", file="../evil.zst"), img("v6", "6.8", min_from="six")]
got = asu.parse_index(json.dumps({"format": 1, "images": [good] + bad}).encode())
check([i["version"] for i in got] == ["6.3"], "index: only the complete, consistent, https-only entry survives")
check(raises(lambda: asu.parse_index(b'{"format": 2, "images": []}')), "index: an unknown format is refused")

# ---- versions --------------------------------------------------------------------------------------
check(asu.vkey("6.10") > asu.vkey("6.9") and asu.vkey("6.2.1") > asu.vkey("6.2"), "version order")
check(raises(lambda: asu.vkey("6.x"), ValueError) and raises(lambda: asu.train_no("6"), ValueError), "bad version / train rejected")

tmp = tempfile.mkdtemp(prefix="alnasl-test-update-")
try:
    # ---- grub environment block -------------------------------------------------------------------
    env_path = os.path.join(tmp, "grubenv")
    with open(env_path, "wb") as f:
        f.write(b"# GRUB Environment Block\nalnasl_slot=A\nalnasl_try=none\nalnasl_tries=0\nalnasl_failed=none\n".ljust(1024, b"#"))
    e = asu.read_env(env_path)
    check(e == {"alnasl_slot": "A", "alnasl_try": "none", "alnasl_tries": "0", "alnasl_failed": "none"}, "grubenv: read")
    ino = os.stat(env_path).st_ino
    e.update(alnasl_try="B", alnasl_tries="3", alnasl_try_version="6.2")
    asu.write_env(e, env_path)
    check(os.path.getsize(env_path) == 1024 and asu.read_env(env_path)["alnasl_tries"] == "3", "grubenv: written, still 1024 bytes")
    check(os.name == "nt" or os.stat(env_path).st_ino == ino, "grubenv: written in place (same file: grub's save_env needs its blocks)")
    check(raises(lambda: asu.write_env({"alnasl_slot": "A\nalnasl_try=B"}, env_path), ValueError), "grubenv: a value with a newline is refused")
    with open(env_path, "wb") as f:
        f.write(b"x" * 100)
    check(raises(lambda: asu.read_env(env_path), OSError), "grubenv: a damaged block is not read as empty")

    # ---- grub-ab.cfg: the counter the updater relies on ----------------------------------------------
    cfg = open(GRUB_AB).read()
    for need in ('load_env -f $alnasl_env', 'save_env -f $alnasl_env alnasl_try alnasl_tries alnasl_failed',
                 'set alnasl_tries=2', 'set alnasl_tries=1', 'set alnasl_tries=0', 'set alnasl_failed=$alnasl_try',
                 'root=PARTUUID=@DISKID@-$alnasl_part', 'panic=10'):
        check(need in cfg, "grub-ab.cfg has: " + need)
    check(asu.TRIES == 3 and 'if [ "$alnasl_tries" = "3" ]' in cfg, "grub-ab.cfg counts down from the updater's TRIES (3)")

    # ---- signatures -------------------------------------------------------------------------------
    ph = open(PLACEHOLDER).read() if os.path.exists(PLACEHOLDER) else ""
    asu.KEY = PLACEHOLDER
    ok, why = asu.key_state()
    check("PRIVATE KEY-----" not in ph, "the shipped key file holds no private key")
    if "ALNASL-PLACEHOLDER" in ph:
        check(not ok and "placeholder" in why, "the shipped key is the PLACEHOLDER: updates say they are off")
    else:
        check(ok, "the shipped key is a real public key: updates are on")
    openssl = shutil.which("openssl")
    if not openssl:
        print("skip  signature tests: no openssl here")
    else:
        key, pub = os.path.join(tmp, "throwaway.key"), os.path.join(tmp, "throwaway.pub")
        subprocess.run([openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key], check=True, capture_output=True)
        subprocess.run([openssl, "ec", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
        data = os.path.join(tmp, "index.json")
        with open(data, "w") as f:
            json.dump({"format": 1, "images": [good]}, f)
        subprocess.run([openssl, "dgst", "-sha256", "-sign", key, "-out", data + ".sig", data], check=True, capture_output=True)
        asu.KEY = pub
        check(asu.key_state()[0], "a real public key switches updates on")
        check(not raises(lambda: asu.verify_sig(data, data + ".sig")), "signature: a signed index verifies")
        with open(data, "a") as f:
            f.write(" ")
        check(raises(lambda: asu.verify_sig(data, data + ".sig")), "signature: one byte changed -> REFUSED")
        key2, pub2 = os.path.join(tmp, "other.key"), os.path.join(tmp, "other.pub")
        subprocess.run([openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key2], check=True, capture_output=True)
        subprocess.run([openssl, "ec", "-in", key2, "-pubout", "-out", pub2], check=True, capture_output=True)
        subprocess.run([openssl, "dgst", "-sha256", "-sign", key2, "-out", data + ".sig", data], check=True, capture_output=True)
        check(raises(lambda: asu.verify_sig(data, data + ".sig")), "signature: signed by another key -> REFUSED")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n%d failed" % len(FAILS) if FAILS else "\nall passed")
sys.exit(1 if FAILS else 0)
