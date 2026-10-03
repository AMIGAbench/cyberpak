#!/usr/bin/env python3
"""Produces tests/clips/bigcb.cvid - a codebook that announces more than 256
entries.

WHAT FOR: the FULL codebook form (0x2000/0x2200) had no limit. The
C code computed `n = cSize / 6` and wrote n entries - but `cSize` comes
from the bitstream and can become up to 65531, so up to 10921 entries. The
codebook has 256. It thus wrote far past the block into the
shared pool of all strips; with a strip near the end it even runs
past the pool.

The PARTIAL form has always checked it (`ci < 256`), the full one has not. It
does not occur in real material - which is exactly why it never shows up
without this clip.

The clip is built so that it makes the bug maximally visible: a
0x2200 chunk with the largest possible number of entries, right in the first strip.
Under AddressSanitizer the unclamped decoder fails on it.
"""
import struct

W, H = 320, 180
NB = (W // 4) * (H // 4)
# The maximum the bitstream allows: cSize is 16 bits, so
# (65535-4)/6 = 10921 entries. The pool of all codebooks holds
# CVID_MAX_STRIPS*2*256 = 8192 entries, and maps1[0] starts at 256 -
# so 256+10921 lies 2985 entries BEHIND the pool. That is exactly what
# AddressSanitizer catches.
#
# With fewer (2048 say) it does run past the 256 block and
# destroys the codebooks of other strips, but stays inside the pool - and ASAN
# says nothing. The first attempt at this test walked right past that.
# The STRIP size is 16 bits as well. With a 12-byte strip header and a 4-byte
# chunk header, (65535-12-4)/6 = 10919 entries remain. 256+10919 = 11175
# lies 2983 entries behind the pool - that is enough.
ENTRIES = 10919

def chunk(cid, payload):
    return struct.pack('>HH', cid, len(payload) + 4) + payload

def frame(n):
    cb = bytearray()
    for i in range(ENTRIES):
        cb += bytes([(i * 7 + n) & 0xff, (i * 11) & 0xff, (i * 13) & 0xff,
                     (i * 17) & 0xff, (i * 3) & 0xff, (i * 5) & 0xff])
    # The codebook only - a block chunk no longer fits beside it into the
    # 16-bit strip size, and it is not needed for this test
    # either: the overflow happens during the build, not during drawing.
    body = chunk(0x2200, bytes(cb))
    strip = struct.pack('>HHHHHH', 0x1000, 12 + len(body), 0, 0, H, W) + body
    total = 10 + len(strip)
    return bytes([0]) + total.to_bytes(3, 'big') + struct.pack('>HHH', W, H, 1) + strip

# A RAW Cinepak frame, no container: the CPKS reader limits a packet
# to 32 KB (real frames are far smaller), and for this test the
# shell is irrelevant anyway - what is checked is the codebook build.
open('tests/clips/bigcb.cvid', 'wb').write(frame(0))
print("bigcb.cvid: %d Bytes, %d Codebook-Eintraege" % (len(frame(0)), ENTRIES))
