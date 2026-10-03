#!/usr/bin/env bash
# Host regression test. Runs in seconds and is the net every
# optimisation is checked against: tolerance exactly 0 against tests/golden/*.hash.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The source material (AVI) is not in the repository; directory through CLIPDIR.
CLIPDIR="${CLIPDIR:-clips}"
BIN=build.x86_64/cvidtest
fail=0
mkdir -p build.x86_64          # otherwise the first run fails on the missing target

echo "== Build =="
gcc -O2 -std=gnu99 -Wall -Wextra -Isrc \
    host/hostmain.c src/avi.c src/yuv.c src/codec/cvid.c -lm -o "$BIN" || exit 1
gcc -O1 -g -std=gnu99 -Wall -Wextra -Isrc -fsanitize=address,undefined \
    host/hostmain.c src/avi.c src/yuv.c src/codec/cvid.c -lm -o "$BIN.asan" || exit 1

echo "== Table self test =="
gcc -O2 -std=gnu99 -Isrc tests/selftest.c src/yuv.c -lm -o build.x86_64/selftest && \
  ./build.x86_64/selftest || fail=1

echo "== Sanitizer (first 30 frames per clip) =="
for n in 320x180 640x360; do
  "$BIN.asan" --frames 30 "$CLIPDIR/Inception_cinepak_$n.avi" >/dev/null 2>&1 \
    && echo "  $n ok" || { echo "  $n FAILED"; fail=1; }
done

echo "== Identity of the test clips =="
# The clips lie outside the project and are used by other projects as
# well. If a file is re-encoded, all hashes inevitably change - that is then
# NOT a decoder bug. The identity of the input is therefore checked
# separately and reported separately.
clip_changed=0
for n in 320x180 640x360; do
  f="$CLIPDIR/Inception_cinepak_$n.avi"
  [ -f "$f" ] || { echo "  $n  MISSING: $f"; fail=1; continue; }
  got=$(md5sum < "$f" | cut -d" " -f1)
  ref="tests/golden/$n.clip.md5"
  if [ -f "$ref" ]; then
    want=$(cat "$ref")
    if [ "$got" = "$want" ]; then
      echo "  $n  unchanged"
    else
      echo "  $n  INPUT CHANGED (md5 $got, baseline $want)"
      clip_changed=1
    fi
  else
    echo "  $n  no baseline stored"
    clip_changed=1
  fi
done

if [ $clip_changed -ne 0 ]; then
  echo
  echo "  The test clips differ from those the golden hashes were produced"
  echo "  against. The hash comparison is skipped - it would only report the"
  echo "  changed input, not the decoder."
  echo "  Recreate the baseline with:  tools/mkgolden.sh"
  echo
fi

echo "== Golden hashes (tolerance 0) =="
if [ $clip_changed -ne 0 ]; then
  echo "  skipped (input changed)"
else
  for n in 320x180 640x360; do
    for m in rgb32 gray; do
      flag=""; [ "$m" = gray ] && flag="--gray"
      got=$("$BIN" --hash $flag "$CLIPDIR/Inception_cinepak_$n.avi" 2>/dev/null | tail -1)
      want=$(tail -1 "tests/golden/$n.$m.hash")
      if [ "$got" = "$want" ]; then
        echo "  $n.$m  ok   $got"
      else
        echo "  $n.$m  DEVIATION"; echo "    got:      $got"; echo "    expected: $want"; fail=1
      fi
    done
  done
fi

echo "== 16 bit output against 32 bit (tolerance 0) =="
# The 16-bit mode has no external reference. It is therefore checked against
# the already verified 32-bit output: both read the same
# clamped values, the 16-bit path merely shifts them into place in advance.
gcc -O2 -std=gnu99 -Wall -Wextra -Isrc tests/rgb16check.c src/avi.c src/yuv.c \
    src/codec/cvid.c -lm -o build.x86_64/rgb16check || fail=1
for n in test320 goku600; do
  [ -f "tests/clips/$n.avi" ] || continue
  for f in 0 1 2 3; do
    o=$(./build.x86_64/rgb16check "tests/clips/$n.avi" $f)
    if echo "$o" | grep -q ", 0 deviating"; then
      echo "  $n  format $f  ok"
    else
      echo "  $n  format $f  DEVIATION"; echo "$o"; fail=1
    fi
  done
done

echo "== A codebook that is too large must not overflow =="
# The FULL codebook form computed n = cSize/6 and wrote n entries without
# limiting them to 256. cSize comes from the bitstream; at the largest
# possible strip size that is 10919 entries into an array of 256. The
# overflow goes past the shared pool of all strips.
#
# Under AddressSanitizer the unclamped decoder aborts here. For that the clip
# has to have the MAXIMUM number of entries - with 2048 the
# overflow stays inside the pool and ASAN says nothing.
python3 tests/mkbigcb.py >/dev/null 2>&1 || true
if [ -f tests/clips/bigcb.cvid ]; then
  gcc -O1 -g -std=gnu99 -Wall -Wextra -Isrc -fsanitize=address,undefined \
      tests/bigcbcheck.c src/yuv.c src/codec/cvid.c -lm \
      -o build.x86_64/bigcbcheck || fail=1
  o=$(./build.x86_64/bigcbcheck tests/clips/bigcb.cvid 2>&1)
  if echo "$o" | grep -q "no overflow"; then
    echo " $(echo "$o" | sed -n '1s/^ *//p')"
  else
    echo "  bigcb  OVERFLOW"; echo "$o" | head -4; fail=1
  fi
fi

echo "== CPKS path =="
gcc -O2 -std=gnu99 -Wall -Wextra -Isrc tests/cpkscheck.c src/cpks.c src/avi.c \
    src/timing.c src/yuv.c src/codec/cvid.c -lm -o build.x86_64/cpkscheck || fail=1
if [ -f tests/clips/cpkstest.cpks ] && [ -f tests/clips/cpkstest.avi ]; then
  # 1. The Cinepak bitstream MUST be identical. Both files come from
  #    the same source material and the same encoder settings; the
  #    specification claims equality, here it is verified.
  a=$(./build.x86_64/cpkscheck tests/clips/cpkstest.cpks --decode      | awk '{print $3, $6}')
  b=$(./build.x86_64/cpkscheck tests/clips/cpkstest.avi  --decode-avi  | awk '{print $3, $6}')
  if [ "$a" = "$b" ] && [ -n "$a" ]; then
    echo "  bitstream CPKS==AVI  ok   $a"
  else
    echo "  bitstream CPKS==AVI  DEVIATION"; echo "    cpks: $a"; echo "    avi : $b"; fail=1
  fi

  # 2. Playback loop. Comparison figures as in the encoder's
  #    tools/cpkssim.py: at most one frame period of offset, no frame dropped.
  #    Undisturbed only - cpkssim.py lets the position jump back on an
  #    underrun, which is deliberately not reproduced here.
  for dev in 0 5; do
    o=$(./build.x86_64/cpkscheck tests/clips/cpkstest.cpks --sim $dev)
    v=$(echo "$o" | awk '/offset/ {print $4+0}')
    d=$(echo "$o" | awk '/frames shown/ {print $7+0}')
    if [ "$v" -le 84 ] && [ "$d" -eq 0 ]; then
      echo "  loop Paula ${dev} per mille  ok   offset ${v} ms, 0 dropped"
    else
      echo "  loop Paula ${dev} per mille  DEVIATION"; echo "$o"; fail=1
    fi
  done

  # 3. Keyframe jump. cpkssim.py does NOT check that one: there the
  #    skip-ahead block is behaviour-neutral, because the simulator does not decode.
  if ./build.x86_64/cpkscheck tests/clips/cpkstest.cpks --skip | grep -q "always resumes on a keyframe"; then
    echo "  keyframe jump  ok"
  else
    echo "  keyframe jump  DEVIATION"; ./build.x86_64/cpkscheck tests/clips/cpkstest.cpks --skip; fail=1
  fi
else
  echo "  tests/clips/cpkstest.* missing - skipped"
fi

echo "== Clips of this project (golden hashes, tolerance 0) =="
# These lie IN the project and cannot change under us.
# goku600 is the only clip with TWO strips - exactly the case in which
# Cinepak keeps the codebooks per strip. Without it this path stays
# untested.
for n in test320 goku600; do
  [ -f "tests/clips/$n.avi" ] || { echo "  $n  missing"; continue; }
  for m in rgb32 gray; do
    flag=""; [ "$m" = gray ] && flag="--gray"
    got=$("$BIN" --hash $flag "tests/clips/$n.avi" 2>/dev/null | tail -1)
    want=$(tail -1 "tests/golden/$n.$m.hash")
    if [ "$got" = "$want" ]; then
      echo "  $n.$m  ok   $got"
    else
      echo "  $n.$m  DEVIATION"; echo "    got:      $got"; echo "    expected: $want"; fail=1
    fi
  done
done

echo "== Independent reference decoder (Y plane, tolerance 0) =="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for spec in "tests/clips/test320.avi 320 180 120" "tests/clips/goku600.avi 320 180 600"; do
  set -- $spec
  python3 tools/refdec.py "$1" "$TMP/ref.y" "$2" "$3" "$4" 2>/dev/null
  mkdir -p "$TMP/mine"
  "$BIN" --pgm "$TMP/mine" "$1" >/dev/null 2>&1
  python3 - "$TMP" "$2" "$3" "$4" "$1" <<'PY' || fail=1
import sys, os
tmp, w, h, nf, name = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
n = w*h
py = open(os.path.join(tmp, "ref.y"), "rb").read()
bad = 0; cnt = 0
for i in range(nf):
    p = os.path.join(tmp, "mine", "f%05d.pgm" % i)
    if not os.path.exists(p): break
    C = open(p, "rb").read().split(b"\n", 3)[3][:n]
    P = py[i*n:(i+1)*n]
    if len(P) < n: break
    cnt += 1
    if C != P: bad += 1
print("  %-26s %d frames, %d deviating" % (os.path.basename(name), cnt, bad))
sys.exit(1 if bad else 0)
PY
  rm -rf "$TMP/mine"
done

# The chipset modes (HAM6, DHAM6, DHAM8, GRAY) and the RTG output of the
# assembler players are checked by the test rig against cvidref.py:
#   tools/pruefstand/pruefe.py      (68000-Player)
#   tools/pruefstand/pruefe020.py   (020/030 player, also the chipset path of the C builds)

echo
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit $fail
