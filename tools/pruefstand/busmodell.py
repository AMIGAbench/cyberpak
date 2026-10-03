#!/usr/bin/env python3
"""busmodell.py - chip bus cycles per frame: straight into the planes against chunky + C2P.

FS-UAE does not reproduce the costs of the chip bus (NOTES, A600: goku_full in
the emulator -1 %, on the hardware +13 %). For the measurement hurdle of the 020+
rework this tool counts in the test rig how many bus cycles of the 16-bit chip
bus the 020 player really needs per frame (byte and word 1, longword 2,
reading and writing), and puts the model of the C2P path beside it: Kalms
writes every plane of the picture area as longwords, so planes x bytes / 2
cycles per frame, without reading.

Call: busmodell.py [--bilder 60] [--us 0.9]     (needs unicorn)"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pruefe as P  # noqa: E402
import pruefe020 as Q  # noqa: E402
import cvidref  # noqa: E402

# Clips as in pruefe.py: directory through CYBERPAK_CLIPS, default clips/.
CLIPS = {n: os.path.join(P.CLIPDIR, n + '.cpks') for n in ('cpkstest', 'goku3200', 'goku_full')}


def schneiden(path, bilder):
    """The header packet and the first `bilder` picture packets, without sound."""
    data = open(path, 'rb').read()
    out = bytearray()
    n = 0
    off = 0
    while off + 16 <= len(data) and n < bilder:
        if data[off:off + 4] != b'CPKS':
            off = data.find(b'CPKS', off + 1)
            if off < 0:
                break
            continue
        typ = data[off + 4]
        ln = int.from_bytes(data[off + 12:off + 16], 'big')
        end = off + 16 + ln + ((4 - (ln & 3)) & 3)
        if typ == 1:
            kopf = bytearray(data[off:end])
            # arate/achans/abits to 0: a stream without sound
            out += kopf
        elif typ == 2:
            out += data[off:end]
            n += 1
        off = end
    return bytes(out)


def zaehle(data, modus):
    z = {}
    stand = []

    def setup_after(am):
        zz = am.chip_zaehler()
        z['zz'] = zz

        def da():
            zz['lesen'] = zz['schreiben'] = 0

        def fertig():
            stand.append((zz['lesen'], zz['schreiben']))
        am.hook_symbol('bild_da', da)
        am.hook_symbol('bild_fertig', fertig)
    wort, chipset, np_, bpl, _ = Q.MODI[modus]
    path = P.als_datei(data)
    am, rc, out, err = Q.lauf('test.cpks %s NOAUDIO STATS' % wort, files={'test.cpks': path},
                              chipset=chipset, us_per_byte=0, after_load=setup_after)
    if err or rc:
        raise SystemExit('%s: rc %r %r %s' % (modus, rc, err, out[-300:]))
    n = len(stand)
    return n, sum(s[0] for s in stand) / n, sum(s[1] for s in stand) / n


def c2p_zyklen(modus, h=180):
    wort, chipset, np_, bpl, _ = Q.MODI[modus]
    breite = 640 if modus.startswith('dham') else 320
    return np_ * (breite // 8) * h / 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bilder', type=int, default=60)
    ap.add_argument('--us', type=float, default=0.9, help='us per chip bus cycle (the A600 value)')
    a = ap.parse_args()
    print('chip bus cycles per frame (%d frames), evaluated with %.2f us per cycle' % (a.bilder, a.us))
    print('%-9s %-6s %9s %9s %9s %9s %9s' % ('Clip', 'Modus', 'lesen', 'schreiben', 'direkt ms', 'C2P', 'C2P ms'))
    for clip, path in CLIPS.items():
        data = schneiden(path, a.bilder)
        for modus in Q.MODI:
            n, le, sc = zaehle(data, modus)
            c2p = c2p_zyklen(modus)
            print('%-9s %-6s %9.0f %9.0f %9.1f %9.0f %9.1f' % (clip, modus, le, sc, (le + sc) * a.us / 1000,
                                                              c2p, c2p * a.us / 1000), flush=True)


if __name__ == '__main__':
    main()
