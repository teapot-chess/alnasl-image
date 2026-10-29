#!/usr/bin/env python3
"""Tests of the box's QR encoder (overlay/usr/local/lib/alnasl-setup/alnasl_qr.py), by DECODING what it draws.

    python3 scripts/test-qr.py [path/to/alnasl_qr.py]

The decoder below shares no code with the encoder and takes its numbers from the standard's tables
(alignment positions, block structure), not from the encoder's formulas: it reads the format bits from
both copies, rebuilds the function-pattern map, unmasks, reads the zigzag, de-interleaves, checks every
Reed-Solomon syndrome is zero and parses the byte-mode segment. A symbol that passes all of that is one
a phone can read; one that fails it would have been a very nice-looking sticker. Runs on the PC and in
verify.sh (on the image's own Python), also against the PNG the box writes.
"""
import importlib.util
import os
import random
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "overlay", "usr", "local", "lib", "alnasl-setup", "alnasl_qr.py")
spec = importlib.util.spec_from_file_location("alnasl_qr", path)
q = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(q)

fails = 0


def check(cond, what):
    global fails
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        fails += 1


# ------------------------------------------------------------- the decoder ---
EXP, LOG = [0] * 512, [0] * 256
v = 1
for i in range(255):
    EXP[i] = v
    LOG[v] = i
    v <<= 1
    if v & 0x100:
        v ^= 0x11D
for i in range(255, 512):
    EXP[i] = EXP[i - 255]

# ISO/IEC 18004 table E.1 and table 9 (level M): alignment centres; blocks as (count, total, data).
ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
         9: [6, 26, 46], 10: [6, 28, 50]}
BLOCKS_M = {1: [(1, 26, 16)], 2: [(1, 44, 28)], 3: [(1, 70, 44)], 4: [(2, 50, 32)], 5: [(2, 67, 43)],
            6: [(4, 43, 27)], 7: [(4, 49, 31)], 8: [(2, 60, 38), (2, 61, 39)], 9: [(3, 58, 36), (2, 59, 37)],
            10: [(4, 69, 43), (1, 70, 44)]}
# mask conditions as the standard writes them: i = row, j = column
MASK = [lambda i, j: (i + j) % 2 == 0, lambda i, j: i % 2 == 0, lambda i, j: j % 3 == 0,
        lambda i, j: (i + j) % 3 == 0, lambda i, j: (i // 2 + j // 3) % 2 == 0,
        lambda i, j: (i * j) % 2 + (i * j) % 3 == 0, lambda i, j: ((i * j) % 2 + (i * j) % 3) % 2 == 0,
        lambda i, j: ((i * j) % 3 + (i + j) % 2) % 2 == 0]


def bch_format(data5):
    g = 0b10100110111
    v = data5 << 10
    for k in range(14, 9, -1):
        if v & (1 << k):
            v ^= g << (k - 10)
    return ((data5 << 10) | v) ^ 0b101010000010010


def decode(m):
    n = len(m)
    ver = (n - 17) // 4
    assert n == 17 + 4 * ver and 1 <= ver <= 10, "odd size %d" % n
    # finders
    for (r0, c0) in ((0, 0), (0, n - 7), (n - 7, 0)):
        for r in range(7):
            for c in range(7):
                want = not (r in (1, 5) and 1 <= c <= 5 or c in (1, 5) and 1 <= r <= 5)
                assert m[r0 + r][c0 + c] == want, "finder pattern broken"
    for k in range(8, n - 8):
        assert m[6][k] == (k % 2 == 0) and m[k][6] == (k % 2 == 0), "timing pattern broken"
    assert m[n - 8][8], "dark module missing"
    # format: copy 1 around the top-left finder, copy 2 split over the other two
    c1 = [m[8][c] for c in (0, 1, 2, 3, 4, 5, 7, 8)] + [m[r][8] for r in (7, 5, 4, 3, 2, 1, 0)]
    c2 = [m[r][8] for r in range(n - 1, n - 8, -1)] + [m[8][c] for c in range(n - 8, n)]
    val1 = int("".join("1" if b else "0" for b in c1), 2)
    val2 = int("".join("1" if b else "0" for b in c2), 2)
    # bit 14 is read first in both; c1 here lists bit 14 .. bit 0 as the standard places them
    assert val1 == val2, "the two format copies differ"
    table = {bch_format(d): d for d in range(32)}
    assert val1 in table, "format bits are not a BCH code word"
    d = table[val1]
    ecl, mask = d >> 3, d & 7
    assert ecl == 0, "not level M"
    # function map
    f = [[False] * n for _ in range(n)]

    def area(r0, c0, h, w):
        for r in range(max(r0, 0), min(r0 + h, n)):
            for c in range(max(c0, 0), min(c0 + w, n)):
                f[r][c] = True
    area(0, 0, 9, 9)
    area(0, n - 8, 9, 8)
    area(n - 8, 0, 8, 9)
    area(6, 0, 1, n)
    area(0, 6, n, 1)
    pos = ALIGN[ver]
    for r in pos:
        for c in pos:
            if (r, c) in ((6, 6), (6, pos[-1]), (pos[-1], 6)):
                continue
            area(r - 2, c - 2, 5, 5)
    if ver >= 7:
        area(0, n - 11, 6, 3)
        area(n - 11, 0, 3, 6)
    # zigzag
    bits = []
    col = n - 1
    up = True
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(n - 1, -1, -1) if up else range(n)
        for r in rows:
            for c in (col, col - 1):
                if not f[r][c]:
                    bits.append(m[r][c] ^ MASK[mask](r, c))
        up = not up
        col -= 2
    cw = [int("".join("1" if b else "0" for b in bits[i:i + 8]), 2) for i in range(0, len(bits) // 8 * 8, 8)]
    # de-interleave
    spec_ = [(t, dlen) for cnt, t, dlen in BLOCKS_M[ver] for _ in range(cnt)]
    total = sum(t for t, _ in spec_)
    assert len(cw) == total, "codeword count %d, expected %d" % (len(cw), total)
    blocks = [[] for _ in spec_]
    k = 0
    for i in range(max(dl for _, dl in spec_)):
        for b, (t, dl) in enumerate(spec_):
            if i < dl:
                blocks[b].append(cw[k])
                k += 1
    eccn = spec_[0][0] - spec_[0][1]
    for i in range(eccn):
        for b in range(len(spec_)):
            blocks[b].append(cw[k])
            k += 1
    data = []
    for b, (t, dl) in enumerate(spec_):
        blk = blocks[b]
        for i in range(eccn):  # syndromes: c(a^i) must be 0
            s = 0
            for c in blk:
                s = (EXP[(LOG[s] + i) % 255] if s else 0) ^ c
            assert s == 0, "Reed-Solomon syndrome %d of block %d is not zero" % (i, b)
        data += blk[:dl]
    # byte mode
    bs = "".join(format(c, "08b") for c in data)
    assert bs[:4] == "0100", "not byte mode"
    cl = 8 if ver <= 9 else 16
    length = int(bs[4:4 + cl], 2)
    p = 4 + cl
    return bytes(int(bs[p + 8 * i:p + 8 * i + 8], 2) for i in range(length)), ver, mask


def png_matrix(blob, scale, border):
    """Back from the PNG to modules: the centre pixel of each."""
    assert blob[:8] == b"\x89PNG\r\n\x1a\n"
    p, idat, w = 8, b"", 0
    while p < len(blob):
        ln, = struct.unpack(">I", blob[p:p + 4])
        kind, body = blob[p + 4:p + 8], blob[p + 8:p + 8 + ln]
        assert struct.unpack(">I", blob[p + 8 + ln:p + 12 + ln])[0] == zlib.crc32(kind + body) & 0xFFFFFFFF, "bad CRC"
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert (depth, ctype) == (8, 0) and w == h
        elif kind == b"IDAT":
            idat += body
        p += 12 + ln
    raw = zlib.decompress(idat)
    rows = [raw[y * (w + 1) + 1:(y + 1) * (w + 1)] for y in range(w)]
    nmod = w // scale - 2 * border
    return [[rows[(border + y) * scale + scale // 2][(border + x) * scale + scale // 2] < 128 for x in range(nmod)] for y in range(nmod)]


# ------------------------------------------------------------------- tests ---
# Reed-Solomon against the worked example everyone uses: "HELLO WORLD", 1-M, alphanumeric data codewords.
hw = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
check(q.rs_remainder(hw, q.rs_divisor(10)) == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23],
      "Reed-Solomon: the HELLO WORLD 1-M example's ten ECC codewords")
check(q.format_bits(0) == 0b101010000010010 and q.format_bits(5) == bch_format(5), "format bits: M with mask 0 is 101010000010010")
check(q.version_bits(7) == 0b000111110010010100, "version bits of version 7: 000111110010010100")
check(all(q.alignment_positions(v) == ALIGN[v] for v in range(1, 11)), "alignment centres match the standard's table, versions 1-10")

samples = [b"A", b"hello", "WIFI:T:WPA;S:Alnasl-setup-4F2A;P:Kp7xR3mQ2w;;".encode()]
rnd = random.Random(1729)
for ln in (1, 13, 14, 26, 27, 41, 42, 61, 62, 83, 84, 105, 106, 121, 151, 152, 179, 180, 211, 213):
    samples.append(bytes(rnd.randrange(256) for _ in range(ln)))
okc = 0
for s in samples:
    for mask in (None, 0, 3, 7):
        try:
            got, ver, m = decode(q.encode(s, mask=mask))
            okc += got == s and (mask is None or m == mask)
        except AssertionError as e:
            print("       %d bytes, mask %s: %s" % (len(s), mask, e))
check(okc == len(samples) * 4, "decoded %d of %d symbols (1 to 213 bytes, versions 1-10, chosen and fixed masks)" % (okc, len(samples) * 4))
seen_versions = {decode(q.encode(s))[1] for s in samples}
check(seen_versions == set(range(1, 11)), "every version 1-10 was exercised: %s" % sorted(seen_versions))
try:
    q.encode(b"x" * 214)
    check(False, "214 bytes refused")
except ValueError:
    check(True, "214 bytes refused (more than version 10-M holds)")

# The Wi-Fi payload and its escapes.
check(q.wifi_payload("Alnasl-setup-4F2A", "Kp7xR3mQ2w") == "WIFI:T:WPA;S:Alnasl-setup-4F2A;P:Kp7xR3mQ2w;;", "Wi-Fi payload, plain")
check(q.wifi_payload('a;b', 'p\\a:s,s"w;') == 'WIFI:T:WPA;S:a\\;b;P:p\\\\a\\:s\\,s\\"w\\;;;', "Wi-Fi payload escapes \\ ; , : and \"")
longest = q.wifi_payload("Alnasl-setup-FFFF", ";" * 63)
check(len(longest.encode()) <= 213, "the longest possible payload (63 escaped characters) fits: %d bytes" % len(longest.encode()))

# The PNG, read back pixel by pixel.
pl = q.wifi_payload("Alnasl-setup-4F2A", "Kp7xR3mQ2w")
blob = q.wifi_png("Alnasl-setup-4F2A", "Kp7xR3mQ2w")
try:
    got, ver, _m = decode(png_matrix(blob, 10, 4))
    check(got.decode() == pl, "the PNG decodes to the payload (version %d, %d bytes of PNG)" % (ver, len(blob)))
except AssertionError as e:
    check(False, "the PNG decodes: %s" % e)

if len(sys.argv) > 2:  # a PNG the box wrote, and the payload it should hold
    try:
        got, ver, _m = decode(png_matrix(open(sys.argv[2], "rb").read(), 10, 4))
        check(len(sys.argv) < 4 or got.decode() == sys.argv[3], "%s decodes to the expected payload" % sys.argv[2])
    except (AssertionError, OSError) as e:
        check(False, "%s decodes: %s" % (sys.argv[2], e))

print("%s: %d failure(s)" % ("test-qr", fails))
sys.exit(1 if fails else 0)
