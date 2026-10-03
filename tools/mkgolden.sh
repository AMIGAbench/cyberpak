#!/usr/bin/env bash
# Recreates the golden baseline: the frame hashes AND the identity of the
# input files. Only call it when the test clips have changed on purpose -
# otherwise it hides a real regression.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# The source material (AVI) is not in the repository; directory through CLIPDIR.
CLIPDIR="${CLIPDIR:-clips}"
BIN=build.x86_64/cvidtest

mkdir -p build.x86_64 tests/golden
gcc -O2 -std=gnu99 -Wall -Wextra -Isrc \
    host/hostmain.c src/avi.c src/yuv.c src/codec/cvid.c src/palq.c -o "$BIN"

for n in 320x180 640x360; do
  f="$CLIPDIR/Inception_cinepak_$n.avi"
  md5sum < "$f" | cut -d' ' -f1 > "tests/golden/$n.clip.md5"
  for m in rgb32 gray; do
    flag=""; [ "$m" = gray ] && flag="--gray"
    "$BIN" --hash $flag "$f" 2>/dev/null > "tests/golden/$n.$m.hash"
    printf '  %-16s %s\n' "$n.$m" "$(tail -1 "tests/golden/$n.$m.hash")"
  done
done
echo "Baseline recreated."
