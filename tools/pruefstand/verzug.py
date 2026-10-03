#!/usr/bin/env python3
"""verzug.py - the main loop under load: the player in the test rig with
decoder times per frame from the time model (A600, 68000 @ 28 MHz).

Time only passes where it goes on the A600: on entering
cvid_decode the clock jumps by the model time of that frame, per read pass
by `--pump-ms`. Everything else costs nothing here. What STATS
reports is printed (shown, dropped, backlog, run time) and how often Paula ran dry.

  verzug.py <clip> <modellzeiten.txt> [HAM6] [--pump-ms 2]"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pruefe  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('clip')
    ap.add_argument('modell')
    ap.add_argument('modus', nargs='?', default='')
    ap.add_argument('--pump-ms', type=float, default=2.0)
    a = ap.parse_args()
    zeiten = [float(x) for x in open(a.modell)]
    n = [0]

    def after(am):
        def dekodieren():
            am.now += zeiten[min(n[0], len(zeiten) - 1)] * 1000.0
            n[0] += 1

        def pumpen():
            am.now += a.pump_ms * 1000.0
        am.hook_symbol('cvid_decode', dekodieren)
        am.hook_symbol('pumpen', pumpen)
    am, rc, out, err = pruefe.lauf('%s %s STATS' % (a.clip, a.modus), after_load=after, us_per_byte=0)
    if err:
        print('[TEST RIG] aborted:', err)
        return 1
    for zeile in out.splitlines():
        if re.search(r'Time:|PLANAR:|Lateness|shown|Sound: channel|Memory', zeile):
            print(zeile)
    dev = am.devices['audio.device']
    print('  Paula ran dry (test rig): left %d, right %d; run time %.2f s; return %s' % (
        dev.leer[1], dev.leer[2], am.now / 1e6, rc))
    return 0


if __name__ == '__main__':
    sys.exit(main())
