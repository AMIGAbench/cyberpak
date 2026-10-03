#!/usr/bin/env python3
"""Produces tests/clips/only3200.cpks - material for the 0x3200 block chunk.

The chunk occurs in NO real test clip (neither test320 nor goku600a
contains it), was therefore untested, and an assembler version for it was
measured 22 % slower than the C code - unnoticed until this material
existed. Every frame consists of nothing but a full V1 codebook (0x2200)
and a 0x3200 chunk with one index per block.
"""
import struct, random
W, H = 320, 180
NB = (W // 4) * (H // 4)
random.seed(4711)

def chunk(cid, payload):
    return struct.pack('>HH', cid, len(payload) + 4) + payload

def frame(n):
    cb = bytearray()
    for i in range(256):
        cb += bytes([(i*7+n) & 0xff, (i*11) & 0xff, (i*13) & 0xff,
                     (i*17) & 0xff, (i*3) & 0xff, (i*5) & 0xff])
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
open('tests/clips/only3200.cpks', 'wb').write(out)
print(f"only3200.cpks: {len(out)} Bytes, 40 Frames")
