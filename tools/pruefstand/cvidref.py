#!/usr/bin/env python3
"""cvidref - independent reference decoder for the assembler players.

Decodes Cinepak from a CPKS file the way the player has to lay the picture
down: for the chipset modes straight into the bitplanes of the screen (picture
vertically centred in 256 rows), for RTG as a chunky picture. The arithmetic is
done at PIXEL level: every pixel gets a value (palette index, grey value,
HAM components or colour value), and only then are planes or bytes made from it.
So the path shares nothing with the block loops or codebook patterns of the
players; if both agree, that is evidence, not an echo.

Modes (chipset, screen 256 rows):
  clut   fixed palette 4-4-2 (index r*8 + g*2 + b), 5 planes, 320 wide
  gray   32 grey levels (Y >> 3), 5 planes, 320 wide (ECS)
  gray8  256 grey levels (Y), 8 planes, 320 wide (AGA)
  ham6   HAM6 single width: screen column mod 4 = blue, green, red, green;
         data planes 0-3 carry the 4-bit level, control planes 4/5 fixed
         $DD/$77 in the picture area. 6 planes, 320 wide.
  dham6  like ham6, but double width: source column x occupies the
         screen columns 2x and 2x+1, even x sets (blue, green), odd
         (red, green). 6 planes, 640 wide (AGA).
  dham8  like dham6 with 6-bit levels in the data planes 0-5, control planes
         6/7 fixed $DD/$77. 8 planes, 640 wide (AGA).
Modes (RTG, chunky, picture size):
  rgb32    four bytes per pixel A,R,G,B with A = 0 (PACK_ARGB, src/cpu.h)
  rgb16:N  two bytes per pixel, N = CVX_PIX16_* from src/cpu.h:
           0 R5G6B5, 1 R5G5B5, 2 R5G6B5PC, 3 R5G5B5PC (PC = Bytes vertauscht)

The colour arithmetic follows src/yuv.c (the original's tables, rounding-down
division, clamp table after the IJG scheme) - that is the definition of what
is to stand on the screen. HAM levels are ROUNDED: 4 bit
(v*15+127)//255 as in tools/gen_a68k_tabellen.py, 6 bit min(63, (v+2)>>2).

Calls:
  cvidref.py <clip.cpks> <mode> --hashes out.txt     one MD5 per frame
  cvidref.py <clip.cpks> <mode> --compare dump.bin   against a dump
  cvidref.py --hash-dump dump.bin --planes 5|6|8 [--rb 40|80] --hashes out.txt
Needs numpy (system Python)."""
import argparse
import hashlib
import sys

import numpy as np

SCR_H, RB = 256, 40
MAX_STRIPS = 16

# kind: idx = one value per pixel, ham = (B, G, R) per pixel, rgb = bytes per pixel
# planes: planes of the screen, data: of those the data planes, xs: screen pixels
# per source pixel horizontally, ch: components per pixel in the decoder
MODES = {
    'clut':  dict(kind='idx', planes=5, data=5, xs=1, ch=1),
    'gray':  dict(kind='idx', planes=5, data=5, xs=1, ch=1),
    'gray8': dict(kind='idx', planes=8, data=8, xs=1, ch=1),
    'ham6':  dict(kind='ham', planes=6, data=4, xs=1, ch=3),
    'dham6': dict(kind='ham', planes=6, data=4, xs=2, ch=3),
    'dham8': dict(kind='ham', planes=8, data=6, xs=2, ch=3),
    'rgb32': dict(kind='rgb', ch=4),
}
for _n in range(4):
    MODES['rgb16:%d' % _n] = dict(kind='rgb', ch=2, fmt=_n)


# --- Farbtabellen (src/yuv.c) -----------------------------------------------

def _tables():
    ub, vr, ug, vg, yt = [], [], [], [], []
    for cnt in range(256):
        x = 2 * cnt - 255
        ub.append((14301 * x + 250 * 32) // 250)      # // is floor as ENTIER
        vr.append((11341 * x + 250 * 32) // 250)
        ug.append((-71953 * x) // 6250)
        vg.append((-145953 * x + 6250 * 32) // 6250)
        yt.append((cnt << 6) + (cnt >> 2))
    return ub, vr, ug, vg, yt


UB, VR, UG, VG, YT = _tables()


def rng(v):
    """Klemmtabelle rngLimit[v], v in -256..1151."""
    if v < 0:
        return 0
    if v < 256:
        return v
    if v < 640:
        return 255
    if v < 1024:
        return 0
    return v - 1024


def h4(v):
    """HAM6 level 0..15 to the 8-bit share, rounded (displayed c*17)."""
    return (v * 15 + 127) // 255


def h6(v):
    """HAM8 level 0..63 to the 8-bit share, rounded (displayed c*4)."""
    return min(63, (v + 2) >> 2)


def rgb16(r, g, b, fmt):
    """Two bytes of a pixel as in yuv_rng16_tables() in src/yuv.c."""
    g6 = fmt in (0, 2)
    val = ((r >> 3) << (11 if g6 else 10)) | (((g >> 2) if g6 else (g >> 3)) << 5) | (b >> 3)
    if fmt in (2, 3):
        return (val & 0xFF, val >> 8)
    return (val >> 8, val & 0xFF)


def lev(v, lv):
    return (v * (lv - 1) + 127) // 255


def entry_colors(e, mode):
    """Four subpixels of a codebook entry (6 bytes: Y0..Y3, U, V), each
    a tuple with MODES[mode]['ch'] values: clut/gray/gray8 (value,),
    ham6/dham6 (B, G, R) as 4 bit, dham8 (B, G, R) as 6 bit, rgb32
    (A, R, G, B), rgb16:N (byte 0, byte 1)."""
    if mode == 'gray':
        return [(e[k] >> 3,) for k in range(4)]
    if mode == 'gray8':
        return [(e[k],) for k in range(4)]
    u, v = e[4] ^ 0x80, e[5] ^ 0x80
    cr, cg, cb = VR[v], UG[u] + VG[v], UB[u]
    out = []
    for k in range(4):
        y = YT[e[k]]
        r, g, b = rng((y + cr) >> 6), rng((y + cg) >> 6), rng((y + cb) >> 6)
        if mode == 'clut':
            out.append((lev(r, 4) * 8 + lev(g, 4) * 2 + lev(b, 2),))
        elif mode in ('ham6', 'dham6'):
            out.append((h4(b), h4(g), h4(r)))  # rounded as gen_a68k_tabellen.h4
        elif mode == 'dham8':
            out.append((h6(b), h6(g), h6(r)))
        elif mode == 'rgb32':
            out.append((0, r, g, b))
        else:
            out.append(rgb16(r, g, b, MODES[mode]['fmt']))
    return out


class Entry:
    """One converted entry: finished 4x4 pixels for V1 and the 2x2
    quarter for V4, per pixel MODES[mode]['ch'] components. The pattern of the
    HAM modes (which component at which screen column) arises only when the
    planes are built - entries carry the whole colour."""
    __slots__ = ('v1', 'ql', 'qr')

    def __init__(self, sub, mode):
        ch = MODES[mode]['ch']
        if sub is None:                                # calloc: alles 0
            self.v1 = np.zeros((4, 4, ch), np.uint8)
            self.ql = np.zeros((2, 2, ch), np.uint8)
            self.qr = self.ql
            return
        v1 = np.zeros((4, 4, ch), np.uint8)
        for y in range(4):
            for x in range(4):
                v1[y, x] = sub[(y >> 1) * 2 + (x >> 1)]
        q = np.zeros((2, 2, ch), np.uint8)
        for y in range(2):
            for x in range(2):
                q[y, x] = sub[y * 2 + x]
        self.v1, self.ql, self.qr = v1, q, q


# --- CPKS ------------------------------------------------------------------

def cpks_packets(data):
    """(type, flags, pts, payload) of all packets; after disturbances it resumes
    at the next sync word."""
    off, n = 0, len(data)
    while off + 16 <= n:
        if data[off:off + 4] != b'CPKS':
            nxt = data.find(b'CPKS', off + 1)
            if nxt < 0:
                return
            off = nxt
            continue
        typ, flags = data[off + 4], data[off + 5]
        pts = int.from_bytes(data[off + 8:off + 12], 'big')
        ln = int.from_bytes(data[off + 12:off + 16], 'big')
        if off + 16 + ln > n:
            return
        yield typ, flags, pts, data[off + 16:off + 16 + ln]
        off += 16 + ln + ((4 - (ln & 3)) & 3)


def rd16(b, o):
    return (b[o] << 8) | b[o + 1]


def rd24(b, o):
    return (b[o] << 16) | (b[o + 1] << 8) | b[o + 2]


def rd32(b, o):
    return int.from_bytes(b[o:o + 4], 'big')


# --- Decoder ---------------------------------------------------------------

class Decoder:
    def __init__(self, width, height, mode):
        self.w = width
        self.h = height & ~3
        self.bcols = width >> 2
        self.mode = mode
        self.zero = Entry(None, mode)
        self.maps0 = [None] * MAX_STRIPS
        self.maps1 = [None] * MAX_STRIPS
        self.vmap0 = [0] * MAX_STRIPS
        self.vmap1 = [0] * MAX_STRIPS
        self.pix = np.zeros((self.h, width, MODES[mode]['ch']), np.uint8)

    def _put(self, brow, col, arr):
        y, x = brow * 4, col * 4
        self.pix[y:y + 4, x:x + 4] = arr

    def _v4(self, cb, idx):
        a = np.empty((4, 4, MODES[self.mode]['ch']), np.uint8)
        a[0:2, 0:2] = cb[idx[0]].ql
        a[0:2, 2:4] = cb[idx[1]].qr
        a[2:4, 0:2] = cb[idx[2]].ql
        a[2:4, 2:4] = cb[idx[3]].qr
        return a

    def decode(self, f):
        size = len(f)
        if size < 10:
            return 'kurz'
        ln = rd24(f, 1)
        if ln != size:
            if ln & 1:
                ln += 1
            if ln != size:
                return 'laenge'
        strips = min(rd16(f, 8), MAX_STRIPS)
        pos, ytop, brow = 10, 0, 0
        for kk in range(strips):
            if self.maps0[kk] is None:
                self.maps0[kk] = [self.zero] * 256
            if self.maps1[kk] is None:
                self.maps1[kk] = [self.zero] * 256
            src = strips - 1 if kk == 0 else kk - 1
            if not self.vmap0[kk]:
                s = self.maps0[src]
                self.maps0[kk] = list(s) if s is not None else [self.zero] * 256
                self.vmap0[kk] = 1
            if not self.vmap1[kk]:
                s = self.maps1[src]
                self.maps1[kk] = list(s) if s is not None else [self.zero] * 256
                self.vmap1[kk] = 1
            cb0, cb1 = self.maps0[kk], self.maps1[kk]
            if size - pos < 12:
                return 'strip'
            top = rd16(f, pos + 2) - 12
            ytop += rd16(f, pos + 8)
            pos += 12
            ylim = min(ytop, self.h)
            col = 0
            while top > 0:
                if size - pos < 4:
                    return 'chunk'
                cid, cs = rd16(f, pos), rd16(f, pos + 2)
                pos += 4
                top -= cs
                cs -= 4
                if cs < 0 or size - pos < cs:
                    return 'chunk'
                cend = pos + cs
                if cid in (0x2000, 0x2200):
                    v1 = cid == 0x2200
                    n = min(cs // 6, 256)
                    for i in range(strips):
                        if v1:
                            self.vmap1[i] = 0
                        else:
                            self.vmap0[i] = 0
                    if v1:
                        self.vmap1[kk] = 1
                    else:
                        self.vmap0[kk] = 1
                    cb = cb1 if v1 else cb0
                    for i in range(n):
                        e = f[pos + 6 * i:pos + 6 * i + 6]
                        cb[i] = Entry(entry_colors(e, self.mode), self.mode)
                elif cid in (0x2100, 0x2300):
                    cb = cb1 if cid == 0x2300 else cb0
                    ci = 0
                    while pos + 4 <= cend:
                        flag = rd32(f, pos)
                        pos += 4
                        mask = 0x80000000
                        while mask:
                            if (mask & flag) and ci < 256:
                                if pos + 6 > cend:
                                    break
                                cb[ci] = Entry(entry_colors(f[pos:pos + 6], self.mode), self.mode)
                                pos += 6
                            ci += 1
                            mask >>= 1
                elif cid == 0x3000:
                    done = False
                    while not done and pos + 4 <= cend and brow * 4 < ylim:
                        flag = rd32(f, pos)
                        pos += 4
                        mask = 0x80000000
                        while mask:
                            if brow * 4 >= ylim:
                                break
                            if mask & flag:
                                if pos + 4 > cend:
                                    done = True
                                    break
                                self._put(brow, col, self._v4(cb0, f[pos:pos + 4]))
                                pos += 4
                            else:
                                if pos + 1 > cend:
                                    done = True
                                    break
                                self._put(brow, col, cb1[f[pos]].v1)
                                pos += 1
                            col += 1
                            if col >= self.bcols:
                                col, brow = 0, brow + 1
                            mask >>= 1
                elif cid == 0x3200:
                    while pos < cend and brow * 4 < ylim:
                        self._put(brow, col, cb1[f[pos]].v1)
                        pos += 1
                        col += 1
                        if col >= self.bcols:
                            col, brow = 0, brow + 1
                elif cid == 0x3100:
                    flag, mask = 0, 0
                    while True:
                        if brow * 4 >= ylim:
                            break
                        if not mask:
                            if pos + 4 > cend:
                                break
                            flag, mask = rd32(f, pos), 0x80000000
                            pos += 4
                        coded = flag & mask
                        mask >>= 1
                        if coded:
                            if not mask:
                                if pos + 4 > cend:
                                    break
                                flag, mask = rd32(f, pos), 0x80000000
                                pos += 4
                            v4 = flag & mask
                            mask >>= 1
                            if v4:
                                if pos + 4 > cend:
                                    break
                                self._put(brow, col, self._v4(cb0, f[pos:pos + 4]))
                                pos += 4
                            else:
                                if pos >= cend:
                                    break
                                self._put(brow, col, cb1[f[pos]].v1)
                                pos += 1
                        col += 1
                        if col >= self.bcols:
                            col, brow = 0, brow + 1
                else:
                    return 'chunkid %04x' % cid
                pos = cend
        return None

    def planes(self):
        """The picture the way the player lays it down: chipset all planes of the
        screen (256 rows, picture vertically centred), RTG the chunky picture."""
        m = MODES[self.mode]
        if m['kind'] == 'rgb':
            return self.pix.tobytes()
        xs, sw = m['xs'], self.w * m['xs']
        rb = RB * xs
        y0 = (SCR_H - self.h) // 2
        out = np.zeros((m['planes'], SCR_H, rb), np.uint8)
        if m['kind'] == 'idx':
            scr = self.pix[:, :, 0]
        else:
            cols = np.arange(sw)
            scr = self.pix[:, cols // xs, np.array((0, 1, 2, 1))[cols % 4]]
        for k in range(m['data']):
            bits = (scr >> k) & 1
            out[k, y0:y0 + self.h, :sw // 8] = np.packbits(bits, axis=1)
        if m['kind'] == 'ham':
            out[m['data'], y0:y0 + self.h, :sw // 8] = 0xDD
            out[m['data'] + 1, y0:y0 + self.h, :sw // 8] = 0x77
        return out.tobytes()


def clip_frames(path):
    data = open(path, 'rb').read()
    head = None
    for typ, flags, pts, pl in cpks_packets(data):
        if typ == 1 and head is None:
            head = (rd16(pl, 4), rd16(pl, 6))
        elif typ == 2:
            yield head, pl


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('clip', nargs='?')
    ap.add_argument('mode', nargs='?', choices=tuple(MODES))
    ap.add_argument('--hashes', help='je Bild "nummer md5" schreiben')
    ap.add_argument('--compare', help='Plane-Dump (alle Bilder hintereinander)')
    ap.add_argument('--frames', type=int, default=0)
    ap.add_argument('--hash-dump', help='nur Hashes eines Plane-Dumps bilden')
    ap.add_argument('--planes', type=int, default=5)
    ap.add_argument('--rb', type=int, default=RB, help='Byte je Zeile (40, doppelt breit 80)')
    a = ap.parse_args()

    if a.hash_dump:
        fsz = a.planes * SCR_H * a.rb
        lines = []
        with open(a.hash_dump, 'rb') as fh:
            n = 0
            while True:
                b = fh.read(fsz)
                if len(b) < fsz:
                    break
                lines.append('%d %s' % (n, hashlib.md5(b).hexdigest()))
                n += 1
        open(a.hashes, 'w').write('\n'.join(lines) + '\n')
        print('%d Bilder aus %s' % (n, a.hash_dump))
        return 0

    dec = None
    ref = open(a.compare, 'rb') if a.compare else None
    lines, bad, n = [], 0, 0
    for head, f in clip_frames(a.clip):
        if dec is None:
            dec = Decoder(head[0], head[1], a.mode)
        err = dec.decode(f)
        if err:
            print('Bild %d: %s' % (n, err))
        pl = dec.planes()
        lines.append('%d %s' % (n, hashlib.md5(pl).hexdigest()))
        if ref is not None:
            r = ref.read(len(pl))
            if r != pl:
                bad += 1
                if bad <= 3:
                    j = next((i for i in range(min(len(r), len(pl))) if r[i] != pl[i]), len(r))
                    rb = RB * MODES[a.mode].get('xs', 1)
                    print('ABWEICHUNG Bild %d Byte %d (Plane %d, Zeile %d, Byte %d)' % (
                        n, j, j // (SCR_H * rb), (j % (SCR_H * rb)) // rb, j % rb))
        n += 1
        if a.frames and n >= a.frames:
            break
    if a.hashes:
        open(a.hashes, 'w').write('\n'.join(lines) + '\n')
    if ref is not None:
        print('frames %d, deviating %d (%s, %s)' % (n, bad, a.mode, a.clip))
    else:
        print('Bilder %d (%s)' % (n, a.mode))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
