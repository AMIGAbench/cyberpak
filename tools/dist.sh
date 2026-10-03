#!/bin/sh
# dist.sh - builds CyberPak for all six CPUs and collects the players in dist/.
#
# WHAT FOR: the build directories (build.m68020, build.m68020.noasm, ...) are
# intermediate states and grow to dozens of them. dist/ holds only the
# result: one player per CPU, plus MD5 sums and the state (commit, date).
# Everything in it can be reproduced from the sources at any time, so dist/
# is not in the repository (.gitignore).
#
# NOT in dist/: the .dbg versions with symbols (the test rig needs those,
# not the user), the test programs (selftest, cvidbench, readbench,
# modelist, beep) and the comparison builds (NOASM=1, NOMKCB=1, VARIANT=...,
# KERNWEG=080). Those are built individually when needed, see the Makefile header.
#
# Call:  tools/dist.sh          builds what is needed and fills dist/
#        tools/dist.sh -n       only collects, builds nothing (must be built)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BAUEN=1
[ "${1:-}" = "-n" ] && BAUEN=0

# CPU:suffix - the same mapping as SUFFIX_* in the Makefile.
ZIELE="68000:000 68020:020 68030:030 68040:040 68060:060 68080:080"

mkdir -p dist

for z in $ZIELE; do
    cpu=${z%:*}
    sfx=${z#*:}
    [ "$BAUEN" = 1 ] && tools/mk.sh CPU="$cpu"
    bin="build.m$cpu/CyberPak.$sfx"
    [ -f "$bin" ] || { echo "[dist] $bin missing -- run tools/mk.sh CPU=$cpu first" >&2; exit 1; }
    cp -f "$bin" "dist/CyberPak.$sfx"
done

( cd dist && md5sum CyberPak.* > MD5SUMS )

{   echo "CyberPak - state of these binaries"
    echo
    echo "Built:   $(date '+%Y-%m-%d %H:%M')"
    echo "Commit:  $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT" diff --quiet 2>/dev/null || echo ' (with uncommitted changes)')"
    echo
    echo "Which player for which CPU:"
    echo "  CyberPak.000   68000 (assembler, ECS; HAM6 and GRAY with 5 planes)"
    echo "  CyberPak.020   68020 \\"
    echo "  CyberPak.030   68030 /  one binary, byte-identical (assembler)"
    echo "  CyberPak.040   68040 \\"
    echo "  CyberPak.060   68060  >  C builds"
    echo "  CyberPak.080   68080 /  (the 68080 additionally with AMMX)"
    echo
    echo "Rebuild:     tools/dist.sh        (builds everything and refills dist/)"
    echo "Collect only: tools/dist.sh -n    (when build.m* is already up to date)"
    echo "Test rig:    tools/mk.sh CPU=68000  or  CPU=68020  (needs the .dbg)"
} > dist/README.txt

echo "[dist] ready:"
sed 's/^/  /' dist/MD5SUMS
