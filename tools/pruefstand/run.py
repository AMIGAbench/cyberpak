#!/usr/bin/env python3
"""run.py - run an Amiga program in the test rig.

  run.py <program> [--file NAME=HOSTPATH ...] [--nofast] [--trace] -- <arguments>

Prints the program's output, the return code, the OS calls and everything
that is still allocated or open after it has ended. Returns 1 when the
program has not released something or the test rig had to abort."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from amiga import Amiga, TimerDevice, Pruefabbruch  # noqa: E402


def main():
    argv = sys.argv[1:]
    prog_args = []
    if '--' in argv:
        i = argv.index('--')
        argv, prog_args = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument('programm')
    ap.add_argument('--file', action='append', default=[])
    ap.add_argument('--nofast', action='store_true')
    ap.add_argument('--trace', action='store_true')
    ap.add_argument('--calls', action='store_true')
    a = ap.parse_args(argv)
    am = Amiga(fast_kb=0 if a.nofast else 8192, trace=a.trace)
    am.add_device(TimerDevice())
    for f in a.file:
        name, _, path = f.partition('=')
        am.files[name] = path
    rc = 0
    try:
        code = am.run(a.programm, ' '.join(prog_args))
    except Pruefabbruch as e:
        sys.stdout.write(am.stdout.decode('latin-1'))
        print('[TEST RIG] aborted: %s' % e)
        return 1
    sys.stdout.write(am.stdout.decode('latin-1'))
    print('[TEST RIG] return %d, virtual time %.1f ms' % (code, am.now / 1000))
    for h in am.hunks:
        print('[TEST RIG] hunk 0x%06x %6d bytes %s' % h)
    if a.calls:
        for k in sorted(am.calls):
            print('[TEST RIG]   %-28s %d' % (k, am.calls[k]))
    lk = am.leaks()
    for x in lk:
        print('[TEST RIG] NOT RELEASED: %s' % x)
        rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
