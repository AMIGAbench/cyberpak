#!/usr/bin/env python3
"""gen_a68k_tabellen - build the tables of the 68000 player.

Writes src/a68k/tabellen.bin (the data) and src/a68k/tabellen.s (labels at the
right places, through incbin). Content and layout as they used to be in C
(src/yuv.c, build_patterns/build_clut8 and the HAM6 tables of the planar
path):

  UB UG VR VG yTab               256 int16 each, big endian (tab_wort = yTab;
                                 UB -2048, UG -1536, VR -1024, VG -512). The
                                 chroma tables are indexed with the RAW u/v
                                 byte (rotated by 128).
  clr8 clg8 clb8                 1408 bytes each, index -256..1151 (tab_r8 etc.
                                 point at index 0)
  patblk                         65536 bytes (tab_pat = middle)
  n4hi n4lo                      1408 bytes each (tab_n4hi/lo at index 0)
  h6tab                          4096 bytes (tab_h6 = start)

The fast codebook routines (src/asm/cvidp_mkcb000.s, cvidh_mkcb.s) take LARGE
clamp tables, indexed directly with (_y + c): entry s = small[s >> 6]. Those are
built by cvid_open at runtime from the small ones, only for the chosen mode (up
to 119 KB). Their bounds are in tabellen.i.
Call: python3 tools/gen_a68k_tabellen.py"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'src', 'a68k')
BIAS, SIZE = 256, 1408


def yuv_tables():
    ub, vr, ug, vg, yt = [], [], [], [], []
    for cnt in range(256):
        x = 2 * cnt - 255
        ub.append((14301 * x + 250 * 32) // 250)
        vr.append((11341 * x + 250 * 32) // 250)
        ug.append((-71953 * x) // 6250)
        vg.append((-145953 * x + 6250 * 32) // 6250)
        yt.append((cnt << 6) + (cnt >> 2))
    return ub, vr, ug, vg, yt


def rng(i):
    """rngLimit at table position i (value i - 256)."""
    v = i - BIAS
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
    """8-bit share to the next HAM6 level 0..15 (displayed as c*17): ROUNDED.
    Truncating (v >> 4) made dark darker and bright brighter, with errors up to
    15; rounded it is +0.5 dB at the same number of cycles."""
    return (v * 15 + 127) // 255


def lev(v, lv):
    return (v * (lv - 1) + 127) // 255


def patterns():
    blk = bytearray(65536)
    pat = 32768
    for i0 in range(32):
        for i1 in range(32):
            p = (i0 << 5) | i1
            v4 = pat - 32768 + (p << 5)
            l = pat + (p << 4)
            r = pat + 16384 + (p << 4)
            for k in range(5):
                a, b = (i0 >> k) & 1, (i1 >> k) & 1
                nib = (a << 3) | (a << 2) | (b << 1) | b
                two = (a << 1) | b
                blk[l + k] = blk[l + 5 + k] = nib << 4
                blk[r + k] = blk[r + 5 + k] = nib
                blk[v4 + k] = two << 6
                blk[v4 + 5 + k] = two << 4
                blk[v4 + 10 + k] = two << 2
                blk[v4 + 15 + k] = two
    return bytes(blk)


def h6tab():
    t = bytearray(4096)
    for i in range(256):
        for k in range(4):
            a, b = (i >> (4 + k)) & 1, (i >> k) & 1
            t[8 * i + k] = a << 7 | b << 6
            t[8 * i + 4 + k] = a << 3 | b << 2
            t[2048 + 8 * i + k] = a << 5 | b << 4
            t[2048 + 8 * i + 4 + k] = a << 1 | b
    return bytes(t)


def grenzen():
    """Range of (_y + c) per large clamp table: (lo, hi)."""
    ub, vr, ug, vg, yt = yuv_tables()
    cg = [a + b for a in ug for b in vg]
    ymax = max(yt)
    return {'N4HI': (min(min(ub), min(vr)), ymax + max(max(ub), max(vr))),
            'N4LO': (min(cg), ymax + max(cg)),
            'R8': (min(vr), ymax + max(vr)),
            'G8': (min(cg), ymax + max(cg)),
            'B8': (min(ub), ymax + max(ub))}


def main():
    data = bytearray()
    ub, vr, ug, vg, yt = yuv_tables()
    roh = lambda t: [t[u ^ 0x80] for u in range(256)]
    for t in (roh(ub), roh(ug), roh(vr), roh(vg), yt):
        data += struct.pack('>256h', *t)
    data += bytes(lev(rng(i), 4) * 8 for i in range(SIZE))
    data += bytes(lev(rng(i), 4) * 2 for i in range(SIZE))
    data += bytes(lev(rng(i), 2) for i in range(SIZE))
    data += patterns()
    data += bytes(h4(rng(i)) << 4 for i in range(SIZE))
    data += bytes(h4(rng(i)) for i in range(SIZE))
    data += h6tab()
    open(os.path.join(OUT, 'tabellen.bin'), 'wb').write(data)

    # Pieces with labels at the places the routines point at.
    parts = [(None, 4 * 512), ('tab_wort', 512),
             (None, BIAS), ('tab_r8', SIZE - BIAS), (None, BIAS), ('tab_g8', SIZE - BIAS),
             (None, BIAS), ('tab_b8', SIZE - BIAS),
             (None, 32768), ('tab_pat', 32768),
             (None, BIAS), ('tab_n4hi', SIZE - BIAS), (None, BIAS), ('tab_n4lo', SIZE - BIAS),
             ('tab_h6', 4096)]
    assert sum(n for _, n in parts) == len(data)
    lines = ['; tabellen.s - GENERATED by tools/gen_a68k_tabellen.py, do not edit by hand.',
             '', '        section tabellen,data', '',
             '        xdef    ' + ','.join(n for n, _ in parts if n), '']
    off = 0
    for name, n in parts:
        lab = (name + ':') if name else ''
        lines.append('%-12s incbin  "tabellen.bin",%d,%d' % (lab, off, n))
        off += n
    open(os.path.join(OUT, 'tabellen.s'), 'w').write('\n'.join(lines) + '\n')
    inc = ['; tabellen.i - GENERATED by tools/gen_a68k_tabellen.py, do not edit by hand.',
           '; Large clamp tables: index (_y + c) from LO to LO + LEN - 1.', '']
    for k, (lo, hi) in grenzen().items():
        assert -32768 <= lo and hi <= 32767 and hi - lo + 1 <= 65535, k
        inc.append('GR_%s_LO  equ %d' % (k, lo))
        inc.append('GR_%s_LEN equ %d' % (k, hi - lo + 1))
    open(os.path.join(OUT, 'tabellen.i'), 'w').write('\n'.join(inc) + '\n')
    print('tabellen.bin: %d bytes' % len(data))


if __name__ == '__main__':
    main()
