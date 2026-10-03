#!/usr/bin/env bash
# A/B measurement: what do the individual optimisations gain on real 68k semantics?
#
#   tools/ab.sh 68030 [gray]
#
# Builds four bit-identical build forms of the same decoder and measures each in FS-UAE:
#   legacy  = like the original (a multiplication per block + 80-byte codebook)
#   legaddr = only the original's address arithmetic
#   legcb   = only the original's 80-byte codebook
#   opt     = target form
#
# All four have to return the same hash - if one is off, one of
# the transformations is not behaviour-neutral.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CPU="${1:-68030}"
MODE="${2:-}"
export TIMEOUT="${TIMEOUT:-900}"

case "$CPU" in
  68000) SFX=000;; 68020) SFX=020;; 68030) SFX=030;;
  68040) SFX=040;; 68060) SFX=060;;
  *) echo "CPU $CPU not measurable (FS-UAE knows no 68080)"; exit 3;;
esac

echo "== build forms for $CPU =="
tools/mk.sh CPU="$CPU" variants >/dev/null 2>&1 || { echo "build failed"; exit 1; }

# The target form lies in build.m$CPU -- that is, exactly where the loop
# copies the build form to be measured (run.sh assumes the path fixed).
# Without this safeguard the last legacy variant overwrites the opt binary
# and the line "opt" measures legcb a second time in truth.
STASH="$(mktemp /tmp/cyberavix-opt-XXXXXX)"
cp -f "build.m$CPU/cvidbench.$SFX" "$STASH"
trap 'cp -f "$STASH" "build.m'"$CPU"'/cvidbench.'"$SFX"'" 2>/dev/null; rm -f "$STASH"' EXIT

printf '\n%-9s %-10s %-10s %s\n' "variant" "decode_ms" "fps" "hash"
for v in legacy legaddr legcb opt; do
  if [ "$v" = opt ]; then src="$STASH"; else src="build.m$CPU.$v/cvidbench.$SFX"; fi
  [ -f "$src" ] || { printf '%-9s %s\n' "$v" "BINARY MISSING: $src"; continue; }
  cp -f "$src" "build.m$CPU/cvidbench.$SFX"
  out=$(tools/run.sh "$CPU" cvidbench "clip.avi $MODE" 2>/dev/null | grep -a 'frames=')
  cp -f "logs/serial.$CPU.cvidbench.log" "logs/ab.$CPU.${MODE:-rgb32}.$v.log" 2>/dev/null
  ms=$(echo "$out"  | sed -n 's/.*decode_ms=\([0-9]*\).*/\1/p')
  fps=$(echo "$out" | sed -n 's/.*fps=\([0-9]*\).*/\1/p')
  hsh=$(echo "$out" | sed -n 's/.*hash=\([0-9a-f]*\).*/\1/p')
  printf '%-9s %-10s %-10s %s\n' "$v" "${ms:-?}" "${fps:-?}" "${hsh:-?}"
done
