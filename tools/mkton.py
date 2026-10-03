#!/usr/bin/env python3
"""mkton - a CPKS stream with a known test tone, for listening tests.

What for: the AHI path is the only one that plays 16 bit as it is, and 16 bit
in the stream is signed LITTLE endian while ahi.device wants the m68k word
order. If that swap were wrong, the result would not be a slightly wrong
sound - it would be loud noise. A clip with a clean tone makes that audible in
one second, which no hash can do: the Amiga is the only machine with a real
ahi.device.

The tone is deliberately asymmetric: the left channel is a sine of 440 Hz, the
right one of 554 Hz (a major third above). So a listener hears at once whether
the channels are swapped, whether one is silent, and whether the pitch is
right - a wrong sample rate shifts both, a wrong byte order destroys both.

The video side is drop frames (empty ##dc chunks, "repeat the picture"), so
the clip tests nothing but the sound. Call it with NOVIDEO.

  tools/mkton.py <out.cpks> [--rate 22050] [--bits 16] [--chans 2]
                            [--seconds 8] [--fps 12]
"""
import argparse
import math
import struct


def paket(out, typ, flags, pts, pl):
    out += b'CPKS' + bytes([typ, flags]) + struct.pack('>HII', 0, pts, len(pl)) + pl
    out += bytes((4 - (len(pl) & 3)) & 3)


def sample(i, rate, hz, bits):
    v = math.sin(2.0 * math.pi * hz * i / rate) * 0.7
    if bits == 8:
        return bytes([max(0, min(255, int(round(v * 127.0)) + 128))])
    q = max(-32768, min(32767, int(round(v * 32767.0))))
    return struct.pack('<h', q)          # signed little endian, as in the AVI


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--rate', type=int, default=22050)
    ap.add_argument('--bits', type=int, default=16, choices=(8, 16))
    ap.add_argument('--chans', type=int, default=2, choices=(1, 2))
    ap.add_argument('--seconds', type=float, default=8.0)
    ap.add_argument('--fps', type=int, default=12)
    a = ap.parse_args()

    out = bytearray()
    paket(out, 1, 0, 0, struct.pack('>HHHHIIIIBBHII', 1, 0, 320, 180,
                                    a.fps, 1, a.rate, a.rate,
                                    a.chans, a.bits, 0, 0x63766964, a.rate // 2))
    je_bild = a.rate // a.fps
    pos = 0
    for n in range(int(a.seconds * a.fps)):
        paket(out, 2, 1 if n % a.fps == 0 else 0, pos, b'')   # drop frame
        pcm = bytearray()
        for i in range(pos, pos + je_bild):
            pcm += sample(i, a.rate, 440.0, a.bits)
            if a.chans == 2:
                pcm += sample(i, a.rate, 554.37, a.bits)
        paket(out, 3, 0, pos, bytes(pcm))
        pos += je_bild
    open(a.out, 'wb').write(bytes(out))
    print('%s: %d bytes, %d Hz, %d bit, %d channels, %.1f s'
          % (a.out, len(out), a.rate, a.bits, a.chans, a.seconds))


main()
