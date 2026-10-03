#!/usr/bin/env python3
"""Produces a CPKS stream with a width that is NOT a multiple of 32.

What for: the native output path demands of Kalms' converters a width that is a
multiple of 32 and knows no horizontal modulo. Odd widths used to be
rejected outright ("kein brauchbarer Bildschirmmodus");
since c2p_pad_width() the screen is rounded up and the picture centred.

300 is divisible by 4 (Cinepak works in 4x4 blocks), but not by
32 - so the screen becomes 320 wide and the picture sits in it with an offset of 8.

The stream deliberately does NOT lie in tests/clips: the arithmetic itself is
checked by tests/c2ptest.c on the host, and for the emulator run a file
in clips/ is enough. Call:  python3 tests/mkodd.py clips/odd300.cpks
"""
import struct, random, sys

W, H = 300, 176
NB = (W // 4) * (H // 4)
random.seed(4711)

def chunk(cid, payload):
    return struct.pack('>HH', cid, len(payload) + 4) + payload

def frame(n):
    cb = bytearray()
    for i in range(256):
        cb += bytes([(i * 7 + n) & 0xff, (i * 11) & 0xff, (i * 13) & 0xff,
                     (i * 17) & 0xff, (i * 3) & 0xff, (i * 5) & 0xff])
    body = chunk(0x2200, bytes(cb)) + \
           chunk(0x3200, bytes(random.randrange(256) for _ in range(NB)))
    strip = struct.pack('>HHHHHH', 0x1000, 12 + len(body), 0, 0, H, W) + body
    total = 10 + len(strip)
    return bytes([0]) + total.to_bytes(3, 'big') + struct.pack('>HHH', W, H, 1) + strip

out = bytearray()
def put(t, flags, pts, payload):
    out.extend(b'CPKS' + bytes([t, flags]) + struct.pack('>HII', 0, pts, len(payload)))
    out.extend(payload)
    out.extend(b'\0' * ((4 - (len(payload) & 3)) & 3))

put(1, 0, 0, struct.pack('>HHHHIIII', 1, 0, W, H, 25, 1, 1000, 0)
             + bytes([1, 8, 0, 0]) + b'cvid' + struct.pack('>I', 0))
for n in range(40):
    put(2, 1, n * 40, frame(n))

path = sys.argv[1] if len(sys.argv) > 1 else 'clips/odd300.cpks'
open(path, 'wb').write(out)
print(f"{path}: {len(out)} Bytes, 40 Frames, {W}x{H}")
