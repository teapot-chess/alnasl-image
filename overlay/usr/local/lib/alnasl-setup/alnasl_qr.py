"""A QR code, byte mode, written as a plain PNG. Python standard library only.

Written for this image (no third-party code, no licence to carry): what the box needs is one symbol,
the Wi-Fi join code of its setup hotspot (alnasl-hotspot-qr.png on the boot partition), so this does
byte mode, error correction level M, versions 1 to 10, and nothing else. That is up to 213 bytes,
which is more than a WIFI: payload with a 63-character password can be even after escaping.

    encode(data: bytes) -> list of rows of bools (True = dark), quiet zone not included
    png(matrix, scale=10, border=4) -> bytes of a greyscale PNG
    wifi_payload(ssid, password) -> the standard "WIFI:T:WPA;S:...;P:...;;" text

The structure follows ISO/IEC 18004 (and every QR encoder that ever copied it): finder, separator,
timing and alignment patterns, the format and version bits, the data in the zigzag order, eight masks
with the standard penalty rules. scripts/test-qr.py decodes what this draws, independently, and checks
the Reed-Solomon codes, because "looks like a QR code" is not a test.
"""
import struct
import zlib

# Level M, versions 1..10: (ECC codewords per block, number of blocks). Index 0 unused.
ECC_M = [None, (10, 1), (16, 1), (26, 1), (18, 2), (24, 2), (16, 4), (18, 4), (22, 4), (22, 5), (26, 5)]
MAX_VERSION = 10
FORMAT_ECL_M = 0  # the two format bits of level M (L=1, M=0, Q=3, H=2)


# ------------------------------------------------------------------ GF(256) --
def gf_mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def rs_divisor(degree):
    """The generator polynomial with roots a^0 .. a^(degree-1), highest coefficient (1) left out."""
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = gf_mul(root, 0x02)
    return result


def rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= gf_mul(coef, factor)
    return result


# ------------------------------------------------------------------- layout --
def size_of(version):
    return version * 4 + 17


def raw_data_modules(version):
    result = (16 * version + 128) * version + 64
    if version >= 2:
        n = version // 7 + 2
        result -= (25 * n - 10) * n - 55
        if version >= 7:
            result -= 36
    return result


def alignment_positions(version):
    if version == 1:
        return []
    n = version // 7 + 2
    step = (version * 8 + n * 3 + 5) // (n * 4 - 4) * 2
    size = size_of(version)
    return [6] + sorted(size - 7 - i * step for i in range(n - 1))


def data_capacity(version):
    """Data codewords at level M."""
    ecc, blocks = ECC_M[version]
    return raw_data_modules(version) // 8 - ecc * blocks


def format_bits(mask, ecl=FORMAT_ECL_M):
    data = (ecl << 3) | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def version_bits(version):
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


class _Grid:
    def __init__(self, version):
        self.version = version
        self.size = size_of(version)
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.func = [[False] * self.size for _ in range(self.size)]

    def set_func(self, x, y, dark):
        self.dark[y][x] = dark
        self.func[y][x] = True

    def draw_function_patterns(self):
        n = self.size
        for i in range(n):  # timing
            self.set_func(6, i, i % 2 == 0)
            self.set_func(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (n - 4, 3), (3, n - 4)):  # finders with their separators
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < n and 0 <= y < n:
                        self.set_func(x, y, max(abs(dx), abs(dy)) not in (2, 4))
        pos = alignment_positions(self.version)
        last = len(pos) - 1
        for i, ay in enumerate(pos):
            for j, ax in enumerate(pos):
                if (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0):
                    continue  # those three corners belong to the finders
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.set_func(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
        self.draw_format(0)  # reserves the area; drawn again for real once the mask is chosen
        if self.version >= 7:
            bits = version_bits(self.version)
            for i in range(18):
                b = (bits >> i) & 1 == 1
                a, c = n - 11 + i % 3, i // 3
                self.set_func(a, c, b)
                self.set_func(c, a, b)

    def draw_format(self, mask):
        bits = format_bits(mask)
        n = self.size
        bit = lambda i: (bits >> i) & 1 == 1  # noqa: E731
        for i in range(6):
            self.set_func(8, i, bit(i))
        self.set_func(8, 7, bit(6))
        self.set_func(8, 8, bit(7))
        self.set_func(7, 8, bit(8))
        for i in range(9, 15):
            self.set_func(14 - i, 8, bit(i))
        for i in range(8):
            self.set_func(n - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self.set_func(8, n - 15 + i, bit(i))
        self.set_func(8, n - 8, True)  # the dark module, always there

    def draw_codewords(self, codewords):
        n = self.size
        i = 0
        total = len(codewords) * 8
        right = n - 1
        while right >= 1:
            if right == 6:
                right = 5  # the vertical timing pattern is skipped as a whole column
            upward = ((right + 1) & 2) == 0
            for vert in range(n):
                y = n - 1 - vert if upward else vert
                for j in range(2):
                    x = right - j
                    if not self.func[y][x] and i < total:
                        self.dark[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
            right -= 2
        assert i == total

    def apply_mask(self, mask):
        for y in range(self.size):
            for x in range(self.size):
                if not self.func[y][x] and MASKS[mask](x, y):
                    self.dark[y][x] = not self.dark[y][x]


MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def penalty(m):
    """The four rules of the standard. Any mask decodes; this only picks the one scanners like best."""
    n = len(m)
    score = 0
    lines = [row for row in m] + [[m[y][x] for y in range(n)] for x in range(n)]
    pat1 = [True, False, True, True, True, False, True, False, False, False, False]
    pat2 = pat1[::-1]
    for line in lines:
        run, prev = 0, None
        for v in line:
            if v == prev:
                run += 1
            else:
                if run >= 5:
                    score += 3 + run - 5
                run, prev = 1, v
        if run >= 5:
            score += 3 + run - 5
        for i in range(n - 10):
            seg = line[i:i + 11]
            if seg == pat1 or seg == pat2:
                score += 40
    for y in range(n - 1):
        for x in range(n - 1):
            c = m[y][x]
            if c == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                score += 3
    dark = sum(v for row in m for v in row)
    total = n * n
    k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
    return score + k * 10


# ------------------------------------------------------------------- encode --
def data_codewords(data, version):
    bits = []

    def put(val, length):
        for i in range(length - 1, -1, -1):
            bits.append((val >> i) & 1)

    cap_bits = data_capacity(version) * 8
    put(0b0100, 4)  # byte mode
    put(len(data), 8 if version <= 9 else 16)
    for b in data:
        put(b, 8)
    if len(bits) > cap_bits:
        raise ValueError("too long for version %d" % version)
    put(0, min(4, cap_bits - len(bits)))  # terminator
    put(0, (8 - len(bits) % 8) % 8)
    out = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(out) < cap_bits // 8:
        out.append(pad)
        pad ^= 0xEC ^ 0x11
    return out


def interleave(data, version):
    ecc, nblocks = ECC_M[version]
    raw = raw_data_modules(version) // 8
    nshort = nblocks - raw % nblocks
    short_len = raw // nblocks
    div = rs_divisor(ecc)
    blocks, k = [], 0
    for i in range(nblocks):
        dlen = short_len - ecc + (0 if i < nshort else 1)
        dat = data[k:k + dlen]
        k += dlen
        e = rs_remainder(dat, div)
        if i < nshort:
            dat = dat + [0]  # placeholder, skipped below
        blocks.append(dat + e)
    out = []
    for i in range(len(blocks[0])):
        for j, blk in enumerate(blocks):
            if i != short_len - ecc or j >= nshort:
                out.append(blk[i])
    assert len(out) == raw
    return out


def encode(data, mask=None):
    if isinstance(data, str):
        data = data.encode("utf-8")
    for version in range(1, MAX_VERSION + 1):
        need = 4 + (8 if version <= 9 else 16) + 8 * len(data)
        if need <= data_capacity(version) * 8:
            break
    else:
        raise ValueError("data too long for a version %d symbol" % MAX_VERSION)
    cw = interleave(data_codewords(data, version), version)
    best = None
    for m in ([mask] if mask is not None else range(8)):
        g = _Grid(version)
        g.draw_function_patterns()
        g.draw_codewords(cw)
        g.apply_mask(m)
        g.draw_format(m)
        p = penalty(g.dark)
        if best is None or p < best[0]:
            best = (p, g.dark)
    return best[1]


# ---------------------------------------------------------------------- PNG --
def png(matrix, scale=10, border=4):
    """8-bit greyscale PNG, black on white, `border` modules of quiet zone (the standard asks for 4)."""
    n = len(matrix)
    side = (n + 2 * border) * scale
    rows = []
    white = b"\xff" * side
    for y in range(-border, n + border):
        if 0 <= y < n:
            line = bytearray()
            for x in range(-border, n + border):
                v = 0 if 0 <= x < n and matrix[y][x] else 255
                line += bytes([v]) * scale
            line = bytes(line)
        else:
            line = white
        rows.extend([b"\x00" + line] * scale)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", side, side, 8, 0, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


# --------------------------------------------------------------------- Wi-Fi --
def wifi_escape(s):
    """The WIFI: scheme's escapes: backslash before \\ ; , : and "."""
    return "".join("\\" + c if c in '\\;,:"' else c for c in s)


def wifi_payload(ssid, password):
    return "WIFI:T:WPA;S:%s;P:%s;;" % (wifi_escape(ssid), wifi_escape(password))


def wifi_png(ssid, password, scale=10):
    return png(encode(wifi_payload(ssid, password)), scale=scale)
