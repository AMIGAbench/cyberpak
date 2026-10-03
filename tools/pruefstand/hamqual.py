#!/usr/bin/env python3
"""hamqual - picture quality of the HAM modes: round or truncate the levels.

Decodes a CPKS clip with cvidref (RGB reference), forms the HAM commands of a
mode from it and plays them back the way the chipset displays them:
every row starts with COLOR00 (black), every screen pixel changes exactly
one component (screen column mod 4 = blue, green, red, green), the others
stay as they are. PSNR against the RGB picture is measured; at double width
against the mean of the two screen pixels of one source pixel (on the
tube the screen is just as wide).

Display of a level c:
  HAM6 (4 bit)  c*17 (12-bit colour as on ECS) or c*16 (upper 4 bits set,
                lower 4 held from black - as AGA describes it for HAM8)
  HAM8 (6 bit)  c*4 (upper 6 bits set, lower 2 held; AGA guide)

Call: hamqual.py <clip.cpks> [...]   Needs numpy. Measurement only, no test."""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cvidref  # noqa: E402

PAT = np.array((2, 1, 0, 1))          # Index in (R, G, B): Blau, Gruen, Rot, Gruen

STUFEN = {
    'h4 rund':  lambda v: (v.astype(np.int32) * 15 + 127) // 255,
    'h4 ab':    lambda v: v.astype(np.int32) >> 4,
    'h6 rund':  lambda v: np.minimum(63, (v.astype(np.int32) + 2) >> 2),
    'h6 ab':    lambda v: v.astype(np.int32) >> 2,
}

# (name, width factor, levels, display)
FAELLE = [
    ('HAM6 c*17', 1, ('h4 rund', 'h4 ab'), lambda c: c * 17),
    ('HAM6 c*16', 1, ('h4 rund', 'h4 ab'), lambda c: c * 16),
    ('DHAM6 c*17', 2, ('h4 rund', 'h4 ab'), lambda c: c * 17),
    ('DHAM6 c*16', 2, ('h4 rund', 'h4 ab'), lambda c: c * 16),
    ('DHAM8 c*4', 2, ('h6 rund', 'h6 ab'), lambda c: c * 4),
]


def zeige(rgb, xs, stufe, anzeige):
    """rgb (h, w, 3) uint8 -> displayed picture (h, w, 3) float, at xs=2 the
    mean of the two screen pixels."""
    h, w, _ = rgb.shape
    sw = w * xs
    cols = np.arange(sw)
    src = cols // xs
    comp = PAT[cols % 4]
    wert = anzeige(STUFEN[stufe](rgb[:, src, comp])).astype(np.float64)   # (h, sw)
    scr = np.zeros((h, sw, 3))
    for k in range(3):
        gesetzt = comp == k
        idx = np.where(gesetzt, cols, -1)
        idx = np.maximum.accumulate(idx)                  # letzte setzende Spalte
        spalte = np.where(idx >= 0, idx, 0)
        v = wert[:, spalte]
        scr[:, :, k] = np.where(idx >= 0, v, 0.0)
    if xs == 2:
        scr = (scr[:, 0::2] + scr[:, 1::2]) / 2
    return scr


def main():
    for clip in sys.argv[1:]:
        dec = None
        se = {(f[0], s): 0.0 for f in FAELLE for s in f[2]}
        n = 0
        for head, fr in cvidref.clip_frames(clip):
            if dec is None:
                dec = cvidref.Decoder(head[0], head[1], 'rgb32')
            dec.decode(fr)
            rgb = dec.pix[:, :, 1:4]
            for name, xs, stufen, anz in FAELLE:
                for s in stufen:
                    d = zeige(rgb, xs, s, anz) - rgb
                    se[(name, s)] += float(np.mean(d * d))
            n += 1
        print('%s, %d Bilder' % (os.path.basename(clip), n))
        for name, xs, stufen, anz in FAELLE:
            txt = '  %-11s' % name
            for s in stufen:
                mse = se[(name, s)] / n
                txt += '  %s %5.2f dB' % (s, 10 * math.log10(255 * 255 / mse))
            print(txt)


if __name__ == '__main__':
    main()
