#!/usr/bin/env python3
"""busvergleich.py - chip bus accesses per frame, direct path against C2P, BOTH
paths really counted.

busmodell.py had only a model for the C2P path (Kalms writes longwords).
This tool counts in the test rig between bild_da and bild_fertig of a
BENCH run - decoding and, on the chunky path, the C2P -, separated by
read/write and access width: the direct path with the normal
020/030 build, the C2P path with the check variant KERNWEG=080 (the 68080's path,
all chipset modes through C2P). Build both beforehand:
  tools/mk.sh CPU=68020   and   tools/mk.sh CPU=68020 KERNWEG=080

Evaluated with the A1200 bus times calibrated on the Vampire (NOTES,
"Messhuerde nachgerechnet"): byte and word 0.87 us, longword 0.72 us (one cycle
on the 32-bit bus). The CPU share is missing here - FS-UAE respectively
the throttled Vampire supplies that.

Call: busvergleich.py [--bilder 60]     (needs unicorn)"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pruefe as P  # noqa: E402
import pruefe020 as Q  # noqa: E402
import busmodell as B  # noqa: E402

US_KURZ = 0.87
US_LANG = 0.72
EXE = {'direkt': os.path.join(P.ROOT, 'build.m68020/CyberPak.dbg'),
       'C2P': os.path.join(P.ROOT, 'build.m68020.kern080/CyberPak.dbg')}


def zaehle(data, modus, weg, bilder):
    from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
    stand = []
    z = {'lk': 0, 'll': 0, 'sk': 0, 'sl': 0}

    def setup_after(am):
        def rd(uc, acc, addr, size, val, ud):
            z['ll' if size == 4 else 'lk'] += 1

        def wr(uc, acc, addr, size, val, ud):
            z['sl' if size == 4 else 'sk'] += 1
        am.u.hook_add(UC_HOOK_MEM_READ, rd, begin=0x1000, end=0x1FFFFF)
        am.u.hook_add(UC_HOOK_MEM_WRITE, wr, begin=0x1000, end=0x1FFFFF)

        def da():
            for k in z:
                z[k] = 0

        def fertig():
            stand.append(dict(z))
        am.hook_symbol('bild_da', da)
        am.hook_symbol('bild_fertig', fertig)
    wort, chipset, np_, bpl, _ = Q.MODI[modus]
    am, rc, out, err = P.lauf('test.cpks %s BENCH=%d NOAUDIO' % (wort, bilder), exe=EXE[weg], cpu=Q.CPU,
                              files={'test.cpks': P.als_datei(data)}, chipset=chipset, us_per_byte=0,
                              after_load=setup_after)
    if err or rc:
        raise SystemExit('%s %s: rc %r %r %s' % (modus, weg, rc, err, out[-300:]))
    weg_ist = 'C2P' if 'C2P' in Q.zeile(out, 'Ausgabe:') else 'direkt'
    n = len(stand)
    return weg_ist, n, {k: sum(s[k] for s in stand) / n for k in z}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bilder', type=int, default=60)
    a = ap.parse_args()
    print('chip bus accesses per frame (%d frames, BENCH), byte/word %.2f us, longword %.2f us'
          % (a.bilder, US_KURZ, US_LANG))
    print('%-9s %-6s %-6s %9s %9s %9s %9s %8s' % ('Clip', 'Modus', 'Weg', 'lesen', 'lesen L', 'schreiben',
                                                  'schreib L', 'Bus ms'))
    for clip, path in B.CLIPS.items():
        data = B.schneiden(path, a.bilder)
        for modus in Q.MODI:
            for weg in ('direkt', 'C2P'):
                ist, n, z = zaehle(data, modus, weg, a.bilder)
                ms = ((z['lk'] + z['sk']) * US_KURZ + (z['ll'] + z['sl']) * US_LANG) / 1000
                print('%-9s %-6s %-6s %9.0f %9.0f %9.0f %9.0f %8.1f' % (clip, modus, ist, z['lk'], z['ll'], z['sk'],
                                                                      z['sl'], ms), flush=True)


if __name__ == '__main__':
    main()
